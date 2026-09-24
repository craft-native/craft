import type { PushStage } from './protocol'
import type { LegOutcome, RunnerOptions } from './types'
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { bootSimulator, init, pickSimulator } from '../../packages/ios/src/index'
import { deepLinkProblems, deepLinkResults, evaluateRun, hasTerminated, LOCAL_NOTIFICATION_DELAY_MS, localNotificationProblems, NOTIFICATION_TEST_TIMEOUT_MS, notificationBody, notificationPayload, notificationReceiptProblems, notificationReceiptReport, notificationTapProblems, notificationTapReport, ZIG_REFUSED_ACTIONS, ZIG_SERVED_ACTIONS, ZIG_TESTED_ACTIONS, zigDispatchedActions, zigHandBacks, zigRefusals } from './protocol'
import { command, driverPage, waitForFile } from './support'

/** The scheme the probe registers, and the one its cold-start link uses. */
const DEEP_LINK_SCHEME = 'crafte2eprobe'

/**
 * The app the suite runs against.
 *
 * Clipboard and geolocation on, sharing off. The success cases need
 * capabilities that are enabled and reachable without a prompt, and the
 * rejection case needs one that is switched off so the refusal is a property
 * of the configuration rather than of the machine. Reading a pasteboard the
 * app itself just wrote raises no iOS paste prompt, and location is granted
 * from the host with `simctl privacy` before launch, so nothing waits on a
 * person.
 *
 * Geolocation used to be the switched-off capability. It is on because #197
 * was a location promise that never settled with location *enabled*, and a
 * disabled capability cannot reach that code. Sharing took over the rejection.
 *
 * `enableShare` and `enableSpeechRecognition` are spelled out although false
 * is the default, because the refusal cases depend on them and a default is
 * not something this file controls.
 */
const CONFIG = {
  enableClipboard: true,
  enableGeolocation: true,
  // On so the success path is exercised: an enabled haptic used to answer
  // nothing at all (#207).
  enableHaptics: true,
  enableShare: false,
  enableSpeechRecognition: false,
  // For the cold-start link (#198), which the harness opens from an XCUITest.
  enableDeepLinks: true,
  // For the notification the page schedules with data (#258), served by
  // Swift on the shim leg and by Zig on the runtime leg.
  enableLocalNotifications: true,
  urlSchemes: [DEEP_LINK_SCHEME],
}

/**
 * Where the simulator is told it is, for the page to report back.
 *
 * Nowhere near the simulator's default, which is Apple Park, so a position
 * served from a cache or a stale scenario cannot pass for this one.
 */
const SIMULATED_POSITION = { latitude: 51.5007, longitude: -0.1246 }
const POSITION_TOLERANCE = 0.001

const BUNDLE_ID = 'dev.craft.e2e.probe'
const APP_NAME = 'CraftE2EProbe'

/**
 * The UI test target the harness adds to the generated project.
 *
 * Added here rather than by the generator, because no app wants it: it exists
 * to cold-start the probe through a link, and through a tap on a pushed
 * notification, which neither `simctl launch` nor `simctl openurl` can do
 * unattended. See `ios-uitests/` for why.
 */
const UI_TESTS = `${APP_NAME}UITests`

/** The UI test classes, each run on its own with `-only-testing`. */
const UI_TEST_CLASSES = ['DeepLinkColdStartTests', 'NotificationTapColdStartTests'] as const

/**
 * The pushes the notification UI test has asked for, in order, one per
 * `CRAFT-E2E-PUSH-READY <stage>` line.
 */
function pushesAskedFor(output: string): PushStage[] {
  return [...output.matchAll(/^CRAFT-E2E-PUSH-READY (cold|foreground)\s*$/gm)].map(match => match[1] as PushStage)
}

/**
 * One leg is one answer to "who served the call".
 *
 * `shim` is what every generated app is today: no Zig archive, every dlsym
 * miss, Swift serving the whole surface. `runtime` links the archive so Zig
 * takes the actions it owns. They assert the same cases, because the hand-off
 * is supposed to be invisible to the page - and that is exactly why the
 * runtime leg also counts Zig's dispatch log lines. Identical behaviour is the
 * requirement; identical behaviour with the archive silently absent is the bug
 * that requirement would otherwise hide.
 */
interface Leg {
  name: 'shim' | 'runtime'
  runtimeDir: string | null
  requireZigDispatch: boolean
}

function legs(runtimeDir: string | null): Leg[] {
  return [
    { name: 'shim', runtimeDir: null, requireZigDispatch: false },
    { name: 'runtime', runtimeDir, requireZigDispatch: true },
  ]
}

async function runLeg(leg: Leg, options: RunnerOptions): Promise<LegOutcome> {
  const label = `ios-${leg.name}`
  const evidence = join(options.evidenceDir, label)
  const project = join(options.workDir, label)
  const failures: string[] = []

  mkdirSync(evidence, { recursive: true })
  rmSync(project, { force: true, recursive: true })

  await init({
    name: APP_NAME,
    bundleId: BUNDLE_ID,
    output: project,
    config: CONFIG,
    runtimeDir: leg.runtimeDir,
  })

  // The archive is linked through project.yml's {{CRAFT_RUNTIME_SETTINGS}},
  // which init() leaves empty when it installed no runtime. Checking the
  // generated file rather than trusting the option means a leg cannot quietly
  // become a second copy of the shim leg.
  const projectYml = readFileSync(join(project, 'project.yml'), 'utf8')
  const linksRuntime = projectYml.includes('-lcraft-ios')
  if (leg.requireZigDispatch && !linksRuntime)
    failures.push(`the ${leg.name} leg generated a project that does not link the Zig archive; check ${leg.runtimeDir}`)
  if (!leg.requireZigDispatch && linksRuntime)
    failures.push(`the ${leg.name} leg was supposed to have no runtime but its project links one`)

  // The cold-start UI tests, as a target in the generated project.
  mkdirSync(join(project, 'UITests'), { recursive: true })
  for (const testClass of UI_TEST_CLASSES)
    copyFileSync(join(import.meta.dir, 'ios-uitests', `${testClass}.swift`), join(project, 'UITests', `${testClass}.swift`))
  writeFileSync(join(project, 'project.yml'), `${projectYml.trimEnd()}
  ${UI_TESTS}:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - UITests
    settings:
      TEST_TARGET_NAME: ${APP_NAME}
      PRODUCT_BUNDLE_IDENTIFIER: ${BUNDLE_ID}.uitests
      GENERATE_INFOPLIST_FILE: YES
      SWIFT_VERSION: "5.0"
    dependencies:
      - target: ${APP_NAME}
schemes:
  ${APP_NAME}:
    build:
      targets:
        ${APP_NAME}: all
        ${UI_TESTS}: [test]
    test:
      targets:
        - ${UI_TESTS}
`)

  const nonce = `craft-e2e-${label}-${options.runId}`
  writeFileSync(join(project, 'dist', 'index.html'), driverPage(nonce, 'ios'))
  copyFileSync(join(project, 'dist', 'index.html'), join(evidence, 'index.html'))
  copyFileSync(join(project, 'craft.config.json'), join(evidence, 'craft.config.json'))
  copyFileSync(join(project, 'project.yml'), join(evidence, 'project.yml'))

  await command(['xcodegen', 'generate'], { cwd: project, logPath: join(evidence, 'xcodegen.log') })

  const derived = join(project, 'DerivedData')
  await command([
    'xcodebuild',
    '-project', `${APP_NAME}.xcodeproj`,
    '-scheme', APP_NAME,
    '-configuration', 'Debug',
    // The simulator SDK, which no existing job builds against: the templates
    // gate compiles -sdk iphoneos only. A generated app that links for a
    // device and not for a simulator would have gone unnoticed.
    '-sdk', 'iphonesimulator',
    '-destination', 'generic/platform=iOS Simulator',
    '-derivedDataPath', derived,
    'CODE_SIGNING_ALLOWED=NO',
    // The app and the UI test runner together, so the cold-start step below
    // runs what was built here rather than building again.
    'build-for-testing',
  ], { cwd: project, logPath: join(evidence, 'xcodebuild.log') })

  const app = join(derived, 'Build', 'Products', 'Debug-iphonesimulator', `${APP_NAME}.app`)
  if (!existsSync(app))
    throw new Error(`xcodebuild reported success but ${app} is missing`)

  const device = await pickSimulator()
  if (!device)
    throw new Error('no iOS simulator is available; `xcrun simctl list devices available` found none')
  await bootSimulator(device)
  writeFileSync(join(evidence, 'device.json'), `${JSON.stringify(device, null, 2)}\n`)

  await command(['xcrun', 'simctl', 'uninstall', device.udid, BUNDLE_ID], { allowFailure: true })
  await command(['xcrun', 'simctl', 'install', device.udid, app])

  // Location answered from the host, before launch: permission granted so no
  // prompt waits on a person, and a coordinate the page cannot know. Not
  // best-effort. Without either, the location cases fail for a reason that
  // has nothing to do with the bridge.
  const coordinate = `${SIMULATED_POSITION.latitude},${SIMULATED_POSITION.longitude}`
  await command(['xcrun', 'simctl', 'privacy', device.udid, 'grant', 'location', BUNDLE_ID], { logPath: join(evidence, 'simctl.log') })
  await command(['xcrun', 'simctl', 'location', device.udid, 'set', coordinate], { logPath: join(evidence, 'simctl.log') })

  // Clear the pasteboard first. Without this a nonce left by the previous leg
  // would still be there, and the external check below would pass on a value
  // this run never wrote.
  await command(['xcrun', 'simctl', 'pbcopy', device.udid], { stdin: 'craft-e2e-pasteboard-cleared', allowFailure: true })

  // The app's stdout and stderr, each to its own file, read back while it
  // runs. Swift's `print` carries the page's `craft.log`; Zig's logger writes
  // to stderr.
  //
  // Not `simctl launch --console-pty`, which is what this was. On a freshly
  // booted simulator the first pty launch took about 200 seconds to start the
  // app, measured on a new device, against 10 for a plain launch. The clock
  // below used to start at that spawn, so the shim leg, always the first
  // launch after boot, could spend its whole budget waiting for the app to
  // exist and fail with "the test page never announced a plan". It did, on
  // main (run 35091847509) and on #208 and #210. The runtime leg, second on
  // the same device, never did.
  //
  // `NSUnbufferedIO=YES` is what makes plain files usable. A pty is line
  // buffered and a file is not: without the variable, `print` wrote nothing
  // at all, not even once the app was terminated. Xcode sets it for the same
  // reason. `SIMCTL_CHILD_` is how simctl hands a variable to the app.
  //
  // And the launch now fails on its own terms. `simctl launch` returns once
  // the app has a pid, so a launch that cannot happen is an exception naming
  // simctl's error, not a timeout blamed on the page.
  const stdoutPath = join(evidence, 'app-stdout.log')
  const stderrPath = join(evidence, 'app-stderr.log')
  const consolePath = join(evidence, 'console.log')
  const readConsole = () => [stdoutPath, stderrPath]
    .map(path => existsSync(path) ? readFileSync(path, 'utf8') : '')
    .join('')

  await command([
    'xcrun', 'simctl', 'launch', '--terminate-running-process',
    `--stdout=${stdoutPath}`, `--stderr=${stderrPath}`,
    device.udid, BUNDLE_ID,
  ], { env: { SIMCTL_CHILD_NSUnbufferedIO: 'YES' }, logPath: join(evidence, 'simctl.log') })

  // The suite is quick once the app is up, so poll for the terminator rather
  // than sleeping a fixed amount.
  //
  // `hasTerminated` parses rather than matching a substring, because the very
  // next statement kills the writer: a poll landing mid-write of the final
  // line would otherwise leave a truncated event in the file and turn a
  // passing suite into "driver emitted an unparseable event".
  const finished = await waitForFile(consolePath, options.timeoutMs, hasTerminated, async () => {
    writeFileSync(consolePath, readConsole())
  })

  await command(['xcrun', 'simctl', 'terminate', device.udid, BUNDLE_ID], { allowFailure: true })
  writeFileSync(consolePath, readConsole())

  // Evidence before assertions, always: a leg that dies here is the one whose
  // screenshot is worth the most.
  await command(['xcrun', 'simctl', 'io', device.udid, 'screenshot', join(evidence, 'screen.png')], { allowFailure: true })
  const pasteboard = await command(['xcrun', 'simctl', 'pbpaste', device.udid], { allowFailure: true })
  writeFileSync(join(evidence, 'pasteboard.txt'), pasteboard.stdout)

  const consoleText = existsSync(consolePath) ? readFileSync(consolePath, 'utf8') : ''
  if (!finished)
    failures.push(`the app produced no terminating event within ${options.timeoutMs}ms; see ${label}/console.log`)

  const verdict = evaluateRun('ios', consoleText, nonce)
  failures.push(...verdict.failures)

  // The one assertion the page cannot fake. simctl reads the device's own
  // pasteboard from the host, so a nonce found here travelled from JavaScript
  // through the bridge into real UIPasteboard state.
  if (!pasteboard.stdout.includes(nonce))
    failures.push(`the simulator pasteboard does not hold the nonce this run wrote; it holds ${JSON.stringify(pasteboard.stdout.trim().slice(0, 80))}`)

  // The position the page reported against the one the host set. Resolving
  // is not enough: a bridge that answered with a cached or default fix would
  // resolve too.
  const reported = (name: string) => consoleText.match(new RegExp(`"event":"observed","name":"${name}","value":(-?[\\d.]+)`))?.[1]
  const latitude = Number(reported('latitude'))
  const longitude = Number(reported('longitude'))
  if (verdict.planned.includes('geolocation.currentPosition')) {
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      failures.push('the page never reported the position getCurrentPosition gave it')
    }
    else if (Math.abs(latitude - SIMULATED_POSITION.latitude) > POSITION_TOLERANCE
      || Math.abs(longitude - SIMULATED_POSITION.longitude) > POSITION_TOLERANCE) {
      failures.push(`getCurrentPosition answered ${latitude},${longitude} but the simulator was set to ${SIMULATED_POSITION.latitude},${SIMULATED_POSITION.longitude}`)
    }
  }

  // #198: cold-start the app through a link, twice, and judge what the page
  // received. After the suite and its evidence, because the UI test
  // terminates and relaunches the app.
  const uiTest = (testClass: typeof UI_TEST_CLASSES[number]) => [
    'xcodebuild',
    '-project', `${APP_NAME}.xcodeproj`,
    '-scheme', APP_NAME,
    '-destination', `id=${device.udid}`,
    '-derivedDataPath', derived,
    `-only-testing:${UI_TESTS}/${testClass}`,
    'CODE_SIGNING_ALLOWED=NO',
    'test-without-building',
  ]
  const link = `${DEEP_LINK_SCHEME}://e2e/cold?run=${encodeURIComponent(nonce)}`
  const coldStart = await command(uiTest('DeepLinkColdStartTests'), {
    cwd: project,
    // xcodebuild hands TEST_RUNNER_-prefixed variables to the runner without
    // the prefix.
    env: { TEST_RUNNER_PROBE_BUNDLE_ID: BUNDLE_ID, TEST_RUNNER_PROBE_LINK: link },
    logPath: join(evidence, 'xcodebuild-deeplink.log'),
    allowFailure: true,
  })
  await command(['xcrun', 'simctl', 'io', device.udid, 'screenshot', join(evidence, 'deeplink-screen.png')], { allowFailure: true })
  await command(['xcrun', 'simctl', 'terminate', device.udid, BUNDLE_ID], { allowFailure: true })
  failures.push(...deepLinkProblems(deepLinkResults(`${coldStart.stdout}\n${coldStart.stderr}`), link))

  // #255 and #256: a tap on a push that launches the app, then a push that
  // arrives while it is open, each judged by what the page was handed. The UI
  // test prints CRAFT-E2E-PUSH-READY <stage> when it is ready for each one:
  // once it has allowed notifications and killed the app, and once the page
  // it tapped open is listening. `simctl push` runs on the host, so each push
  // is sent from here when its line appears.
  //
  // Spawned rather than run through `command`, which returns only once the
  // process has exited, and this one waits on the pushes.
  const notificationLog = join(evidence, 'xcodebuild-notification.log')
  const notificationEvidence = `${label}/xcodebuild-notification.log`
  const tapping = Bun.spawn(uiTest('NotificationTapColdStartTests'), {
    cwd: project,
    env: {
      ...process.env,
      TEST_RUNNER_PROBE_BUNDLE_ID: BUNDLE_ID,
      TEST_RUNNER_PROBE_NOTIFY_LINK: `${DEEP_LINK_SCHEME}://e2e/notify?run=${encodeURIComponent(nonce)}`,
      TEST_RUNNER_PROBE_PUSH_BODY: notificationBody(nonce, 'cold'),
      TEST_RUNNER_PROBE_LOCAL_LINK: `${DEEP_LINK_SCHEME}://e2e/local?run=${encodeURIComponent(nonce)}&delayMs=${LOCAL_NOTIFICATION_DELAY_MS}`,
      TEST_RUNNER_PROBE_LOCAL_BODY: notificationBody(nonce, 'local'),
    },
    stdin: 'ignore',
    stdout: Bun.file(notificationLog),
    stderr: Bun.file(join(evidence, 'xcodebuild-notification-stderr.log')),
  })
  // One push per line asked for, sent as each line appears, until the test
  // exits or runs out of time.
  const pushed: PushStage[] = []
  const deadline = Date.now() + NOTIFICATION_TEST_TIMEOUT_MS
  while (tapping.exitCode === null && Date.now() < deadline) {
    for (const stage of pushesAskedFor(readFileSync(notificationLog, 'utf8')).slice(pushed.length)) {
      const payloadPath = join(evidence, `notification-${stage}.apns`)
      writeFileSync(payloadPath, notificationPayload(nonce, stage))
      await command(['xcrun', 'simctl', 'push', device.udid, BUNDLE_ID, payloadPath], { logPath: join(evidence, 'simctl.log') })
      pushed.push(stage)
    }
    await Bun.sleep(250)
  }
  if (tapping.exitCode === null) tapping.kill()
  await tapping.exited
  if (tapping.exitCode !== 0)
    failures.push(`notification UI test exited ${tapping.exitCode}; see ${notificationEvidence}`)
  await command(['xcrun', 'simctl', 'io', device.udid, 'screenshot', join(evidence, 'notification-screen.png')], { allowFailure: true })
  await command(['xcrun', 'simctl', 'terminate', device.udid, BUNDLE_ID], { allowFailure: true })
  const notificationOutput = readFileSync(notificationLog, 'utf8')
  if (!pushed.includes('cold')) {
    failures.push(`the notification UI test never had the app killed and ready for a push; see ${notificationEvidence}`)
  }
  else {
    failures.push(...notificationTapProblems(notificationTapReport(notificationOutput), nonce, notificationEvidence))
    if (!pushed.includes('foreground')) {
      failures.push(`the notification UI test never got to the push that arrives while the app is open; see ${notificationEvidence}`)
    }
    else {
      failures.push(...notificationReceiptProblems(notificationReceiptReport(notificationOutput), nonce, notificationEvidence))
      failures.push(...localNotificationProblems(notificationTapReport(notificationOutput, 'CRAFT-E2E-LOCAL-RESULT'), nonce, notificationEvidence))
    }
  }

  const dispatched = zigDispatchedActions(consoleText)
  const refused = zigRefusals(consoleText)
  const handedBack = zigHandBacks(consoleText)

  if (leg.requireZigDispatch) {
    const missing = ZIG_TESTED_ACTIONS.filter(action => !dispatched.includes(action))
    if (missing.length)
      failures.push(`the runtime leg links the Zig archive but ${missing.join(', ')} never reached the Zig dispatcher; Swift served ${missing.length === 1 ? 'it' : 'them'} and the archive was not in the loop for the cases under test`)

    // A dispatch line is logged on entry, before Zig decides whether it owns
    // the action, so it alone does not prove Zig answered. The refusal line is
    // written by Zig's own capability gate, which means the rejection the page
    // saw came off Zig's error route.
    for (const action of ZIG_REFUSED_ACTIONS.filter(action => !refused.includes(action)))
      failures.push(`Zig never refused ${action}; the rejection the page saw came from Swift, not from the Zig gate`)

    // Offered is not served. Zig logs the dispatch line on entry and then
    // hands an action it does not own back to Swift, which answers with the
    // same shape, so a case passing says nothing about which side answered.
    for (const action of ZIG_SERVED_ACTIONS.filter(action => handedBack.includes(action)))
      failures.push(`Zig handed ${action} back to Swift; the runtime leg expects Zig to serve it`)
  }
  else {
    if (dispatched.length)
      failures.push(`the shim leg reached the Zig dispatcher for ${dispatched.join(', ')}; it was supposed to link no runtime`)
    if (refused.length)
      failures.push(`the shim leg saw Zig refuse ${refused.join(', ')}; it was supposed to link no runtime`)
    if (handedBack.length)
      failures.push(`the shim leg saw Zig hand back ${handedBack.join(', ')}; it was supposed to link no runtime`)
  }

  return {
    name: label,
    status: failures.length ? 'failed' : 'passed',
    failures,
    planned: verdict.planned,
    passed: verdict.passed,
    failed: verdict.failed,
    zigActions: dispatched,
    evidence: evidence.replace(`${options.root}/`, ''),
  }
}

export async function runIos(options: RunnerOptions): Promise<LegOutcome[]> {
  const runtimeDir = options.iosRuntimeDir
  if (!runtimeDir)
    throw new Error('no iOS Zig runtime directory; run `zig build build-ios-all` in packages/zig and pass --ios-runtime <dir>')

  // The device archive as well as the simulator ones, because that is what
  // `installRuntime` requires: it resolves every SDK in RUNTIME_ARCHIVES before
  // writing anything and throws when one has none. Checking only the simulator
  // slices here would accept a zig-out that project generation then rejects,
  // several minutes later, with a message about a different build step.
  const simulator = ['libcraft-ios-simulator-arm64.a', 'libcraft-ios-simulator-x64.a']
  const missing: string[] = []
  if (!simulator.some(name => existsSync(join(runtimeDir, name)))) missing.push(...simulator)
  if (!existsSync(join(runtimeDir, 'libcraft-ios.a'))) missing.push('libcraft-ios.a')

  if (missing.length) {
    throw new Error(
      `${runtimeDir} is missing ${missing.join(', ')}. `
      + 'Run `zig build build-ios-all -Doptimize=ReleaseSafe` in packages/zig first — '
      + 'build-ios-simulator alone is not enough, because the generated project links a device slice too. '
      + 'Skipping the runtime leg instead would leave the Zig bridge untested while the suite still reported green.',
    )
  }

  const outcomes: LegOutcome[] = []
  for (const leg of legs(runtimeDir)) {
    try {
      outcomes.push(await runLeg(leg, options))
    }
    catch (caught) {
      outcomes.push({
        name: `ios-${leg.name}`,
        status: 'failed',
        failures: [caught instanceof Error ? caught.message : String(caught)],
        planned: [],
        passed: [],
        failed: [],
        zigActions: [],
        evidence: join(options.evidenceDir, `ios-${leg.name}`).replace(`${options.root}/`, ''),
      })
    }
  }

  return outcomes
}
