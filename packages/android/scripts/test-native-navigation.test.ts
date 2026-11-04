import { describe, expect, test } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { withTempDir } from '../../typescript/src/temp-dir'
import { retainNativeNavigationEvidence } from './native-navigation-evidence'

const runner = resolve(import.meta.dir, 'test-native-navigation.ts')

async function fixture(options: { serial?: string, brokenAdb?: boolean, success?: boolean }, verify: (directory: string, result: Bun.SyncSubprocess<'pipe', 'pipe'>) => void): Promise<void> {
  await withTempDir('android-evidence-test', (directory) => {
    const bin = join(directory, 'bin')
    const scratch = join(directory, 'scratch')
    mkdirSync(bin)
    mkdirSync(scratch)
    const compiler = join(directory, 'compiler.ts')
    writeFileSync(compiler, `await Bun.write(process.argv[process.argv.indexOf('--output') + 1]!, 'var mutationProtocolVersion = 1; var action = "MUTATE";')`)
    const gradle = join(bin, 'gradle')
    writeFileSync(gradle, `#!/bin/sh
mkdir -p app/build/outputs/androidTest-results/connected app/build/reports/androidTests/connected app/build/outputs/connected_android_test_additional_output/debugAndroidTest
echo '${options.success ? '<testsuite tests="1" failures="0"><testcase name="first"/></testsuite>' : '<testsuite failures="1"><testcase name="first"><failure>native failure</failure></testcase></testsuite>'}' > app/build/outputs/androidTest-results/connected/TEST-native.xml
echo '${options.success ? 'native report: 1 test passed' : 'native report'}' > app/build/reports/androidTests/connected/index.html
echo 'device attachment' > app/build/outputs/connected_android_test_additional_output/debugAndroidTest/device.txt
${options.success ? "echo 'BUILD SUCCESSFUL'" : "echo 'original native Gradle failure' >&2"}
exit ${options.success ? 0 : 23}
`)
    chmodSync(gradle, 0o755)
    const adb = join(bin, 'adb')
    writeFileSync(adb, `#!/bin/sh
echo "$*" >> "$ADB_CALLS"
${options.brokenAdb ? "echo 'device unavailable' >&2; exit 7" : `case "$*" in
  *'-b all'*) echo '${options.success ? 'provider diagnostic: sandbox service connected' : 'provider first-fault: sandbox service disconnected'}';;
  *) echo 'device diagnostic';;
esac`}
`)
    chmodSync(adb, 0o755)
    const result = Bun.spawnSync([process.execPath, runner], {
      cwd: directory,
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        TMPDIR: scratch,
        STX_CLI: compiler,
        ANDROID_SERIAL: options.serial ?? '',
        CRAFT_KEEP_ANDROID_NATIVE_PROJECT: '0',
        CRAFT_ANDROID_NATIVE_ARTIFACTS: join(directory, 'evidence'),
        ADB_CALLS: join(directory, 'adb-calls'),
      },
      stdout: 'pipe', stderr: 'pipe', timeout: 15_000, killSignal: 'SIGKILL',
    })
    verify(directory, result)
  })
}

describe('Android native runner failure evidence', () => {
  test('retains provider logs and native reports before deleting the project', async () => {
    await fixture({ serial: 'emulator-5554' }, (directory, result) => {
      expect(result.exitCode).toBe(1)
      expect(result.stderr.toString()).toContain('gradle exited with 23')
      const evidence = join(directory, 'evidence')
      expect(existsSync(join(evidence, 'logcat-all.txt'))).toBe(true)
      expect(readFileSync(join(evidence, 'logcat-all.txt'), 'utf8')).toContain('provider first-fault')
      expect(readFileSync(join(evidence, 'androidTest-results/connected/TEST-native.xml'), 'utf8')).toContain('native failure')
      expect(readFileSync(join(evidence, 'androidTests/connected/index.html'), 'utf8')).toBe('native report\n')
      expect(readFileSync(join(evidence, 'connected_android_test_additional_output/debugAndroidTest/device.txt'), 'utf8')).toBe('device attachment\n')
      const calls = readFileSync(join(directory, 'adb-calls'), 'utf8').trim().split('\n')
      expect(calls.length).toBeGreaterThan(0)
      expect(calls.every(call => call.startsWith('-s emulator-5554 '))).toBe(true)
      expect(calls).toContain('-s emulator-5554 shell dumpsys activity lastanr')
      expect(calls).toContain('-s emulator-5554 shell dumpsys input')
      expect(readdirSync(join(directory, 'scratch'))).toEqual([])
    })
  })

  test('records diagnostic failure without replacing the original native failure', async () => {
    await fixture({ serial: 'emulator-5554', brokenAdb: true }, (directory, result) => {
      expect(result.exitCode).toBe(1)
      expect(result.stderr.toString()).toContain('gradle exited with 23')
      expect(readFileSync(join(directory, 'evidence/logcat-all.txt'), 'utf8')).toContain('device unavailable')
      const report = JSON.parse(readFileSync(join(directory, 'evidence/diagnostics.json'), 'utf8'))
      expect(report.commands.every((command: { exitCode: number }) => command.exitCode === 7)).toBe(true)
    })
  })

  test('does not query an unspecified or foreign device', async () => {
    await fixture({}, (directory, result) => {
      expect(result.stderr.toString()).toContain('gradle exited with 23')
      expect(existsSync(join(directory, 'adb-calls'))).toBe(false)
      const report = JSON.parse(readFileSync(join(directory, 'evidence/diagnostics.json'), 'utf8'))
      expect(report.deviceCaptureSkipped).toContain('ANDROID_SERIAL')
      expect(existsSync(join(directory, 'evidence/androidTest-results/connected/TEST-native.xml'))).toBe(true)
    })
  })

  test('also retains evidence on successful instrumentation without changing its verdict', async () => {
    await fixture({ serial: 'emulator-5554', success: true }, (directory, result) => {
      expect(result.exitCode).toBe(0)
      expect(result.stdout.toString()).toContain('Android native navigation test passed')
      expect(result.stdout.toString()).toContain('BUILD SUCCESSFUL')
      expect(result.stderr.toString()).not.toContain('original native Gradle failure')
      expect(readFileSync(join(directory, 'evidence/androidTest-results/connected/TEST-native.xml'), 'utf8')).toBe('<testsuite tests="1" failures="0"><testcase name="first"/></testsuite>\n')
      expect(readFileSync(join(directory, 'evidence/androidTests/connected/index.html'), 'utf8')).toBe('native report: 1 test passed\n')
      expect(readFileSync(join(directory, 'evidence/logcat-all.txt'), 'utf8')).toContain('provider diagnostic: sandbox service connected')
      expect(readdirSync(join(directory, 'scratch'))).toEqual([])
    })
  })

  test('kills and reaps unresponsive diagnostic clients within each read deadline', async () => {
    await withTempDir('android-diagnostic-timeout', (directory) => {
      const adb = join(directory, 'adb')
      const pids = join(directory, 'pids')
      // No descendant or shared ADB process: the hung client is this owned
      // fixture executable itself, including when it ignores graceful signals.
      writeFileSync(adb, `#!${process.execPath}\nrequire('node:fs').appendFileSync(${JSON.stringify(pids)}, process.pid + '\\n'); process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`)
      chmodSync(adb, 0o755)
      const before = performance.now()
      let launchedPids: number[] = []
      try {
        retainNativeNavigationEvidence({ project: directory, directory: join(directory, 'evidence'), serial: 'emulator-owned', adbPath: adb, timeoutMs: 500 })
        expect(performance.now() - before).toBeLessThan(4000)
        const report = JSON.parse(readFileSync(join(directory, 'evidence/diagnostics.json'), 'utf8'))
        expect(report.commands).toHaveLength(5)
        expect(report.commands.every((command: { signalCode: string }) => command.signalCode === 'SIGKILL')).toBe(true)
        const reportedPids = report.commands.map((command: { pid: number }) => command.pid)
        expect(reportedPids.every((pid: number) => Number.isSafeInteger(pid) && pid > 0)).toBe(true)
        launchedPids = reportedPids
        expect(new Set(launchedPids).size).toBe(5)
        for (const pid of launchedPids) expect(() => process.kill(pid, 0)).toThrow()
        // A cold client can be killed before it writes a startup receipt.
        // Still require a running TERM-ignoring fixture, but prove all five
        // launches were reaped from the parent's OS process identities.
        const startedPids = readFileSync(pids, 'utf8').trim().split('\n').map(Number)
        expect(startedPids.length).toBeGreaterThan(0)
        expect(startedPids.every(pid => launchedPids.includes(pid))).toBe(true)
      }
      finally {
        // A failed assertion still rescues only this fixture's owned clients,
        // including one killed before reaching its startup receipt.
        for (const pid of launchedPids) {
          try { process.kill(pid, 'SIGKILL') }
          catch { /* already reaped */ }
        }
        if (existsSync(pids)) {
          for (const pid of readFileSync(pids, 'utf8').trim().split('\n').map(Number)) {
            try { process.kill(pid, 'SIGKILL') }
            catch { /* already reaped */ }
          }
        }
      }
    })
  })
})
