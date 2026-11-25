import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { installSdkPackages, type SdkInstallAttempt } from './sdk-install'

const image = 'system-images;android-34;default;x86_64'
const truncated = 'Installing system images.\njava.io.IOException: Error reading Zip content from a SeekableByteChannel\n'

function scripted(...attempts: SdkInstallAttempt[]) {
  const calls: string[][] = []
  return { calls, runner: async (packages: string[]) => { calls.push(packages); return attempts[calls.length - 1] ?? { code: 99, output: 'called too often' } } }
}

test('an install that succeeds runs once (#451)', async () => {
  const { calls, runner } = scripted({ code: 0, output: '' })
  expect(await installSdkPackages([image], runner, () => {})).toBe(1)
  expect(calls).toEqual([[image]])
})

test('a download that arrives truncated is retried once, with a warning naming #451', async () => {
  const { calls, runner } = scripted({ code: 1, output: truncated }, { code: 0, output: '' })
  const lines: string[] = []
  expect(await installSdkPackages(['emulator', image], runner, line => lines.push(line))).toBe(2)
  expect(calls).toEqual([['emulator', image], ['emulator', image]])
  expect(lines).toHaveLength(1)
  expect(lines[0]).toStartWith('::warning title=Android SDK download arrived truncated (#451)::')
  expect(lines[0]).toContain('Error reading Zip content')
})

test('a second unreadable download fails, and only one retry is made', async () => {
  const { calls, runner } = scripted({ code: 1, output: truncated }, { code: 1, output: truncated })
  await expect(installSdkPackages([image], runner, () => {})).rejects.toThrow('sdkmanager failed again with exit 1')
  expect(calls).toHaveLength(2)
})

test('any other failure is not retried', async () => {
  const { calls, runner } = scripted({ code: 1, output: "Error: Failed to find package 'system-images;android-34;default;x86_64'" })
  await expect(installSdkPackages([image], runner, () => {})).rejects.toThrow('Failed to find package')
  expect(calls).toHaveLength(1)
})

test('Mobile E2E installs the emulator and its image this way before the emulator action runs', () => {
  const workflow = readFileSync(join(import.meta.dir, '../../../.github/workflows/mobile-e2e.yml'), 'utf8')
  const install = workflow.indexOf(`bun packages/android/scripts/sdk-install.ts emulator '${image}'`)
  const action = workflow.indexOf('uses: reactivecircus/android-emulator-runner@v2')
  expect(install).toBeGreaterThan(-1)
  expect(install).toBeLessThan(action)
  // The action must ask for the same image, or it would download its own.
  const settings = workflow.slice(action, action + 400)
  expect(settings).toContain('api-level: 34')
  expect(settings).toContain('arch: x86_64')
  expect(settings).not.toContain('target:')
})
