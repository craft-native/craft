# Checks that a notification title cannot become PowerShell.
#
# On Windows `notification.show` builds a PowerShell script and runs it with
# `-Command`. The title and body are embedded in single-quoted literals, and
# `escapePsSingleQuoted` doubles apostrophes and replaces CR/LF with spaces. If
# that were wrong, a title would be code: this probe sends a title and a body that
# create a marker file when evaluated, and fails if either file appears.
#
# It also needs the opposite reassurance. A path that never ran would also leave
# no marker, so the probe watches for the `powershell.exe` child that craft spawns
# and fails when the toast was never attempted at all.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    [string] $CraftExe = '',
    [int]    $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }
if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (run: zig build -Doptimize=ReleaseSafe)" -ForegroundColor Yellow
    exit 2
}

$htmlPath = Join-Path $env:TEMP 'craft-notification-probe.html'
$resultPath = Join-Path $env:TEMP 'craft-notification-result.txt'
$logErr = Join-Path $env:TEMP 'craft-notification-probe.err.txt'
$markerTitle = Join-Path $env:TEMP 'craft-injection-from-title.txt'
$markerBody = Join-Path $env:TEMP 'craft-injection-from-body.txt'
Remove-Item $resultPath, $logErr, $markerTitle, $markerBody -Force -ErrorAction SilentlyContinue

# A toast needs an AppUserModelID, and the app reads it from this file beside the
# executable. Nothing documented it and nothing shipped it, so `show` used to do
# nothing at all here; the app now warns instead. Create it for the run and take
# it away again if it was not ours.
$appIdFile = Join-Path (Split-Path -Parent $CraftExe) 'craft-notification-id.txt'
$createdAppId = $false
if (-not (Test-Path $appIdFile)) {
    Set-Content -Path $appIdFile -Value 'Craft.Probe.Notification' -Encoding ASCII
    $createdAppId = $true
}

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>notification probe</title>
<script>
  const out = [];
  const RESULT = '__RESULT_PATH__';
  const M1 = '__MARKER1__';
  const M2 = '__MARKER2__';

  (async function () {
    // The payload has to be able to run in the position it lands in. It is
    // embedded inside a method-call argument list, where a `;` is a parse error
    // rather than a statement separator -- a statement-style payload proves
    // nothing, because it fails to parse whether or not the escaping is right.
    // Breaking out with `' + $(... ) + '` stays an expression and does run.
    const title = "probe ' + $(New-Item -Path '" + M1 + "' -Force) + '";
    // The body must use the same shape. A `$( )` alone leaves the path outside
    // the literal, which is a parse error -- and a parse error aborts the whole
    // script, so the title payload never runs either and "no marker" proves
    // nothing. Both payloads have to keep the script parseable.
    const body = "probe ' + $(New-Item -Path '" + M2 + "' -Force) + '";
    craft.notifications.show({ title: title, body: body });
    out.push('SENT');

    // Give the child PowerShell time to finish.
    await new Promise(function (r) { setTimeout(r, 3000); });

    // A benign one afterwards, to show the path still works and to leave a
    // visible sign on screen if someone is watching.
    craft.notifications.show({ title: 'craft probe', body: 'injection check' });
    out.push('SENT2');
    await new Promise(function (r) { setTimeout(r, 1500); });

    out.push('ALLDONE');
    await craft.fs.writeFile(RESULT, out.join('\n'));
    craft.window.setTitle('ALLDONE');
  })();
</script>
'@
$html = $html.Replace('__RESULT_PATH__', $resultPath.Replace('\', '\\'))
$html = $html.Replace('__MARKER1__', $markerTitle.Replace('\', '\\'))
$html = $html.Replace('__MARKER2__', $markerBody.Replace('\', '\\'))
Set-Content -Path $htmlPath -Value $html -Encoding ASCII

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '520', '--height', '320') `
    -PassThru -RedirectStandardError $logErr

$title = ''
$sawPowerShell = $false
$appStart = $proc.StartTime
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if (-not $live) { break }
    if ($live.MainWindowTitle) { $title = $live.MainWindowTitle }
    if (-not $sawPowerShell) {
        # The toast runs as a child process; a probe that never saw one would
        # prove nothing by finding no marker. Querying Win32_Process was too slow
        # to catch it -- a PowerShell start plus a toast is under a second -- so
        # this compares start times instead, which Get-Process answers quickly.
        $started = @(Get-Process powershell -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $appStart })
        if ($started.Count -gt 0) { $sawPowerShell = $true }
    }
    if ($title -like '*ALLDONE*') { break }
}
Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host "title: $title"
Write-Host "powershell child seen: $sawPowerShell"
if (Test-Path $resultPath) { Get-Content $resultPath | ForEach-Object { Write-Host "  $_" } }

$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the page never finished' }
if (-not (Test-Path $resultPath)) { $failures += 'the page wrote no results' }
if (-not $sawPowerShell) { $failures += 'craft never spawned PowerShell, so nothing was proven about escaping' }
if (Test-Path $markerTitle) {
    $failures += "a title created $markerTitle -- the title became code"
    Remove-Item $markerTitle -Force -ErrorAction SilentlyContinue
}
if (Test-Path $markerBody) {
    $failures += "a body created $markerBody -- the body became code"
    Remove-Item $markerBody -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 8 | ForEach-Object { "  log: $_" } }
    if ($createdAppId) { Remove-Item $appIdFile -Force -ErrorAction SilentlyContinue }
    exit 1
}
if ($createdAppId) { Remove-Item $appIdFile -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS: the toast ran, and neither a title nor a body became PowerShell' -ForegroundColor Green
exit 0
