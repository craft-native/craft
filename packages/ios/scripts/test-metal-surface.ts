import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { resolveZig } from '../../../scripts/zig'
import { tempDirPrefix } from '../../typescript/src/temp-dir'
import { NativeFixtureCommandScope } from './native-fixture-command'
import { metalXCTestSteps, verifyMetalXCTestSummaries } from './metal-xctest-steps'

const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: { runtime: { type: 'string' }, xcodegen: { type: 'string' }, output: { type: 'string' } } })
if (process.platform !== 'darwin' || !values.runtime || !values.xcodegen || !isAbsolute(values.xcodegen))
  throw new Error('Use macOS with --runtime <installed iOS runtime identifier> --xcodegen <absolute managed executable> [--output <evidence directory>]')
const commandScope = new NativeFixtureCommandScope()
const root = resolve(import.meta.dir, '../../..')
const source = join(root, 'packages/ios/fixtures/metal-surface')
const zig = resolveZig(root)
if (zig.overridden) throw new Error('Native Metal acceptance requires the pinned compiler')
const xcodegen = realpathSync(values.xcodegen)
const evidenceRoot = resolve(values.output ?? join(root, 'artifacts/native-metal-ios'))
mkdirSync(evidenceRoot, { recursive: true })
const evidence = mkdtempSync(join(evidenceRoot, 'run-'))
// This harness owns asynchronous command and simulator teardown. Its signal
// handler must finish that teardown before removing the project directory.
const workspace = mkdtempSync(join(tmpdir(), tempDirPrefix('metal-ios')))
const interruption = new AbortController()
const onSignal = () => interruption.abort(new Error('Native Metal acceptance interrupted'))
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.on(signal, onSignal)
const proof: Record<string, unknown> = { purpose: 'native UIKit Metal surface acceptance', startedAt: new Date().toISOString(), compiler: zig, runtime: values.runtime, evidence, commands: [] }
let simulator: string | undefined
let failure: unknown
function save(): void { writeFileSync(join(evidence, 'verification.json'), `${JSON.stringify(proof, null, 2)}\n`) }
async function capture(args: string[], options: { allowFailure?: boolean, cleanup?: boolean, timeoutMs?: number } = {}): Promise<string> {
  const timeoutMs = options.timeoutMs ?? 30_000
  const result = await commandScope.run(args, { cwd: workspace, timeoutMs, signal: options.cleanup ? undefined : interruption.signal })
  const { code, stdout, stderr } = result
  ;(proof.commands as unknown[]).push({ args, timeoutMs, ...result })
  save()
  if ((code !== 0 || result.timedOut || result.cancelled) && !options.allowFailure) throw new Error(`Command failed (${code}): ${args[0]}: ${stderr}`)
  return stdout.trim()
}
async function run(name: string, args: string[], timeoutMs: number): Promise<void> {
  const log = join(evidence, `${name}.log`)
  const startedAt = new Date().toISOString()
  proof.currentStep = name
  save()
  const result = await commandScope.run(args, { cwd: workspace, timeoutMs, logPath: log, signal: interruption.signal })
  ;(proof.commands as unknown[]).push({ name, args, timeoutMs, ...result, startedAt, finishedAt: new Date().toISOString(), log })
  save()
  if (result.code !== 0 || result.timedOut || result.cancelled) throw new Error(`${name} failed (${result.code}); see ${log}`)
}
try {
  // The first CoreSimulator query may start its service and migrate metadata.
  // Later metadata commands retain their normal 30-second deadline.
  const runtimes = JSON.parse(await capture(['xcrun', 'simctl', 'list', 'runtimes', '--json'], { timeoutMs: 120_000 })).runtimes as { identifier: string, isAvailable: boolean }[]
  if (!runtimes.some(runtime => runtime.identifier === values.runtime && runtime.isAvailable)) throw new Error('The requested iOS runtime must be installed and available')
  const sdk = await capture(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
  proof.xcode = await capture(['xcodebuild', '-version'])
  proof.xcodegen = await capture([xcodegen, '--version'])
  proof.source = await capture(['git', '-C', root, 'rev-parse', 'HEAD'])
  proof.sourceDirty = (await capture(['git', '-C', root, 'status', '--porcelain', '--untracked-files=all'])).length > 0
  proof.harnessSha256 = new Bun.CryptoHasher('sha256').update(readFileSync(import.meta.path)).digest('hex')
  proof.commandOwnerSha256 = new Bun.CryptoHasher('sha256').update(readFileSync(join(import.meta.dir, 'native-fixture-command.ts'))).digest('hex')
  proof.fixtureSources = Object.fromEntries(['fixture.zig', 'HostApp.swift', 'MetalSurfaceTests.swift', 'MetalSurfaceUITests.swift'].map(name => [name, new Bun.CryptoHasher('sha256').update(readFileSync(join(source, name))).digest('hex')]))
  proof.surfaceSha256 = new Bun.CryptoHasher('sha256').update(readFileSync(join(root, 'packages/zig/src/metal_surface.zig'))).digest('hex')
  const target = process.arch === 'arm64' ? 'aarch64-ios.15.0-simulator' : 'x86_64-ios.15.0-simulator'
  const library = join(workspace, 'libMetalSurfaceFixture.a')
  await run('compile-native-surface', [zig.path, 'build-lib', '-static', '-OReleaseSafe', '-target', target, '--dep', 'metal_surface', `-Mroot=${join(source, 'fixture.zig')}`, '-OReleaseSafe', '-target', target, `-Mmetal_surface=${join(root, 'packages/zig/src/metal_surface.zig')}`, '-lc', '-framework', 'Metal', '-framework', 'QuartzCore', '-F', join(sdk, 'System/Library/Frameworks'), '-L', join(sdk, 'usr/lib'), `-femit-bin=${library}`], 180_000)
  proof.librarySha256 = new Bun.CryptoHasher('sha256').update(readFileSync(library)).digest('hex')
  for (const folder of ['App', 'UnitTests', 'UITests']) mkdirSync(join(workspace, folder))
  copyFileSync(join(source, 'HostApp.swift'), join(workspace, 'App/HostApp.swift'))
  copyFileSync(join(source, 'MetalSurfaceTests.swift'), join(workspace, 'UnitTests/MetalSurfaceTests.swift'))
  copyFileSync(join(source, 'MetalSurfaceUITests.swift'), join(workspace, 'UITests/MetalSurfaceUITests.swift'))
  writeFileSync(join(workspace, 'project.yml'), `name: MetalSurfaceFixture
options:
  deploymentTarget:
    iOS: '15.0'
settings:
  base:
    SWIFT_VERSION: '5.0'
    CODE_SIGNING_ALLOWED: NO
targets:
  MetalSurfaceFixture:
    type: application
    platform: iOS
    sources: [App]
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Craft Metal Fixture
        UILaunchScreen: {}
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: false
          UISceneConfigurations:
            UIWindowSceneSessionRoleApplication:
              - UISceneConfigurationName: Default Configuration
                UISceneDelegateClassName: $(PRODUCT_MODULE_NAME).SceneDelegate
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.craft.metal-fixture
        ENABLE_TESTABILITY: YES
        LIBRARY_SEARCH_PATHS:
          - $(inherited)
          - $(PROJECT_DIR)
    dependencies:
      - framework: libMetalSurfaceFixture.a
        embed: false
      - sdk: Metal.framework
      - sdk: QuartzCore.framework
  MetalSurfaceUnitTests:
    type: bundle.unit-test
    platform: iOS
    sources: [UnitTests]
    dependencies:
      - target: MetalSurfaceFixture
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: dev.craft.metal-fixture.tests
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/MetalSurfaceFixture.app/MetalSurfaceFixture
        BUNDLE_LOADER: $(TEST_HOST)
  MetalSurfaceUITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [UITests]
    dependencies:
      - target: MetalSurfaceFixture
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: dev.craft.metal-fixture.uitests
        TEST_TARGET_NAME: MetalSurfaceFixture
schemes:
  MetalSurfaceFixture:
    build:
      targets:
        MetalSurfaceFixture: all
        MetalSurfaceUnitTests: [test]
        MetalSurfaceUITests: [test]
    test:
      config: Debug
      targets: [MetalSurfaceUnitTests, MetalSurfaceUITests]
`)
  await run('generate-project', [xcodegen, 'generate'], 60_000)
  const name = `Craft Metal ${crypto.randomUUID()}`
  simulator = await capture(['xcrun', 'simctl', 'create', name, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', values.runtime])
  if (!/^[0-9A-F-]{36}$/i.test(simulator)) { simulator = undefined; throw new Error('Simulator creation did not return an owned UUID') }
  proof.simulator = { udid: simulator, name, deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro' }
  await capture(['xcrun', 'simctl', 'boot', simulator])
  await run('boot-owned-simulator', ['xcrun', 'simctl', 'bootstatus', simulator, '-b'], 180_000)
  const results = join(evidence, 'TestResults.xcresult')
  const summaries: Record<string, unknown>[] = []
  for (const step of metalXCTestSteps(simulator, join(workspace, 'DerivedData'), results)) {
    await run(step.name, step.args, step.timeoutMs)
    if (step.resultBundle) {
      const summary = JSON.parse(await capture(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', step.resultBundle]))
      summaries.push(summary)
      proof.xctest = summaries
      save()
    }
  }
  verifyMetalXCTestSummaries(summaries)
  proof.status = 'passed'
}
catch (error) { failure = error; proof.status = 'failed'; proof.error = String(error) }
finally {
  const cleanupErrors: string[] = []
  if (simulator && commandScope.allDisposed) {
    // Failure to retain a cleanup log must not prevent the next owned cleanup.
    try { await capture(['xcrun', 'simctl', 'shutdown', simulator], { allowFailure: true, cleanup: true }) }
    catch (error) { cleanupErrors.push(String(error)) }
    if (commandScope.allDisposed) {
      try { await capture(['xcrun', 'simctl', 'delete', simulator], { cleanup: true }) }
      catch (error) { cleanupErrors.push(String(error)) }
    }
    if (commandScope.allDisposed) {
      try {
        const remaining = JSON.parse(await capture(['xcrun', 'simctl', 'list', 'devices', simulator, '--json'], { cleanup: true })).devices as Record<string, { udid: string }[]>
        if (Object.values(remaining).flat().some(device => device.udid === simulator)) throw new Error('The owned simulator remained registered after deletion')
        proof.simulatorDisposed = true
      }
      catch (error) { cleanupErrors.push(String(error)) }
    }
  }
  if (!commandScope.allDisposed) {
    cleanupErrors.push('A native command did not acknowledge complete process-group disposal')
    if (simulator && !proof.simulatorDisposed) proof.simulatorRetained = simulator
  }
  if (commandScope.allDisposed && (!simulator || proof.simulatorDisposed)) {
    try { rmSync(workspace, { recursive: true, force: true }); proof.workspaceDisposed = true }
    catch (error) { cleanupErrors.push(String(error)) }
  }
  else { proof.workspaceRetained = workspace }
  proof.commandGroupsDisposed = commandScope.allDisposed
  if (cleanupErrors.length) {
    failure ??= new Error(cleanupErrors.join('; '))
    proof.status = 'failed'
    proof.cleanupErrors = cleanupErrors
  }
  if (interruption.signal.aborted) {
    failure ??= interruption.signal.reason
    proof.status = 'failed'
    proof.error = String(failure)
  }
  proof.finishedAt = new Date().toISOString()
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.off(signal, onSignal)
  save()
}
console.log(JSON.stringify({ status: proof.status, evidence, simulatorDisposed: proof.simulatorDisposed }))
if (failure) throw failure
