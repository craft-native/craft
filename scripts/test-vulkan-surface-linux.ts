import { cp, copyFile, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { NativeFixtureCommandScope } from '../packages/ios/scripts/native-fixture-command'
import { tempDirPrefix } from '../packages/typescript/src/temp-dir'
import { resolveZig } from './zig'

const { values } = parseArgs({ args: process.argv.slice(2), strict: true, options: { output: { type: 'string' } } })
if (process.platform !== 'linux') throw new Error('Native Vulkan display acceptance requires Linux with X11, XTest and a Vulkan1.1 presentation driver.')
const commandScope = new NativeFixtureCommandScope()
const root = resolve(import.meta.dir, '..')
const source = join(root, 'packages/zig')
const fixture = join(source, 'test/fixtures/vulkan-surface-consumer')
const zig = resolveZig(root)
if (zig.overridden) throw new Error('Native Vulkan acceptance requires the pinned compiler')
// Capture source state before creating the evidence output itself.
const identity = await commandScope.run(['git', '-C', root, 'rev-parse', 'HEAD'], { cwd: root, timeoutMs: 10_000 })
const status = await commandScope.run(['git', '-C', root, 'status', '--porcelain', '--untracked-files=all'], { cwd: root, timeoutMs: 10_000 })
if ([identity, status].some(result => result.code !== 0 || result.timedOut || result.cancelled || !result.groupDisposed)) throw new Error('Cannot establish native fixture source identity')
const output = resolve(values.output ?? join(root, 'artifacts/native-vulkan-linux'))
await mkdir(output, { recursive: true })
const evidence = await mkdtemp(join(output, 'run-'))
const workspace = await realpath(await mkdtemp(join(tmpdir(), tempDirPrefix('vulkan-linux'))))
const interruption = new AbortController()
const onSignal = () => interruption.abort(new Error('Native Vulkan acceptance interrupted'))
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.on(signal, onSignal)
const proof: Record<string, unknown> = { purpose: 'Native Xlib Vulkan displayed scene and GPU readback', source: identity.stdout.trim(), sourceDirty: status.stdout.trim().length > 0, sourceStatus: status.stdout, compiler: zig, startedAt: new Date().toISOString(), commands: [] }
let failure: unknown
async function save(): Promise<void> { await writeFile(join(evidence, 'verification.json'), `${JSON.stringify(proof, null, 2)}\n`) }
async function run(name: string, args: string[], timeoutMs: number): Promise<void> {
  proof.currentStep = name
  await save()
  const logPath = join(evidence, `${name}.log`)
  const result = await commandScope.run(args, { cwd: workspace, timeoutMs, logPath, signal: interruption.signal })
  ;(proof.commands as unknown[]).push({ name, args, timeoutMs, ...result, logPath })
  await save()
  if (result.code !== 0 || result.timedOut || result.cancelled || !result.groupDisposed) throw new Error(`${name} failed (${result.code}); see ${logPath}`)
}
try {
  proof.sourceFiles = Object.fromEntries(await Promise.all(['scripts/test-vulkan-surface-linux.ts', 'packages/zig/src/vulkan_surface.zig', 'packages/zig/src/vulkan_api.zig', 'packages/zig/src/graphics.zig', 'packages/zig/src/graphics_scene.zig', 'packages/zig/test/fixtures/vulkan-surface-consumer/build.zig', 'packages/zig/test/fixtures/vulkan-surface-consumer/build.zig.zon', 'packages/zig/test/fixtures/vulkan-surface-consumer/src/fixture.zig', 'packages/zig/test/fixtures/vulkan-surface-consumer/src/host.cpp'].map(async path => [path, Bun.SHA256.hash(await readFile(join(root, path)), 'hex')])) )
  const manifest = await readFile(join(source, 'build.zig.zon'), 'utf8')
  const paths = [...(manifest.match(/\.paths\s*=\s*\.\{([^}]+)\}/)?.[1] ?? '').matchAll(/"([^"\r\n]+)"/g)].map(match => match[1]!)
  if (!paths.length || paths.some(path => isAbsolute(path) || path.split(/[\\/]/).includes('..'))) throw new Error('Invalid public source package paths')
  // Package exactly the declared files, then consume the archive unchanged.
  // The fixture uses the same public craft module as external applications.
  const archive = join(workspace, 'craft-source.tar.gz')
  await run('archive-public-source', ['tar', '-czf', archive, '-C', source, '--', ...paths], 60_000)
  proof.sourceArchiveSha256 = Bun.SHA256.hash(await readFile(archive), 'hex')
  await mkdir(join(workspace, 'package'))
  await run('extract-public-source', ['tar', '-xzf', archive, '-C', join(workspace, 'package')], 60_000)
  for (const file of ['build.zig', 'build.zig.zon']) await copyFile(join(fixture, file), join(workspace, file))
  await cp(join(fixture, 'src'), join(workspace, 'src'), { recursive: true })
  await run('compile-native-public-consumer', [zig.path, 'build', '-Doptimize=ReleaseSafe', '--summary', 'all'], 300_000)
  const executable = join(workspace, 'zig-out/bin/vulkan-surface-consumer')
  proof.nativeExecutableSha256 = Bun.SHA256.hash(await readFile(executable), 'hex')
  await run('verify-displayed-vulkan-frames', ['sh', join(root, 'scripts/run-linux-with-wm.sh'), executable], 120_000)
  const log = await readFile(join(evidence, 'verify-displayed-vulkan-frames.log'), 'utf8')
  if (/Validation Error|VUID-[a-zA-Z0-9_-]+/.test(log)) throw new Error('Vulkan validation reported an invalid native operation; retain the original native log')
  const record = log.split(/\r?\n/).map(line => { try { return JSON.parse(line) } catch { return null } }).find(value => value?.status === 'passed')
  if (!record || record.nativeSessions !== 2 || record.actualGpuFrames !== 128 || record.nativeInputEvents !== 2 || record.nativeCaptures !== 4 || record.fullDisplayedPixelsMatched !== true || record.webViewUsed !== false || record.disposed !== true) throw new Error('The real native consumer did not complete the full Vulkan acceptance matrix')
  proof.native = record
  const frames: unknown[] = []
  for (const name of ['initial', 'resized', 'resumed', 'input']) {
    const bytes = await readFile(join(workspace, `${name}.ppm`))
    const header = bytes.subarray(0, 64).toString('ascii').match(/^P6\n(\d+) (\d+)\n255\n/)
    const width = name === 'initial' ? 256 : 160, height = name === 'initial' ? 192 : 120
    if (!header || Number(header[1]) !== width || Number(header[2]) !== height || bytes.length !== header[0].length + width * height * 3) throw new Error(`Missing or invalid real native ${name} capture`)
    await copyFile(join(workspace, `${name}.ppm`), join(evidence, `${name}.ppm`))
    frames.push({ name, width, height, bytes: bytes.length, sha256: Bun.SHA256.hash(bytes, 'hex') })
  }
  proof.frames = frames
  proof.status = 'passed'
}
catch (error) { failure = error; proof.status = 'failed'; proof.error = String(error) }
finally {
  if (commandScope.allDisposed) {
    try { await rm(workspace, { recursive: true, force: true }); proof.workspaceDisposed = true }
    catch (error) { failure ??= error; proof.status = 'failed'; proof.workspaceCleanupError = String(error) }
  }
  else { proof.workspaceRetained = workspace; failure ??= new Error('A native command group could not be disposed'); proof.status = 'failed' }
  proof.commandGroupsDisposed = commandScope.allDisposed
  if (interruption.signal.aborted) { failure ??= interruption.signal.reason; proof.status = 'failed'; proof.error = String(failure) }
  proof.finishedAt = new Date().toISOString()
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.off(signal, onSignal)
  await save()
}
console.log(JSON.stringify({ status: proof.status, evidence, commandGroupsDisposed: commandScope.allDisposed }))
if (failure) throw failure
