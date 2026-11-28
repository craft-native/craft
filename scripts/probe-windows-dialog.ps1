# Exercises the dialog namespace on Windows by driving the dialogs that open.
#
# A dialog is the one capability a page cannot finish on its own -- something has
# to press the button -- so this probe does the pressing: it watches for the
# dialog window belonging to our process and sends the same notifications the
# window would get from a click.
#
#   showAlert / showConfirm  -> a TaskDialog, drawn through DirectUI, so its
#                               buttons have no control ids. TDM_CLICK_BUTTON is
#                               the supported way in.
#   openFolder / saveFile    -> a shell IFileDialog, whose buttons are real
#                               children (id 1 = OK, id 2 = Cancel).
#
# openFile is checked as far as it can be without a human: the dialog opens and
# cancelling reports the documented empty result. Typing a path into the shell
# dialog's edit box from another process does not commit -- the dialog keeps the
# filename in its own state and leaves OK a no-op -- so the pick itself is proved
# through saveFile and openFolder, which return through the same code path.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    [string] $CraftExe = '',
    [int]    $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }
if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (run: zig build -Doptimize=ReleaseSafe)" -ForegroundColor Yellow
    exit 2
}

Add-Type -Namespace DialogProbe -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder sb, int max);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
public delegate bool EnumProc(IntPtr h, IntPtr p);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
'@

$TDM_CLICK_BUTTON = 1126
$BM_CLICK = 0x00F5

function Get-Class([IntPtr] $h) {
    $sb = New-Object Text.StringBuilder 256
    [void][DialogProbe.Win]::GetClassNameW($h, $sb, 256)
    $sb.ToString()
}

# The dialog is a top-level window of our own process with the stock dialog
# class. Found by enumerating rather than FindWindowEx, so a dialog of another
# app on screen cannot be mistaken for ours.
function Find-Dialog([int] $ProcessId) {
    $script:dialogHit = [IntPtr]::Zero
    $scan = [DialogProbe.Win+EnumProc] {
        param([IntPtr] $h, [IntPtr] $p)
        $owner = 0
        [void][DialogProbe.Win]::GetWindowThreadProcessId($h, [ref] $owner)
        if ($owner -eq $ProcessId -and (Get-Class $h) -eq '#32770' -and [DialogProbe.Win]::IsWindowVisible($h)) {
            $script:dialogHit = $h
        }
        return $true
    }
    [void][DialogProbe.Win]::EnumWindows($scan, [IntPtr]::Zero)
    return $script:dialogHit
}

function Find-ChildButton([IntPtr] $Dialog, [int] $Id) {
    $script:buttonHit = [IntPtr]::Zero
    $scan = [DialogProbe.Win+EnumProc] {
        param([IntPtr] $c, [IntPtr] $p)
        if ((Get-Class $c) -eq 'Button' -and [DialogProbe.Win]::GetDlgCtrlID($c) -eq $Id -and [DialogProbe.Win]::IsWindowVisible($c)) {
            $script:buttonHit = $c
        }
        return $true
    }
    [void][DialogProbe.Win]::EnumChildWindows($Dialog, $scan, [IntPtr]::Zero)
    return $script:buttonHit
}

$htmlPath = Join-Path $env:TEMP 'craft-dialog-probe.html'
$resultPath = Join-Path $env:TEMP 'craft-dialog-result.txt'
$logErr = Join-Path $env:TEMP 'craft-dialog-probe.err.txt'
$workDir = Join-Path $env:TEMP ('craft-dialog-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Remove-Item $resultPath, $logErr -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>dialog probe</title>
<script>
  const out = [];
  const RESULT = '__RESULT_PATH__';
  const DIR = '__WORK_DIR__';
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function post() { try { craft.fs.writeFile(RESULT, out.join('\n') + '\n'); } catch (e) {} }

  // The marker goes out before the dialog opens, because nothing on the page can
  // be written while it is up. The runner polls the file and presses the button.
  async function step(name, call) {
    out.push('STEP=' + name);
    post();
    await wait(200);
    try {
      const value = await call();
      out.push(name + '=' + JSON.stringify(value));
    } catch (e) {
      out.push(name + '=ERR:' + ((e && (e.code || e.name)) || 'unknown'));
    }
    post();
    await wait(300);
  }

  (async function () {
    await step('alert', function () {
      return craft.dialog.showAlert({ title: 'Probe alert', message: 'one button' });
    });
    await step('confirmYes', function () {
      return craft.dialog.showConfirm({ title: 'Probe confirm', message: 'take the first' });
    });
    await step('confirmNo', function () {
      return craft.dialog.showConfirm({ title: 'Probe cancel', message: 'take the last' });
    });
    await step('save', function () {
      return craft.dialog.showSaveDialog({ defaultPath: DIR, defaultName: 'picked-probe.txt' });
    });
    await step('folder', function () {
      return craft.dialog.showOpenDialog({ properties: ['openDirectory'], defaultPath: DIR });
    });
    await step('open', function () {
      return craft.dialog.showOpenDialog({});
    });

    out.push('ALLDONE');
    post();
    await wait(600);
    try { craft.window.setTitle('ALLDONE'); } catch (e) {}
  })();
</script>
'@
$html = $html.Replace('__RESULT_PATH__', $resultPath.Replace('\', '\\'))
$html = $html.Replace('__WORK_DIR__', $workDir.Replace('\', '\\'))
Set-Content -Path $htmlPath -Value $html -Encoding ASCII

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '520', '--height', '320') `
    -PassThru -RedirectStandardError $logErr

# What the page cannot do for itself: press the button.
$presses = [ordered]@{
    'alert'      = @{ Kind = 'task';     Button = 100 }  # first button
    'confirmYes' = @{ Kind = 'task';     Button = 100 }
    'confirmNo'  = @{ Kind = 'task';     Button = 101 }  # second button
    'save'       = @{ Kind = 'shell';    Button = 1 }
    'folder'     = @{ Kind = 'shell';    Button = 1 }
    'open'       = @{ Kind = 'shell';    Button = 2 }    # cancel
}
$handled = @{}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$title = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
    $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $live) { break }
    if ($live.MainWindowTitle) { $title = $live.MainWindowTitle }

    if (Test-Path $resultPath) {
        $text = Get-Content $resultPath -Raw
        foreach ($line in ($text -split "`n")) {
            if (-not $line.StartsWith('STEP=')) { continue }
            $name = $line.Substring(5).Trim()
            if ($handled.ContainsKey($name)) { continue }
            $press = $presses[$name]
            if (-not $press) { continue }
            $handled[$name] = $true

            # The dialog is posted after the marker, so it may not exist yet.
            $dialog = [IntPtr]::Zero
            $wait = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $wait -and $dialog -eq [IntPtr]::Zero) {
                $dialog = Find-Dialog $proc.Id
                if ($dialog -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 }
            }
            if ($dialog -eq [IntPtr]::Zero) {
                Write-Host "  no dialog appeared for '$name'" -ForegroundColor Red
                break
            }
            if ($press.Kind -eq 'task') {
                [void][DialogProbe.Win]::SendMessageW($dialog, $TDM_CLICK_BUTTON, [IntPtr] $press.Button, [IntPtr]::Zero)
            } else {
                $button = Find-ChildButton $dialog $press.Button
                if ($button -eq [IntPtr]::Zero) {
                    Write-Host "  '$name' has no button $($press.Button)" -ForegroundColor Red
                } else {
                    [void][DialogProbe.Win]::PostMessageW($button, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
                }
            }
            # Let it close before looking for the next one.
            $gone = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $gone -and [DialogProbe.Win]::IsWindow($dialog)) { Start-Sleep -Milliseconds 100 }
        }
    }
    if ($title -like '*ALLDONE*') { break }
}
Start-Sleep -Milliseconds 400
Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

$result = [ordered]@{}
if (Test-Path $resultPath) {
    Write-Host '--- results ---'
    foreach ($line in (Get-Content $resultPath)) {
        Write-Host "  $line"
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $result[$line.Substring(0, $at)] = $line.Substring($at + 1) }
    }
}

function Get-Value([string] $name) {
    if ($result.Contains($name)) { return $result[$name] }
    return ''
}

$leaf = Split-Path $workDir -Leaf
$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the page never finished' }
if (-not (Test-Path $resultPath)) { $failures += 'the page wrote no results' }
foreach ($key in $result.Keys) {
    if ($result[$key] -like 'ERR:*') { $failures += "$key rejected: $($result[$key])" }
}

if ((Get-Value 'alert') -ne '{"buttonIndex":0}') { $failures += "showAlert answered '$(Get-Value 'alert')'" }
# `alert` is the weak one of the pair: it has a single button, and the dialog
# allows itself to be cancelled, so a dismissal by any route reports index 0.
# The two confirm cases are what proves the ids reach the right button -- sending
# 101 where 100 was expected turns `confirmYes` into {"ok":false}.
if ((Get-Value 'confirmYes') -ne '{"ok":true}') { $failures += "showConfirm on the first button answered '$(Get-Value 'confirmYes')'" }
if ((Get-Value 'confirmNo') -ne '{"ok":false}') { $failures += "showConfirm on the last button answered '$(Get-Value 'confirmNo')'" }
$save = Get-Value 'save'
if ($save -notlike '*"canceled":false*' -or $save -notlike '*picked-probe.txt*') { $failures += "showSaveDialog answered '$save'" }
$folder = Get-Value 'folder'
if ($folder -notlike '*"canceled":false*' -or $folder -notlike "*$leaf*") { $failures += "showOpenDialog for a folder answered '$folder'" }
if ((Get-Value 'open') -ne '{"canceled":true,"filePaths":[]}') { $failures += "cancelling showOpenDialog answered '$(Get-Value 'open')'" }

if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  log: $_" } }
    exit 1
}
Write-Host 'PASS: every dialog opened, took the button it was sent, and reported what that button means' -ForegroundColor Green
exit 0



