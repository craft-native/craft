import { copyFile, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve, win32 } from 'node:path'
import type { NativeWindowsCommandResult } from './windows-command'

export const windowsVulkanDriverSources = {
  headers: { url: 'https://github.com/KhronosGroup/Vulkan-Headers.git', commit: '6802bb4733b63ed5efd3adb308a6c885ef180ea1' },
  loader: { url: 'https://github.com/KhronosGroup/Vulkan-Loader.git', commit: 'fa218055ff4948b159f31d43f800c808a13d51df' },
  swiftshader: { url: 'https://github.com/google/swiftshader.git', commit: 'cddb5c91b23ff70a1f607ea31610aa0d7f4b5ad5' },
} as const

type Run = (name: string, args: string[], timeoutMs: number, captureOutput?: boolean) => Promise<NativeWindowsCommandResult>

export const windowsVulkanDriverRegistryKey = 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Khronos\\Vulkan\\Drivers'

/** The pinned loader reports every actual vkCreateDevice driver, including elevated discovery. */
export function verifyWindowsVulkanDriverSelection(log: string, expectedDriver: string): { name: string, driver: string }[] {
  if (!win32.isAbsolute(expectedDriver)) throw new Error('Expected an absolute original Windows Vulkan driver')
  const devices = [...log.matchAll(/Using "([^"]+)" with driver: "([^"]+)"/g)].map(match => ({ name: match[1]!, driver: match[2]! }))
  if (devices.length < 2 || devices.some(device => win32.normalize(device.driver).toLowerCase() !== win32.normalize(expectedDriver).toLowerCase()))
    throw new Error('Both native sessions must use the original source-built software Vulkan driver')
  return devices
}

/** Match the installed C++ toolchain to a generator this CMake actually supports. */
export function visualStudioGenerator(capabilities: unknown, instances: unknown): { args: string[], installationVersion: string } {
  const available = capabilities as { generators?: { name?: string, platformSupport?: boolean }[] }
  const installed = instances as { installationPath?: string, installationVersion?: string }[]
  if (!Array.isArray(available?.generators) || !Array.isArray(installed) || installed.length !== 1)
    throw new Error('CMake capabilities and one installed Visual Studio C++ instance are required')
  const instance = installed[0]!
  if (typeof instance.installationPath !== 'string' || !win32.isAbsolute(instance.installationPath)
    || typeof instance.installationVersion !== 'string' || !/^\d+\.\d/.test(instance.installationVersion))
    throw new Error('Visual Studio discovery returned an invalid native C++ installation')
  const major = instance.installationVersion.split('.')[0]
  const generator = available.generators.find(value => value.platformSupport === true && value.name?.startsWith(`Visual Studio ${major} `))
  if (!generator?.name) throw new Error(`CMake does not support the installed Visual Studio ${major} toolchain`)
  return { args: ['-G', generator.name, '-A', 'x64', '-T', 'host=x64', `-DCMAKE_GENERATOR_INSTANCE=${instance.installationPath}`], installationVersion: instance.installationVersion }
}

/** Everything a source-built driver depends on. A cached build is reused only for an identical one. */
export interface WindowsVulkanDriverIdentity {
  sources: typeof windowsVulkanDriverSources
  script: string
  cmake: string
  visualStudio: string
  generator: string[]
}

interface CachedDriverFile { relative: string, bytes: number, sha256: string }

function insideRelative(path: string): boolean {
  return path.length > 0 && !isAbsolute(path) && !win32.isAbsolute(path) && !path.split(/[\\/]/).includes('..')
}

/**
 * Copy the loader, ICD manifest and driver that an identical earlier run built
 * from the pinned sources back to their places under `root`, byte for byte.
 * Null when the cache holds no complete, matching and intact build.
 */
export async function restoreWindowsVulkanDriver(cache: string, identity: WindowsVulkanDriverIdentity, root: string): Promise<{ builtAt: string } | null> {
  let record: { identity?: unknown, builtAt?: unknown, files?: unknown }
  try { record = JSON.parse(await readFile(join(cache, 'driver.json'), 'utf8')) }
  catch { return null }
  if (JSON.stringify(record.identity) !== JSON.stringify(identity) || typeof record.builtAt !== 'string' || !Array.isArray(record.files) || record.files.length !== 3) return null
  const files = record.files as CachedDriverFile[]
  const contents: Buffer[] = []
  for (const file of files) {
    if (typeof file?.relative !== 'string' || !insideRelative(file.relative) || !Number.isSafeInteger(file.bytes) || typeof file.sha256 !== 'string') return null
    let bytes: Buffer
    try { bytes = await readFile(join(cache, 'files', file.relative)) }
    catch { return null }
    if (bytes.length !== file.bytes || Bun.SHA256.hash(bytes, 'hex') !== file.sha256) return null
    contents.push(bytes)
  }
  for (const [index, file] of files.entries()) {
    const target = join(root, file.relative)
    await mkdir(dirname(target), { recursive: true })
    await writeFile(target, contents[index]!, { flag: 'wx' })
  }
  return { builtAt: record.builtAt }
}

/** Keep a verified build for the next run with the same identity; the record is written last. */
export async function storeWindowsVulkanDriver(cache: string, identity: WindowsVulkanDriverIdentity, root: string, files: { path: string, bytes: number, sha256: string }[]): Promise<void> {
  const entries = files.map(file => ({ relative: relative(root, file.path), bytes: file.bytes, sha256: file.sha256 }))
  if (entries.length !== 3 || entries.some(entry => !insideRelative(entry.relative))) throw new Error('Only the owned driver build can be cached')
  await rm(cache, { recursive: true, force: true })
  for (const [index, entry] of entries.entries()) {
    const target = join(cache, 'files', entry.relative)
    await mkdir(dirname(target), { recursive: true })
    await copyFile(files[index]!.path, target)
  }
  await writeFile(join(cache, 'driver.json'), `${JSON.stringify({ identity, builtAt: new Date().toISOString(), files: entries }, null, 2)}\n`)
}

/**
 * Build the pinned loader and SwiftShader ICD, or, with `cache`, reuse the
 * output of an earlier build with the same identity. A cold SwiftShader build
 * compiles its LLVM backend and has run to within a minute or two of its
 * 30-minute command budget on hosted runners (0.0.406 timed out there, and
 * 0.0.402 timed out checking out the sources), so CI keeps the result.
 */
export async function buildWindowsVulkanDriver(workspace: string, run: Run, cache?: string) {
  if (process.platform !== 'win32') throw new Error('The native Windows Vulkan test driver must be built on Windows')
  const root = join(workspace, 'native-vulkan-dependencies')
  await mkdir(root)
  const cmake = Bun.which('cmake'), git = Bun.which('git')
  if (!cmake || !git) throw new Error('The Windows native fixture requires CMake, Git and Visual Studio C++ build tools')
  const cmakeIdentity = await run('cmake-identity', [cmake, '--version'], 10_000, true)
  const gitIdentity = await run('git-identity', [git, '--version'], 10_000, true)
  const programFiles = process.env['ProgramFiles(x86)']
  if (!programFiles) throw new Error('Windows must declare its Visual Studio installer directory')
  const vswhere = join(programFiles, 'Microsoft Visual Studio', 'Installer', 'vswhere.exe')
  const capabilities = await run('cmake-capabilities', [cmake, '-E', 'capabilities'], 10_000, true)
  // vswhere enumerates every installed product; on a cold hosted runner that
  // outlasted 10 s twice in a row (exit 124) before any Vulkan code ran. It
  // only reads, so a generous bound costs nothing when it is quick.
  const instances = await run('visual-studio-identity', [vswhere, '-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-format', 'json', '-utf8'], 120_000, true)
  const visualStudio = visualStudioGenerator(JSON.parse(capabilities.stdout), JSON.parse(instances.stdout.replace(/^\uFEFF/, '')))
  if (cache !== undefined && !isAbsolute(cache)) throw new Error('The Windows Vulkan driver cache must be an absolute directory')
  const identity: WindowsVulkanDriverIdentity = {
    sources: windowsVulkanDriverSources,
    script: Bun.SHA256.hash(await readFile(import.meta.path), 'hex'),
    cmake: cmakeIdentity.stdout.trim(),
    visualStudio: visualStudio.installationVersion,
    generator: visualStudio.args,
  }
  const restored = cache ? await restoreWindowsVulkanDriver(cache, identity, root) : null
  const headersBuild = join(root, 'headers-build'), headersInstall = join(root, 'headers-install')
  const loaderBuild = join(root, 'loader-build'), loaderInstall = join(root, 'loader-install')
  const swiftshaderBuild = join(root, 'swiftshader-build')
  if (!restored) {
    for (const [name, source] of Object.entries(windowsVulkanDriverSources)) {
      const path = join(root, name)
      await run(`${name}-init`, [git, 'init', path], 10_000)
      await run(`${name}-remote`, [git, '-C', path, 'remote', 'add', 'origin', source.url], 10_000)
      await run(`${name}-fetch`, [git, '-C', path, 'fetch', '--depth', '1', 'origin', source.commit], 300_000)
      // Checkout writes the whole tree (SwiftShader vendors LLVM) to a cold,
      // scanned Windows disk: 0.0.402 ran out of a 60 s budget here.
      await run(`${name}-checkout`, [git, '-C', path, 'checkout', '--detach', 'FETCH_HEAD'], 300_000)
      const actual = await run(`${name}-identity`, [git, '-C', path, 'rev-parse', 'HEAD'], 10_000, true)
      if (actual.stdout.trim() !== source.commit) throw new Error(`Native Vulkan ${name} source identity changed`)
    }
    const generator = visualStudio.args
    await run('configure-vulkan-headers', [cmake, '-S', join(root, 'headers'), '-B', headersBuild, ...generator, `-DCMAKE_INSTALL_PREFIX=${headersInstall}`], 60_000)
    await run('install-vulkan-headers', [cmake, '--install', headersBuild, '--config', 'Release'], 60_000)
    // Build the upstream loader and CPU ICD unchanged. No renamed ICD pretending
    // to be a loader, downloaded browser runtime, or display fallback is supplied.
    await run('configure-vulkan-loader', [cmake, '-S', join(root, 'loader'), '-B', loaderBuild, ...generator, `-DVULKAN_HEADERS_INSTALL_DIR=${headersInstall}`, `-DCMAKE_INSTALL_PREFIX=${loaderInstall}`], 60_000)
    await run('build-vulkan-loader', [cmake, '--build', loaderBuild, '--config', 'Release', '--target', 'vulkan', '--parallel', '2'], 300_000)
    await run('install-vulkan-loader', [cmake, '--install', loaderBuild, '--config', 'Release'], 60_000)
    await run('configure-swiftshader', [cmake, '-S', join(root, 'swiftshader'), '-B', swiftshaderBuild, ...generator, '-DSWIFTSHADER_BUILD_TESTS=OFF'], 120_000)
    // A cold MSVC build also compiles SwiftShader's LLVM backend. Keep compilation
    // separate from rendering deadlines; the pinned build is still required in full.
    await run('build-swiftshader', [cmake, '--build', swiftshaderBuild, '--config', 'Release', '--target', 'vk_swiftshader', '--parallel', '2'], 1_800_000)
  }
  const loader = join(loaderInstall, 'bin', 'vulkan-1.dll')
  const manifest = join(swiftshaderBuild, 'Windows', 'vk_swiftshader_icd.json')
  const record = JSON.parse(await readFile(manifest, 'utf8')) as { file_format_version?: string, ICD?: { library_path?: string } }
  if (record.file_format_version !== '1.0.0' || typeof record.ICD?.library_path !== 'string' || isAbsolute(record.ICD.library_path)) throw new Error('Unexpected original SwiftShader ICD manifest')
  const driver = await realpath(resolve(dirname(manifest), record.ICD.library_path))
  const inside = relative(await realpath(swiftshaderBuild), driver)
  if (isAbsolute(inside) || inside.startsWith('..')) throw new Error('The original ICD manifest points outside its owned build')
  const files = []
  for (const path of [loader, manifest, driver]) {
    const bytes = await readFile(path)
    if (path.endsWith('.dll')) {
      if (bytes.length < 64 || bytes.length > 128 * 1024 * 1024 || bytes.readUInt16LE(0) !== 0x5a4d) throw new Error('Invalid native Vulkan PE binary')
      const offset = bytes.readUInt32LE(60)
      if (offset > bytes.length - 24 || bytes.readUInt32LE(offset) !== 0x00004550 || bytes.readUInt16LE(offset + 4) !== 0x8664) throw new Error('Native Vulkan test dependency is not an x64 Windows PE')
    }
    files.push({ path, bytes: bytes.length, sha256: Bun.SHA256.hash(bytes, 'hex') })
  }
  if (cache && !restored) await storeWindowsVulkanDriver(cache, identity, root, files)
  return { loader, manifest, driver, files, cache: cache ? { directory: cache, restored: restored !== null, builtAt: restored?.builtAt ?? null } : null, sources: windowsVulkanDriverSources, cmake: { path: cmake, version: cmakeIdentity.stdout.trim() }, visualStudio, git: { path: git, version: gitIdentity.stdout.trim() }, softwareVulkanDriver: true }
}
