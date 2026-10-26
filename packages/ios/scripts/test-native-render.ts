import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { bootSimulator, build, init, pickSimulator } from '../src/index'
import { addSchemeTestTargets, insertProjectTargetsBeforeSchemes } from './insert-project-targets'
import { nativeTestResultBundle } from './native-test-result'
import { createTempDir, keepTempDir, removeTempDir } from '../../typescript/src/temp-dir'

const cliArgs = process.argv.slice(2)
if (cliArgs.length > 0) {
  if (cliArgs.length === 1 && ['--help', '-h'].includes(cliArgs[0]!)) {
    console.log('Usage: bun packages/ios/scripts/test-native-render.ts\nSet CRAFT_NATIVE_RENDER_SIMULATOR to an owned disposable simulator UUID and CRAFT_ONLY_TESTING to an XCTest selection.\nCRAFT_NATIVE_RENDER_RESULT selects a retained .xcresult destination.')
    process.exit(0)
  }
  throw new Error(`Unknown native renderer test argument: ${cliArgs.join(' ')}`)
}

const fixture = join(import.meta.dir, '..', 'fixtures', 'native-screen')
const workspace = createTempDir('craft-native-render-')
const output = join(workspace, 'NativeRender')

function run(args: string[], cwd: string): void {
  console.log(args.join(' '))
  const result = Bun.spawnSync(args, { cwd, stdout: 'inherit', stderr: 'inherit' })
  if (result.exitCode !== 0)
    throw new Error(`${args[0]} exited with ${result.exitCode}`)
}

try {
  await init({
    name: 'NativeRender',
    bundleId: 'dev.craft.native-render',
    output,
    config: { renderer: 'native', urlSchemes: ['craft-fixture'], appShortcuts: [{ id: 'saved', title: 'Saved trails', symbol: 'heart.fill', url: 'craft-fixture://saved', phrases: ['Show saved trails in {app}'] }] },
    runtimeDir: null,
  })
  await build({
    output,
    nativeBundlePath: process.env.CRAFT_NATIVE_RENDER_BUNDLE || join(fixture, 'render-test.js'),
    generateProject: false,
    runtimeDir: null,
  })

  mkdirSync(join(output, 'UnitTests'))
  mkdirSync(join(output, 'UITests'))
  // A plain UIKit comparison is installed only in this generated test app,
  // never in the shipped template or an application's public bridge.
  copyFileSync(join(fixture, 'SwitchReference.swift'), join(output, 'Sources', 'SwitchReference.swift'))
  const appSourcePath = join(output, 'Sources', 'NativeRenderApp.swift')
  const appSource = readFileSync(appSourcePath, 'utf8')
  const sceneAnchor = 'WindowGroup {\n            Group {\n'
  if (!appSource.includes(sceneAnchor)) throw new Error('Native renderer test app scene anchor changed')
  writeFileSync(appSourcePath, appSource.replace(sceneAnchor, `${sceneAnchor}                if ProcessInfo.processInfo.arguments.contains("--reference-switch") {
                    SwitchReference()
                } else
`))
  copyFileSync(join(fixture, 'NativeRenderUnitTests.swift'), join(output, 'UnitTests', 'NativeRenderUnitTests.swift'))
  copyFileSync(join(fixture, 'NativeLayoutUnitTests.swift'), join(output, 'UnitTests', 'NativeLayoutUnitTests.swift'))
  copyFileSync(join(fixture, 'NativeAudioUnitTests.swift'), join(output, 'UnitTests', 'NativeAudioUnitTests.swift'))
  copyFileSync(join(fixture, 'HeartRateUnitTests.swift'), join(output, 'UnitTests', 'HeartRateUnitTests.swift'))
  copyFileSync(join(fixture, 'FilesUnitTests.swift'), join(output, 'UnitTests', 'FilesUnitTests.swift'))
  copyFileSync(join(fixture, 'ScriptThreadUnitTests.swift'), join(output, 'UnitTests', 'ScriptThreadUnitTests.swift'))
  copyFileSync(join(fixture, 'KeychainUnitTests.swift'), join(output, 'UnitTests', 'KeychainUnitTests.swift'))
  copyFileSync(join(fixture, 'NativeRenderUITests.swift'), join(output, 'UITests', 'NativeRenderUITests.swift'))
  const project = join(output, 'project.yml')
  const projectWithTargets = insertProjectTargetsBeforeSchemes(readFileSync(project, 'utf8'), `
  NativeRenderUnitTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - UnitTests
    dependencies:
      - target: NativeRender
    settings:
      TEST_HOST: "$(BUILT_PRODUCTS_DIR)/NativeRender.app/NativeRender"
      BUNDLE_LOADER: "$(TEST_HOST)"
      GENERATE_INFOPLIST_FILE: YES
      PRODUCT_NAME: "$(TARGET_NAME)"
      PRODUCT_BUNDLE_IDENTIFIER: dev.craft.native-render.tests
      SWIFT_VERSION: "5.0"
  NativeRenderUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - UITests
    dependencies:
      - target: NativeRender
    settings:
      TEST_TARGET_NAME: NativeRender
      GENERATE_INFOPLIST_FILE: YES
      PRODUCT_NAME: "$(TARGET_NAME)"
      PRODUCT_BUNDLE_IDENTIFIER: dev.craft.native-render.uitests
      SWIFT_VERSION: "5.0"
`)
  writeFileSync(project, addSchemeTestTargets(projectWithTargets, 'NativeRender', ['NativeRenderUnitTests', 'NativeRenderUITests']))
  run(['xcodegen', 'generate'], output)

  // A simulator of its own (CRAFT_NATIVE_RENDER_SIMULATOR=<udid>) keeps other
  // apps launched on a shared one from interrupting the UI test.
  const requested = process.env.CRAFT_NATIVE_RENDER_SIMULATOR
  const device = requested ? { udid: requested, name: requested, state: 'Booted', runtime: 'iOS' } : await pickSimulator()
  if (!device) throw new Error('No iOS simulator is available for native renderer tests')
  if (!requested) await bootSimulator(device)
  // XCTest writes failures and screenshots directly into retained CI evidence,
  // so temporary-project cleanup cannot discard them after an error or abort.
  const results = nativeTestResultBundle(workspace, process.env.CRAFT_NATIVE_RENDER_RESULT)
  run([
    'xcodebuild', '-project', 'NativeRender.xcodeproj', '-scheme', 'NativeRender',
    '-configuration', 'Debug', '-destination', `id=${device.udid}`,
    '-derivedDataPath', join(workspace, 'DerivedData'),
    '-collect-test-diagnostics', 'never',
    '-test-timeouts-enabled', 'YES',
    '-default-test-execution-time-allowance', '300',
    '-maximum-test-execution-time-allowance', '300',
    '-resultBundlePath', results,
    '-parallel-testing-enabled', 'NO', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', 'ENABLE_TESTABILITY=YES',
    'ONLY_ACTIVE_ARCH=YES', 'SWIFT_OPTIMIZATION_LEVEL=-Onone',
    'test', ...(process.env.CRAFT_ONLY_TESTING ? [`-only-testing:${process.env.CRAFT_ONLY_TESTING}`] : []),
  ], output)
  const summary = Bun.spawnSync(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', results], { stdout: 'pipe', stderr: 'pipe' })
  if (summary.exitCode !== 0) throw new Error(`Could not read XCTest results: ${summary.stderr.toString()}`)
  const counts = JSON.parse(summary.stdout.toString())
  if (counts.result !== 'Passed' || counts.totalTestCount < 1 || counts.passedTests !== counts.totalTestCount || counts.failedTests !== 0 || counts.skippedTests !== 0)
    throw new Error(`Expected passed native tests with no empty selection or skips: ${JSON.stringify(counts)}`)
  console.log('Native renderer unit and simulator UI tests passed')
}
finally {
  if (process.env.CRAFT_KEEP_NATIVE_RENDER_PROJECT === '1') {
    keepTempDir(workspace)
    console.log(`Kept generated test project: ${workspace}`)
  }
  else {
    removeTempDir(workspace)
  }
}
