# Checks that craft.capabilities() tells the truth on Windows.
#
# capability_registry.zig describes the audited macOS dispatch chain. On Windows
# a `declared` namespace that has no dispatcher arm there must be demoted to
# `unavailable` with a reason, because otherwise the page is promised a surface
# that answers PLATFORM_NOT_SUPPORTED the moment it calls it.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    [string] $CraftExe = '',
    [int]    $TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }
if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (run: zig build -Doptimize=ReleaseSafe)" -ForegroundColor Yellow
    exit 2
}

$htmlPath = Join-Path $env:TEMP 'craft-caps-probe.html'
$logErr = Join-Path $env:TEMP 'craft-caps-probe.err.txt'

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>capabilities probe</title>
<script>
  craft.window.setTitle('T0');
  craft.capabilities().then(function (m) {
    const ns = m.namespaces;
    function mark(n) {
      const e = ns[n];
      if (!e) return n + '=missing';
      return n + '=' + e.status + (e.reason ? '/' + e.reason.length : '');
    }
    function acts(n) {
      const e = ns[n];
      return (!e || !e.actions) ? 0 : Object.keys(e.actions).length;
    }
    const parts = [
      mark('haptics'),
      mark('timers') + '/' + acts('timers'),
      mark('screen') + '/' + acts('screen'),
      mark('system'),
      mark('updater'),
      mark('marketplace'),
      'channels=' + Object.keys(m.channels || {}).length,
      'ALLDONE'
    ];
    craft.window.setTitle(parts.join(' '));
  }).catch(function (e) { craft.window.setTitle('FATAL:' + e.name + ' ALLDONE'); });
</script>
'@
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Remove-Item $logErr -Force -ErrorAction SilentlyContinue

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '560', '--height', '360') `
    -PassThru -RedirectStandardError $logErr

$title = ''
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $live) { break }
    if ($live.MainWindowTitle) { $title = $live.MainWindowTitle }
    if ($title -like '*ALLDONE*') { break }
}
Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not $title) {
    Write-Host 'FAIL: the window never titled itself' -ForegroundColor Red
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  $_" } }
    exit 1
}
Write-Host "observed: $title"

$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the manifest never answered' }
if ($title -like '*FATAL*') { $failures += 'craft.capabilities() rejected' }

# A declared namespace Windows cannot dispatch, and it must carry a reason.
if ($title -notmatch 'haptics=unavailable/\d+') { $failures += 'haptics is still claimed on Windows, or lost its reason' }
# Declared and actually routed: the claim must survive, with its actions.
if ($title -notmatch 'timers=declared/3') { $failures += 'timers lost its declared action table' }
if ($title -notmatch 'screen=declared/[1-9]') { $failures += 'screen lost its declared action table' }
# Untouched: these statuses are already true on every backend.
if ($title -notmatch 'system=undeclared') { $failures += 'system was rewritten instead of left undeclared' }
if ($title -notmatch 'updater=unavailable') { $failures += 'updater lost the reason it already carried' }
if ($title -notmatch 'marketplace=unrouted') { $failures += 'marketplace lost the unrouted distinction' }
if ($title -notmatch 'channels=[1-9]\d*') { $failures += 'the channel list came back empty' }

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'PASS: the Windows manifest demotes what it cannot dispatch and keeps the rest' -ForegroundColor Green
exit 0
