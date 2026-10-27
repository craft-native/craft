import { copyFileSync, cpSync, existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { Glob } from 'bun'
import { bootSimulator, init, pickSimulator, type CraftConfig } from '../src/index'
import { initSimulatorDriver, serializeSimulatorSteps } from '../src/testing'
import { checkLoadFailureClassifier } from './load-failure'
import { checkRecoveryBudget } from './recovery-budget'
import { watchCompanionProblems } from './watch-bundle'
import { createTempDir, keepTempDir, removeTempDir } from '../../typescript/src/temp-dir'

interface CompileFixture {
  bundleId: string
  config?: Partial<CraftConfig>
  name: string
}

const capabilityConfig: Partial<CraftConfig> = {
  enableAppleMusic: true,
  enableAR: true,
  enableAudioRecording: true,
  enableBackgroundLocation: true,
  enableBackgroundTasks: true,
  enableBiometric: true,
  enableBluetooth: true,
  enableCalendar: true,
  enableCamera: true,
  enableContacts: true,
  enableDeepLinks: true,
  enableFileDownload: true,
  enableFilePicker: true,
  enableGeolocation: true,
  enableHealthKit: true,
  enableHeartRate: true,
  enableInAppPurchase: true,
  enableLiveActivities: true,
  enableLocalNotifications: true,
  enableMotionSensors: true,
  enableNFC: true,
  enablePushNotifications: true,
  enableQRScanner: true,
  enableScheduledWorkouts: true,
  enableSocialAuth: true,
  enableSpeechRecognition: true,
  enableVideoRecording: true,
}

const fixtures: CompileFixture[] = [
  {
    name: 'MinimalProbe',
    bundleId: 'dev.craft.templates.minimal',
  },
  {
    name: 'CapabilityProbe',
    bundleId: 'dev.craft.templates.capabilities',
    config: capabilityConfig,
  },
  {
    name: 'WatchProbe',
    bundleId: 'dev.craft.templates.watch',
    config: {
      ...capabilityConfig,
      enableWatchApp: true,
    },
  },
  {
    // Web plus native screens: CraftHybrid.swift and its hooks compile.
    name: 'HybridProbe',
    bundleId: 'dev.craft.templates.hybrid',
    config: {
      devServerURL: 'http://localhost:3000/m',
      nativeScreens: { '/m': 'Today', '/m/workout/:id': 'Workout' },
      tabs: [{ id: '/m', title: 'Today', symbol: 'sun.max' }, { id: '/m/calendar', title: 'Calendar', symbol: 'calendar' }],
      shareStorage: { auth_token: 'auth.token' },
    },
  },
  {
    // All native with the shell's tabs and paths, no web view, an app
    // script, and the web view's services from a coordinator without one.
    name: 'NativeRoutesProbe',
    bundleId: 'dev.craft.templates.nativeroutes',
    config: {
      renderer: 'native',
      devServerURL: 'https://example.com/m',
      nativeScreens: { '/m': 'Today', '/m/calendar': 'Calendar', '/m/workout/:id': 'Workout' },
      tabs: [{ id: '/m', title: 'Today', symbol: 'sun.max' }, { id: '/m/calendar', title: 'Calendar', symbol: 'calendar' }],
      nativeApp: '__app',
      enableAppleMusic: true,
      enableGeolocation: true,
      enableHealthKit: true,
      enableHeartRate: true,
      enablePushNotifications: true,
      backgroundRefresh: { enabled: true },
      // CraftCrashReporter.swift installs only with a key: compile it on.
      crashReporting: { key: 'bughq_templates', host: 'https://bughq.org', environment: 'ci' },
    },
  },
]

/** Push on and nothing else, so the entitlement builds stay quick. */
const pushFixture: CompileFixture = {
  name: 'PushProbe',
  bundleId: 'dev.craft.templates.push',
  config: { enablePushNotifications: true },
}

const keepProjects = process.argv.includes('--keep')
const workspace = createTempDir('craft-ios-templates-')

function run(args: string[], cwd: string, label: string): void {
  console.log(`\n${label}`)
  const result = Bun.spawnSync(args, {
    cwd,
    env: process.env,
    stdout: 'inherit',
    stderr: 'inherit',
  })
  if (result.exitCode !== 0)
    throw new Error(`${label} exited with ${result.exitCode}`)
}

/** Keep XCTest's own failure details before the disposable project is removed. */
function retainTimedInputEvidence(requirePassed = false): void {
  const results = join(workspace, 'TimedInputDriver.xcresult')
  if (!existsSync(results)) {
    if (requirePassed) throw new Error('Timed input returned no XCTest result bundle')
    return
  }
  const evidence = process.env.CRAFT_IOS_TEMPLATE_EVIDENCE
  const output = evidence ? resolve(evidence) : undefined
  if (output) mkdirSync(output, { recursive: true })
  let summary: { exitCode: number, output: string } | undefined
  for (const kind of ['summary', 'tests']) {
    const report = Bun.spawnSync(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', results], { stdout: 'pipe', stderr: 'pipe' })
    if (kind === 'summary') summary = { exitCode: report.exitCode, output: report.stdout.toString() }
    console.log(`XCTest ${kind} (exit ${report.exitCode}):\n${report.stdout.toString()}`)
    if (report.stderr.length) console.error(report.stderr.toString())
    if (output) {
      writeFileSync(join(output, `${kind}.json`), report.stdout)
      writeFileSync(join(output, `${kind}.stderr.log`), report.stderr)
      writeFileSync(join(output, `${kind}.exit-code.txt`), String(report.exitCode))
    }
  }
  if (output) cpSync(results, join(output, 'TimedInputDriver.xcresult'), { recursive: true, force: false, errorOnExist: true })
  if (requirePassed) {
    if (!summary || summary.exitCode !== 0) throw new Error('Unable to verify the timed input XCTest summary')
    const counts = JSON.parse(summary.output)
    if (counts.result !== 'Passed' || !Number.isInteger(counts.totalTestCount) || counts.totalTestCount < 1 || counts.passedTests !== counts.totalTestCount || counts.failedTests !== 0 || counts.skippedTests !== 0)
      throw new Error(`Expected actual passed timed input tests without skips: ${summary.output}`)
  }
}

/**
 * The `aps-environment` a configuration actually signs with (#196).
 *
 * The generator writes `$(CRAFT_APNS_ENVIRONMENT)` into the entitlements and
 * sets it per configuration in project.yml. `index.test.ts` checks both
 * strings, which proves what was written, not what Xcode makes of it. An
 * entitlement Xcode does not expand, or a configuration name xcodegen maps
 * differently, would pass those tests and still ship `development` to the
 * App Store, the exact bug reported.
 *
 * So this builds for the simulator with ad-hoc signing, which needs no team
 * and still runs entitlement processing, and reads the processed entitlements
 * Xcode wrote (`<app>.app-Simulated.xcent`). The substitution is the same one
 * device signing performs; only the signature differs.
 */
function signedApnsEnvironment(output: string, projectName: string, configuration: 'Debug' | 'Release'): string {
  run([
    'xcodebuild',
    '-quiet',
    '-project', `${projectName}.xcodeproj`,
    '-target', projectName,
    '-configuration', configuration,
    '-sdk', 'iphonesimulator',
    'CODE_SIGN_IDENTITY=-',
    'CODE_SIGNING_REQUIRED=NO',
    'build',
  ], output, `Signing ${projectName} (${configuration}) to read its entitlements`)

  const pattern = `build/${projectName}.build/${configuration}-iphonesimulator/${projectName}.build/${projectName}.app-Simulated.xcent`
  const [path] = [...new Glob(pattern).scanSync({ cwd: output, absolute: true })]
  if (!path)
    throw new Error(`${configuration} produced no ${pattern}; entitlement processing did not run`)

  const converted = Bun.spawnSync(['plutil', '-convert', 'json', '-o', '-', path])
  if (converted.exitCode !== 0)
    throw new Error(`plutil could not read ${path}: ${converted.stderr.toString()}`)
  const environment = (JSON.parse(converted.stdout.toString()) as Record<string, unknown>)['aps-environment']
  return typeof environment === 'string' ? environment : `(${JSON.stringify(environment)})`
}

/**
 * Build the Watch-enabled app the way Xcode builds it for a person, with the
 * Watch app embedded, and install it on an iOS simulator (#193, #194, #195).
 *
 * The three reports came from exactly this path. The phone target did not
 * compile, then the built app would not install ("does not have a
 * WKWatchKitApp or WKApplication key", then "not a WatchKit 2 app"). Building
 * the Watch targets on their own, below, proves they compile and proves
 * nothing about the bundle they end up in. So the scheme builds the whole
 * embedded graph, `watchCompanionProblems` names any missing piece of the
 * bundle, and `simctl install` has the last word.
 *
 * It needs a watchOS simulator runtime matching the selected Xcode, and
 * refuses without one rather than skipping: Xcode's error names the version.
 * GitHub's macOS images ship them.
 */
async function installEmbeddedWatchApp(output: string, projectName: string, bundleId: string): Promise<void> {
  const derived = join(output, 'DerivedData-embedded')
  run([
    'xcodebuild',
    '-quiet',
    '-project', `${projectName}.xcodeproj`,
    '-scheme', projectName,
    '-configuration', 'Debug',
    '-destination', 'generic/platform=iOS Simulator',
    '-derivedDataPath', derived,
    'CODE_SIGNING_ALLOWED=NO',
    'build',
  ], output, `Building ${projectName} with its Watch app embedded`)

  const app = join(derived, 'Build', 'Products', 'Debug-iphonesimulator', `${projectName}.app`)
  const problems = watchCompanionProblems(app, projectName)
  if (problems.length)
    throw new Error(`${projectName}.app: ${problems.join('; ')}`)

  const device = await pickSimulator()
  if (!device)
    throw new Error('no iOS simulator is available to install the Watch-enabled app on')
  await bootSimulator(device)
  run(['xcrun', 'simctl', 'install', device.udid, app], output, `Installing ${projectName}.app on ${device.name}`)
  run(['xcrun', 'simctl', 'uninstall', device.udid, bundleId], output, `Removing ${projectName}.app again`)
  console.log(`ok: ${projectName}.app installed with its Watch companion`)
}

function buildTarget(output: string, projectName: string, targetName: string, sdk: string, configuration = 'Debug'): void {
  run([
    'xcodebuild',
    '-quiet',
    '-project', `${projectName}.xcodeproj`,
    '-target', targetName,
    '-configuration', configuration,
    '-sdk', sdk,
    'CODE_SIGNING_ALLOWED=NO',
    'build',
  ], output, `Compiling ${targetName} against ${sdk}`)
}

// Check the linked executable, not just a #if in source or a plist snapshot.
// Both Debug and the shipped Release configuration must exclude the APIs.
function checkMusicPermissionBinary(output: string, name: string, enabled: boolean, configuration: string): void {
  const binary = join(output, 'build', `${configuration}-iphoneos`, `${name}.app`, name)
  const symbols = Bun.spawnSync(['xcrun', 'nm', '-u', binary], { stdout: 'pipe', stderr: 'pipe' })
  if (symbols.exitCode !== 0) throw new Error(`Unable to inspect ${binary}: ${symbols.stderr.toString()}`)
  for (const api of ['MPMediaLibrary', 'MPMusicPlayerController']) {
    const linked = symbols.stdout.toString().includes(`_OBJC_CLASS_$_${api}`)
    if (linked !== enabled) throw new Error(`${configuration} ${name}: ${api} linked=${linked}, expected ${enabled}`)
  }
  console.log(`ok: ${configuration} ${name} music APIs ${enabled ? 'included' : 'excluded'}`)
}

try {
  // Compile the separate test host too: the application template builds cannot
  // catch Swift/Objective-C importer or bridging-header failures in the driver.
  const driverOutput = join(workspace, 'TimedInputDriver')
  const inputNames = ['One', 'Two', 'Three', 'Four']
  const inputSequence = Array.from({ length: 24 }, (_, index) => inputNames[index % 4]!)
  const script = serializeSimulatorSteps([
    { command: 'launch' }, { command: 'labelid', id: 'received-taps', text: 'none' },
    { command: 'touches', paths: inputSequence.map((tab, index) => [
      { tab, at: index * 0.08 }, { tab, at: index * 0.08 + 0.025 },
    ]) },
    { command: 'labelid', id: 'received-taps', text: inputSequence.join(',') },
    { command: 'selected', text: 'Four' },
    { command: 'scrollto', text: 'End of scroll fixture' },
    { command: 'expectid', text: 'driver-scroll-end' },
    { command: 'scrollto', text: 'Start of scroll fixture' },
    { command: 'expectid', text: 'driver-scroll-start' },
  ])
  initSimulatorDriver({ output: driverOutput, bundleId: 'dev.craft.timedinput.host',
    bundleIdPrefix: 'dev.craft.timedinput', projectName: 'TimedInputDriver', tabs: inputNames, script })
  copyFileSync(join(import.meta.dir, '../fixtures/timed-input/HostApp.swift'), join(driverOutput, 'Host/HostApp.swift'))
  run(['xcodegen', 'generate'], driverOutput, 'Generating timed input driver')
  run(['xcodebuild', '-quiet', '-project', 'TimedInputDriver.xcodeproj', '-scheme', 'TimedInputDriver',
    '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', join(workspace, 'DriverDerivedData'),
    'CODE_SIGNING_ALLOWED=NO', 'build-for-testing'], driverOutput, 'Compiling generated native input test host')
  const inputDevice = await pickSimulator()
  await bootSimulator(inputDevice)
  run(['xcodebuild', '-quiet', '-project', 'TimedInputDriver.xcodeproj', '-scheme', 'TimedInputDriver',
    '-destination', `id=${inputDevice.udid}`, '-derivedDataPath', join(workspace, 'DriverDerivedData'),
    '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', 'CODE_SIGNING_ALLOWED=NO',
    '-resultBundlePath', join(workspace, 'TimedInputDriver.xcresult'), 'test-without-building'],
  driverOutput, 'Verifying 24 timed native taps reach independent native buttons')

  checkLoadFailureClassifier(workspace, run)
  checkRecoveryBudget(workspace, run)

  for (const fixture of fixtures) {
    const output = join(workspace, fixture.name)
    await init({
      name: fixture.name,
      bundleId: fixture.bundleId,
      output,
      config: fixture.config,
      runtimeDir: null,
    })

    run(['xcodegen', 'generate'], output, `Generating ${fixture.name}.xcodeproj`)
    // The app target embeds the Watch app when enabled, and building it for a
    // device SDK by target cannot resolve that mixed-platform graph, so the
    // device-SDK compile of the identical iOS source happens in the sibling
    // capability fixture. The embedded graph is built and installed on a
    // simulator by installEmbeddedWatchApp instead.
    if (!fixture.config?.enableWatchApp)
      buildTarget(output, fixture.name, fixture.name, 'iphoneos')

    if (fixture.name === 'MinimalProbe' || fixture.name === 'CapabilityProbe') {
      checkMusicPermissionBinary(output, fixture.name, !!fixture.config?.enableAppleMusic, 'Debug')
      buildTarget(output, fixture.name, fixture.name, 'iphoneos', 'Release')
      checkMusicPermissionBinary(output, fixture.name, !!fixture.config?.enableAppleMusic, 'Release')
    }

    if (fixture.config?.enableLiveActivities)
      buildTarget(output, fixture.name, `${fixture.name}LiveActivity`, 'iphoneos')

    if (fixture.config?.enableWatchApp) {
      buildTarget(output, fixture.name, `${fixture.name}WatchExtension`, 'watchos')
      buildTarget(output, fixture.name, `${fixture.name}Watch`, 'watchos')
      await installEmbeddedWatchApp(output, fixture.name, fixture.bundleId)
    }
  }

  // A Release build is what gets archived for the App Store and TestFlight,
  // and APNs refuses production pushes to an app signed for development.
  const pushOutput = join(workspace, pushFixture.name)
  await init({ name: pushFixture.name, bundleId: pushFixture.bundleId, output: pushOutput, config: pushFixture.config, runtimeDir: null })
  run(['xcodegen', 'generate'], pushOutput, `Generating ${pushFixture.name}.xcodeproj`)
  for (const [configuration, expected] of [['Debug', 'development'], ['Release', 'production']] as const) {
    const signed = signedApnsEnvironment(pushOutput, pushFixture.name, configuration)
    if (signed !== expected)
      throw new Error(`${configuration} signs aps-environment=${signed}, expected ${expected}`)
    console.log(`ok: ${configuration} signs aps-environment=${signed}`)
  }
  retainTimedInputEvidence(true)
}
catch (error) {
  try { retainTimedInputEvidence() }
  catch (diagnosticError) { console.error('Unable to retain XCTest diagnostics:', diagnosticError) }
  throw error
}
finally {
  if (keepProjects) {
    keepTempDir(workspace)
    console.log(`\nGenerated iOS fixtures kept at ${workspace}`)
  }
  else {
    removeTempDir(workspace)
  }
}
