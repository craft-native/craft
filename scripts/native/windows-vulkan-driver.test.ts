import { afterAll, expect, test } from 'bun:test'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { WindowsVulkanDriverIdentity } from './windows-vulkan-driver'
import { restoreWindowsVulkanDriver, storeWindowsVulkanDriver, verifyWindowsVulkanDriverSelection, visualStudioGenerator, windowsVulkanDriverSources } from './windows-vulkan-driver'
import { createTempDir, removeAllTempDirs } from '../../packages/typescript/src/temp-dir'

afterAll(removeAllTempDirs)

const capabilities = { generators: [
  { name: 'Visual Studio 17 2022', platformSupport: true },
  { name: 'Visual Studio 18 2026', platformSupport: true },
] }

test('native device evidence identifies the actual driver for both sessions', () => {
  const original = 'C:\\owned\\Windows\\vk_swiftshader.dll'
  const line = (driver: string) => `[Vulkan Loader] DRIVER: Using "SwiftShader Device" with driver: "${driver}"\r\n`
  expect(verifyWindowsVulkanDriverSelection(line(original) + line('c:\\owned\\Windows\\.\\vk_swiftshader.dll'), original)).toHaveLength(2)
  expect(() => verifyWindowsVulkanDriverSelection('Found no registry files', original)).toThrow('Both native sessions')
  expect(() => verifyWindowsVulkanDriverSelection(line(original), original)).toThrow('Both native sessions')
  expect(() => verifyWindowsVulkanDriverSelection(line(original) + line('C:\\other\\driver.dll'), original)).toThrow('Both native sessions')
})

test('native Vulkan driver configuration uses the installed C++ instance and its supported generator', () => {
  for (const [major, year] of [[17, 2022], [18, 2026]]) {
    const path = `C:\\Program Files\\Microsoft Visual Studio\\${year}\\Enterprise`
    const result = visualStudioGenerator(capabilities, [{ installationPath: path, installationVersion: `${major}.1.2` }])
    expect(result.args).toEqual(['-G', `Visual Studio ${major} ${year}`, '-A', 'x64', '-T', 'host=x64', `-DCMAKE_GENERATOR_INSTANCE=${path}`])
    expect(result.installationVersion).toBe(`${major}.1.2`)
  }
})

test('native toolchain discovery rejects absent, malformed and unsupported installations', () => {
  expect(() => visualStudioGenerator(capabilities, [])).toThrow('one installed')
  expect(() => visualStudioGenerator(capabilities, [{ installationPath: '../toolchain', installationVersion: '18.1' }])).toThrow('invalid native')
  expect(() => visualStudioGenerator({ generators: [] }, [{ installationPath: 'C:\\VS', installationVersion: '18.1' }])).toThrow('does not support')
  expect(() => visualStudioGenerator({}, [{ installationPath: 'C:\\VS', installationVersion: '18.1' }])).toThrow('capabilities')
})

const identity: WindowsVulkanDriverIdentity = {
  sources: windowsVulkanDriverSources,
  script: 'a'.repeat(64),
  cmake: 'cmake version 4.1.2',
  visualStudio: '18.1.2',
  generator: ['-G', 'Visual Studio 18 2026', '-A', 'x64'],
}

function builtDriver() {
  const root = join(createTempDir('craft-vulkan-built-'), 'native-vulkan-dependencies')
  const paths = [
    join(root, 'loader-install', 'bin', 'vulkan-1.dll'),
    join(root, 'swiftshader-build', 'Windows', 'vk_swiftshader_icd.json'),
    join(root, 'swiftshader-build', 'Release', 'vk_swiftshader.dll'),
  ]
  const files = paths.map((path, index) => {
    mkdirSync(join(path, '..'), { recursive: true })
    const bytes = Buffer.from(`built file ${index}`)
    writeFileSync(path, bytes)
    return { path, bytes: bytes.length, sha256: Bun.SHA256.hash(bytes, 'hex') }
  })
  return { root, files }
}

test('a stored driver build returns byte for byte for the same identity only', async () => {
  const built = builtDriver()
  const cache = join(createTempDir('craft-vulkan-cache-'), 'driver')
  await storeWindowsVulkanDriver(cache, identity, built.root, built.files)
  const fresh = join(createTempDir('craft-vulkan-fresh-'), 'native-vulkan-dependencies')
  expect(await restoreWindowsVulkanDriver(cache, { ...identity, visualStudio: '18.2.0' }, fresh)).toBeNull()
  expect(await restoreWindowsVulkanDriver(cache, { ...identity, script: 'b'.repeat(64) }, fresh)).toBeNull()
  const restored = await restoreWindowsVulkanDriver(cache, identity, fresh)
  expect(typeof restored?.builtAt).toBe('string')
  for (const file of built.files)
    expect(readFileSync(file.path.replace(built.root, fresh), 'utf8')).toBe(readFileSync(file.path, 'utf8'))
})

test('a damaged, partial or escaping cache is never restored', async () => {
  const built = builtDriver()
  const cache = join(createTempDir('craft-vulkan-cache-'), 'driver')
  expect(await restoreWindowsVulkanDriver(cache, identity, join(createTempDir('craft-vulkan-empty-'), 'deps'))).toBeNull()
  await storeWindowsVulkanDriver(cache, identity, built.root, built.files)
  writeFileSync(join(cache, 'files', 'swiftshader-build', 'Release', 'vk_swiftshader.dll'), 'changed bytes')
  expect(await restoreWindowsVulkanDriver(cache, identity, join(createTempDir('craft-vulkan-fresh-'), 'deps'))).toBeNull()
  const record = JSON.parse(readFileSync(join(cache, 'driver.json'), 'utf8'))
  record.files[2].relative = '../outside.dll'
  writeFileSync(join(cache, 'driver.json'), JSON.stringify(record))
  expect(await restoreWindowsVulkanDriver(cache, identity, join(createTempDir('craft-vulkan-fresh-'), 'deps'))).toBeNull()
  await expect(storeWindowsVulkanDriver(cache, identity, built.root, [...built.files.slice(0, 2), { ...built.files[2]!, path: join(built.root, '..', 'elsewhere.dll') }])).rejects.toThrow('owned driver build')
})
