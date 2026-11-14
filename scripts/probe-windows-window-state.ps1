# Checks the window geometry/state reads and writes, and the clipboard round trip.
#
# These are the calls an app makes on every layout change, and the reads go
# through the correlated request path (`_req`), so a handler that never answers
# leaves the page waiting rather than failing loudly.
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

$htmlPath = Join-Path $env:TEMP 'craft-window-state-probe.html'
$logErr = Join-Path $env:TEMP 'craft-window-state-probe.err.txt'

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>window state probe</title>
<script>
  const out = ['READY'];
  function show() { try { craft.window.setTitle(out.join(' ')); } catch (e) {} }
  function err(where, e) { out.push(where + 'ERR:' + (e && e.name || e)); show(); }
  async function settle() { await new Promise(function (r) { setTimeout(r, 250); }); }

  (async function () {
    // The public object only exposes `getFocused`; the rest are reached through
    // the `_call` adapter the typed SDK uses, which is also the only path that
    // sends a target window id.
    const read = (action) => craft.window._call(action, {}, 'main');
    try {
      await craft.window.setSize(700, 500); await settle();
      const size = await read('getSize');
      out.push('SIZE=' + size.width + 'x' + size.height);

      await craft.window.setPosition(140, 110); await settle();
      const pos = await read('getPosition');
      out.push('POS=' + pos.x + ',' + pos.y);

      const bounds = await read('getBounds');
      out.push('BOUNDS=' + [bounds.x, bounds.y, bounds.width, bounds.height].join(','));

      await craft.window.setAlwaysOnTop(true); await settle();
      const top = await read('isAlwaysOnTop');
      await craft.window.setAlwaysOnTop(false); await settle();
      const notTop = await read('isAlwaysOnTop');
      out.push('TOP=' + top + '/' + notTop);

      const wasResizable = await read('isResizable');
      await craft.window.setResizable(false); await settle();
      const nowResizable = await read('isResizable');
      await craft.window.setResizable(true); await settle();
      const backResizable = await read('isResizable');
      out.push('RESIZABLE=' + wasResizable + '/' + nowResizable + '/' + backResizable);

      await craft.window.setTitle('state-probe-title'); await settle();
      out.push('TITLE=' + (await read('getTitle')));

      // `getFocused` answers `{}` today, which is recorded in FORK.md as a gap
      // rather than asserted here; `getState` carries the same fact and more.
      out.push('FOCUSED=' + JSON.stringify(await read('getFocused')));
      const state = await read('getState');
      out.push('STATE=' + [state.isVisible, state.isFocused, state.isAlwaysOnTop, state.bounds.width].join(','));
    } catch (e) { err('WIN', e); }

    try {
      const stamp = 'craft-probe-' + Date.now();
      await craft.clipboard.writeText(stamp); await settle();
      out.push('CLIP=' + ((await craft.clipboard.readText()) === stamp ? 'same' : 'DIFF'));
      out.push('HASTEXT=' + (await craft.clipboard.hasText()));

      // HTML is written and read back as one string, so the markers the native
      // side wraps around a fragment are not part of the assertion.
      await craft.clipboard.writeHTML('<b>probe-html</b>'); await settle();
      const html = await craft.clipboard.readHTML();
      out.push('HTML=' + (html.indexOf('probe-html') >= 0 ? 'same' : 'DIFF'));
      out.push('HASHTML=' + (await craft.clipboard.hasHTML()));

      await craft.clipboard.clear(); await settle();
      out.push('AFTERCLEAR=' + (await craft.clipboard.hasText()) + '/' + (await craft.clipboard.hasHTML()));
    } catch (e) { err('CLIP', e); }

    out.push('ALLDONE');
    show();
  })();
</script>
'@
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Remove-Item $logErr -Force -ErrorAction SilentlyContinue

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '600', '--height', '400') `
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
if ($title -notlike '*ALLDONE*') { $failures += 'the page never finished; a read probably never answered' }
foreach ($marker in 'WINERR', 'CLIPERR') {
    if ($title -like "*$marker*") { $failures += "saw $marker" }
}

function Get-Value([string] $name) {
    $m = [regex]::Match($title, [regex]::Escape($name) + '=([^\s]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Size and position must survive the write. +-2 px of tolerance covers the
# non-client frame, which is what these calls measure.
$size = Get-Value 'SIZE'
if ($size -match '^(\d+)x(\d+)$') {
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    if ([Math]::Abs($w - 700) -gt 2 -or [Math]::Abs($h - 500) -gt 2) {
        $failures += "setSize(700,500) read back as ${w}x${h}"
    }
} else { $failures += "SIZE was not readable ('$size')" }

$pos = Get-Value 'POS'
if ($pos -match '^(-?\d+),(-?\d+)$') {
    $x = [int]$Matches[1]; $y = [int]$Matches[2]
    if ([Math]::Abs($x - 140) -gt 2 -or [Math]::Abs($y - 110) -gt 2) {
        $failures += "setPosition(140,110) read back as ${x},${y}"
    }
} else { $failures += "POS was not readable ('$pos')" }

$bounds = Get-Value 'BOUNDS'
if (@($bounds -split ',').Count -ne 4) { $failures += "BOUNDS was not four numbers ('$bounds')" }

if ((Get-Value 'TOP') -ne 'true/false') { $failures += "always-on-top did not round-trip: '$(Get-Value 'TOP')'" }
if ((Get-Value 'RESIZABLE') -ne 'true/false/true') { $failures += "resizable did not round-trip: '$(Get-Value 'RESIZABLE')'" }
if ((Get-Value 'TITLE') -ne 'state-probe-title') { $failures += "getTitle read '$(Get-Value 'TITLE')'" }
$state = Get-Value 'STATE'
if ($state -notmatch '^(true|false),(true|false),(true|false),([1-9]\d*)$') { $failures += "getState did not answer a usable shape: '$state'" }
if ((Get-Value 'CLIP') -ne 'same') { $failures += "clipboard round trip: '$(Get-Value 'CLIP')'" }
if ((Get-Value 'HASTEXT') -ne 'true') { $failures += "clipboard hasText: '$(Get-Value 'HASTEXT')'" }if ((Get-Value 'HTML') -ne 'same') { $failures += "clipboard html round trip: '$(Get-Value 'HTML')" }
if ((Get-Value 'HASHTML') -ne 'true') { $failures += "clipboard hasHTML: '$(Get-Value 'HASHTML')" }
if ((Get-Value 'AFTERCLEAR') -ne 'false/false') { $failures += "clipboard clear left content behind: '$(Get-Value 'AFTERCLEAR')" }
if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  log: $_" } }
    exit 1
}
Write-Host 'PASS: geometry, state flags, title and clipboard all read back what was written' -ForegroundColor Green
exit 0
