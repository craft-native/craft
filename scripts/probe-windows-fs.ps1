# Exercises the Windows filesystem bridge end to end, inside one temp directory.
#
# Most mutating fs actions are fire-and-forget sends: `writeFile` resolving means
# the message was posted, not that the file exists. So every mutation here is
# checked by reading the result back, which is the only thing a page can rely on.
#
# Nothing outside a generated temp directory is touched, and it is removed at the
# end whether the run passed or failed.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    [string] $CraftExe = '',
    [int]    $TimeoutSeconds = 40
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }
if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (run: zig build -Doptimize=ReleaseSafe)" -ForegroundColor Yellow
    exit 2
}

$htmlPath = Join-Path $env:TEMP 'craft-fs-probe.html'
$resultPath = Join-Path $env:TEMP 'craft-fs-result.txt'
$logErr = Join-Path $env:TEMP 'craft-fs-probe.err.txt'
$workDir = Join-Path $env:TEMP ('craft-fs-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Remove-Item $resultPath, $logErr -Force -ErrorAction SilentlyContinue
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }

$dirLiteral = $workDir.Replace('\', '\\')

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>fs probe</title>
<script>
  const out = [];
  const RESULT = '__RESULT_PATH__';
  const DIR = '__WORK_DIR__';
  const F0 = DIR + '\\zero.txt';
  const F1 = DIR + '\\one.txt';
  const F2 = DIR + '\\two.txt';
  const F3 = DIR + '\\three.txt';
  async function settle() { await new Promise(function (r) { setTimeout(r, 300); }); }
  function has(value, needle) { return String(JSON.stringify(value)).indexOf(needle) >= 0; }

  (async function () {
    try {
      await craft.fs.mkdir(DIR); await settle();
      out.push('MKDIR=' + (await craft.fs.exists(DIR)));

      await craft.fs.writeFile(F1, 'hello'); await settle();
      out.push('WRITE=' + (has(await craft.fs.readFile(F1), 'hello') ? 'ok' : 'missing'));

      // The same append, but on a file nothing has read yet. If the two differ,
      // the earlier read is holding something open rather than appendFile being
      // wrong on its own.
      await craft.fs.writeFile(F0, 'a'); await settle();
      await craft.fs.appendFile(F0, 'b'); await settle();
      out.push('APPENDFRESH=' + (has(await craft.fs.readFile(F0), 'ab') ? 'ok' : 'no'));

      await craft.fs.appendFile(F1, ' world'); await settle();
      out.push('APPEND=' + (has(await craft.fs.readFile(F1), 'hello world') ? 'ok' : 'no'));

      const st = await craft.fs.stat(F1);
      out.push('STAT=' + st.isFile + ',' + st.isDirectory + ',' + st.size);

      await craft.fs.copy(F1, F2); await settle();
      out.push('COPY=' + (await craft.fs.exists(F2)) + '/' + (has(await craft.fs.readFile(F2), 'hello world') ? 'same' : 'diff'));

      await craft.fs.move(F2, F3); await settle();
      out.push('MOVE=' + (await craft.fs.exists(F2)) + ',' + (await craft.fs.exists(F3)));

      out.push('LIST=' + (has(await craft.fs.readDir(DIR), 'one.txt') ? 'has-one' : 'no-one'));

      await craft.fs.deleteFile(F3); await settle();
      out.push('DELETE=' + (await craft.fs.exists(F3)));

      const dirs = [await craft.fs.homeDir(), await craft.fs.tempDir(), await craft.fs.appDataDir()];
      out.push('DIRS=' + dirs.map(function (d) { return d && d.length > 0 ? '1' : '0'; }).join(''));
    } catch (e) {
      out.push('FSERR=' + ((e && e.name) || e) + ':' + ((e && e.message) || ''));
    }

    // Removing the directory is itself an fs action, so it is the last one tried.
    try {
      await craft.fs.rmdir(DIR, { recursive: true }); await settle();
      out.push('RMDIR=' + (await craft.fs.exists(DIR)));
    } catch (e) {
      out.push('RMERR=' + ((e && e.name) || e));
    }

    out.push('ALLDONE');
    await craft.fs.writeFile(RESULT, out.join('\n'));
    await settle();
    craft.window.setTitle('ALLDONE');
  })();
</script>
'@
$html = $html.Replace('__RESULT_PATH__', $resultPath.Replace('\', '\\'))
$html = $html.Replace('__WORK_DIR__', $dirLiteral)
Set-Content -Path $htmlPath -Value $html -Encoding ASCII

Get-Process craft -ErrorAction SilentlyContinue | Stop-Process -Force | Out-Null
Start-Sleep -Milliseconds 300

$proc = Start-Process -FilePath $CraftExe `
    -ArgumentList @('--html-file', $htmlPath, '-t', 'T0', '-w', '520', '--height', '320') `
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

if (Test-Path $resultPath) {
    Write-Host '--- results ---'
    Get-Content $resultPath | ForEach-Object { Write-Host "  $_" }
}

$result = @{}
if (Test-Path $resultPath) {
    foreach ($line in (Get-Content $resultPath)) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $result[$line.Substring(0, $at)] = $line.Substring($at + 1) }
    }
}
function Get-Value([string] $name) {
    if ($result.ContainsKey($name)) { return $result[$name] }
    return ''
}

$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the page never finished' }
if (-not (Test-Path $resultPath)) { $failures += 'the page wrote no results' }
foreach ($key in $result.Keys) {
    if ($key -like '*ERR') { $failures += "saw $key=$($result[$key])" }
}

if ((Get-Value 'MKDIR') -ne 'true') { $failures += "mkdir did not create the directory: '$(Get-Value 'MKDIR')'" }
if ((Get-Value 'WRITE') -ne 'ok') { $failures += "writeFile did not land: '$(Get-Value 'WRITE')'" }
if ((Get-Value 'APPENDFRESH') -ne 'ok') { $failures += "appendFile failed on a file nothing had read: '$(Get-Value 'APPENDFRESH')'" }
if ((Get-Value 'APPEND') -ne 'ok') { $failures += "appendFile did not land: '$(Get-Value 'APPEND')'" }
# 'hello world' is 11 bytes.
if ((Get-Value 'STAT') -ne 'true,false,11') { $failures += "stat answered '$(Get-Value 'STAT')', expected true,false,11" }
if ((Get-Value 'COPY') -ne 'true/same') { $failures += "copy answered '$(Get-Value 'COPY')'" }
if ((Get-Value 'MOVE') -ne 'false,true') { $failures += "move answered '$(Get-Value 'MOVE')'" }
if ((Get-Value 'LIST') -ne 'has-one') { $failures += "readDir answered '$(Get-Value 'LIST')'" }
if ((Get-Value 'DELETE') -ne 'false') { $failures += "deleteFile answered '$(Get-Value 'DELETE')'" }
if ((Get-Value 'DIRS') -ne '111') { $failures += "homeDir/tempDir/appDataDir answered '$(Get-Value 'DIRS')'" }
if ((Get-Value 'RMDIR') -ne 'false') { $failures += "rmdir answered '$(Get-Value 'RMDIR')'" }

# The probe's own cleanup, in case rmdir failed above.
if (Test-Path $workDir) {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($failures.Count -eq 0) { $failures += 'the temp directory survived the run' }
}

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 8 | ForEach-Object { "  log: $_" } }
    exit 1
}
Write-Host 'PASS: every fs action landed, checked by reading the result back' -ForegroundColor Green
exit 0
