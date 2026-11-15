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
  // The window title is page-controlled text that has to squeeze through a
  // fixed native buffer, and a probe with a dozen fields does not fit. Results
  // go to a file; the title carries only the four markers the runner watches.
  const RESULT = '__RESULT_PATH__';
  let phase = 'READY';
  function show() { try { craft.window.setTitle(phase); } catch (e) {} }
  function mark(s) { out.push(s); }
  function err(where, e) {
    const name = (e && e.name) || 'Unknown';
    const message = (e && e.message) || (e && JSON.stringify(e)) || String(e);
    out.push(where + 'ERR:' + name + ':' + message);
  }
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

      // `getFocused` answers null when none of our windows is focused, and the
      // typed SDK turns that into `null` rather than a handle. Sampling while
      // minimised and again after the runner activates the window covers both
      // branches; normalising null to {} would show up as "obj" here.
      //
      // The window restores itself before asking the runner to activate it:
      // AppActivate cannot raise a minimised window, and SW_SHOW does not
      // restore one either (that is what SW_RESTORE is for).
      const seen = [];
      async function sample(times) {
        for (let i = 0; i < times; i++) {
          const v = await read('getFocused');
          const tag = v === null ? 'null' : (typeof v === 'string' ? v : 'obj');
          if (seen[seen.length - 1] !== tag) seen.push(tag);
          await new Promise(function (r) { setTimeout(r, 280); });
        }
      }
      await craft.window.minimize(); await settle();
      await sample(2);
      await craft.window._call('restore', {}, 'main');
      await settle();
      phase = 'RESTORED'; show();
      await sample(8);
      out.push('FOCUSSEQ=' + seen.join('>'));

      const state = await read('getState');
      out.push('STATE=' + [state.isVisible, state.isFocused, state.isAlwaysOnTop, state.bounds.width].join(','));

      // Opacity is checked twice: once through the bridge, and once from the OS
      // side by the runner while the value is held at 0.5. A bridge that stored
      // the number and echoed it back would pass the first and fail the second.
      await craft.window.setOpacity(0.5); await settle();
      out.push('OPACITY05=' + (await read('getOpacity')));
      phase = 'OPACITY05'; show();
      await new Promise(function (r) { setTimeout(r, 1400); });
      await craft.window.setOpacity(1); await settle();
      out.push('OPACITY10=' + (await read('getOpacity')));

      // Oversized page input must be refused, not fatal. A title longer than the
      // native buffer used to trap inside the standard library and take the
      // process with it, so the check is that the app still answers afterwards.
      await craft.window.setTitle('x'.repeat(5000)); await settle();
      await craft.window.setTitle('after-long-title'); await settle();
      out.push('LONGTITLE=' + (await read('getTitle')));
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
    await craft.fs.writeFile(RESULT, out.join('\n'));
    await settle();
    phase = 'ALLDONE'; show();
  })();
</script>
'@
$resultPath = Join-Path $env:TEMP 'craft-window-state-result.txt'
Remove-Item $resultPath -Force -ErrorAction SilentlyContinue
# The HTML is a single-quoted here-string, so the path is substituted here rather
# than interpolated, and its backslashes are escaped for the JS string literal.
$html = $html.Replace('__RESULT_PATH__', $resultPath.Replace('\', '\\'))
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Remove-Item $logErr -Force -ErrorAction SilentlyContinue

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

# This probe writes to the clipboard and then clears it. On someone's desktop
# that throws away whatever they had copied, so the text is saved first and put
# back afterwards, on the failure path too.
$savedClipboard = $null
$hadClipboard = $false
try {
    $savedClipboard = Get-Clipboard -Raw -ErrorAction Stop
    $hadClipboard = $true
} catch {
    Write-Host 'note: the clipboard could not be read, so it cannot be restored' -ForegroundColor Yellow
}

# Reads the real layered-window state, so an opacity that was only remembered by
# the bridge cannot pass.
if (-not ('CraftProbeLayered' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CraftProbeLayered {
    [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr hWnd, int index);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr hWnd, out uint key, out byte alpha, out uint flags);
    const int GWL_EXSTYLE = -20;
    const uint WS_EX_LAYERED = 0x00080000;
    const uint LWA_ALPHA = 0x2;
    public static string Describe(IntPtr hwnd) {
        long style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE).ToInt64();
        bool layered = (style & WS_EX_LAYERED) != 0;
        if (!layered) return "layered=false";
        uint key; byte alpha; uint flags;
        if (!GetLayeredWindowAttributes(hwnd, out key, out alpha, out flags)) return "layered=true,alpha=? ";
        if ((flags & LWA_ALPHA) == 0) return "layered=true,alpha=none";
        return "layered=true,alpha=" + alpha;
    }
}
'@
}

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '600', '--height', '400') `
    -PassThru -RedirectStandardError $logErr

$title = ''
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$activated = $false
$layeredAtHalf = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $live) { break }
    if ($live.MainWindowTitle) { $title = $live.MainWindowTitle }
    if ($title -like '*ALLDONE*') { break }
    # The focused half of the sample needs the window in front; do it once.
    if (-not $activated -and $title -like '*RESTORED*') {
        $activated = $true
        (New-Object -ComObject WScript.Shell).AppActivate($proc.Id) | Out-Null
    }
    # Sample the OS state while the page is holding opacity at 0.5.
    if (-not $layeredAtHalf -and $title -like '*OPACITY05*') {
        $hwnd = (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue).MainWindowHandle
        if ($hwnd -and $hwnd -ne [IntPtr]::Zero) { $layeredAtHalf = [CraftProbeLayered]::Describe($hwnd) }
    }
}
$layeredAtFull = ''
$finalHwnd = (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue).MainWindowHandle
if ($finalHwnd -and $finalHwnd -ne [IntPtr]::Zero) { $layeredAtFull = [CraftProbeLayered]::Describe($finalHwnd) }
Write-Output "os state at 0.5: $layeredAtHalf"
Write-Output "os state at 1.0: $layeredAtFull"
Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not $title) {
    Write-Host 'FAIL: the window never titled itself' -ForegroundColor Red
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  $_" } }
    exit 1
}
Write-Host "observed: $title"
if (Test-Path $resultPath) {
    Write-Host '--- results ---'
    Get-Content $resultPath | ForEach-Object { Write-Host "  $_" }
}

# Results arrive in a file; the title only carried the markers the loop watched.
$result = @{}
if (Test-Path $resultPath) {
    foreach ($line in (Get-Content $resultPath)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $result[$line.Substring(0, $at)] = $line.Substring($at + 1) }
    }
}

$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the page never finished; a read probably never answered' }
if (-not (Test-Path $resultPath)) { $failures += 'the page never wrote its results' }
foreach ($marker in 'WINERR', 'CLIPERR') {
    if ($title -like "*$marker*") { $failures += "saw $marker" }
}
foreach ($key in $result.Keys) {
    if ($key -like '*ERR') { $failures += "saw $key=$($result[$key])" }
}

function Get-Value([string] $name) {
    if ($result.ContainsKey($name)) { return $result[$name] }
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

$seq = Get-Value 'FOCUSSEQ'
if (-not $seq) { $failures += 'getFocused was never sampled' }
else {
    if ($seq -notmatch 'null') { $failures += "getFocused never answered null while minimised: '$seq'" }
    if ($seq -notmatch 'main') { $failures += "getFocused never answered the window name once activated: '$seq'" }
    if ($seq -match 'obj') { $failures += "getFocused answered a non-string, non-null value: '$seq'" }
}
if ((Get-Value 'CLIP') -ne 'same') { $failures += "clipboard round trip: '$(Get-Value 'CLIP')'" }
if ((Get-Value 'HASTEXT') -ne 'true') { $failures += "clipboard hasText: '$(Get-Value 'HASTEXT')" }
if ((Get-Value 'HTML') -ne 'same') { $failures += "clipboard html round trip: '$(Get-Value 'HTML')" }
if ((Get-Value 'HASHTML') -ne 'true') { $failures += "clipboard hasHTML: '$(Get-Value 'HASHTML')" }
if ((Get-Value 'AFTERCLEAR') -ne 'false/false') { $failures += "clipboard clear left content behind: '$(Get-Value 'AFTERCLEAR')" }

$o05 = Get-Value 'OPACITY05'
if ($o05 -notmatch '^0\.5\d*$') { $failures += "setOpacity(0.5) read back as '$o05'" }
$o10 = Get-Value 'OPACITY10'
if ($o10 -notmatch '^1(\.0+)?$') { $failures += "setOpacity(1) read back as '$o10'" }
# The OS side: half opacity must be a real layered window at roughly 128/255.
if ($layeredAtHalf -notmatch 'alpha=12\d$') { $failures += "the window was not really layered at 0.5: '$layeredAtHalf'" }
# And full opacity must have dropped WS_EX_LAYERED rather than leaving it on.
if ($layeredAtFull -notmatch '^layered=false') { $failures += "the window stayed layered at opacity 1: '$layeredAtFull'" }

# A 5000-character title must leave the app answering reads, not dead.
if ((Get-Value 'LONGTITLE') -ne 'after-long-title') {
    $failures += "the app did not survive an oversized title: '$(Get-Value 'LONGTITLE')"
}
# Put the caller's clipboard back before reporting, whichever way this ends.
if ($hadClipboard) {
    if ($savedClipboard) { Set-Clipboard -Value $savedClipboard -ErrorAction SilentlyContinue }
    else { Set-Clipboard -Value '' -ErrorAction SilentlyContinue }
    Write-Host "clipboard restored: $($savedClipboard.Length) chars" -ForegroundColor DarkGray
}

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  log: $_" } }
    exit 1
}
Write-Host 'PASS: geometry, state flags, title and clipboard all read back what was written' -ForegroundColor Green
exit 0
