import { createReadStream } from 'node:fs'
import { chmod, copyFile, cp, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { NativeFixtureCommandScope, nativeFixtureBuildTimeoutMs } from '../../ios/scripts/native-fixture-command'
import { build, init } from '../src/index'
import { createAndroidEmulator } from '../src/emulator'
import { emulatorVersionCommand } from './vulkan-surface-probe'
import { launchAndroidNativeFixture } from './native-fixture-launch'

// #440: one controlled Android interruption boundary, not the full #396 matrix.
const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: { output: { type: 'string' } } })
const root = resolve(import.meta.dir, '../../..')
const fixture = resolve(import.meta.dir, '../fixtures/checkpoint-interruption')
const packageName = 'dev.craft.checkpointprobe'
const destination = 'files/craft-snapshots/craft-interrupted-checkpoint.json'
const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT
const ndk = process.env.ANDROID_NDK_HOME
const sdkmanager = Bun.which('sdkmanager'), avdmanager = Bun.which('avdmanager'), gradle = Bun.which('gradle')
const java = Bun.which('java')
if (!sdk || !ndk || !sdkmanager || !avdmanager || !gradle || !java) throw new Error('Select SDK, NDK and Pantry Android command-line tools')
if (!['darwin', 'linux'].includes(process.platform)) throw new Error('Android checkpoint acceptance requires macOS or Linux')
if (!['arm64', 'x64'].includes(process.arch)) throw new Error('A matching native Android emulator ABI is required')
const abi = process.arch === 'arm64' ? 'arm64-v8a' : 'x86_64'
const triple = process.arch === 'arm64' ? 'aarch64-linux-android' : 'x86_64-linux-android'
const image = `system-images;android-35;google_apis_playstore;${abi}`
const compiler = join(ndk, 'toolchains/llvm/prebuilt', process.platform === 'darwin' ? 'darwin-x86_64' : 'linux-x86_64', 'bin', `${triple}35-clang`)
const output = resolve(values.output ?? join(root, 'artifacts/android-checkpoints'))
let evidence = '', workspace = '', project = ''
const scope = new NativeFixtureCommandScope(), cancellation = new AbortController()
const commands: unknown[] = []
const launches: unknown[] = []
const proof: Record<string, unknown> = {
  purpose: 'Android checkpoint recovery after controlled pre-rename process termination', startedAt: new Date().toISOString(),
  bounds: { buildMs: nativeFixtureBuildTimeoutMs, emulatorBootMs: 600000, publicUiMs: 30000, renameBoundaryMs: 10000, commandMs: 10000 },
  packageName, image, abi, commands, launches,
}
let device: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
let failure: unknown, sequence = 0
const abort = () => cancellation.abort(new Error('Checkpoint probe interrupted'))

async function identity(path: string) {
  const hasher = new Bun.CryptoHasher('sha256')
  for await (const chunk of createReadStream(path)) hasher.update(chunk)
  return { file: await realpath(path), bytes: Bun.file(path).size, sha256: hasher.digest('hex') }
}
async function save() { if (evidence) await writeFile(join(evidence, 'verification.json'), `${JSON.stringify(proof, null, 2)}\n`) }
async function run(name: string, args: string[], timeoutMs = 10000, cwd = workspace, cleanup = false) {
  const logPath = join(evidence, `${String(++sequence).padStart(3, '0')}-${name}.log`)
  proof.currentStep = name
  await save()
  const startedAt = new Date().toISOString(), started = performance.now()
  const result = await scope.run(args, { cwd, timeoutMs, logPath, signal: cleanup ? undefined : cancellation.signal })
  commands.push({ name, args, timeoutMs, startedAt, elapsedMs: performance.now() - started, logPath, ...result })
  await save()
  if (result.code !== 0 || result.timedOut || result.cancelled) throw new Error(`${name} failed (${result.code}); ${logPath}`)
  return readFile(logPath, 'utf8')
}
function adb(...args: string[]) {
  if (!device) throw new Error('Owned Android session is not available')
  return [device.adb, '-s', device.serial, ...args]
}
function shell(...args: string[]) {
  return adb('shell', args.map(value => `'${value.replaceAll("'", "'\\''")}'`).join(' '))
}
function app(...args: string[]) { return shell('run-as', packageName, ...args) }
function expected(generation: number) { return JSON.stringify({ generation, payload: String(generation).repeat(262144) }) }
async function captureUi(label: string, budget = 10000) {
  const deadline = performance.now() + budget
  await run(`${label}-dump`, adb('shell', 'uiautomator', 'dump', '--compressed', '/data/local/tmp/checkpoint-probe.xml'), budget)
  const remaining = Math.floor(deadline - performance.now())
  if (remaining <= 0) throw new Error(`Native UI capture exceeded its original bound: ${label}`)
  const xml = await run(`${label}-xml`, adb('shell', 'cat', '/data/local/tmp/checkpoint-probe.xml'), remaining)
  if (performance.now() > deadline) throw new Error(`Native UI capture exceeded its original bound: ${label}`)
  if (!xml.includes(`package="${packageName}"`)) throw new Error(`Public native UI not in foreground: ${label}`)
  if (xml.includes('class="android.webkit.WebView"')) throw new Error('Checkpoint fixture rendered a WebView instead of native controls')
  return xml
}
async function uiContaining(text: string, label: string, deadline = performance.now() + 30000) {
  while (performance.now() < deadline) {
    const remaining = Math.floor(deadline - performance.now())
    const xml = await captureUi(label, Math.min(10000, remaining))
    if (performance.now() > deadline) throw new Error(`Public UI exceeded its original 30000ms bound: ${label}`)
    const owned = xml.includes(`package="${packageName}"`)
    if (owned && xml.includes(`text="${text}"`)) return xml
    if (owned && /unsupported|unavailable|failed|corrupt|error/i.test(xml)) throw new Error(`Native public UI reported a failure; ${label}`)
    await Bun.sleep(200)
  }
  throw new Error(`Public UI did not show ${text} within its original 30000ms bound`)
}
async function click(text: string, label: string) {
  const xml = await uiContaining(text, `${label}-before`)
  const node = [...xml.matchAll(/<node\b[^>]*>/g)].find(match => match[0].includes(`text="${text}"`))?.[0]
  const bounds = node?.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/)
  if (!bounds) throw new Error(`Missing native control bounds: ${text}`)
  const [, left, top, right, bottom] = bounds.map(Number)
  await run(`${label}-tap`, adb('shell', 'input', 'tap', String(Math.floor((left! + right!) / 2)), String(Math.floor((top! + bottom!) / 2))))
}
function session(xml: string) {
  const value = xml.match(/text="Session ([^"]+)"/)?.[1]
  if (!value) throw new Error('Missing public process session identity')
  return value
}
async function launch(label: string, readyText: string) {
  const result = await launchAndroidNativeFixture({ label, packageName, readyText, adb, run, waitForUi: uiContaining })
  launches.push({ label, pid: result.pid, elapsedMs: result.elapsedMs, boundMs: result.boundMs, uiSha256: Bun.SHA256.hash(result.xml, 'hex') })
  await save()
  return result
}
async function stop(label: string) {
  await run(`${label}-force-stop`, adb('shell', 'am', 'force-stop', packageName))
  const pids = await run(`${label}-absence`, shell('sh', '-c', `if pidof ${packageName}; then exit 1; fi`))
  if (pids.trim()) throw new Error('Stopped app process remained')
}
async function arm(mode: 'pass' | 'hold') {
  await run(`arm-${mode}`, app('sh', '-c', `rm -f files/checkpoint-probe.boundary; printf ${mode} > files/checkpoint-probe.arm`))
}
async function boundary(label: string) {
  const deadline = performance.now() + 10000
  while (performance.now() < deadline) {
    const result = await run(`${label}-boundary`, app('sh', '-c', 'if test -f files/checkpoint-probe.boundary; then cat files/checkpoint-probe.boundary; fi'), Math.min(10000, Math.floor(deadline - performance.now())))
    if (result.trim()) return result.trim().split('\n')
    await Bun.sleep(100)
  }
  throw new Error('No actual rename boundary within the original 10000ms bound')
}
function requireBoundary(record: string[], pid: string, mode: 'pass' | 'hold') {
  if (record.length !== 5 || record[0] !== mode || record[1] !== pid || !/^\d+$/.test(record[2]!) || record[2] === pid
    || !record[3]?.match(/\/craft-snapshots\/\.craft-snapshot-[^/]+\.tmp$/)
    || record[4] !== `/data/user/0/${packageName}/${destination}`) throw new Error('Required worker rename boundary was absent or invalid')
}

try {
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.on(signal, abort)
  cancellation.signal.throwIfAborted()
  await mkdir(output, { recursive: true })
  evidence = await mkdtemp(join(output, 'run-'))
  console.log(`Checkpoint interruption evidence: ${evidence}`)
  cancellation.signal.throwIfAborted()
  workspace = await mkdtemp(join(tmpdir(), 'craft-checkpoint-probe-'))
  workspace = await realpath(workspace)
  project = join(workspace, 'android')
  cancellation.signal.throwIfAborted()
  proof.source = (await run('source', ['git', '-C', root, 'rev-parse', 'HEAD'])).trim()
  proof.sourceStatus = await run('source-status', ['git', '-C', root, 'status', '--short'])
  await mkdir(join(evidence, 'authored'), { recursive: true })
  await cp(fixture, join(evidence, 'authored'), { recursive: true })
  await copyFile(import.meta.filename, join(evidence, 'authored/test-checkpoint-interruption.ts'))
  await copyFile(join(import.meta.dir, 'native-fixture-launch.ts'), join(evidence, 'authored/native-fixture-launch.ts'))
  proof.authored = await Promise.all([...new Bun.Glob('*').scanSync({ cwd: fixture, absolute: true, onlyFiles: true })].map(identity))
  proof.sourceInputs = await Promise.all([
    import.meta.filename, join(import.meta.dir, 'native-fixture-launch.ts'), join(root, 'packages/ios/scripts/native-fixture-command.ts'), join(import.meta.dir, 'vulkan-surface-probe.ts'),
    ...[...new Bun.Glob('**/*').scanSync({ cwd: join(root, 'packages/android/templates'), absolute: true, onlyFiles: true })],
    ...[...new Bun.Glob('*.ts').scanSync({ cwd: join(root, 'packages/android/src'), absolute: true, onlyFiles: true })].filter(path => !path.endsWith('.test.ts')),
    ...['package.json', 'bun.lock', 'pantry.lock', 'packages/android/package.json'].map(path => join(root, path)),
  ].map(identity))
  proof.compiler = await identity(compiler)
  proof.compilerExecutable = await identity(join(compiler, '../clang'))
  proof.compilerVersion = await run('compiler-version', [compiler, '--version'])
  if (!/Android[^\n]*clang version 18\./.test(proof.compilerVersion as string)) throw new Error('Expected the NDK Android clang18 compiler')
  proof.ndk = await readFile(join(ndk, 'source.properties'), 'utf8')
  if (!/^Pkg.Revision\s*=\s*27\.2\.12479018$/m.test(proof.ndk as string)) throw new Error('Expected NDK 27.2.12479018')
  proof.java = await run('java-version', [java, '-version'])
  proof.gradle = await run('gradle-version', [gradle, '--version'])
  if (!/version "17\./.test(proof.java as string) || !/Gradle 8\.11\.1\b/.test(proof.gradle as string)) throw new Error('Require JDK17 and Gradle8.11.1')
  proof.hostTools = await Promise.all([process.execPath, java, gradle, sdkmanager, avdmanager].map(identity))
  await init({ name: 'CheckpointProbe', packageName, output: project, config: { renderer: 'native', nativeScreens: { '/': 'checkpoint' } }, runtimeDir: null })
  await build({ output: project, nativeBundlePath: join(fixture, 'checkpoint.js'), compile: false, runtimeDir: null })
  const backendDirectory = join(project, 'app/src/main/java', ...packageName.split('.'))
  proof.backends = await Promise.all(['CraftSnapshotFile', 'CraftNativeShell', 'MainActivity'].map(async name => {
    const template = name === 'MainActivity' ? 'MainActivityNative.kt.template' : `${name}.kt.template`
    const source = join(root, 'packages/android/templates', template)
    const generated = join(backendDirectory, `${name}.kt`)
    const original = await readFile(source, 'utf8')
    const actual = await readFile(generated, 'utf8')
    // MainActivity contains normal generator substitutions beyond its package.
    if (name !== 'MainActivity' && actual !== original.replaceAll('{{PACKAGE_NAME}}', packageName)) throw new Error(`Generated ${name} backend changed`)
    await copyFile(generated, join(evidence, `${name}.kt`))
    return { template: await identity(source), generated: await identity(generated), unchangedAfterPackageSubstitution: name !== 'MainActivity' }
  }))
  const libraries = join(workspace, 'debug-libraries', abi), resources = join(workspace, 'debug-resources/lib', abi)
  await mkdir(libraries, { recursive: true }); await mkdir(resources, { recursive: true })
  const library = join(libraries, 'libcraft-checkpoint-probe.so')
  await run('compile-debug-interposer', [compiler, '-shared', '-fPIC', '-std=c11', '-Wl,--no-undefined', '-Wall', '-Wextra', '-Werror', join(fixture, 'interpose.c'), '-ldl', '-o', library], 30000)
  proof.interposer = await identity(library)
  await copyFile(library, join(evidence, 'libcraft-checkpoint-probe.so'))
  await copyFile(join(fixture, 'wrap.sh'), join(resources, 'wrap.sh'))
  await chmod(join(resources, 'wrap.sh'), 0o755)
  await writeFile(join(project, 'local.properties'), `sdk.dir=${sdk}\n`)
  await run('compile-generated-native-host', ['env', `CRAFT_CHECKPOINT_DEBUG_LIBS=${join(workspace, 'debug-libraries')}`, `CRAFT_CHECKPOINT_DEBUG_RESOURCES=${join(workspace, 'debug-resources')}`,
    gradle, '--no-daemon', '--init-script', join(fixture, 'probe.gradle'), ':app:assembleDebug'], nativeFixtureBuildTimeoutMs, project)
  for (const backend of proof.backends as { generated: { file: string, sha256: string } }[]) {
    if ((await identity(backend.generated.file)).sha256 !== backend.generated.sha256) throw new Error('Debug overlay changed a generated native backend')
  }
  const apk = join(project, 'app/build/outputs/apk/debug/app-debug.apk')
  proof.apk = await identity(apk)
  await copyFile(apk, join(evidence, 'app-debug.apk'))
  proof.apkEntries = await run('apk-entries', ['unzip', '-l', apk])
  if (!(proof.apkEntries as string).includes(`lib/${abi}/wrap.sh`) || !(proof.apkEntries as string).includes(`lib/${abi}/libcraft-checkpoint-probe.so`)) throw new Error('Debug wrapper/interposer missing from real APK')
  try { device = await createAndroidEmulator({ sdkRoot: sdk, sdkmanager, avdmanager, image, acceleration: 'hardware', memoryMb: 4096, artifactsDirectory: join(evidence, 'emulator'), port: 5562, bootTimeoutMs: 600000, signal: cancellation.signal }) }
  catch (error) { if (error instanceof AggregateError) proof.emulatorDisposalUnconfirmed = true; throw error }
  cancellation.signal.throwIfAborted()
  const imageDirectory = join(sdk, ...image.split(';'))
  const imageProperties = await readFile(join(imageDirectory, 'source.properties'), 'utf8')
  if (!/^AndroidVersion.ApiLevel=35$/m.test(imageProperties) || !new RegExp(`^SystemImage.Abi=${abi}$`, 'm').test(imageProperties)
    || !/^SystemImage.TagId=google_apis_playstore$/m.test(imageProperties)) throw new Error('Installed image identity differs from the required API35 Play ABI')
  proof.systemImage = { sourceProperties: imageProperties, files: await Promise.all(['source.properties', 'package.xml', 'build.prop', 'system.img', 'vendor.img', 'kernel-ranchu', 'ramdisk.img'].map(file => identity(join(imageDirectory, file)))) }
  proof.sdkTools = await Promise.all([join(sdk, 'emulator/emulator'), join(sdk, 'platform-tools/adb')].map(identity))
  proof.emulatorVersion = await run('emulator-version', emulatorVersionCommand(join(sdk, 'emulator/emulator')))
  proof.adbVersion = await run('adb-version', [device.adb, 'version'])
  proof.compileSdk = await readFile(join(sdk, 'platforms/android-36/source.properties'), 'utf8')
  proof.buildTools = await readFile(join(sdk, 'build-tools/36.0.0/source.properties'), 'utf8')
  if (!/AndroidVersion.ApiLevel=36/.test(proof.compileSdk as string) || !/Pkg.Revision=36\.0\.0/.test(proof.buildTools as string)) throw new Error('Expected compileSdk36 and build-tools36.0.0')
  proof.serial = device.serial
  proof.platformIdentity = await run('platform-identity', adb('shell', 'getprop'))
  if (!/\[ro\.build\.version\.sdk\]: \[35\]/.test(proof.platformIdentity as string)
    || !(proof.platformIdentity as string).includes(`[ro.product.cpu.abi]: [${abi}]`)) throw new Error('Owned guest API or ABI differs from the selected image')
  proof.webviewProvider = await run('webview-provider', adb('shell', 'dumpsys', 'webviewupdate'))
  const provider = (proof.webviewProvider as string).match(/Current WebView package \(name, version\): \(([\w.]+), ([\d.]+)\)/)
  if (!provider) throw new Error('No actual selected native-screen script provider')
  proof.scriptProvider = { package: provider[1], version: provider[2], role: 'JavaScriptSandbox script engine; UI is Android native controls' }
  await run('install-fixture', adb('install', '-t', apk), 30000)
  const { pid: firstPid, xml: empty } = await launch('first', 'Checkpoint absent')
  const firstSession = session(empty)
  const loaded = await run('preload-identity', app('cat', 'files/checkpoint-probe.loaded'))
  if (loaded.trim() !== `pid=${firstPid}`) throw new Error('Preload did not initialize in the actual native app process')
  await click('Save generation 1', 'seed-control')
  await uiContaining('Acknowledgements 1', 'seed-control-ack')
  await arm('pass')
  await click('Save generation 2', 'pass-control')
  await uiContaining('Acknowledgements 1,2', 'pass-control-ack')
  const passRecord = await boundary('pass-control')
  requireBoundary(passRecord, firstPid, 'pass')
  let rejected = false
  try { requireBoundary(passRecord, firstPid, 'hold') } catch { rejected = true }
  if (!rejected) throw new Error('Pass-through negative control satisfied the held boundary unexpectedly')
  await stop('pass-control')
  const { pid: secondPid, xml: passUi } = await launch('pass-control-relaunch', 'Recovered complete generation 2')
  const secondSession = session(passUi)
  if (secondPid === firstPid || secondSession === firstSession) throw new Error('Negative control did not start a new app process')
  proof.negativeControl = { expectedBoundaryRejection: rejected, boundary: passRecord, firstPid, secondPid, firstSession, secondSession, recoveredGeneration: 2 }
  await click('Save generation 1', 'seed-interruption')
  await uiContaining('Acknowledgements 1', 'seed-interruption-ack')
  await arm('hold')
  await click('Save generation 2', 'interrupt')
  const held = await boundary('interruption')
  requireBoundary(held, secondPid, 'hold')
  const staged = await run('staged-generation-2', app('cat', held[3]!))
  const previous = await run('previous-generation-1', app('cat', destination))
  if (staged !== expected(2) || previous !== expected(1)) throw new Error('Complete staged/previous checkpoint bytes do not match the independent expected payloads')
  proof.payloads = { previous: { bytes: Buffer.byteLength(previous), sha256: Bun.SHA256.hash(previous, 'hex') }, staged: { bytes: Buffer.byteLength(staged), sha256: Bun.SHA256.hash(staged, 'hex') } }
  await click('Pulse UI', 'held-pulse')
  const heldUi = await uiContaining('Pulse 1', 'held-responsive')
  if (!heldUi.includes('text="Saving generation 2"') || !heldUi.includes('text="Acknowledgements 1"')) throw new Error('In-flight save acknowledged early or UI became unresponsive')
  await run('held-screenshot', adb('shell', 'screencap', '-p', '/data/local/tmp/checkpoint-probe.png'))
  await run('pull-held-screenshot', adb('pull', '/data/local/tmp/checkpoint-probe.png', join(evidence, 'held.png')))
  proof.interruption = { held, pending: true, publicUiResponsive: true, previousSha256: Bun.SHA256.hash(previous, 'hex'), stagedSha256: Bun.SHA256.hash(staged, 'hex') }
  await stop('interruption')
  const { pid: thirdPid, xml: recoveryUi } = await launch('recovery', 'Recovered complete generation 1')
  await run('recovery-screenshot', adb('shell', 'screencap', '-p', '/data/local/tmp/checkpoint-probe.png'))
  await run('pull-recovery-screenshot', adb('pull', '/data/local/tmp/checkpoint-probe.png', join(evidence, 'recovered.png')))
  const thirdSession = session(recoveryUi)
  if (thirdPid === secondPid || thirdSession === secondSession) throw new Error('Recovery did not start a new app process')
  if (await run('recovered-disk', app('cat', destination)) !== expected(1)) throw new Error('Recovery disk checkpoint differs')
  await click('Save generation 3', 'retry')
  await uiContaining('Acknowledgements 3', 'retry-ack')
  await stop('retry')
  const { pid: fourthPid, xml: retryUi } = await launch('retry-relaunch', 'Recovered complete generation 3')
  const fourthSession = session(retryUi)
  if (fourthPid === thirdPid || fourthSession === thirdSession) throw new Error('Retry recovery did not start a new process')
  proof.recovery = { secondPid, thirdPid, fourthPid, secondSession, thirdSession, fourthSession, recoveredGeneration: 1, retryRecoveredGeneration: 3 }
  proof.status = 'passed'
}
catch (error) { failure = error; proof.status = 'failed'; proof.error = String(error) }
finally {
  if (device) {
    for (const [label, args] of [['final-logcat', ['logcat', '-d', '-b', 'all']], ['final-events', ['logcat', '-d', '-b', 'events']]] as const) {
      try {
        const log = await run(label, adb(...args), 10000, workspace, true)
        if (/\bam_(anr|crash)\b|FATAL EXCEPTION|Fatal signal/.test(log)) throw new Error('Android platform or app fault invalidates checkpoint acceptance')
      } catch (error) { failure ??= error; proof[`${label}Error`] = String(error) }
    }
    try {
      await run('cleanup-stop', adb('shell', 'am', 'force-stop', packageName), 10000, workspace, true)
      await run('cleanup-uninstall', adb('uninstall', packageName), 10000, workspace, true)
      proof.appDisposed = true
    } catch (error) { failure ??= error; proof.appCleanupError = String(error) }
    try { await device.dispose(); await device.closed; proof.emulatorDisposed = true } catch (error) { failure ??= error; proof.emulatorCleanupError = String(error) }
  }
  proof.commandGroupsDisposed = scope.allDisposed
  if (workspace && scope.allDisposed && proof.emulatorDisposalUnconfirmed !== true && (!device || proof.emulatorDisposed === true)) {
    try { await rm(workspace, { recursive: true, force: true }); proof.workspaceDisposed = true }
    catch (error) { failure ??= error; proof.workspaceCleanupError = String(error) }
  } else if (workspace) { proof.workspaceRetained = workspace; failure ??= new Error('Owned process disposal incomplete') }
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.off(signal, abort)
  if (failure || cancellation.signal.aborted) proof.status = 'failed'
  if (failure && !proof.error) proof.error = String(failure)
  proof.finishedAt = new Date().toISOString()
  if (evidence) {
    try {
      proof.artifacts = await Promise.all([...new Bun.Glob('**/*').scanSync({ cwd: evidence, absolute: true, onlyFiles: true })].filter(path => !path.endsWith('/verification.json')).map(identity))
      await save()
      for (const file of [...new Bun.Glob('**/*').scanSync({ cwd: evidence, absolute: true, onlyFiles: true })]) await chmod(file, 0o444)
    } catch (error) { failure ??= error; proof.status = 'failed'; console.error(`Final checkpoint evidence failed: ${error}`) }
  }
}
console.log(JSON.stringify({ status: proof.status, evidence, error: proof.error }))
if (failure) throw failure
if (cancellation.signal.aborted) throw cancellation.signal.reason
