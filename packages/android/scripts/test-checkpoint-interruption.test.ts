import { expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { NativeFixtureCommandScope } from '../../ios/scripts/native-fixture-command'
import { captureAndroidNativeDiagnostics, captureAndroidNativeUi, launchAndroidNativeFixture } from './native-fixture-launch'

const root = resolve(import.meta.dir, '../../..')
const runner = join(import.meta.dir, 'test-checkpoint-interruption.ts')

async function fixture(run: (directory: string, scope: NativeFixtureCommandScope) => Promise<void>) {
  const directory = await mkdtemp(join(tmpdir(), 'craft-checkpoint-runner-test-'))
  const scope = new NativeFixtureCommandScope()
  try { await run(directory, scope) }
  finally {
    if (!scope.allDisposed) throw new Error(`Owned runner process group remains: ${directory}`)
    await rm(directory, { recursive: true, force: true })
  }
}

async function toolchain(directory: string, mode: 'failure' | 'cancellation') {
  const bin = join(directory, 'bin'), ndk = join(directory, 'ndk'), sdk = join(directory, 'sdk'), output = join(directory, 'output')
  await Promise.all([mkdir(bin), mkdir(sdk), mkdir(output)])
  const compilerDirectory = join(ndk, 'toolchains/llvm/prebuilt', process.platform === 'darwin' ? 'darwin-x86_64' : 'linux-x86_64', 'bin')
  await mkdir(compilerDirectory, { recursive: true })
  await writeFile(join(ndk, 'source.properties'), 'Pkg.Revision = 27.2.12479018\n')
  for (const [name, version] of [['sdkmanager', 'Android SDK fixture'], ['avdmanager', 'Android AVD fixture'], ['gradle', 'Gradle 8.11.1'], ['java', 'openjdk version "17.0.19"']]) {
    const file = join(bin, name!)
    await writeFile(file, `#!${process.execPath}\nif (process.argv.includes('--version') || process.argv.includes('-version')) console.log(${JSON.stringify(version)}); else { await Bun.write(${JSON.stringify(join(directory, 'unexpected-native-work'))}, process.argv.join(' ')); process.exit(90); }\n`)
    await chmod(file, 0o755)
  }
  const compiler = join(compilerDirectory, `${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-linux-android35-clang`)
  const marker = join(directory, 'compiler-processes.json')
  await writeFile(compiler, `#!${process.execPath}\nif (process.argv.includes('--version')) console.log('Android fixture clang version 18.0.3'); else {
    ${mode === 'failure' ? 'console.error("actual compiler exit 7"); process.exit(7);' : `
    process.on('SIGTERM',()=>{});
    const child=Bun.spawn([process.execPath,'-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],{stdin:'ignore',stdout:'ignore',stderr:'ignore'});
    await Bun.write(${JSON.stringify(marker)},JSON.stringify({runner:process.ppid,compiler:process.pid,child:child.pid}));
    setInterval(()=>{},1000);`}
  }\n`)
  await chmod(compiler, 0o755)
  await writeFile(join(compilerDirectory, 'clang'), await readFile(compiler))
  await chmod(join(compilerDirectory, 'clang'), 0o755)
  return { output, marker, env: [`ANDROID_HOME=${sdk}`, 'ANDROID_SDK_ROOT=', `ANDROID_NDK_HOME=${ndk}`, `PATH=${bin}:${process.env.PATH}`] }
}

async function receipt(output: string) {
  const runs = await readdir(output)
  expect(runs).toHaveLength(1)
  return JSON.parse(await readFile(join(output, runs[0]!, 'verification.json'), 'utf8'))
}

test('missing Android prerequisites allocate no output or workspace', async () => {
  await fixture(async (directory, scope) => {
    const result = await scope.run(['/usr/bin/env', `TMPDIR=${directory}`, 'ANDROID_HOME=', 'ANDROID_SDK_ROOT=', 'ANDROID_NDK_HOME=', `PATH=${directory}`, process.execPath, runner, '--output', join(directory, 'output')], { cwd: root, timeoutMs: 10000 })
    expect(result.code).not.toBe(0)
    expect(result.stderr).toContain('Select SDK, NDK and Pantry Android command-line tools')
    expect(await readdir(directory)).toEqual([])
  })
}, 15000)

test('workspace acquisition failure retains its original failure and disposes everything acquired', async () => {
  await fixture(async (directory, scope) => {
    const tools = await toolchain(directory, 'failure')
    const blocked = join(directory, 'blocked')
    await writeFile(blocked, 'not a directory')
    const result = await scope.run(['/usr/bin/env', ...tools.env, `TMPDIR=${blocked}`, process.execPath, runner, '--output', tools.output], { cwd: root, timeoutMs: 10000 })
    expect(result.code).not.toBe(0)
    expect(result.stdout).toContain('"status":"failed"')
    const report = await receipt(tools.output)
    expect(report.status).toBe('failed')
    expect(report.error).toContain('mkdtemp')
    expect(report.commandGroupsDisposed).toBe(true)
    expect(await Bun.file(join(directory, 'unexpected-native-work')).exists()).toBe(false)
  })
}, 15000)

test('real compiler failure preserves exit status and full log without starting an emulator', async () => {
  await fixture(async (directory, scope) => {
    const tools = await toolchain(directory, 'failure')
    const result = await scope.run(['/usr/bin/env', ...tools.env, `TMPDIR=${directory}`, process.execPath, runner, '--output', tools.output], { cwd: root, timeoutMs: 10000 })
    expect(result.code).not.toBe(0)
    const report = await receipt(tools.output)
    expect(report.status).toBe('failed')
    expect(report.workspaceDisposed).toBe(true)
    expect(report.commandGroupsDisposed).toBe(true)
    const command = report.commands.find((item: { name: string }) => item.name === 'compile-debug-interposer')
    expect(command.code).toBe(7)
    expect(await readFile(command.logPath, 'utf8')).toBe('actual compiler exit 7\n')
    expect(await Bun.file(join(directory, 'unexpected-native-work')).exists()).toBe(false)
    expect(report.serial).toBeUndefined()
  })
}, 15000)

test('SIGINT during native work kills owned descendants, retains failure, and leaves unrelated processes alive', async () => {
  await fixture(async (directory, scope) => {
    const tools = await toolchain(directory, 'cancellation')
    const unrelated = Bun.spawn([process.execPath, '-e', 'setInterval(()=>{},1000)'], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' })
    let sent = false
    const timer = setInterval(() => {
      if (sent || !existsSync(tools.marker)) return
      const data = readFileSync(tools.marker, 'utf8')
      if (!data.trim().endsWith('}')) return
      const owned = JSON.parse(data)
      process.kill(owned.runner, 'SIGINT'); sent = true
    }, 10)
    try {
      const result = await scope.run(['/usr/bin/env', ...tools.env, `TMPDIR=${directory}`, process.execPath, runner, '--output', tools.output], { cwd: root, timeoutMs: 10000 })
      expect(sent).toBe(true)
      expect(result.code).not.toBe(0)
      const report = await receipt(tools.output)
      expect(report.status).toBe('failed')
      expect(report.workspaceDisposed).toBe(true)
      expect(report.commandGroupsDisposed).toBe(true)
      expect(report.commands.find((item: { name: string }) => item.name === 'compile-debug-interposer').cancelled).toBe(true)
      const owned = JSON.parse(await readFile(tools.marker, 'utf8'))
      for (const pid of [owned.compiler, owned.child]) expect(() => process.kill(pid, 0)).toThrow()
      expect(() => process.kill(unrelated.pid, 0)).not.toThrow()
      expect(await Bun.file(join(directory, 'unexpected-native-work')).exists()).toBe(false)
    }
    finally { clearInterval(timer); unrelated.kill('SIGKILL'); await unrelated.exited }
  })
}, 15000)

// Unit checks for phase ownership. Actual Android interruption remains a native gate.
function launchFixture() {
  let clock = 0
  const calls: { label: string, args: string[], timeoutMs: number }[] = []
  const xml = '<hierarchy><node package="dev.craft.probe" text="Ready" /></hierarchy>'
  const options = {
    label: 'cold', packageName: 'dev.craft.probe', readyText: 'Ready',
    adb: (...args: string[]) => ['adb', '-s', 'owned-device', ...args],
    now: () => clock,
    run: async (label: string, args: string[], timeoutMs: number): Promise<string> => {
      calls.push({ label, args, timeoutMs })
      clock += label.endsWith('-launch') ? 50 : 5
      return label.endsWith('-pid') ? '12345\n' : 'Starting: Intent'
    },
    waitForUi: async (text: string, label: string, deadline: number) => {
      expect([text, label, deadline]).toEqual(['Ready', 'cold', 30000])
      clock += 15000
      return xml
    },
  }
  return { options, calls, xml, at(value: number) { clock = value } }
}

test('native first draw uses the shared UI budget after bounded intent acknowledgement', async () => {
  const f = launchFixture()
  const result = await launchAndroidNativeFixture(f.options)
  expect(result).toEqual({ pid: '12345', xml: f.xml, elapsedMs: 15055, boundMs: 30000 })
  expect(f.calls.map(call => call.label)).toEqual(['cold-launch', 'cold-pid'])
  expect(f.calls[0]!.args).toEqual(['adb', '-s', 'owned-device', 'shell', 'am', 'start', '-n', 'dev.craft.probe/.MainActivity'])
  expect(f.calls.every(call => call.timeoutMs <= 10000)).toBe(true)
})

test.each(['ui', 'pid'])('native launch rejects readiness returned after the shared deadline (%s)', async (stage) => {
  const f = launchFixture()
  if (stage === 'ui') f.options.waitForUi = async () => { f.at(30001); return f.xml }
  else {
    const run = f.options.run
    f.options.run = async (label, args, timeoutMs) => {
      const answer = await run(label, args, timeoutMs)
      if (label.endsWith('-pid')) f.at(30001)
      return answer
    }
  }
  await expect(launchAndroidNativeFixture(f.options)).rejects.toThrow('original 30000ms bound')
  if (stage === 'ui') expect(f.calls.map(call => call.label)).toEqual(['cold-launch'])
})

test('native launch refuses another application surface and multiple processes', async () => {
  const foreign = launchFixture()
  foreign.options.waitForUi = async () => '<node package="other.application" text="Ready" />'
  await expect(launchAndroidNativeFixture(foreign.options)).rejects.toThrow('different application')
  const multiple = launchFixture()
  const run = multiple.options.run
  multiple.options.run = async (label, args, timeoutMs) => label.endsWith('-pid') ? '12345 67890' : run(label, args, timeoutMs)
  await expect(launchAndroidNativeFixture(multiple.options)).rejects.toThrow('exactly one fixture app process')
})

// Actual Android 430 output: the tool exits zero before a root tree exists.
test('native UI capture treats an explicitly missing root as not yet observed', async () => {
  const calls: string[] = []
  const xml = await captureAndroidNativeUi({
    label: 'first', deadline: 30000, now: () => 0,
    adb: (...args) => ['adb', ...args],
    run: async (label) => {
      calls.push(label)
      if (label === 'first-dump') return 'ERROR: null root node returned by UiTestAutomationBridge.\n'
      throw new Error('cat: /data/local/tmp/checkpoint-probe.xml: No such file or directory')
    },
  })
  expect(xml).toBeNull()
  expect(calls).toEqual(['first-dump'])
})


test('native UI capture accepts only a fresh complete tree and preserves its command cap', async () => {
  const paths: string[] = []
  const xml = '<?xml version="1.0"?><hierarchy><node package="dev.craft.probe" /></hierarchy>'
  for (let observation = 0; observation < 2; observation++) {
    let clock = 0
    const calls: string[] = []
    expect(await captureAndroidNativeUi({
      label: 'ready', deadline: 30000, now: () => clock,
      adb: (...args) => ['adb', ...args],
      run: async (label, args, timeoutMs) => {
        expect(timeoutMs).toBe(10000 - clock)
        clock += 10
        calls.push(label)
        if (label.endsWith('-dump')) {
          const path = args.at(-1)!
          paths.push(path)
          return `UI hierchary dumped to: ${path}\n`
        }
        return label.endsWith('-xml') ? xml : ''
      },
    })).toBe(xml)
    expect(calls).toEqual(['ready-dump', 'ready-xml', 'ready-remove'])
  }
  expect(paths[0]).not.toBe(paths[1])
})

test.each(['transport', 'unknown-output', 'invalid-tree', 'late-root'])('native UI capture propagates failure rather than treating it as missing root (%s)', async (failure) => {
  await expect(captureAndroidNativeUi({
    label: 'bad', deadline: 30000, now: (() => { let calls = 0; return () => failure === 'late-root' && calls++ > 1 ? 10001 : 0 })(),
    adb: (...args) => ['adb', ...args],
    run: async (label, args) => {
      if (failure === 'transport') throw new Error('adb disconnected')
      if (failure === 'late-root') return 'ERROR: null root node returned by UiTestAutomationBridge.\n'
      if (failure === 'unknown-output') return 'ERROR: permission denied'
      return label.endsWith('-dump') ? `UI hierchary dumped to: ${args.at(-1)}` : '<hierarchy>truncated'
    },
  })).rejects.toThrow()
})

test('failed native display diagnostics stay owned, read-only and within one eight-second budget', async () => {
  let clock = 0
  const calls: Array<{ label: string, args: string[], timeoutMs: number }> = []
  const results = await captureAndroidNativeDiagnostics({
    packageName: 'dev.craft.checkpointprobe', now: () => clock,
    adb: (...args) => ['owned-adb', '-s', 'owned-device', ...args],
    run: async (label, args, timeoutMs) => {
      calls.push({ label, args, timeoutMs })
      expect(timeoutMs).toBeLessThanOrEqual(2000)
      clock += timeoutMs
      if (label === 'display-surfaceflinger') throw new Error('display service did not answer')
      return ''
    },
  })
  expect(clock).toBe(8000)
  expect(calls).toHaveLength(4)
  for (const call of calls) expect(call.args.slice(0, 4)).toEqual(['owned-adb', '-s', 'owned-device', 'shell'])
  expect(calls.map(call => call.args[4])).toEqual(['dumpsys', 'dumpsys', 'dumpsys', 'ps'])
  expect(calls[1]!.args).toContain('dev.craft.checkpointprobe')
  expect(results[0]).toEqual({ name: 'display-surfaceflinger', status: 'failed', error: 'Error: display service did not answer' })
  expect(results.slice(1).every(result => result.status === 'captured')).toBe(true)
})

test('diagnostics cannot start another command after their total deadline', async () => {
  let clock = 0
  const results = await captureAndroidNativeDiagnostics({
    packageName: 'dev.craft.checkpointprobe', now: () => clock,
    adb: (...args) => ['owned-adb', ...args],
    run: async () => { clock = 8000; throw new Error('original display fault') },
  })
  expect(results).toHaveLength(1)
  expect(results[0]!.status).toBe('failed')
})
