# Checks that a page can open a second window, that it runs its own page, and
# that closing it leaves one window behind.
#
# The Windows path is not a plain call: WebView2 does not run async completion
# callbacks inside its own message callback, so `window.open` is queued and
# pumped from a posted message (queueWindowOpen / processPendingOpens). A
# regression there shows up as an open() that never resolves.
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

$htmlPath = Join-Path $env:TEMP 'craft-multiwindow-probe.html'
$logErr = Join-Path $env:TEMP 'craft-multiwindow-probe.err.txt'

# The child reports itself in its own title, then closes itself so the probe can
# tell "closed" from "never opened".
$html = @'
<!doctype html>
<meta charset="utf-8">
<title>main</title>
<script>
  const out = ['READY'];
  function show() { try { craft.window.setTitle(out.join(' ')); } catch (e) {} }
  show();
  const child = [
    '<!doctype html><meta charset="utf-8"><title>child</title>',
    '<script>',
    'craft.window.setTitle("CHILD-OK");',
    'setTimeout(function () { craft.window.close(); }, 4000);',
    '<\/script>'
  ].join('');
  (async function () {
    try {
      const name = await craft.window.open({
        name: 'child', html: child, title: 'CHILD-WINDOW', width: 460, height: 320
      });
      out.push('OPENED:' + JSON.stringify(name));
      show();
    } catch (e) {
      out.push('OPENERR:' + e.name);
      show();
    }
  })();
</script>
'@
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Remove-Item $logErr -Force -ErrorAction SilentlyContinue

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

# Both windows belong to one process, so counting processes counts nothing. The
# titles have to come from the window enumerator.
if (-not ('CraftProbeWindows' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class CraftProbeWindows {
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    public static string[] Titles(int pid) {
        var found = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            if (owner != (uint)pid || !IsWindowVisible(hWnd)) return true;
            var text = new StringBuilder(512);
            GetWindowTextW(hWnd, text, 512);
            if (text.Length > 0) found.Add(text.ToString());
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@
}

$main = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '600', '--height', '400') `
    -PassThru -RedirectStandardError $logErr

$failures = @()

function Get-WindowTitles {
    if (-not (Get-Process -Id $main.Id -ErrorAction SilentlyContinue)) { return @() }
    return @([CraftProbeWindows]::Titles($main.Id))
}

# --- the second window appears with its own page -----------------------------
$sawChild = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    $child = @(Get-WindowTitles | Where-Object { $_ -like '*CHILD-OK*' })
    if ($child.Count -gt 0) { $sawChild = $child[0]; break }
}
if (-not $sawChild) {
    $failures += 'no window ever showed the child page (window.open did not land)'
} else {
    Write-Host "child window: $sawChild"
}

$titles = Get-WindowTitles
Write-Host "window titles: $($titles -join ' / ')"
$mainOwn = @($titles | Where-Object { $_ -like '*OPENED*' })
if ($mainOwn.Count -eq 0) { $failures += 'window.open never resolved in the page that called it' }
if ($titles.Count -ne 2) { $failures += "expected two windows while the child is open, saw $($titles.Count)" }

# --- the child closes itself and only the main window is left ----------------
$backToOne = $null
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $now = Get-WindowTitles
    $stillThere = @($now | Where-Object { $_ -like '*CHILD-OK*' }).Count
    if ($now.Count -eq 1 -and $stillThere -eq 0) { $backToOne = $true; break }
}
if (-not $backToOne) {
    $now = Get-WindowTitles
    $failures += "the child window never went away (windows: $($now -join ' / '))"
} else {
    Write-Host 'child closed, one window left'
}

$mainAlive = [bool](Get-Process -Id $main.Id -ErrorAction SilentlyContinue)
Write-Host "main window process still alive: $mainAlive"
if (-not $mainAlive) { $failures += 'closing the child took the main window with it' }

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  log: $_" } }
    exit 1
}
Write-Host 'PASS: a second window opens with its own page, and closing it leaves the first alone' -ForegroundColor Green
exit 0
