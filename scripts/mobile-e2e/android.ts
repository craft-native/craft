import type { LegOutcome, RunnerOptions } from './types'
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { init } from '../../packages/android/src/index'
import { evaluateRun, hasTerminated } from './protocol'
import { command, driverPage, waitForFile } from './support'

/**
 * Push off, which is what makes the rejection case deterministic: with it
 * disabled the generator writes a literal `_craftPushReject('Push
 * notifications are disabled')` into CraftBridge.kt rather than a Firebase
 * block, so the refusal is fixed at generation time and needs no network, no
 * Play Services and no account on the emulator.
 *
 * Clipboard is not a configurable capability on Android - CraftBridge serves
 * clipboardRead/clipboardWrite unconditionally - so the success case needs no
 * flag, and asking for one would imply a gate that is not there.
 */
const CONFIG = {
  enablePushNotifications: false,
}

const PACKAGE = 'dev.craft.e2e.probe'
const APP_NAME = 'CraftE2EProbe'

/** Both tags matter: the bridge's own, and the WebView's for a page that never reached the bridge. */
const LOGCAT_FILTER = ['CraftBridge:D', 'chromium:I', 'AndroidRuntime:E', '*:S']

async function adb(argv: string[], options: { serial: string, logPath?: string, allowFailure?: boolean }) {
  return command(['adb', '-s', options.serial, ...argv], { logPath: options.logPath, allowFailure: options.allowFailure })
}

async function resolveSerial(): Promise<string> {
  const listed = await command(['adb', 'devices'])
  const serials = listed.stdout
    .split('\n')
    .slice(1)
    .map(line => line.trim().split(/\s+/))
    .filter(parts => parts.length >= 2 && parts[1] === 'device')
    .map(parts => parts[0]!)

  if (!serials.length)
    throw new Error(`no Android device is attached; \`adb devices\` reported:\n${listed.stdout.trim()}`)

  return serials[0]!
}

async function runLeg(options: RunnerOptions): Promise<LegOutcome> {
  const label = 'android-shim'
  const evidence = join(options.evidenceDir, label)
  const project = join(options.workDir, label)
  const failures: string[] = []

  mkdirSync(evidence, { recursive: true })
  rmSync(project, { force: true, recursive: true })

  await init({
    name: APP_NAME,
    packageName: PACKAGE,
    output: project,
    config: CONFIG,
  })

  const nonce = `craft-e2e-${label}-${options.runId}`
  const assets = join(project, 'app', 'src', 'main', 'assets')
  writeFileSync(join(assets, 'index.html'), driverPage(nonce, 'android'))
  copyFileSync(join(assets, 'index.html'), join(evidence, 'index.html'))
  copyFileSync(join(assets, 'craft.config.json'), join(evidence, 'craft.config.json'))

  // The generator writes gradle-wrapper.properties but never gradlew, so there
  // is no wrapper to invoke. Call Gradle directly, the way the templates gate
  // already does, and honour the same override so both use one toolchain.
  const gradle = process.env.GRADLE_EXECUTABLE || 'gradle'
  await command([gradle, '--no-daemon', '--stacktrace', ':app:assembleDebug'], {
    cwd: project,
    logPath: join(evidence, 'gradle.log'),
  })

  const apk = join(project, 'app', 'build', 'outputs', 'apk', 'debug', 'app-debug.apk')
  if (!existsSync(apk))
    throw new Error(`gradle reported success but ${apk} is missing`)

  // Which side is about to answer, established from the APK rather than
  // assumed. Nothing in the generator copies libcraft.so into jniLibs (#200),
  // so `System.loadLibrary("craft")` throws, `CraftNative.isAvailable` is
  // false, and Kotlin serves every action. The leg reports that as fact, so it
  // checks it: when #200 lands this assertion fails, and whoever fixes it has
  // to come back and teach this leg to assert the Zig path instead of
  // declaring there isn't one.
  const listed = await command(['unzip', '-l', apk], { logPath: join(evidence, 'apk.txt') })
  const zigLibraries = listed.stdout
    .split('\n')
    .map(line => line.trim().split(/\s+/).pop() ?? '')
    .filter(name => /^lib\/[^/]+\/libcraft\.so$/.test(name))

  if (zigLibraries.length) {
    failures.push(
      `the APK ships ${zigLibraries.join(', ')}, so the Zig runtime may be serving these calls. `
      + 'This leg reports zigActions: [] on the basis that it never loads — teach it to assert which side answered before trusting that again.',
    )
  }

  const serial = await resolveSerial()
  writeFileSync(join(evidence, 'device.txt'), `${serial}\n`)

  // Ground truth from outside the app, to check getDeviceInfo against.
  const sdk = (await adb(['shell', 'getprop', 'ro.build.version.sdk'], { serial })).stdout.trim()

  await adb(['uninstall', PACKAGE], { serial, allowFailure: true })
  await adb(['install', '-r', apk], { serial, logPath: join(evidence, 'adb.log') })

  // Not best-effort: the ring buffer outlives an uninstall, and a transcript
  // left in it would otherwise be read as this run's. The plan event carries
  // this run's nonce as a second guard.
  await adb(['logcat', '-c'], { serial })
  await adb(['shell', 'am', 'force-stop', PACKAGE], { serial, allowFailure: true })
  await adb(['shell', 'am', 'start', '-n', `${PACKAGE}/.MainActivity`], { serial, logPath: join(evidence, 'adb.log') })

  // logcat -d dumps and exits, so poll it into the evidence file rather than
  // streaming: a stream would have to be killed at exactly the right moment,
  // and the dump is cheap.
  const logPath = join(evidence, 'logcat.txt')
  const finished = await waitForFile(logPath, options.timeoutMs, hasTerminated, async () => {
    const dumped = await command(['adb', '-s', serial, 'logcat', '-d', ...LOGCAT_FILTER], { allowFailure: true })
    writeFileSync(logPath, dumped.stdout)
  })

  await command(['adb', '-s', serial, 'exec-out', 'screencap', '-p'], { allowFailure: true, outPath: join(evidence, 'screen.png') })
  const full = await command(['adb', '-s', serial, 'logcat', '-d', '-b', 'all'], { allowFailure: true })
  writeFileSync(join(evidence, 'logcat-full.txt'), full.stdout)
  await adb(['shell', 'am', 'force-stop', PACKAGE], { serial, allowFailure: true })

  const logText = existsSync(logPath) ? readFileSync(logPath, 'utf8') : ''
  if (!finished)
    failures.push(`the app produced no terminating event within ${options.timeoutMs}ms; see ${label}/logcat.txt`)

  const verdict = evaluateRun('android', logText, nonce)
  failures.push(...verdict.failures)

  // The page reported the SDK level the bridge told it; the host asked the
  // device directly. Agreement means the value crossed the bridge rather than
  // being invented in JavaScript - this leg's substitute for the pasteboard
  // read the iOS leg does, since Android has no equally cheap host-side
  // clipboard read.
  const observed = logText.match(/"event":"observed","name":"sdkVersion","value":(\d+)/)
  if (!sdk) {
    // Not skipped when the probe comes back empty. An unverifiable check that
    // quietly passes is worse than one that fails: it reads as corroboration
    // and is not.
    failures.push('`adb shell getprop ro.build.version.sdk` returned nothing, so the page\'s sdkVersion could not be corroborated')
  }
  else if (!observed) {
    failures.push('the page never reported the sdkVersion it got from the bridge')
  }
  else if (observed[1] !== sdk) {
    failures.push(`the bridge reported sdkVersion ${observed[1]} but the device says ${sdk}`)
  }

  return {
    name: label,
    status: failures.length ? 'failed' : 'passed',
    failures,
    planned: verdict.planned,
    passed: verdict.passed,
    failed: verdict.failed,
    // Nothing copies libcraft.so into the generated app's jniLibs (#200), so
    // CraftNative.isAvailable is always false and Kotlin serves every action.
    // Reported as empty rather than omitted, so the report says which side
    // answered instead of leaving it open.
    zigActions: [],
    evidence: evidence.replace(`${options.root}/`, ''),
  }
}

export async function runAndroid(options: RunnerOptions): Promise<LegOutcome[]> {
  try {
    return [await runLeg(options)]
  }
  catch (caught) {
    return [{
      name: 'android-shim',
      status: 'failed',
      failures: [caught instanceof Error ? caught.message : String(caught)],
      planned: [],
      passed: [],
      failed: [],
      zigActions: [],
      evidence: join(options.evidenceDir, 'android-shim').replace(`${options.root}/`, ''),
    }]
  }
}
