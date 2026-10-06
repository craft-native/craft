import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { bootSimulator, build, init, pickSimulator } from '../src/index'

const fixture = join(import.meta.dir, '..', 'fixtures', 'native-navigation')
const stxCli = process.env.STX_NATIVE_CLI || resolve(import.meta.dir, '../../../../stx/packages/stx-native/src/cli/index.ts')
const workspace = mkdtempSync(join(tmpdir(), 'craft-native-navigation-'))
const output = join(workspace, 'NativeNavigation')
const bundle = join(workspace, 'routes.js')

function run(args: string[], cwd: string): void {
  console.log(args.join(' '))
  const result = Bun.spawnSync(args, { cwd, stdout: 'inherit', stderr: 'inherit' })
  if (result.exitCode !== 0)
    throw new Error(`${args[0]} exited with ${result.exitCode}`)
}

function runXcodeTests(args: string[], cwd: string, resultBundle: string): void {
  console.log(args.join(' '))
  const result = Bun.spawnSync(args, { cwd, stdout: 'inherit', stderr: 'inherit' })
  if (result.exitCode === 0) return

  if (existsSync(resultBundle)) {
    console.log('xcodebuild failed; extracting test failure details from the result bundle')
    Bun.spawnSync(
      ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', resultBundle],
      { cwd, stdout: 'inherit', stderr: 'inherit' },
    )
  }
  throw new Error(`${args[0]} exited with ${result.exitCode}`)
}

function assertMutationBundle(path: string): void {
  const source = readFileSync(path, 'utf8')
  if (!source.includes('mutationProtocolVersion') || !source.includes("send('MUTATE'"))
    throw new Error('stx-native compiler did not emit the native mutation protocol')
}

try {
  run([process.execPath, stxCli, 'compile', '--format', 'bundle', '--output', bundle], fixture)
  assertMutationBundle(bundle)
  await init({
    name: 'NativeNavigation',
    bundleId: 'dev.craft.native-navigation',
    output,
    config: {
      renderer: 'native',
      enableDeepLinks: true,
      enableLocalDatabase: true,
      enableLocalNotifications: true,
      enableSecureStorage: true,
      enableBiometric: true,
      urlSchemes: ['craft-native-test'],
    },
    runtimeDir: null,
  })
  await build({ output, nativeBundlePath: bundle, generateProject: false, runtimeDir: null })

  mkdirSync(join(output, 'UITests'))
  copyFileSync(join(fixture, 'NativeNavigationUITests.swift'), join(output, 'UITests', 'NativeNavigationUITests.swift'))
  const project = join(output, 'project.yml')
  writeFileSync(project, readFileSync(project, 'utf8') + `
  NativeNavigationUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - UITests
    dependencies:
      - target: NativeNavigation
`)
  run(['xcodegen', 'generate'], output)

  const device = await pickSimulator()
  if (!device) throw new Error('No iOS simulator is available for native navigation tests')
  await bootSimulator(device)
  const resultBundle = join(workspace, 'NativeNavigation.xcresult')
  const selectedTest = process.env.CRAFT_NATIVE_NAVIGATION_TEST
  const selection = selectedTest
    ? [`-only-testing:NativeNavigationUITests/NativeNavigationUITests/${selectedTest}`]
    : []
  runXcodeTests([
    'xcodebuild', '-quiet', '-project', 'NativeNavigation.xcodeproj', '-scheme', 'NativeNavigation',
    '-configuration', 'Debug', '-destination', `id=${device.udid}`,
    '-derivedDataPath', join(workspace, 'DerivedData'),
    '-resultBundlePath', resultBundle,
    ...selection,
    '-parallel-testing-enabled', 'NO', 'CODE_SIGNING_ALLOWED=NO', 'test',
  ], output, resultBundle)
  console.log('Native navigation simulator tests passed')
}
finally {
  if (process.env.CRAFT_KEEP_NATIVE_NAVIGATION_PROJECT === '1')
    console.log(`Kept generated test project: ${workspace}`)
  else
    rmSync(workspace, { recursive: true, force: true })
}
