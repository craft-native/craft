import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { init, type CraftConfig } from '../src/index'

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
    // The app target embeds the Watch app when enabled. Xcode refuses to
    // resolve that mixed-platform graph without a watchOS runtime, even for
    // device-SDK builds, so compile the identical iOS source in the sibling
    // capability fixture and test Watch targets directly here.
    if (!fixture.config?.enableWatchApp)
      buildTarget(output, fixture.name, fixture.name, 'iphoneos')

    if (fixture.config?.enableLiveActivities)
      buildTarget(output, fixture.name, `${fixture.name}LiveActivity`, 'iphoneos')

    if (fixture.config?.enableWatchApp) {
      buildTarget(output, fixture.name, `${fixture.name}WatchExtension`, 'watchos')
      buildTarget(output, fixture.name, `${fixture.name}Watch`, 'watchos')
    }
  }
}
finally {
  if (keepProjects)
    console.log(`\nGenerated iOS fixtures kept at ${workspace}`)
  else
    rmSync(workspace, { force: true, recursive: true })
}
