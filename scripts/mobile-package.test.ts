import { afterAll, expect, test } from 'bun:test'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const root = resolve(import.meta.dir, '..')

for (const platform of ['android', 'ios']) {
  test(`${platform} tarball exposes usable standalone declarations`, () => {
    const temp = createTempDir(`craft-${platform}-package-`)
    const packageDir = join(root, 'packages', platform)
    const run = (args: string[], cwd = temp): void => {
      const result = Bun.spawnSync(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
      expect(`${result.stdout}\n${result.stderr}`).not.toContain('error TS')
      expect(result.exitCode).toBe(0)
    }

    try {
      run([process.execPath, 'run', 'build'], packageDir)
      run([process.execPath, 'pm', 'pack', '--filename', join(temp, 'package.tgz')], packageDir)
      const installed = join(temp, 'node_modules', '@craft-native', platform)
      mkdirSync(installed, { recursive: true })
      run(['tar', '-xzf', join(temp, 'package.tgz'), '--strip-components=1', '-C', installed])
      if (platform === 'ios') {
        writeFileSync(join(temp, 'runtime.mts'), `
import { initSimulatorDriver } from '@craft-native/ios'
initSimulatorDriver({ output: './driver', bundleId: 'org.example.consumer' })
`)
        run([process.execPath, 'runtime.mts'])
      }
      writeFileSync(join(temp, 'consumer.mts'), `
import { init, type InitOptions } from '@craft-native/${platform}'
const options: InitOptions = { name: 'Consumer', output: '/tmp/consumer', runtimeDir: null }
const result: Promise<void> = init(options)
// @ts-expect-error name must be a string, even outside the workspace
init({ name: 42, output: '/tmp/consumer' })
void result
${platform === 'android' ? `
import type { CraftAndroidConfig } from '@craft-native/android'
const enabled: CraftAndroidConfig = { appName: 'Consumer', packageName: 'org.example.consumer', enableLocalDatabase: true, enableLocalNotifications: true }
const notificationsOnly: CraftAndroidConfig = { appName: 'Consumer', packageName: 'org.example.consumer', enableLocalNotifications: true }
const disabled: CraftAndroidConfig = { ...enabled, enableLocalDatabase: false, enableLocalNotifications: false }
const native: InitOptions = { name: 'Native', output: '/tmp/consumer', runtimeDir: null, config: { renderer: 'native', enableLocalDatabase: true, enableLocalNotifications: true } }
// @ts-expect-error database enablement must be a boolean
const invalidDatabase: CraftAndroidConfig = { ...enabled, enableLocalDatabase: 'yes' }
// @ts-expect-error notification enablement must be a boolean
const invalidNotifications: CraftAndroidConfig = { ...enabled, enableLocalNotifications: 1 }
// @ts-expect-error unknown option names remain rejected
const misspelled: CraftAndroidConfig = { ...enabled, enableLocalDatabse: true }
void [notificationsOnly, disabled, native, invalidDatabase, invalidNotifications, misspelled]
` : ''}
${platform === 'ios' ? `
import { initSimulatorDriver, serializeSimulatorSteps, createNativeMutationValidator, restoreShell } from '@craft-native/ios'
initSimulatorDriver({ output: '/tmp/driver', bundleId: 'org.example.consumer', tabs: ['Home'] })
const script: string = serializeSimulatorSteps([{ command: 'launch' }, { command: 'expect', text: 'Home', seconds: 5 }])
// @ts-expect-error unknown simulator command
serializeSimulatorSteps([{ command: 'unknown' }])
// @ts-expect-error seconds must be numeric
serializeSimulatorSteps([{ command: 'wait', seconds: 'five' }])
void [script, createNativeMutationValidator, restoreShell]
` : ''}
`)
      run([
        process.execPath, join(root, 'packages/typescript/scripts/tsc.ts'),
        'consumer.mts', '--noEmit', '--strict', '--module', 'nodenext',
        '--moduleResolution', 'nodenext', '--target', 'esnext', '--ignoreConfig',
      ])
    }
    finally {
      rmSync(temp, { recursive: true, force: true })
    }
  }, 60_000)
}
