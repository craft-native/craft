# Repeats the Windows `craft.timers` probes and asserts the numbers.
#
# The JS facade passes timeout 0 to `_req` for `sleep`, so the promise settles
# only when a native reply arrives. A missing reply therefore shows up as a
# deadline that never reports, which is exactly the failure this catches.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI, so any non-ASCII
# byte here would arrive mangled.
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

$htmlPath = Join-Path $env:TEMP 'craft-timers-probe.html'
$logOut = Join-Path $env:TEMP 'craft-timers-probe.out.txt'
$logErr = Join-Path $env:TEMP 'craft-timers-probe.err.txt'

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>timers probe</title>
<script>
  const out = [];
  function show() { try { craft.window.setTitle(out.join(' | ')); } catch (e) {} }
  function mark(s) { out.push(s); show(); }
  craft.window.setTitle('T0');
  (async () => {
    const t0 = performance.now();
    try {
      await craft.timers.sleep(400);
      mark('T1=' + Math.round(performance.now() - t0));
    } catch (e) { mark('T1ERR:' + e.name); }

    const ac = new AbortController();
    const pending = craft.timers.sleep(5000, { signal: ac.signal });
    setTimeout(() => ac.abort(), 100);
    try { await pending; mark('T2=RESOLVED'); } catch (e) { mark('T2=' + e.name); }

    const t3 = performance.now();
    const at = () => Math.round(performance.now() - t3);
    const a = craft.timers.sleep(200).then(() => mark('A=' + at()), e => mark('AERR:' + e.name));
    const b = craft.timers.sleep(600).then(() => mark('B=' + at()), e => mark('BERR:' + e.name));
    await Promise.allSettled([a, b]);

    const t4 = performance.now();
    try {
      await craft.timers.sleep(150);
      mark('T4=' + Math.round(performance.now() - t4));
    } catch (e) { mark('T4ERR:' + e.name); }
    mark('ALLDONE');
  })().catch(e => mark('FATAL:' + e.name));
</script>
'@
Set-Content -Path $htmlPath -Value $html -Encoding ASCII
Remove-Item $logOut, $logErr -Force -ErrorAction SilentlyContinue

# A running craft holds its own binary open; it also answers for the window.
Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '560', '--height', '360') `
    -PassThru -RedirectStandardOutput $logOut -RedirectStandardError $logErr

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
    Write-Host 'FAIL: the window never titled itself; the page did not run' -ForegroundColor Red
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  $_" } }
    exit 1
}

Write-Host "observed: $title"

function Get-Mark([string] $name) {
    $m = [regex]::Match($title, [regex]::Escape($name) + '=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -1
}

$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the page never reached ALLDONE' }
if ($title -like '*T1ERR*') { $failures += 'the first deadline was rejected' }
if ($title -like '*T2=RESOLVED*') { $failures += 'aborting a deadline resolved instead of rejecting' }
if ($title -like '*T2=AbortError*' -eq $false) { $failures += 'aborting did not produce AbortError' }
foreach ($name in 'AERR', 'BERR', 'T4ERR', 'FATAL') {
    if ($title -like "*$name*") { $failures += "saw $name" }
}

$t1 = Get-Mark 'T1'
if ($t1 -lt 250 -or $t1 -gt 1500) { $failures += "T1 measured ${t1}ms for a 400ms deadline" }
$a = Get-Mark 'A'
if ($a -lt 120 -or $a -gt 900) { $failures += "A measured ${a}ms for a 200ms deadline" }
$b = Get-Mark 'B'
if ($b -lt 450 -or $b -gt 1600) { $failures += "B measured ${b}ms for a 600ms deadline" }
if ($a -ge 0 -and $b -ge 0 -and $a -ge $b) { $failures += "the 200ms deadline (${a}ms) did not beat the 600ms one (${b}ms)" }
$t4 = Get-Mark 'T4'
if ($t4 -lt 80 -or $t4 -gt 900) { $failures += "T4 measured ${t4}ms for a 150ms deadline" }

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  log: $_" } }
    exit 1
}

Write-Host 'PASS: sleep, abort, concurrent deadlines and slot reuse all behaved' -ForegroundColor Green
exit 0
