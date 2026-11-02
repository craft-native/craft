import { createReadStream } from 'node:fs'
import { cp, copyFile, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { NativeFixtureCommandScope } from '../../ios/scripts/native-fixture-command'
import { createAndroidEmulator } from '../src/emulator'
import { resolveZig } from '../../../scripts/zig'
import { nativeVulkanResult } from './vulkan-surface-result'
import { emulatorVersionCommand } from './vulkan-surface-probe'

const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: { output: { type: 'string' }, image: { type: 'string' } } })
if (!['darwin', 'linux'].includes(process.platform)) throw new Error('Android Vulkan acceptance requires a macOS or Linux Android SDK host')
const root = resolve(import.meta.dir, '../../..')
if (!['arm64', 'x64'].includes(process.arch)) throw new Error('Android Vulkan acceptance requires a 64-bit ARM or x86 host')
const abi = process.arch === 'arm64' ? 'arm64-v8a' : 'x86_64'
const image = values.image ?? `system-images;android-35;default;${abi}`
if (!new RegExp(`^system-images;android-(35|36);(default|google_apis);${abi}$`).test(image)) throw new Error('Choose an Android35/36 SDK image matching the native host ABI')
const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT
const ndk = process.env.ANDROID_NDK_HOME
const sdkmanager = Bun.which('sdkmanager'), avdmanager = Bun.which('avdmanager'), gradle = Bun.which('gradle')
if (!sdk || !ndk || !sdkmanager || !avdmanager || !gradle) throw new Error('Install the Android SDK, NDK 27.2.12479018, command-line tools and Gradle 8.11.1; set ANDROID_HOME and ANDROID_NDK_HOME')
const zig = resolveZig(root)
if (zig.overridden) throw new Error('Android Vulkan acceptance requires the pinned compiler')
const scope = new NativeFixtureCommandScope(), interruption = new AbortController()
const onSignal = () => interruption.abort(new Error('Android Vulkan acceptance interrupted'))
const source = join(root, 'packages/zig')
const fixture = join(source, 'test/fixtures/vulkan-surface-consumer')
const output = resolve(values.output ?? join(root, 'artifacts/native-vulkan-android'))
let evidence = '', workspace = '', project = ''
const triple = process.arch === 'arm64' ? 'aarch64-linux-android' : 'x86_64-linux-android'
const prebuilt = join(ndk, 'toolchains/llvm/prebuilt', process.platform === 'darwin' ? 'darwin-x86_64' : 'linux-x86_64')
const sysroot = join(prebuilt, 'sysroot'), lib = join(sysroot, 'usr/lib', triple, '26')
const proof: Record<string, unknown> = { purpose: 'Android ANativeWindow Vulkan displayed scene, lifecycle and GPU readback', compiler: zig, abi, startedAt: new Date().toISOString(), commands: [] }
let emulator: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
let failure: unknown
async function identity(file: string): Promise<{ file: string, bytes: number, sha256: string }> {
  const hash = new Bun.CryptoHasher('sha256')
  for await (const chunk of createReadStream(file)) hash.update(chunk)
  return { file: await realpath(file), bytes: Bun.file(file).size, sha256: hash.digest('hex') }
}
async function save(): Promise<void> { if (!evidence) return; await writeFile(join(evidence, 'verification.json'), `${JSON.stringify(proof, null, 2)}\n`) }
async function run(name: string, args: string[], timeoutMs: number, cwd = workspace): Promise<void> {
  proof.currentStep = name
  await save()
  const logPath = join(evidence, `${name}.log`)
  const result = await scope.run(args, { cwd, timeoutMs, logPath, signal: interruption.signal })
  ;(proof.commands as unknown[]).push({ name, args, timeoutMs, ...result, logPath })
  await save()
  if (result.code !== 0 || result.timedOut || result.cancelled || !result.groupDisposed) throw new Error(`${name} failed (${result.code}); see ${logPath}`)
}
try {
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.on(signal, onSignal)
  await mkdir(output, { recursive: true })
  evidence = await mkdtemp(join(output, 'run-'))
  workspace = await mkdtemp(join(tmpdir(), 'craft-android-vulkan-'))
  workspace = await realpath(workspace)
  project = join(workspace, 'android')
  interruption.signal.throwIfAborted()
  for (const [name, args] of [['source', ['git', '-C', root, 'rev-parse', 'HEAD']], ['source-status', ['git', '-C', root, 'status', '--porcelain', '--untracked-files=all']]] as const) {
    await run(name, [...args], 10000)
    proof[name] = (await readFile(join(evidence, `${name}.log`), 'utf8')).trim()
  }
  proof.sourceFiles = Object.fromEntries(await Promise.all([
    'packages/android/scripts/test-vulkan-surface.ts', 'packages/android/scripts/vulkan-surface-result.ts', 'packages/android/scripts/vulkan-surface-probe.ts',
    'packages/android/src/emulator.ts', 'packages/ios/scripts/native-fixture-command.ts', 'scripts/zig.ts', 'packages/zig/src/vulkan_surface.zig', 'packages/zig/src/vulkan_api.zig',
    'packages/zig/src/graphics.zig', 'packages/zig/src/graphics_scene.zig', 'packages/zig/test/fixtures/vulkan-surface-consumer/src/fixture.zig',
    'packages/zig/test/fixtures/vulkan-surface-consumer/build.zig',
    ...[...new Bun.Glob('**/*').scanSync({ cwd: join(root, 'packages/android/fixtures/vulkan-surface'), onlyFiles: true })].map(path => `packages/android/fixtures/vulkan-surface/${path}`),
  ].map(async path => [path, Bun.SHA256.hash(await readFile(join(root, path)), 'hex')])) )
  const manifest = await readFile(join(source, 'build.zig.zon'), 'utf8')
  const paths = [...(manifest.match(/\.paths\s*=\s*\.\{([^}]+)\}/)?.[1] ?? '').matchAll(/"([^"\r\n]+)"/g)].map(match => match[1]!)
  if (!paths.length || paths.some(path => isAbsolute(path) || path.split(/[\\/]/).includes('..'))) throw new Error('Invalid public source package paths')
  const ndkProperties = await readFile(join(ndk, 'source.properties'), 'utf8')
  const revision = ndkProperties.match(/^Pkg.Revision\s*=\s*(.+)$/m)?.[1]?.trim()
  if (revision !== '27.2.12479018') throw new Error(`Expected Android NDK27.2.12479018, found ${revision}`)
  await run('gradle-toolchain', [gradle, '--version'], 30000)
  const gradleIdentity = await readFile(join(evidence, 'gradle-toolchain.log'), 'utf8')
  if (!/^Gradle 8\.11\.1$/m.test(gradleIdentity)) throw new Error('Android Vulkan acceptance requires Gradle8.11.1')
  proof.androidToolchain = { ndk: await realpath(ndk), ndkRevision: revision, ndkCompiler: await realpath(join(prebuilt, 'bin', `${triple}26-clang`)), gradle: await realpath(gradle), gradleIdentity }
  proof.scope = 'Actual owned Android emulator software-Vulkan presentation; physical GPU/device execution and full native game parity remain separate gates.'
  proof.image = image
  proof.compilerExecutable = await identity(zig.path)
  await run('ndk-compiler-toolchain', [join(prebuilt, 'bin', `${triple}26-clang`), '--version'], 10000)
  const archive = join(workspace, 'craft-source.tar.gz')
  await run('archive-public-source', ['tar', '-czf', archive, '-C', source, '--', ...paths], 60000)
  proof.sourceArchiveSha256 = Bun.SHA256.hash(await readFile(archive), 'hex')
  await copyFile(archive, join(evidence, 'craft-source.tar.gz'))
  await mkdir(join(workspace, 'package'))
  await run('extract-public-source', ['tar', '-xzf', archive, '-C', join(workspace, 'package')], 60000)
  for (const file of ['build.zig', 'build.zig.zon']) await copyFile(join(fixture, file), join(workspace, file))
  await cp(join(fixture, 'src'), join(workspace, 'src'), { recursive: true })
  const libc = join(workspace, 'android-libc.conf')
  await writeFile(libc, `include_dir=${sysroot}/usr/include\nsys_include_dir=${sysroot}/usr/include/${triple}\ncrt_dir=${lib}\nmsvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir=\ngcc_dir=${lib}\n`)
  await run('compile-native-public-consumer', [zig.path, 'build', '-Doptimize=ReleaseSafe', `-Dtarget=${triple}.26`, `-Dandroid-libc=${libc}`, '--summary', 'all'], 300000)
  await cp(join(root, 'packages/android/fixtures/vulkan-surface'), project, { recursive: true })
  const jni = join(project, 'app/src/main/jniLibs', abi)
  await mkdir(jni, { recursive: true })
  const library = join(jni, 'libcraft-vulkan-acceptance.so')
  await run('link-authored-jni-host', [join(prebuilt, 'bin', `${triple}26-clang`), '-shared', '-fPIC', '-std=c11', '-Wl,--no-undefined',
    join(project, 'app/src/main/cpp/host.c'), join(workspace, 'zig-out/lib/libvulkan-surface-fixture.a'), '-landroid', '-llog', '-ldl', '-lm', '-o', library], 60000)
  proof.nativeLibrarySha256 = Bun.SHA256.hash(await readFile(library), 'hex')
  await copyFile(library, join(evidence, 'libcraft-vulkan-acceptance.so'))
  await writeFile(join(project, 'local.properties'), `sdk.dir=${sdk}\n`)
  await run('compile-authored-activity', [gradle, '--no-daemon', ':app:assembleDebug', ':app:assembleDebugAndroidTest'], 300000, project)
  proof.apks = await Promise.all([
    ['activity', 'app/build/outputs/apk/debug/app-debug.apk'],
    ['instrumentation', 'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'],
  ].map(async ([name, path]) => { const file = join(project, path!); const bytes = await readFile(file); await copyFile(file, join(evidence, `${name}.apk`)); return { name, bytes: bytes.length, sha256: Bun.SHA256.hash(bytes, 'hex') } }))
  emulator = await createAndroidEmulator({ sdkRoot: sdk, sdkmanager, avdmanager, image, acceleration: 'hardware', acceptLicenses: true, artifactsDirectory: join(evidence, 'emulator'), port: 5560, signal: interruption.signal })
  interruption.signal.throwIfAborted()
  const imageDirectory = join(sdk, ...image.split(';'))
  proof.systemImage = { sourceProperties: await readFile(join(imageDirectory, 'source.properties'), 'utf8'), files: await Promise.all(['source.properties', 'package.xml', 'system.img', 'vendor.img', 'kernel-ranchu', 'ramdisk.img'].map(file => identity(join(imageDirectory, file)))) }
  for (const file of ['source.properties', 'package.xml']) await copyFile(join(imageDirectory, file), join(evidence, `system-image-${file}`))
  await run('emulator-toolchain', emulatorVersionCommand(join(sdk, 'emulator/emulator')), 10000)
  const adb = [emulator.adb, '-s', emulator.serial]
  await run('platform-identity', [...adb, 'shell', 'getprop'], 30000)
  await run('driver-capabilities', [...adb, 'shell', 'cmd', 'gpu', 'vkjson'], 30000)
  await run('actual-native-android-display', ['env', ...Object.entries(emulator.env).filter(([key, value]) => ['ANDROID_HOME', 'ANDROID_SDK_ROOT', 'ANDROID_USER_HOME', 'ANDROID_AVD_HOME', 'ANDROID_SERIAL'].includes(key) && value).map(([key, value]) => `${key}=${value}`), gradle, '--no-daemon', ':app:connectedDebugAndroidTest'], 180000, project)
  const reports = [...new Bun.Glob('app/build/outputs/androidTest-results/connected/**/TEST-*.xml').scanSync({ cwd: project, absolute: true })]
  const xml = (await Promise.all(reports.map(path => readFile(path, 'utf8')))).join('\n')
  if ((xml.match(/<testcase\b/g) ?? []).length !== 1 || /<(?:failure|error|skipped)\b/.test(xml)) throw new Error('The required Android Vulkan native test did not pass exactly once without skips')
  await cp(join(project, 'app/build/outputs/androidTest-results'), join(evidence, 'androidTest-results'), { recursive: true })
  const nativeReports = [...new Bun.Glob('app/build/outputs/connected_android_test_additional_output/**/vulkan-surface/verification.json').scanSync({ cwd: project, absolute: true })]
  if (nativeReports.length !== 1) throw new Error('Expected exactly one original native Vulkan result directory from Gradle')
  await cp(resolve(nativeReports[0]!, '..'), join(evidence, 'native'), { recursive: true })
  const native = nativeVulkanResult(JSON.parse(await readFile(join(evidence, 'native/verification.json'), 'utf8')))
  proof.native = native
  proof.frames = await Promise.all(['initial', 'shifted', 'resized', 'resumed', 'input'].map(async name => { const bytes = await readFile(join(evidence, 'native', `${name}.png`)); return { name, bytes: bytes.length, sha256: Bun.SHA256.hash(bytes, 'hex') } }))
  proof.status = 'passed'
}
catch (error) {
  failure = error; proof.status = 'failed'; proof.error = String(error)
  // Preserve original platform/test failures before disposing the owned guest.
  if (emulator) {
    for (const [name, args] of [
      ['failure-logcat', ['logcat', '-d', '-b', 'all']],
      ['failure-platform-events', ['logcat', '-b', 'events', '-d', '-v', 'threadtime']],
    ] as const) {
      try { await run(name, [emulator.adb, '-s', emulator.serial, ...args], 10000) }
      catch (diagnostic) { proof[`${name}-error`] = String(diagnostic) }
    }
  }
  if (project) try { await cp(join(project, 'app/build/outputs/connected_android_test_additional_output'), join(evidence, 'failed-native'), { recursive: true }) }
  catch { /* A setup failure can precede native capture output. */ }
  if (project) try { await cp(join(project, 'app/build/outputs/androidTest-results'), join(evidence, 'failed-androidTest-results'), { recursive: true }) }
  catch { /* Compilation can fail before any instrumentation result exists. */ }
}
finally {
  if (emulator) {
    try { await emulator.dispose(); proof.emulatorDisposed = true }
    catch (error) { failure ??= error; proof.status = 'failed'; proof.emulatorDisposalError = String(error) }
  }
  if (workspace && scope.allDisposed && (!emulator || proof.emulatorDisposed === true)) {
    try { await rm(workspace, { recursive: true, force: true }); proof.workspaceDisposed = true }
    catch (error) { failure ??= error; proof.status = 'failed'; proof.workspaceCleanupError = String(error) }
  } else if (workspace) { proof.workspaceRetained = workspace; failure ??= new Error('Owned native processes could not all be disposed'); proof.status = 'failed' }
  proof.commandGroupsDisposed = scope.allDisposed
  if (interruption.signal.aborted) { failure ??= interruption.signal.reason; proof.status = 'failed' }
  proof.finishedAt = new Date().toISOString()
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.off(signal, onSignal)
  await save()
}
console.log(JSON.stringify({ status: proof.status, evidence, commandGroupsDisposed: scope.allDisposed }))
if (failure) throw failure
