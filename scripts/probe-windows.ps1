# Runs every Windows probe against the built binary and reports one summary.
#
# Five scripts cover different parts of the surface; running them one at a time
# made it easy to skip one and call the platform verified. This is the entry
# point that runs them all.
#
# Exit codes: 0 every probe passed, 1 at least one failed, 2 nothing could run
# (no build).
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    # Build before probing. Off by default: the probes test whatever binary is
    # there, and a build takes minutes.
    [switch] $Build,
    [string] $CraftExe = '',
    # Run only these probes, by name.
    [string[]] $Only = @(),
    [int]    $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }

$probes = @(
    @{ Name = 'timers';          Script = 'probe-windows-timers.ps1';          Covers = 'deadlines, abort, concurrency' },
    @{ Name = 'capabilities';    Script = 'probe-windows-capabilities.ps1';    Covers = 'the manifest tells the truth' },
    @{ Name = 'window-state';    Script = 'probe-windows-window-state.ps1';    Covers = 'geometry, flags, focus, opacity, clipboard, oversized input' },
    @{ Name = 'single-instance'; Script = 'probe-windows-single-instance.ps1'; Covers = 'second launch hand-off and deep links' },
    @{ Name = 'multiwindow';     Script = 'probe-windows-multiwindow.ps1';     Covers = 'a second window and its teardown' },
    @{ Name = 'notification';    Script = 'probe-windows-notification.ps1';    Covers = 'the toast runs, and a title is not PowerShell' },
    @{ Name = 'fs';              Script = 'probe-windows-fs.ps1';              Covers = 'write, append, copy, move, delete, rmdir, read back' },
    @{ Name = 'fs-watch';        Script = 'probe-windows-fs-watch.ps1';        Covers = 'create, modify, rename, recursion, unwatch, a root that goes away' },
    @{ Name = 'dialog';          Script = 'probe-windows-dialog.ps1';          Covers = 'alert, confirm, save, folder pick -- a button is pressed for real' }
)

if ($Build) {
    Write-Host '== building' -ForegroundColor Cyan
    Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
    Push-Location $root
    & cmd /c 'zig build -Doptimize=ReleaseSafe 2>&1' | Out-File -FilePath (Join-Path $env:TEMP 'probe-build.log') -Encoding utf8
    $buildExit = $LASTEXITCODE
    Pop-Location
    if ($buildExit -ne 0) {
        Write-Host "FAIL: the build failed; see $env:TEMP\probe-build.log" -ForegroundColor Red
        exit 2
    }
    Write-Host '   build ok'
}

if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (pass -Build, or run zig build first)" -ForegroundColor Yellow
    exit 2
}

$selected = $probes
if ($Only.Count -gt 0) {
    $selected = @($probes | Where-Object { $Only -contains $_.Name })
    if ($selected.Count -eq 0) {
        Write-Host "FAIL: no probe named $($Only -join ', ')" -ForegroundColor Red
        Write-Host "  known: $(($probes | ForEach-Object { $_.Name }) -join ', ')"
        exit 2
    }
}

$results = @()
foreach ($probe in $selected) {
    Write-Host ''
    Write-Host "== $($probe.Name): $($probe.Covers)" -ForegroundColor Cyan
    $scriptPath = Join-Path $PSScriptRoot $probe.Script
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -CraftExe $CraftExe -TimeoutSeconds $TimeoutSeconds 2>&1
    $code = $LASTEXITCODE
    $verdict = switch ($code) {
        0 { 'PASS' }
        2 { 'SKIP' }
        default { 'FAIL' }
    }
    $line = @($output | Where-Object { "$_" -match '^(PASS|FAIL|SKIP)' } | Select-Object -Last 1)
    $results += [pscustomobject]@{ Probe = $probe.Name; Verdict = $verdict; Exit = $code; Said = ($line -join '') }
    if ($verdict -ne 'PASS') {
        # Show why, rather than only the summary line.
        $output | Where-Object { "$_" -match '^\s{2}\S' } | Select-Object -First 6 | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
    }
    Write-Host "   $verdict"
}

Write-Host ''
Write-Host '== summary' -ForegroundColor Cyan
$results | ForEach-Object { Write-Host ("   {0,-16} {1,-6} {2}" -f $_.Probe, $_.Verdict, $_.Said) }

$failed = @($results | Where-Object { $_.Verdict -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failed.Count) probe(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'All selected probes passed.' -ForegroundColor Green
exit 0
