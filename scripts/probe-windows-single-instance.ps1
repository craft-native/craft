# Checks that a second launch of a `--single-instance` app reaches the first one.
#
# On Windows the forwarded launch travels over WM_COPYDATA to the running window
# (LAUNCH_COPY_TAG), and the page sees it as `craft:secondInstance` with the
# second launch's `--instance-arg` values and deep link. A deep link on its own
# also arrives as `craft:deepLink`.
#
# The failure this catches: the second launch opens its own window instead of
# handing off, so an app that assumed one instance ends up with two toolbars and
# two sets of state.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    [string] $CraftExe = '',
    [int]    $TimeoutSeconds = 25
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }
if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (run: zig build -Doptimize=ReleaseSafe)" -ForegroundColor Yellow
    exit 2
}

$htmlPath = Join-Path $env:TEMP 'craft-single-instance-probe.html'
$logErr = Join-Path $env:TEMP 'craft-single-instance-probe.err.txt'

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>single instance probe</title>
<script>
  const out = ['READY'];
  function show() { try { craft.window.setTitle(out.join(' ')); } catch (e) {} }
  // `_evt` hands the callback `event.detail` itself, not the event: reading
  // `e.detail.args` would throw and the title would never change.
  craft.app.onSecondInstance(function (d) {
    const args = (d && d.args) || [];
    out.push('2ND[' + args.join(',') + ']');
    if (d && d.url) out.push('2NDURL[' + d.url + ']');
    show();
  });
  craft.deepLink.onUrl(function (d) {
    out.push('DEEP[' + ((d && d.url) || '') + ']');
    show();
  });
  show();
  const initial = craft.deepLink.getInitialUrl();
  if (initial) { out.push('INITIAL[' + initial + ']'); show(); }
</script>
'@
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Remove-Item $logErr -Force -ErrorAction SilentlyContinue

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

$instanceId = 'craftprobe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$failures = @()

function Start-Craft([string[]] $Extra) {
    $argv = @('--html-file', $htmlPath, '-t', 'T0', '-w', '560', '--height', '360', '--single-instance', $instanceId) + $Extra
    Start-Process -FilePath $CraftExe -ArgumentList $argv -PassThru -RedirectStandardError $logErr
}

function Read-Title($ProcessId) {
    $live = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $live) { return '' }
    return $live.MainWindowTitle
}

function Wait-For([scriptblock] $Probe, [int] $Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        $value = & $Probe
        if ($value) { return $value }
    }
    return $null
}

# --- first instance ---------------------------------------------------------
$first = Start-Craft @()
$ready = Wait-For { $t = Read-Title $first.Id; if ($t -like '*READY*') { $t } } $TimeoutSeconds
if (-not $ready) {
    Write-Host 'FAIL: the first instance never reported READY' -ForegroundColor Red
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  $_" } }
    Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force
    exit 1
}
Write-Host "first instance up: $ready"

# --- second launch carrying arguments ---------------------------------------
$second = Start-Craft @('--instance-arg', 'hello')
$exited = $second.WaitForExit(10000)
Write-Host "second launch exited=$exited"
if (-not $exited) { $failures += 'the second launch kept running instead of handing off' }

$sawArgs = Wait-For {
    $t = Read-Title $first.Id
    if ($t -match [regex]::Escape('2ND[hello]')) { $t }
} 10
if (-not $sawArgs) { $failures += 'the first instance never received the forwarded --instance-arg' }
else { Write-Host "args delivered: $sawArgs" }

# --- second launch carrying only a deep link --------------------------------
$third = Start-Craft @('--deep-link', 'craftprobe://abc')
$thirdExited = $third.WaitForExit(10000)
Write-Host "deep-link launch exited=$thirdExited"
if (-not $thirdExited) { $failures += 'the deep-link launch kept running instead of handing off' }

$sawLink = Wait-For {
    $t = Read-Title $first.Id
    if ($t -match [regex]::Escape('DEEP[craftprobe://abc]') -or $t -match [regex]::Escape('2NDURL[craftprobe://abc]')) { $t }
} 10
if (-not $sawLink) { $failures += 'the first instance never received the forwarded deep link' }
else { Write-Host "deep link delivered: $sawLink" }

# --- exactly one instance survives -----------------------------------------
$alive = @(Get-Process craft -ErrorAction SilentlyContinue)
$windows = @($alive | Where-Object { $_.MainWindowTitle })
Write-Host "surviving processes=$($alive.Count) with-window=$($windows.Count)"
if ($windows.Count -ne 1) { $failures += "expected one window, saw $($windows.Count)" }

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'PASS: a second launch hands off its arguments and deep link, and no second window opens' -ForegroundColor Green
exit 0
