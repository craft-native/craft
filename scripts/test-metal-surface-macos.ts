import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { NativeFixtureCommandScope, nativeFixtureBuildTimeoutMs } from '../packages/ios/scripts/native-fixture-command'
import { tempDirPrefix } from '../packages/typescript/src/temp-dir'
import { resolveZig } from './zig'

const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: { xcodegen: { type: 'string' }, output: { type: 'string' } } })
if (process.platform !== 'darwin' || !values.xcodegen || !isAbsolute(values.xcodegen))
  throw new Error('Use macOS with --xcodegen <absolute managed executable> [--output <evidence directory>]')
const commandScope = new NativeFixtureCommandScope()
const root = resolve(import.meta.dir, '..')
const source = join(root, 'packages/ios/fixtures/metal-surface')
const zig = resolveZig(root)
if (zig.overridden) throw new Error('Native Metal acceptance requires the pinned compiler')
const xcodegen = realpathSync(values.xcodegen)
const output = resolve(values.output ?? join(root, 'artifacts/native-metal-macos'))
mkdirSync(output, { recursive: true })
const evidence = mkdtempSync(join(output, 'run-'))
const workspace = realpathSync(mkdtempSync(join(tmpdir(), tempDirPrefix('metal-macos'))))
const interruption = new AbortController()
const onSignal = () => interruption.abort(new Error('Native macOS Metal acceptance interrupted'))
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.on(signal, onSignal)
const proof: Record<string, unknown> = { purpose: 'native AppKit Metal displayed-pixel acceptance', startedAt: new Date().toISOString(), compiler: zig, evidence, commands: [] }
let failure: unknown
function save(): void { writeFileSync(join(evidence, 'verification.json'), `${JSON.stringify(proof, null, 2)}\n`) }
async function capture(args: string[], cleanup = false): Promise<string> {
  const result = await commandScope.run(args, { cwd: workspace, timeoutMs: 30_000, signal: cleanup ? undefined : interruption.signal })
  ;(proof.commands as unknown[]).push({ args, ...result })
  save()
  if (result.code !== 0 || result.timedOut || result.cancelled) throw new Error(`Command failed (${result.code}): ${args[0]}: ${result.stderr}`)
  return result.stdout.trim()
}
async function run(name: string, args: string[], timeoutMs: number): Promise<void> {
  const log = join(evidence, `${name}.log`)
  proof.currentStep = name
  save()
  const result = await commandScope.run(args, { cwd: workspace, timeoutMs, logPath: log, signal: interruption.signal })
  ;(proof.commands as unknown[]).push({ name, args, timeoutMs, ...result, log })
  save()
  if (result.code !== 0 || result.timedOut || result.cancelled) throw new Error(`${name} failed (${result.code}); see ${log}`)
}

// LaunchServices can own the tested app outside xcodebuild's process group.
// Restrict cleanup to this unique generated project's executable paths.
async function ownedApplications(): Promise<number[]> {
  const pattern = `${workspace.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/DerivedData/Build/Products/.*\\.app/Contents/MacOS/`
  const result = await commandScope.run(['pgrep', '-f', pattern], { cwd: workspace, timeoutMs: 10_000 })
  if (result.timedOut || result.cancelled || ![0, 1].includes(result.code)) throw new Error('Cannot inspect owned native application disposal')
  if (result.code === 1) return []
  const pids = result.stdout.trim().split(/\s+/)
  if (pids.some(pid => !/^[1-9]\d*$/.test(pid))) throw new Error('Invalid owned application identity')
  return pids.map(Number)
}
async function disposeApplications(): Promise<void> {
  for (const signal of ['SIGTERM', 'SIGKILL'] as const) {
    for (const pid of await ownedApplications()) {
      const inspection = await commandScope.run(['ps', '-p', String(pid), '-o', 'comm='], { cwd: workspace, timeoutMs: 10_000 })
      // The app can finish between the PID inventory and identity inspection.
      if (inspection.code === 1 && !inspection.timedOut && !inspection.cancelled) continue
      if (inspection.code !== 0 || inspection.timedOut || inspection.cancelled) throw new Error('Cannot verify the owned application executable')
      const command = inspection.stdout.trim()
      if (!command.startsWith(`${workspace}/DerivedData/Build/Products/`)) throw new Error('Refusing to signal an unrelated application')
      try { process.kill(pid, signal) }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error }
    }
    const deadline = performance.now() + 1000
    do {
      if (!(await ownedApplications()).length) return
      await Bun.sleep(25)
    } while (performance.now() < deadline)
  }
  throw new Error('An owned native Metal application remained after disposal')
}

try {
  proof.source = await capture(['git', '-C', root, 'rev-parse', 'HEAD'])
  proof.sourceDirty = (await capture(['git', '-C', root, 'status', '--porcelain', '--untracked-files=all'])).length > 0
  proof.harnessSha256 = Bun.SHA256.hash(readFileSync(import.meta.path), 'hex')
  proof.surfaceSha256 = Bun.SHA256.hash(readFileSync(join(root, 'packages/zig/src/metal_surface.zig')), 'hex')
  proof.fixtureSources = Object.fromEntries(['fixture.zig', 'MacHostApp.swift', 'MacMetalSurfaceUITests.swift'].map(name => [name, Bun.SHA256.hash(readFileSync(join(source, name)), 'hex')]))
  // The hosted macOS image provisions unattended UI testing. Inspect that
  // prerequisite without changing the local machine's authentication policy.
  // https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-machine.sh
  proof.automationMode = await capture(['/usr/bin/automationmodetool'])
  if (!String(proof.automationMode).includes('DOES NOT REQUIRE'))
    throw new Error('macOS UI automation requires user authentication on this host. Use a provisioned UI-testing host; the harness does not change authentication policy.')
  const sdk = await capture(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
  proof.xcode = await capture(['xcodebuild', '-version'])
  proof.xcodegen = await capture([xcodegen, '--version'])
  const target = process.arch === 'arm64' ? 'aarch64-macos.13.0' : 'x86_64-macos.13.0'
  const library = join(workspace, 'libMetalSurfaceFixture.a')
  await run('compile-native-surface', [zig.path, 'build-lib', '-static', '-OReleaseSafe', '-target', target, '--dep', 'metal_surface', `-Mroot=${join(source, 'fixture.zig')}`, '-OReleaseSafe', '-target', target, `-Mmetal_surface=${join(root, 'packages/zig/src/metal_surface.zig')}`, '-lc', '-framework', 'Metal', '-framework', 'QuartzCore', '-F', join(sdk, 'System/Library/Frameworks'), '-L', join(sdk, 'usr/lib'), `-femit-bin=${library}`], 180_000)
  proof.librarySha256 = Bun.SHA256.hash(readFileSync(library), 'hex')
  for (const folder of ['App', 'UITests']) mkdirSync(join(workspace, folder))
  copyFileSync(join(source, 'MacHostApp.swift'), join(workspace, 'App/HostApp.swift'))
  copyFileSync(join(source, 'MacMetalSurfaceUITests.swift'), join(workspace, 'UITests/MetalSurfaceUITests.swift'))
  writeFileSync(join(workspace, 'project.yml'), `name: MacMetalSurfaceFixture
options:
  deploymentTarget:
    macOS: '13.0'
settings:
  base:
    SWIFT_VERSION: '5.0'
    CODE_SIGN_IDENTITY: '-'
    ENABLE_HARDENED_RUNTIME: NO
targets:
  MacMetalSurfaceFixture:
    type: application
    platform: macOS
    sources: [App]
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Craft native Metal acceptance
        NSPrincipalClass: NSApplication
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.craft.macos-metal-fixture
        LIBRARY_SEARCH_PATHS: [$(inherited), $(PROJECT_DIR)]
    dependencies:
      - framework: libMetalSurfaceFixture.a
        embed: false
      - sdk: Metal.framework
      - sdk: QuartzCore.framework
  MacMetalSurfaceUITests:
    type: bundle.ui-testing
    platform: macOS
    sources: [UITests]
    dependencies:
      - target: MacMetalSurfaceFixture
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: dev.craft.macos-metal-fixture.uitests
        TEST_TARGET_NAME: MacMetalSurfaceFixture
schemes:
  MacMetalSurfaceFixture:
    build:
      targets:
        MacMetalSurfaceFixture: all
        MacMetalSurfaceUITests: [test]
    test:
      config: Debug
      targets: [MacMetalSurfaceUITests]
`)
  await run('generate-project', [xcodegen, 'generate'], 60_000)
  const common = ['xcodebuild', '-project', 'MacMetalSurfaceFixture.xcodeproj', '-scheme', 'MacMetalSurfaceFixture', '-destination', 'platform=macOS', '-derivedDataPath', join(workspace, 'DerivedData'), '-parallel-testing-enabled', 'NO', 'CODE_SIGN_IDENTITY=-']
  await run('build-native-appkit-tests', [...common, 'build-for-testing'], nativeFixtureBuildTimeoutMs)
  const results = join(evidence, 'TestResults.xcresult')
  await run('verify-displayed-metal-frames', [...common, '-only-testing:MacMetalSurfaceUITests', '-resultBundlePath', results, 'test-without-building'], 300_000)
  const summary = JSON.parse(await capture(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', results]))
  proof.xctest = summary
  if (summary.result !== 'Passed' || summary.totalTestCount !== 1 || summary.passedTests !== 1 || summary.failedTests !== 0 || summary.skippedTests !== 0)
    throw new Error('Native macOS Metal acceptance requires the actual display test to pass without skips')
  proof.status = 'passed'
}
catch (error) { failure = error; proof.status = 'failed'; proof.error = String(error) }
finally {
  try { await disposeApplications(); proof.applicationsDisposed = true }
  catch (error) { failure ??= error; proof.status = 'failed'; proof.cleanupError = String(error) }
  if (proof.applicationsDisposed && commandScope.allDisposed) {
    try { rmSync(workspace, { recursive: true, force: true }); proof.workspaceDisposed = true }
    catch (error) { failure ??= error; proof.status = 'failed'; proof.workspaceCleanupError = String(error) }
  }
  else { proof.workspaceRetained = workspace }
  proof.commandGroupsDisposed = commandScope.allDisposed
  if (!commandScope.allDisposed) {
    failure ??= new Error('A native command did not acknowledge complete process-group disposal')
    proof.status = 'failed'
    proof.error = String(failure)
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
console.log(JSON.stringify({ status: proof.status, evidence, applicationsDisposed: proof.applicationsDisposed }))
if (failure) throw failure
