import { expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { nativeWindowsCommand } from './windows-command'

function owner(): string {
  const binary = process.env.CRAFT_NATIVE_WINDOWS_COMMAND_OWNER
  if (!binary || !existsSync(binary)) throw new Error('Build and declare the first-party Windows command owner before native acceptance')
  return binary
}
function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'ESRCH') return false; throw error }
}
async function until(check: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = performance.now() + timeoutMs
  while (!check()) {
    if (performance.now() >= deadline) throw new Error('Native Windows command condition did not complete')
    await Bun.sleep(20)
  }
}
const nativeTest = test.skipIf(process.platform !== 'win32')

nativeTest('the Job Object preserves exact Unicode and Windows CRT argv', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-native-argv-'))
  try {
    const script = join(directory, 'argument inspection.js')
    writeFileSync(script, 'console.log(JSON.stringify(process.argv.slice(2)))')
    const args = ['', 'two words', 'quote"inside', 'C:\\space here\\', 'tail\\\\', 'Ω settler', '$(literal) & `literal`']
    const result = await nativeWindowsCommand(owner(), [process.execPath, script, ...args], { cwd: directory, timeoutMs: 5000 })
    expect(result.code).toBe(0)
    expect(result.jobDisposed).toBe(true)
    expect(JSON.parse(result.stdout)).toEqual(args)
  }
  finally { rmSync(directory, { recursive: true, force: true }) }
}, 10_000)

nativeTest('normal completion disposes an orphan while preserving an unrelated process', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-native-descendant-'))
  const marker = join(directory, 'child.pid')
  const unrelated = Bun.spawn([process.execPath, '-e', 'setInterval(() => {}, 1000)'], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' })
  let disposed = false
  try {
    const source = `const child=Bun.spawn([process.execPath,'-e','setInterval(()=>{},1000)'],{stdin:'ignore',stdout:'inherit',stderr:'inherit'});await Bun.write(${JSON.stringify(marker)},String(child.pid));process.exit(0)`
    const result = await nativeWindowsCommand(owner(), [process.execPath, '-e', source], { cwd: directory, timeoutMs: 5000 })
    disposed = result.jobDisposed
    expect(result.code).toBe(0)
    expect(alive(Number(readFileSync(marker, 'utf8')))).toBe(false)
    expect(alive(unrelated.pid)).toBe(true)
  }
  finally {
    unrelated.kill(); await unrelated.exited
    if (disposed) rmSync(directory, { recursive: true, force: true })
  }
}, 10_000)

for (const mode of ['timeout', 'cancellation'] as const) {
  nativeTest(`${mode} disposes the command and its actual descendant`, async () => {
    const directory = mkdtempSync(join(tmpdir(), 'craft-native-stop-'))
    const marker = join(directory, 'owned.json')
    const signal = new AbortController()
    let trigger: ReturnType<typeof setInterval> | undefined
    let disposed = false
    try {
      const source = `const child=Bun.spawn([process.execPath,'-e','setInterval(()=>{},1000)'],{stdin:'ignore',stdout:'inherit',stderr:'inherit'});await Bun.write(${JSON.stringify(marker)},JSON.stringify({parent:process.pid,child:child.pid}));setInterval(()=>{},1000)`
      if (mode === 'cancellation') trigger = setInterval(() => { if (existsSync(marker)) signal.abort() }, 20)
      const result = await nativeWindowsCommand(owner(), [process.execPath, '-e', source], { cwd: directory, timeoutMs: mode === 'timeout' ? 2000 : 5000, signal: signal.signal })
      disposed = result.jobDisposed
      const owned = JSON.parse(readFileSync(marker, 'utf8')) as { parent: number, child: number }
      expect(result.timedOut).toBe(mode === 'timeout')
      expect(result.cancelled).toBe(mode === 'cancellation')
      expect(result.code).not.toBe(0)
      expect(alive(owned.parent)).toBe(false)
      expect(alive(owned.child)).toBe(false)
    }
    finally {
      if (trigger) clearInterval(trigger)
      if (disposed) rmSync(directory, { recursive: true, force: true })
    }
  }, 12_000)
}

nativeTest('a dead controlling process triggers native job disposal and an original receipt', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-native-parent-'))
  const marker = join(directory, 'owned.json'), receipt = join(directory, 'receipt.json')
  const parent = Bun.spawn([process.execPath, '-e', 'setInterval(() => {}, 1000)'], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' })
  const source = `const child=Bun.spawn([process.execPath,'-e','setInterval(()=>{},1000)'],{stdin:'ignore',stdout:'inherit',stderr:'inherit'});await Bun.write(${JSON.stringify(marker)},JSON.stringify({parent:process.pid,child:child.pid}));setInterval(()=>{},1000)`
  const command = Bun.spawn([owner(), String(parent.pid), '10000', receipt, join(directory, 'cancel'), process.execPath, '-e', source], { cwd: directory, stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' })
  let disposed = false
  try {
    await until(() => existsSync(marker))
    parent.kill(); await parent.exited
    await until(() => existsSync(receipt), 7000)
    expect(await command.exited).toBe(0)
    const result = JSON.parse(readFileSync(receipt, 'utf8'))
    disposed = result.jobDisposed === true
    expect(result.cancelled).toBe(true)
    expect(result.jobDisposed).toBe(true)
    const owned = JSON.parse(readFileSync(marker, 'utf8')) as { parent: number, child: number }
    expect(alive(owned.parent)).toBe(false)
    expect(alive(owned.child)).toBe(false)
  }
  finally {
    if (parent.exitCode === null) parent.kill()
    if (command.exitCode === null) command.kill()
    await Promise.all([parent.exited, command.exited])
    if (disposed) rmSync(directory, { recursive: true, force: true })
  }
}, 15_000)

nativeTest('native child failure retains its exit status and complete diagnostic output', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-native-log-'))
  try {
    const logPath = join(directory, 'native.log')
    const result = await nativeWindowsCommand(owner(), [process.execPath, '-e', 'console.log("native stdout");console.error("native stderr");process.exit(7)'], { cwd: directory, timeoutMs: 5000, logPath })
    expect(result.code).toBe(7)
    expect(result.jobDisposed).toBe(true)
    expect(readFileSync(logPath, 'utf8').replaceAll('\r\n', '\n')).toBe('native stdout\nnative stderr\n')
  }
  finally { rmSync(directory, { recursive: true, force: true }) }
}, 10_000)
