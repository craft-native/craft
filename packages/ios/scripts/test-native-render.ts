import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { bootSimulator, build, init, pickSimulator } from '../src/index'
import { addSchemeTestTargets, insertProjectTargetsBeforeSchemes } from './insert-project-targets'

const fixture = join(import.meta.dir, '..', 'fixtures', 'native-screen')
const workspace = mkdtempSync(join(tmpdir(), 'craft-native-render-'))
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
    config: { renderer: 'native' },
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
  copyFileSync(join(fixture, 'NativeRenderUnitTests.swift'), join(output, 'UnitTests', 'NativeRenderUnitTests.swift'))
  copyFileSync(join(fixture, 'NativeLayoutUnitTests.swift'), join(output, 'UnitTests', 'NativeLayoutUnitTests.swift'))
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
  NativeRenderUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - UITests
    dependencies:
      - target: NativeRender
`)
  writeFileSync(project, addSchemeTestTargets(projectWithTargets, 'NativeRender', ['NativeRenderUnitTests', 'NativeRenderUITests']))
  run(['xcodegen', 'generate'], output)

  // A simulator of its own (CRAFT_NATIVE_RENDER_SIMULATOR=<udid>) keeps other
  // apps launched on a shared one from interrupting the UI test.
  const requested = process.env.CRAFT_NATIVE_RENDER_SIMULATOR
  const device = requested ? { udid: requested, name: requested, state: 'Booted', runtime: 'iOS' } : await pickSimulator()
  if (!device) throw new Error('No iOS simulator is available for native renderer tests')
  if (!requested) await bootSimulator(device)
  run([
    'xcodebuild', '-project', 'NativeRender.xcodeproj', '-scheme', 'NativeRender',
    '-configuration', 'Debug', '-destination', `id=${device.udid}`,
    '-derivedDataPath', join(workspace, 'DerivedData'),
    '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO', 'test',
  ], output)
  console.log('Native renderer unit and simulator UI tests passed')
}
finally {
  if (process.env.CRAFT_KEEP_NATIVE_RENDER_PROJECT === '1')
    console.log(`Kept generated test project: ${workspace}`)
  else
    rmSync(workspace, { recursive: true, force: true })
}
