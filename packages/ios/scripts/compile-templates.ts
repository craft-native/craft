import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Glob } from 'bun'
import { bootSimulator, init, pickSimulator, type CraftConfig } from '../src/index'
import { watchCompanionProblems } from './watch-bundle'

interface CompileFixture {
  bundleId: string
  config?: Partial<CraftConfig>
  name: string
}

const capabilityConfig: Partial<CraftConfig> = {
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
  enableInAppPurchase: true,
  enableLiveActivities: true,
  enableLocalNotifications: true,
  enableMotionSensors: true,
  enableNFC: true,
  enablePushNotifications: true,
  enableQRScanner: true,
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
]

/** Push on and nothing else, so the entitlement builds stay quick. */
const pushFixture: CompileFixture = {
  name: 'PushProbe',
  bundleId: 'dev.craft.templates.push',
  config: { enablePushNotifications: true },
}

const keepProjects = process.argv.includes('--keep')
const workspace = mkdtempSync(join(tmpdir(), 'craft-ios-templates-'))

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

function buildTarget(output: string, projectName: string, targetName: string, sdk: string): void {
  run([
    'xcodebuild',
    '-quiet',
    '-project', `${projectName}.xcodeproj`,
    '-target', targetName,
    '-configuration', 'Debug',
    '-sdk', sdk,
    'CODE_SIGNING_ALLOWED=NO',
    'build',
  ], output, `Compiling ${targetName} against ${sdk}`)
}

try {
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
}
finally {
  if (keepProjects)
    console.log(`\nGenerated iOS fixtures kept at ${workspace}`)
  else
    rmSync(workspace, { force: true, recursive: true })
}
