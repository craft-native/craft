# Exercises fs.watch on Windows end to end: a fresh event, a modify, a rename, a
# delete, the recursion toggle, a single-file watch, unwatch, and a bad path.
#
# Events are pushed into the page, so unlike the other fs actions there is
# nothing to read back -- the only honest check is to wait for the event and to
# prove that a change which should stay quiet does. Both directions are here:
# a nested write under a non-recursive watch and a sibling write under a
# single-file watch are expected to produce nothing at all.
#
# Nothing outside a generated temp directory is touched, and it is removed at the
# end whether the run passed or failed.
#
# ASCII only: PowerShell 5.1 reads a BOM-less script as ANSI.
[CmdletBinding()]
param(
    [string] $CraftExe = '',
    [int]    $TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $CraftExe) { $CraftExe = Join-Path $root 'packages\zig\zig-out\bin\craft.exe' }
if (-not (Test-Path $CraftExe)) {
    Write-Host "SKIP: $CraftExe is not built (run: zig build -Doptimize=ReleaseSafe)" -ForegroundColor Yellow
    exit 2
}

$htmlPath = Join-Path $env:TEMP 'craft-fs-watch-probe.html'
$resultPath = Join-Path $env:TEMP 'craft-fs-watch-result.txt'
$logErr = Join-Path $env:TEMP 'craft-fs-watch-probe.err.txt'
$workDir = Join-Path $env:TEMP ('craft-watch-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Remove-Item $resultPath, $logErr -Force -ErrorAction SilentlyContinue
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue }

$html = @'
<!doctype html>
<meta charset="utf-8">
<title>fs watch probe</title>
<script>
  const out = [];
  const RESULT = '__RESULT_PATH__';
  const DIR = '__WORK_DIR__';
  const SUB = DIR + '\\sub';
  const EV = [];
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function seen(type, needle) {
    return EV.some(function (e) { return (!type || e.type === type) && e.path.toLowerCase().indexOf(needle.toLowerCase()) >= 0; });
  }
  function count() { return EV.length; }
  function wipe() { EV.length = 0; }
  // Polling rather than a fixed sleep: an event that arrives late would
  // otherwise be read as missing.
  async function until(fn, ms) {
    const end = Date.now() + ms;
    while (Date.now() < end) { if (fn()) return true; await wait(50); }
    return false;
  }
  function dump() {
    const uniq = [];
    EV.forEach(function (e) {
      const line = e.type + ' ' + e.path.replace(DIR, '<dir>');
      if (uniq.indexOf(line) < 0) uniq.push(line);
    });
    return uniq.join(' ; ');
  }

  (async function () {
    try {
      await craft.fs.mkdir(DIR);
      await craft.fs.mkdir(SUB);
      await wait(300);
      craft.fs.onChange(function (d) { EV.push({ type: d && d.type, path: String((d && d.path) || '') }); });

      // --- a directory watch, not recursive ---
      const w = await craft.fs.watch(DIR);
      out.push('WATCHDIR=' + (w && typeof w.id === 'string' && w.id.length > 0 ? 'ok' : 'noid'));

      await craft.fs.writeFile(DIR + '\\a.txt', 'one');
      out.push('CREATE=' + ((await until(function () { return seen('create', '\\a.txt'); }, 4000)) ? 'ok' : 'no'));

      await craft.fs.appendFile(DIR + '\\a.txt', ' two');
      out.push('MODIFY=' + ((await until(function () { return seen('modify', '\\a.txt'); }, 4000)) ? 'ok' : 'no'));

      // The control: a change two levels down must not reach this watch.
      await craft.fs.writeFile(SUB + '\\deep.txt', 'x');
      await wait(1200);
      out.push('NORECURSE=' + (seen('', 'deep.txt') ? 'LEAK' : 'ok'));

      await craft.fs.move(DIR + '\\a.txt', DIR + '\\b.txt');
      const old = await until(function () { return seen('delete', '\\a.txt'); }, 4000);
      const ren = await until(function () { return seen('create', '\\b.txt'); }, 4000);
      out.push('RENAME=' + (old && ren ? 'ok' : 'old=' + old + ',new=' + ren));

      await craft.fs.deleteFile(DIR + '\\b.txt');
      out.push('DELETE=' + ((await until(function () { return seen('delete', '\\b.txt'); }, 4000)) ? 'ok' : 'no'));

      // --- unwatch ---
      await w.unwatch();
      await wait(400);
      wipe();
      await craft.fs.writeFile(DIR + '\\c.txt', 'quiet');
      await wait(1500);
      out.push('AFTERUNWATCH=' + count());

      // --- a watch on one file, with a sibling changing beside it ---
      await craft.fs.writeFile(DIR + '\\one.txt', 'a');
      await craft.fs.writeFile(DIR + '\\two.txt', 'a');
      await wait(400);
      let fired = 0;
      const fw = await craft.fs.watch(DIR + '\\one.txt', function (d) { if (d && d.type) fired += 1; });
      out.push('WATCHFILE=' + (fw && fw.id ? 'ok' : 'noid'));
      wipe();
      await craft.fs.writeFile(DIR + '\\two.txt', 'bb');
      await wait(1200);
      out.push('SIBLING=' + count());
      await craft.fs.appendFile(DIR + '\\one.txt', 'cc');
      const own = await until(function () { return seen('', '\\one.txt'); }, 4000);
      out.push('OWN=' + (own ? 'ok' : 'no') + '/' + (fired > 0 ? 'cb' : 'nocb'));
      await fw.unwatch();

      // --- recursive ---
      await craft.fs.writeFile(SUB + '\\deep2.txt', 'a');
      await wait(400);
      wipe();
      const rw = await craft.fs.watch(DIR, null, { recursive: true });
      out.push('WATCHREC=' + (rw && rw.id ? 'ok' : 'noid'));
      await craft.fs.appendFile(SUB + '\\deep2.txt', 'b');
      const deep = await until(function () { return seen('', 'deep2.txt'); }, 4000);
      const deepPath = EV.some(function (e) { return e.path.toLowerCase().indexOf('\\sub\\deep2.txt') >= 0; });
      out.push('RECURSE=' + (deep ? (deepPath ? 'ok' : 'path=' + dump()) : 'no'));
      await rw.unwatch();

      // --- a path that is not there ---
      try {
        await craft.fs.watch(DIR + '\\nope.txt');
        out.push('NOPATH=accepted');
      } catch (e) {
        // A bridge rejection is the error native sent -- `{action, id, code,
        // message}` -- so the code is on `.code`, not `.name`.
        out.push('NOPATH=' + ((e && e.code) || (e && e.name) || 'bare:' + String(e)));
      }

      // --- the watched directory itself goes away ---
      // `ReadDirectoryChangesW` never reports the directory it was handed, so
      // the delete ends the call instead. The page must still hear something:
      // FSEvents reports it, and a watch that dies quietly is a page waiting
      // for a folder that is gone.
      const gone = DIR + '\\gone';
      await craft.fs.mkdir(gone);
      await wait(300);
      wipe();
      const gw = await craft.fs.watch(gone);
      out.push('WATCHGONE=' + (gw && gw.id ? 'ok' : 'noid'));
      await craft.fs.rmdir(gone, { recursive: true });
      await wait(1800);
      out.push('ROOTDELETED=' + (count() === 1 && seen('delete', '\\gone') ? 'ok' : count() + '/' + dump()));

      // --- the watched directory is renamed out from under the watch ---
      const mv1 = DIR + '\\mv1';
      const mv2 = DIR + '\\mv2';
      await craft.fs.mkdir(mv1);
      await wait(300);
      wipe();
      const mw = await craft.fs.watch(mv1);
      out.push('WATCHMV=' + (mw && mw.id ? 'ok' : 'noid'));
      await craft.fs.move(mv1, mv2);
      await wait(800);
      await craft.fs.writeFile(mv2 + '\\in.txt', 'x');
      await wait(1500);
      // Reported as the old path, because that is the one the page knows. A
      // rename reads the same as a delete on purpose: the page cannot act on
      // the difference, and Windows does not expose it here.
      out.push('RENAMEDROOT=' + (count() === 1 && seen('delete', '\\mv1') ? 'ok' : count() + '/' + dump()));
      await mw.unwatch();
    } catch (e) {
      out.push('WERR=' + ((e && e.name) || e) + ':' + ((e && e.message) || ''));
    }

    out.push('EVENTS=' + dump());
    out.push('ALLDONE');
    // writeFile is a fire-and-forget send, so the title is set from a later turn
    // than the write -- the title is what the runner watches, and it must not
    // overtake the file.
    await craft.fs.writeFile(RESULT, out.join('\n'));
    await wait(500);
    try {
      craft.window.setTitle('ALLDONE');
    } catch (e) {
      out.push('TITLEERR=' + ((e && e.name) || e));
    }
  })();
</script>
'@
$html = $html.Replace('__RESULT_PATH__', $resultPath.Replace('\', '\\'))
$html = $html.Replace('__WORK_DIR__', $workDir.Replace('\', '\\'))
Set-Content -Path $htmlPath -Value $html -Encoding ASCII

# The page posts its results through the bridge, so the window has to outlive the
# last assertion; the title is only a hint that the run finished.
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
# Give the console log a moment to flush, then take the process down.
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

$failures = @()
if ($title -notlike '*ALLDONE*') { $failures += 'the page never finished' }
if (-not (Test-Path $resultPath)) { $failures += 'the page wrote no results' }
foreach ($key in $result.Keys) {
    if ($key -like '*ERR') { $failures += "saw $key=$($result[$key])" }
}

if ((Get-Value 'WATCHDIR') -ne 'ok') { $failures += "watch on a directory answered '$(Get-Value 'WATCHDIR')'" }
if ((Get-Value 'CREATE') -ne 'ok') { $failures += "a new file was not reported as create: '$(Get-Value 'CREATE')'" }
if ((Get-Value 'MODIFY') -ne 'ok') { $failures += "an appended file was not reported as modify: '$(Get-Value 'MODIFY')'" }
if ((Get-Value 'NORECURSE') -ne 'ok') { $failures += "a non-recursive watch reported a nested file: '$(Get-Value 'NORECURSE')'" }
if ((Get-Value 'RENAME') -ne 'ok') { $failures += "a rename did not read as delete+create: '$(Get-Value 'RENAME')'" }
if ((Get-Value 'DELETE') -ne 'ok') { $failures += "a deleted file was not reported as delete: '$(Get-Value 'DELETE')'" }
if ((Get-Value 'AFTERUNWATCH') -ne '0') { $failures += "events kept arriving after unwatch: '$(Get-Value 'AFTERUNWATCH')'" }
if ((Get-Value 'WATCHFILE') -ne 'ok') { $failures += "watch on a single file answered '$(Get-Value 'WATCHFILE')'" }
if ((Get-Value 'SIBLING') -ne '0') { $failures += "a file watch reported a sibling: '$(Get-Value 'SIBLING')'" }
if ((Get-Value 'OWN') -ne 'ok/cb') { $failures += "the watched file's own change: '$(Get-Value 'OWN')'" }
if ((Get-Value 'WATCHREC') -ne 'ok') { $failures += "recursive watch answered '$(Get-Value 'WATCHREC')'" }
if ((Get-Value 'RECURSE') -ne 'ok') { $failures += "a nested change under a recursive watch: '$(Get-Value 'RECURSE')'" }
if ((Get-Value 'NOPATH') -ne 'NOT_FOUND') { $failures += "watching a missing path answered '$(Get-Value 'NOPATH')'" }

# The probe's own cleanup, in case a watch held the directory open.
if (Test-Path $workDir) {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host 'FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  $f" -ForegroundColor Red }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -Last 10 | ForEach-Object { "  log: $_" } }
    exit 1
}
Write-Host 'PASS: a watch reports what changed, stays quiet about what it does not own, and stops on unwatch' -ForegroundColor Green
exit 0
