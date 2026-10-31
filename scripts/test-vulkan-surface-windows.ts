import { cp, copyFile, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { nativeWindowsCommand } from './native/windows-command'
import { buildWindowsVulkanDriver, verifyWindowsVulkanDriverSelection, windowsVulkanDriverRegistryKey } from './native/windows-vulkan-driver'
import { tempDirPrefix } from '../packages/typescript/src/temp-dir'
import { resolveZig } from './zig'

const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: { owner: { type: 'string' }, output: { type: 'string' } } })
if (process.platform !== 'win32' || process.arch !== 'x64' || !values.owner || !isAbsolute(values.owner)) throw new Error('Native Win32 Vulkan acceptance requires Windows x64 and the absolute first-party --owner executable')
const root = resolve(import.meta.dir, '..')
const source = join(root, 'packages/zig'), fixture = join(source, 'test/fixtures/vulkan-surface-consumer')
const zig = resolveZig(root)
if (zig.overridden) throw new Error('Native Win32 Vulkan acceptance requires the pinned compiler')
const owner = await realpath(values.owner)
const identity = await nativeWindowsCommand(owner, ['git', '-C', root, 'rev-parse', 'HEAD'], { cwd: root, timeoutMs: 10_000 })
const status = await nativeWindowsCommand(owner, ['git', '-C', root, 'status', '--porcelain', '--untracked-files=all'], { cwd: root, timeoutMs: 10_000 })
if ([identity, status].some(result => result.code !== 0 || result.timedOut || result.cancelled || !result.jobDisposed)) throw new Error('Cannot establish native Win32 source identity')
const output = resolve(values.output ?? join(root, 'artifacts/native-vulkan-windows'))
await mkdir(output, { recursive: true })
const evidence = await mkdtemp(join(output, 'run-'))
const workspace = await realpath(await mkdtemp(join(tmpdir(), tempDirPrefix('vulkan-win32'))))
const interruption = new AbortController()
const onSignal = () => interruption.abort(new Error('Native Win32 Vulkan acceptance interrupted'))
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, onSignal)
const proof: Record<string, unknown> = {
  purpose: 'Native Win32 Vulkan presentation and actual desktop capture', source: identity.stdout.trim(), sourceDirty: status.stdout.trim().length > 0, sourceStatus: status.stdout,
  compiler: zig, commandOwner: { path: owner, sha256: Bun.SHA256.hash(await readFile(owner), 'hex') }, startedAt: new Date().toISOString(), commands: [],
}
let failure: unknown, disposed = true
let registration: { executable: string, manifest: string, key: string, registered: boolean, disposed: boolean } | undefined
async function save(): Promise<void> { await writeFile(join(evidence, 'verification.json'), `${JSON.stringify(proof, null, 2)}\n`) }
async function run(name: string, args: string[], timeoutMs: number, captureOutput = false, env?: NodeJS.ProcessEnv, cleanup = false) {
  proof.currentStep = name
  await save()
  const logPath = join(evidence, `${name}.log`), earlierDisposed = disposed
  disposed = false
  const result = await nativeWindowsCommand(owner, args, { cwd: workspace, timeoutMs, logPath: captureOutput ? undefined : logPath, signal: cleanup ? undefined : interruption.signal, env })
  disposed = earlierDisposed && result.jobDisposed
  if (captureOutput) await writeFile(logPath, result.stdout + result.stderr, { flag: 'wx', mode: 0o600 })
  ;(proof.commands as unknown[]).push({ name, args, timeoutMs, code: result.code, processId: result.processId, timedOut: result.timedOut, cancelled: result.cancelled, jobDisposed: result.jobDisposed, osError: result.osError, logPath })
  await save()
  if (result.code !== 0 || result.timedOut || result.cancelled || !result.jobDisposed) throw new Error(`${name} failed (${result.code}); see ${logPath}`)
  return result
}
try {
  proof.sourceFiles = Object.fromEntries(await Promise.all([
    'scripts/test-vulkan-surface-windows.ts', 'scripts/native/windows-command-owner.c', 'scripts/native/windows-command.ts', 'scripts/native/windows-vulkan-driver.ts',
    'packages/zig/src/vulkan_surface.zig', 'packages/zig/src/vulkan_api.zig', 'packages/zig/src/graphics.zig', 'packages/zig/src/graphics_scene.zig',
    'packages/zig/test/fixtures/vulkan-surface-consumer/build.zig', 'packages/zig/test/fixtures/vulkan-surface-consumer/build.zig.zon',
    'packages/zig/test/fixtures/vulkan-surface-consumer/src/fixture.zig', 'packages/zig/test/fixtures/vulkan-surface-consumer/src/host-win32.cpp',
  ].map(async path => [path, Bun.SHA256.hash(await readFile(join(root, path)), 'hex')])) )
  const manifest = await readFile(join(source, 'build.zig.zon'), 'utf8')
  const paths = [...(manifest.match(/\.paths\s*=\s*\.\{([^}]+)\}/)?.[1] ?? '').matchAll(/"([^"\r\n]+)"/g)].map(match => match[1]!)
  if (!paths.length || paths.some(path => isAbsolute(path) || path.split(/[\\/]/).includes('..'))) throw new Error('Invalid public Craft source package paths')
  const system = process.env.SystemRoot ?? process.env.SYSTEMROOT
  if (!system) throw new Error('Windows must declare its native system directory')
  const archive = join(workspace, 'craft-source.tar.gz'), tar = join(system, 'System32/tar.exe')
  await run('archive-public-source', [tar, '-czf', archive, '-C', source, '--', ...paths], 60_000)
  proof.sourceArchiveSha256 = Bun.SHA256.hash(await readFile(archive), 'hex')
  await mkdir(join(workspace, 'package'))
  await run('extract-public-source', [tar, '-xzf', archive, '-C', join(workspace, 'package')], 60_000)
  for (const file of ['build.zig', 'build.zig.zon']) await copyFile(join(fixture, file), join(workspace, file))
  await cp(join(fixture, 'src'), join(workspace, 'src'), { recursive: true })
  await run('compile-native-public-consumer', [zig.path, 'build', '-Doptimize=ReleaseSafe', '--summary', 'all', '--verbose'], 300_000)
  const executable = join(workspace, 'zig-out/bin/vulkan-surface-consumer.exe')
  proof.nativeExecutableSha256 = Bun.SHA256.hash(await readFile(executable), 'hex')
  // CI restores the driver an identical earlier run built from the same pinned
  // sources and toolchain; without it the cold build runs here in full.
  const driverCache = process.env.CRAFT_WINDOWS_VULKAN_DRIVER_CACHE || undefined
  const driver = await buildWindowsVulkanDriver(workspace, run, driverCache)
  proof.testDriver = driver
  // The normal Vulkan loader is bundled beside this owned test executable.
  // Elevated Windows loaders ignore driver-path environment overrides. Install
  // this owned original ICD through normal 64-bit driver registration instead.
  // This verifies software Vulkan, without making a hardware-GPU claim.
  const bundledLoader = join(dirname(executable), 'vulkan-1.dll')
  await copyFile(driver.loader, bundledLoader)
  if (Bun.SHA256.hash(await readFile(bundledLoader), 'hex') !== Bun.SHA256.hash(await readFile(driver.loader), 'hex')) throw new Error('Bundled original Vulkan loader bytes changed')
  registration = { executable: join(system, 'System32/reg.exe'), manifest: driver.manifest, key: windowsVulkanDriverRegistryKey, registered: false, disposed: false }
  proof.driverRegistration = registration
  await run('register-original-vulkan-driver', [registration.executable, 'add', registration.key, '/v', registration.manifest, '/t', 'REG_DWORD', '/d', '0', '/reg:64'], 10_000)
  registration.registered = true
  const nativeEnvironment: NodeJS.ProcessEnv = { ...process.env, VK_LOADER_DEBUG: 'error,warn,driver' }
  for (const name of ['VK_DRIVER_FILES', 'VK_ICD_FILENAMES', 'VK_ADD_DRIVER_FILES', 'VK_LOADER_DRIVERS_SELECT', 'VK_LOADER_DRIVERS_DISABLE']) delete nativeEnvironment[name]
  await run('verify-displayed-vulkan-frames', [executable], 120_000, false, nativeEnvironment)
  const log = await readFile(join(evidence, 'verify-displayed-vulkan-frames.log'), 'utf8')
  const record = log.split(/\r?\n/).map(line => { try { return JSON.parse(line) } catch { return null } }).find(value => value?.status === 'passed')
  if (!record || record.nativeSessions !== 2 || record.actualGpuFrames !== 128 || record.nativeInputEvents !== 2 || record.nativeCaptures !== 4 || record.fullDisplayedPixelsMatched !== true || record.webViewUsed !== false || record.disposed !== true) throw new Error('The native Win32 consumer did not complete its full acceptance matrix')
  proof.native = record
  proof.selectedDevices = verifyWindowsVulkanDriverSelection(log, driver.driver)
  const frames: unknown[] = []
  for (const name of ['initial', 'resized', 'resumed', 'input']) {
    const bytes = await readFile(join(workspace, `${name}.ppm`))
    const header = bytes.subarray(0, 64).toString('ascii').match(/^P6\n(\d+) (\d+)\n255\n/)
    const width = name === 'initial' ? 256 : 160, height = name === 'initial' ? 192 : 120
    if (!header || Number(header[1]) !== width || Number(header[2]) !== height || bytes.length !== header[0].length + width * height * 3) throw new Error(`Missing real native ${name} capture`)
    await copyFile(join(workspace, `${name}.ppm`), join(evidence, `${name}.ppm`))
    frames.push({ name, width, height, bytes: bytes.length, sha256: Bun.SHA256.hash(bytes, 'hex') })
  }
  proof.frames = frames
  proof.status = 'passed'
}
catch (error) { failure = error; proof.status = 'failed'; proof.error = String(error) }
finally {
  if (registration) {
    const previousStep = proof.currentStep
    try {
      await run('unregister-original-vulkan-driver', [registration.executable, 'delete', registration.key, '/v', registration.manifest, '/f', '/reg:64'], 10_000, false, undefined, true)
      registration.disposed = true
    }
    catch (error) { failure ??= error; proof.status = 'failed'; proof.registryCleanupError = String(error) }
    proof.currentStep = previousStep
  }
  if (disposed && (!registration || registration.disposed)) {
    try { await rm(workspace, { recursive: true, force: true }); proof.workspaceDisposed = true }
    catch (error) { failure ??= error; proof.status = 'failed'; proof.workspaceCleanupError = String(error) }
  }
  else { proof.workspaceRetained = workspace; failure ??= new Error('A native Windows job or driver registration did not acknowledge disposal'); proof.status = 'failed' }
  proof.commandJobsDisposed = disposed
  if (interruption.signal.aborted) { failure ??= interruption.signal.reason; proof.status = 'failed'; proof.error = String(failure) }
  proof.finishedAt = new Date().toISOString()
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.off(signal, onSignal)
  await save()
}
console.log(JSON.stringify({ status: proof.status, evidence, commandJobsDisposed: disposed }))
if (failure) throw failure
