<#
.SYNOPSIS
    Merge upstream craft-native/craft into this fork's working branch, then build.

.DESCRIPTION
    Keeps a self-maintained fork current without hand-running git.

    Branch model:
      main         mirror of upstream. Fast-forward only; never committed to here.
      <Branch>     the fork's work. Syncs by MERGING upstream, not rebasing: a
                   conflict is then resolved once per upstream release instead
                   of once per local commit.

    Exit codes:
      0  nothing to do, or synced and built cleanly
      1  precondition failed (not a git repo, branch missing, fetch failed)
      2  working tree not clean -- nothing attempted
      3  merge conflict (aborted unless -KeepOnConflict)
      4  merge landed but the build failed -- not pushed
      5  built fine but the push failed

.EXAMPLE
    .\scripts\fork-sync.ps1 -Check

.EXAMPLE
    .\scripts\fork-sync.ps1

.EXAMPLE
    .\scripts\fork-sync.ps1 -NoPush -KeepOnConflict
#>
[CmdletBinding()]
param(
    [string] $Branch      = 'feat/windows-bridge-parity',
    [string] $Upstream    = 'origin',
    [string] $UpstreamRef = 'main',
    [string] $ForkRemote  = 'fork',
    [string] $BuildArgs   = '-Doptimize=ReleaseSafe',
    [switch] $Check,
    [switch] $KeepOnConflict,
    [switch] $NoBuild,
    [switch] $NoPush
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# $ErrorActionPreference = 'Stop' turns a native program's stderr into a
# terminating error, which would kill this script with no message. Every
# external call goes through here with the preference temporarily relaxed.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]   $Exe,
        [Parameter(Mandatory = $true)][string[]] $ArgList
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $lines = @()
    $code = 1
    try {
        $lines = @(& $Exe @ArgList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    [pscustomobject]@{ Code = $code; Lines = $lines }
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $ArgList)
    $result = Invoke-Native -Exe 'git' -ArgList $ArgList
    [pscustomobject]@{ Code = $result.Code; Lines = $result.Lines }
}

function Write-Step {
    param([string] $Text)
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}

function Write-Note {
    param([string] $Text)
    Write-Host "   $Text"
}

function Stop-With {
    param([int] $Code, [string] $Message, [string[]] $Detail = @())
    Write-Host ''
    Write-Host "FAILED ($Code): $Message" -ForegroundColor Red
    foreach ($line in $Detail) { Write-Host "  $line" -ForegroundColor Red }
    exit $Code
}

function Show-Lines {
    param([string[]] $Lines, [int] $Tail = 0)
    # PowerShell wraps every stderr line of a native command in a
    # RemoteException record; the text itself follows on the next line.
    $Lines = @($Lines | Where-Object { "$_" -ne 'System.Management.Automation.RemoteException' })
    if ($Tail -gt 0 -and $Lines.Count -gt $Tail) {
        Write-Note "(showing the last $Tail of $($Lines.Count) lines)"
        $Lines = $Lines[($Lines.Count - $Tail)..($Lines.Count - 1)]
    }
    foreach ($line in $Lines) { Write-Note $line }
}

# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot 'build.zig'))) {
    Stop-With -Code 1 -Message "no build.zig above $PSScriptRoot; run this from inside the craft checkout"
}
Set-Location $repoRoot

Write-Step "repository"
Write-Note "root: $repoRoot"

$gitDir = Invoke-Git @('rev-parse', '--git-dir')
if ($gitDir.Code -ne 0) {
    Stop-With -Code 1 -Message 'not a git repository' -Detail $gitDir.Lines
}

$remotes = Invoke-Git @('remote')
if ($remotes.Lines -notcontains $Upstream) {
    Stop-With -Code 1 -Message "remote '$Upstream' is not configured" -Detail $remotes.Lines
}
if (-not $NoPush -and -not $Check -and ($remotes.Lines -notcontains $ForkRemote)) {
    Stop-With -Code 1 -Message "remote '$ForkRemote' is not configured (needed to push; pass -NoPush to skip)"
}

$branchExists = Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")
if ($branchExists.Code -ne 0) {
    Stop-With -Code 1 -Message "local branch '$Branch' does not exist"
}

$currentBranch = (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Lines[0]

$dirty = Invoke-Git @('status', '--porcelain')
if ($dirty.Lines.Count -gt 0) {
    $detail = @('commit or stash these first:') + @($dirty.Lines | ForEach-Object { "    $_" })
    Stop-With -Code 2 -Message 'working tree is not clean; nothing was attempted' -Detail $detail
}

# ---------------------------------------------------------------------------
# what does upstream have that we do not
# ---------------------------------------------------------------------------

Write-Step "fetching $Upstream"
$fetch = Invoke-Git @('fetch', $Upstream, '--tags', '--prune')
if ($fetch.Code -ne 0) {
    Stop-With -Code 1 -Message "git fetch $Upstream failed" -Detail $fetch.Lines
}
Show-Lines $fetch.Lines

$upstreamTip = "$Upstream/$UpstreamRef"
$tipExists = Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/remotes/$upstreamTip")
if ($tipExists.Code -ne 0) {
    Stop-With -Code 1 -Message "upstream ref '$upstreamTip' does not exist"
}

$upstreamHead = (Invoke-Git @('log', '-1', '--format=%h %s', $upstreamTip)).Lines[0]

# Label the merge by the tag only when that tag is the tip itself. describe's
# nearest-tag answer would name a release the merge does not actually contain
# whenever upstream main is ahead of its last tag.
$exactTag = Invoke-Git @('describe', '--tags', '--exact-match', $upstreamTip)
if ($exactTag.Code -eq 0) {
    $upstreamLabel = $exactTag.Lines[0]
} else {
    $shortTip = (Invoke-Git @('rev-parse', '--short', $upstreamTip)).Lines[0]
    $upstreamLabel = "$UpstreamRef@$shortTip (post-$((Invoke-Git @('describe', '--tags', '--abbrev=0', $upstreamTip)).Lines[0]))"
}

Write-Step 'divergence'
Write-Note "upstream: $upstreamHead  [$upstreamLabel]"

$behind = [int](Invoke-Git @('rev-list', '--count', "$Branch..$upstreamTip")).Lines[0]
$ahead  = [int](Invoke-Git @('rev-list', '--count', "$upstreamTip..$Branch")).Lines[0]
Write-Note "branch ${Branch}: $ahead ahead, $behind behind"

$logSummary = Invoke-Git @('log', '--oneline', "$Branch..$upstreamTip")
if ($logSummary.Lines.Count -gt 0) {
    Write-Note "upstream commits we do not have:"
    Show-Lines $logSummary.Lines -Tail 20
}

# ---------------------------------------------------------------------------
# keep the local main mirror current (only when it is not checked out)
# ---------------------------------------------------------------------------

if ($currentBranch -ne $UpstreamRef) {
    $ffMain = Invoke-Git @('fetch', $Upstream, "${UpstreamRef}:${UpstreamRef}")
    if ($ffMain.Code -eq 0) {
        Write-Note "local '$UpstreamRef' fast-forwarded to $upstreamTip"
    } else {
        Write-Note "local '$UpstreamRef' was not fast-forwarded:"
        Show-Lines $ffMain.Lines
    }
}

if ($behind -eq 0) {
    Write-Host ''
    Write-Host 'Already in sync with upstream. Nothing to merge.' -ForegroundColor Green
    exit 0
}

if ($Check) {
    Write-Host ''
    Write-Host "Check only: $behind upstream commit(s) pending. Nothing changed." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------

if ($currentBranch -ne $Branch) {
    Write-Step "checking out $Branch"
    $checkout = Invoke-Git @('checkout', $Branch)
    if ($checkout.Code -ne 0) {
        Stop-With -Code 1 -Message "git checkout $Branch failed" -Detail $checkout.Lines
    }
    Show-Lines $checkout.Lines
}

$mergeMessage = "chore: merge upstream $upstreamLabel into $Branch"
$messageFile = Join-Path $gitDir.Lines[0] 'FORK_SYNC_MERGE_MSG.txt'
Set-Content -Path $messageFile -Value $mergeMessage -Encoding ASCII

Write-Step "merging $upstreamTip"
Write-Note "message: $mergeMessage"

$merge = Invoke-Git @('merge', '--no-ff', '-F', $messageFile, $upstreamTip)
Show-Lines $merge.Lines -Tail 30

if ($merge.Code -ne 0) {
    $conflicts = (Invoke-Git @('diff', '--name-only', '--diff-filter=U')).Lines
    $inMerge = Test-Path (Join-Path $gitDir.Lines[0] 'MERGE_HEAD')

    if (-not $inMerge) {
        Stop-With -Code 1 -Message 'git merge failed without starting a merge; nothing to resolve' -Detail $merge.Lines
    }
    if ($KeepOnConflict) {
        Write-Host ''
        Write-Host 'Merge left in progress (-KeepOnConflict). Conflicted files:' -ForegroundColor Yellow
        foreach ($file in $conflicts) { Write-Host "  $file" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host "Resolve, then:  git add <files>; git commit -F $messageFile"
        Write-Host 'Give up:        git merge --abort'
        exit 3
    }

    $null = Invoke-Git @('merge', '--abort')
    Write-Host ''
    Write-Host "Merge hit a conflict and was aborted; '$Branch' is unchanged." -ForegroundColor Yellow
    foreach ($file in $conflicts) { Write-Host "  conflicted: $file" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'Re-run with -KeepOnConflict to resolve by hand:'
    Write-Host "  .\scripts\fork-sync.ps1 -KeepOnConflict -NoPush -NoBuild"
    Write-Host "Merge message to reuse: $mergeMessage"
    exit 3
}

Write-Note 'merge landed'

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

if ($NoBuild) {
    Write-Note 'build skipped (-NoBuild)'
} else {
    Write-Step 'build'

    $zigVersion = Invoke-Native -Exe 'zig' -ArgList @('version')
    if ($zigVersion.Code -ne 0) {
        Stop-With -Code 4 -Message 'zig is not on PATH, so the merge could not be verified' -Detail $zigVersion.Lines
    }
    Write-Note "zig $($zigVersion.Lines[0])"

    # A running craft.exe holds its own binary open and blocks the build output.
    Get-Process -Name 'craft' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300

    $buildArgsList = @('build') + @($BuildArgs -split '\s+' | Where-Object { $_ })
    Write-Note "zig $($buildArgsList -join ' ')"
    $build = Invoke-Native -Exe 'zig' -ArgList $buildArgsList
    Show-Lines $build.Lines -Tail 40
    if ($build.Code -ne 0) {
        Stop-With -Code 4 -Message "build failed after the merge; '$Branch' is NOT pushed" -Detail @(
            "fix the build, or undo the merge with: git reset --hard HEAD^1",
            "to merge without verifying: .\scripts\fork-sync.ps1 -NoBuild"
        )
    }
    Write-Note 'build ok'
}

# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------

if ($NoPush) {
    Write-Note 'push skipped (-NoPush)'
} else {
    Write-Step "pushing to $ForkRemote"
    $push = Invoke-Git @('push', $ForkRemote, $Branch)
    Show-Lines $push.Lines
    if ($push.Code -ne 0) {
        Stop-With -Code 5 -Message "git push $ForkRemote $Branch failed; the merge is local only" -Detail $push.Lines
    }
    Write-Note 'pushed'
}

Write-Host ''
Write-Host "Done. $Branch is now based on $upstreamLabel ($behind upstream commit(s) merged)." -ForegroundColor Green
exit 0
