import type { LegOutcome, RunnerOptions } from './types'
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { init } from '../../packages/android/src/index'
import { androidDeclines, awaitedNeeds, DISMISS_SHARE_MENU, evaluateRun, hasTerminated, runtimePermissionGranted, shareMenuInFront } from './protocol'
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
 *
 * Geolocation on, because that is what puts the location permissions in the
 * manifest, and `pm grant` refuses a permission the manifest does not declare.
 * The Kotlin does not otherwise read the flag (#209).
 */
const CONFIG = {
  enablePushNotifications: false,
  enableGeolocation: true,
}

/**
 * The one location permission the harness grants: approximate, and not
 * precise.
 *
 * #192 was a device with location granted that still reported something
 * else. Granting both permissions would pass against a bridge that required
 * either one, and that is not the contract. Android 12 onwards lets a person
 * choose approximate only, and CraftPermissionPolicy counts that as `granted`
 * (780e952). Coarse alone is the stricter of the two tests: anything this
 * passes, a device with both permissions granted passes too.
 */
const GRANTED_LOCATION_PERMISSION = 'android.permission.ACCESS_COARSE_LOCATION'

const PACKAGE = 'dev.craft.e2e.probe'
const APP_NAME = 'CraftE2EProbe'

/**
 * Tags worth reading. CraftBridge is the Kotlin shim's, CraftNative is Zig's
 * own — that pair is how this leg tells which side answered — chromium carries
 * the page's console for a run whose bridge never arrived, and AndroidRuntime
 * carries the crash if it did not get that far.
 */
const LOGCAT_FILTER = ['CraftBridge:D', 'CraftNative:D', 'chromium:I', 'AndroidRuntime:E', '*:S']

/**
 * One leg is one answer to "who served the call".
 *
 * The same split the iOS suite runs, and it exists here for a sharper reason:
 * until this change nothing copied libcraft.so into a generated app at all, so
 * every Android app anyone has ever generated was the shim leg and the whole
 * Zig bridge had never run. The runtime leg is what stops that being true
 * again without anybody noticing.
 */
interface Leg {
  name: 'shim' | 'runtime'
  runtimeDir: string | null
  requireZig: boolean
}

function legs(runtimeDir: string | null): Leg[] {
  return [
    { name: 'shim', runtimeDir: null, requireZig: false },
    { name: 'runtime', runtimeDir, requireZig: true },
  ]
}

/** What JNI_OnLoad logs once it has bound the natives. */
const REGISTERED = /craft: registered (\d+) natives on com\/craft\/runtime\/CraftNative/

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

async function runLeg(leg: Leg, options: RunnerOptions): Promise<LegOutcome> {
  const label = `android-${leg.name}`
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
    runtimeDir: leg.runtimeDir,
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
  // assumed. `System.loadLibrary("craft")` finding nothing is a designed
  // no-op — CraftNative catches it and every action falls through to Kotlin —
  // so a runtime leg whose library never shipped would look exactly like the
  // shim leg and pass. The APK is the only place to see the difference before
  // the app runs.
  const listed = await command(['unzip', '-l', apk], { logPath: join(evidence, 'apk.txt') })
  const zigLibraries = listed.stdout
    .split('\n')
    .map(line => line.trim().split(/\s+/).pop() ?? '')
    .filter(name => /^lib\/[^/]+\/libcraft\.so$/.test(name))

  if (leg.requireZig && !zigLibraries.some(name => name.includes('/x86_64/'))) {
    failures.push(
      `the runtime leg's APK carries ${zigLibraries.length ? zigLibraries.join(', ') : 'no libcraft.so at all'}, `
      + 'and nothing for x86_64 — which is the architecture every emulator runs, so the runtime could not load here whatever else shipped',
    )
  }
  if (!leg.requireZig && zigLibraries.length) {
    failures.push(`the shim leg's APK ships ${zigLibraries.join(', ')}; it was generated with no runtime`)
  }

  const serial = await resolveSerial()
  writeFileSync(join(evidence, 'device.txt'), `${serial}\n`)

  // Ground truth from outside the app, to check getDeviceInfo against.
  const sdk = (await adb(['shell', 'getprop', 'ro.build.version.sdk'], { serial })).stdout.trim()

  await adb(['uninstall', PACKAGE], { serial, allowFailure: true })
  await adb(['install', '-r', apk], { serial, logPath: join(evidence, 'adb.log') })

  // Granted from the host before launch, so no dialog waits on a person.
  await adb(['shell', 'pm', 'grant', PACKAGE, GRANTED_LOCATION_PERMISSION], { serial, logPath: join(evidence, 'adb.log') })

  // And read back, because the case is only as strict as the device state it
  // ran against: approximate granted, precise not. A device that had precise
  // granted as well would pass against a bridge requiring precise.
  const packageState = (await adb(['shell', 'dumpsys', 'package', PACKAGE], { serial })).stdout
  writeFileSync(join(evidence, 'package-permissions.txt'), packageState)
  if (runtimePermissionGranted(packageState, GRANTED_LOCATION_PERMISSION) !== true)
    failures.push(`${GRANTED_LOCATION_PERMISSION} is not granted after pm grant; see ${label}/package-permissions.txt`)
  if (runtimePermissionGranted(packageState, 'android.permission.ACCESS_FINE_LOCATION') === true)
    failures.push('ACCESS_FINE_LOCATION is granted too, so the location case cannot tell approximate-only from precise')

  // Not best-effort: the ring buffer outlives an uninstall, and a transcript
  // left in it would otherwise be read as this run's. The plan event carries
  // this run's nonce as a second guard.
  await adb(['logcat', '-c'], { serial })
  await adb(['shell', 'am', 'force-stop', PACKAGE], { serial, allowFailure: true })
  await adb(['shell', 'am', 'start', '-n', `${PACKAGE}/.MainActivity`], { serial, logPath: join(evidence, 'adb.log') })

  // The share case needs its menu dismissed, and nothing on the device will
  // do that: the harness plays the person. It acts only once the page has
  // asked and the menu is really in front, and it keeps a screenshot of the
  // menu, which is the evidence that there was one to dismiss.
  let shareMenu: 'not asked' | 'asked' | 'dismissed' = 'not asked'

  async function dismissShareMenuWhenAsked(log: string): Promise<void> {
    if (shareMenu === 'dismissed' || !awaitedNeeds(log).includes(DISMISS_SHARE_MENU)) return
    shareMenu = 'asked'

    const windows = await command(['adb', '-s', serial, 'shell', 'dumpsys', 'window'], { allowFailure: true })
    if (!shareMenuInFront(windows.stdout)) return

    await command(['adb', '-s', serial, 'exec-out', 'screencap', '-p'], { allowFailure: true, outPath: join(evidence, 'share-menu.png') })
    await adb(['shell', 'input', 'keyevent', 'KEYCODE_BACK'], { serial, logPath: join(evidence, 'adb.log') })
    shareMenu = 'dismissed'
  }

  // logcat -d dumps and exits, so poll it into the evidence file rather than
  // streaming: a stream would have to be killed at exactly the right moment,
  // and the dump is cheap.
  const logPath = join(evidence, 'logcat.txt')
  const finished = await waitForFile(logPath, options.timeoutMs, hasTerminated, async () => {
    const dumped = await command(['adb', '-s', serial, 'logcat', '-d', ...LOGCAT_FILTER], { allowFailure: true })
    writeFileSync(logPath, dumped.stdout)
    await dismissShareMenuWhenAsked(dumped.stdout)
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

  // The page's case only sees that share resolved false. That is also what a
  // share that never opened a menu at all would resolve, so the harness says
  // whether there was a menu to dismiss.
  if (verdict.planned.includes('share.dismissed.resolvesFalse')) {
    if (shareMenu === 'not asked')
      failures.push('the page never asked for the share menu to be dismissed, so the dismissal case did not reach the menu')
    else if (shareMenu === 'asked')
      failures.push('the page asked for the share menu to be dismissed, and no share menu ever came to the front')
  }

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

  // Did the Zig runtime load, bind — and then actually answer? JNI_OnLoad
  // reports the first two on the happy path as well as the failure ones, and
  // every way a native can give up now says so too (android_dispatch.zig's
  // fellThrough / failedWithoutFallback / undelivered).
  //
  // Registration alone is not enough, and the first run that loaded this
  // library showed why: "registered 103 natives", every case passed, and
  // getDeviceInfo threw NoSuchFieldError on every call and handed it to Kotlin.
  // The page could not tell. So the runtime leg asks for both halves: bound,
  // and not one decline while the page ran.
  //
  // Read from the full buffer, not the filtered dump: the stack trace ART
  // prints for the underlying Java exception is under System.err, which is
  // the part worth quoting back.
  const registered = logText.match(REGISTERED)
  const fullLog = existsSync(join(evidence, 'logcat-full.txt')) ? readFileSync(join(evidence, 'logcat-full.txt'), 'utf8') : logText
  const declines = androidDeclines(fullLog)
  const zigActions: string[] = []

  if (leg.requireZig) {
    if (!registered) {
      failures.push(
        'the Zig runtime never reported registering its natives. Either libcraft.so did not load, '
        + `or JNI_OnLoad refused a descriptor — see ${label}/logcat.txt under the CraftNative tag, which now carries the reason`,
      )
    }
    else {
      zigActions.push(`registered:${registered[1]}`)
    }

    for (const decline of declines) {
      failures.push(
        `Zig declined while the page ran — ${decline}. The case still passed because Kotlin answered instead, `
        + `which is exactly what this leg exists to see; the Java exception, if any, is under System.err in ${label}/logcat-full.txt`,
      )
    }
    if (registered && !declines.length) zigActions.push('declines:0')
  }
  else if (registered) {
    failures.push(`the shim leg registered ${registered[1]} natives; it was generated with no runtime`)
  }

  return {
    name: label,
    status: failures.length ? 'failed' : 'passed',
    failures,
    planned: verdict.planned,
    passed: verdict.passed,
    failed: verdict.failed,
    zigActions,
    evidence: evidence.replace(`${options.root}/`, ''),
  }
}

export async function runAndroid(options: RunnerOptions): Promise<LegOutcome[]> {
  const runtimeDir = options.androidRuntimeDir
  if (!runtimeDir) {
    throw new Error(
      'no Android Zig runtime directory; run `zig build build-android-all -Doptimize=ReleaseSafe` '
      + 'in packages/zig and pass --android-runtime packages/zig/zig-out/android',
    )
  }

  const abi = join(runtimeDir, 'x86_64', 'libcraft.so')
  if (!existsSync(abi)) {
    throw new Error(
      `${abi} is missing. Every Android emulator is x86_64, so without it the runtime leg would `
      + 'install an APK that cannot load the library and pass as though the shim were the only option. '
      + 'Run `zig build build-android-all -Doptimize=ReleaseSafe` in packages/zig.',
    )
  }

  const outcomes: LegOutcome[] = []
  for (const leg of legs(runtimeDir)) {
    try {
      outcomes.push(await runLeg(leg, options))
    }
    catch (caught) {
      outcomes.push({
        name: `android-${leg.name}`,
        status: 'failed',
        failures: [caught instanceof Error ? caught.message : String(caught)],
        planned: [],
        passed: [],
        failed: [],
        zigActions: [],
        evidence: join(options.evidenceDir, `android-${leg.name}`).replace(`${options.root}/`, ''),
      })
    }
  }

  return outcomes
}
