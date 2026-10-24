import { expect, test } from 'bun:test'
import { verifyWindowsVulkanDriverSelection, visualStudioGenerator } from './windows-vulkan-driver'

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
