import { mkdir, readFile, realpath } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve } from 'node:path'
import type { NativeWindowsCommandResult } from './windows-command'

export const windowsVulkanDriverSources = {
  headers: { url: 'https://github.com/KhronosGroup/Vulkan-Headers.git', commit: '6802bb4733b63ed5efd3adb308a6c885ef180ea1' },
  loader: { url: 'https://github.com/KhronosGroup/Vulkan-Loader.git', commit: 'fa218055ff4948b159f31d43f800c808a13d51df' },
  swiftshader: { url: 'https://github.com/google/swiftshader.git', commit: 'cddb5c91b23ff70a1f607ea31610aa0d7f4b5ad5' },
} as const

type Run = (name: string, args: string[], timeoutMs: number, captureOutput?: boolean) => Promise<NativeWindowsCommandResult>
export async function buildWindowsVulkanDriver(workspace: string, run: Run) {
  if (process.platform !== 'win32') throw new Error('The native Windows Vulkan test driver must be built on Windows')
  const root = join(workspace, 'native-vulkan-dependencies')
  await mkdir(root)
  const cmake = Bun.which('cmake'), git = Bun.which('git')
  if (!cmake || !git) throw new Error('The Windows native fixture requires CMake, Git and Visual Studio C++ build tools')
  const cmakeIdentity = await run('cmake-identity', [cmake, '--version'], 10_000, true)
  const gitIdentity = await run('git-identity', [git, '--version'], 10_000, true)
  for (const [name, source] of Object.entries(windowsVulkanDriverSources)) {
    const path = join(root, name)
    await run(`${name}-init`, [git, 'init', path], 10_000)
    await run(`${name}-remote`, [git, '-C', path, 'remote', 'add', 'origin', source.url], 10_000)
    await run(`${name}-fetch`, [git, '-C', path, 'fetch', '--depth', '1', 'origin', source.commit], 300_000)
    await run(`${name}-checkout`, [git, '-C', path, 'checkout', '--detach', 'FETCH_HEAD'], 60_000)
    const actual = await run(`${name}-identity`, [git, '-C', path, 'rev-parse', 'HEAD'], 10_000, true)
    if (actual.stdout.trim() !== source.commit) throw new Error(`Native Vulkan ${name} source identity changed`)
  }
  const headersBuild = join(root, 'headers-build'), headersInstall = join(root, 'headers-install')
  const loaderBuild = join(root, 'loader-build'), loaderInstall = join(root, 'loader-install')
  const swiftshaderBuild = join(root, 'swiftshader-build')
  const generator = ['-G', 'Visual Studio 17 2022', '-A', 'x64']
  await run('configure-vulkan-headers', [cmake, '-S', join(root, 'headers'), '-B', headersBuild, ...generator, `-DCMAKE_INSTALL_PREFIX=${headersInstall}`], 60_000)
  await run('install-vulkan-headers', [cmake, '--install', headersBuild, '--config', 'Release'], 60_000)
  // Build the upstream loader and CPU ICD unchanged. No renamed ICD pretending
  // to be a loader, downloaded browser runtime, or display fallback is supplied.
  await run('configure-vulkan-loader', [cmake, '-S', join(root, 'loader'), '-B', loaderBuild, ...generator, `-DVULKAN_HEADERS_INSTALL_DIR=${headersInstall}`, `-DCMAKE_INSTALL_PREFIX=${loaderInstall}`], 60_000)
  await run('build-vulkan-loader', [cmake, '--build', loaderBuild, '--config', 'Release', '--target', 'vulkan', '--parallel', '2'], 300_000)
  await run('install-vulkan-loader', [cmake, '--install', loaderBuild, '--config', 'Release'], 60_000)
  await run('configure-swiftshader', [cmake, '-S', join(root, 'swiftshader'), '-B', swiftshaderBuild, ...generator, '-DSWIFTSHADER_BUILD_TESTS=OFF'], 120_000)
  await run('build-swiftshader', [cmake, '--build', swiftshaderBuild, '--config', 'Release', '--target', 'vk_swiftshader', '--parallel', '2'], 1_200_000)
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
  return { loader, manifest, driver, files, sources: windowsVulkanDriverSources, cmake: { path: cmake, version: cmakeIdentity.stdout.trim() }, git: { path: git, version: gitIdentity.stdout.trim() }, softwareVulkanDriver: true }
}
