import { copyFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { build, init } from '../src/index'

const fixture = resolve(import.meta.dir, '../../ios/fixtures/native-navigation')
const stxCli = process.env.STX_NATIVE_CLI || resolve(import.meta.dir, '../../../../stx/packages/stx-native/src/cli/index.ts')
const workspace = mkdtempSync(join(tmpdir(), 'craft-android-native-navigation-'))
const output = join(workspace, 'NativeNavigation')
const bundle = join(workspace, 'routes.js')
const packageName = 'dev.craft.navigationtest'

function run(args: string[], cwd: string): void {
  console.log(args.join(' '))
  const result = Bun.spawnSync(args, { cwd, stdout: 'inherit', stderr: 'inherit' })
  if (result.exitCode !== 0) throw new Error(`${args[0]} exited with ${result.exitCode}`)
}

try {
  run([process.execPath, stxCli, 'compile', '--format', 'bundle', '--output', bundle], fixture)
  await init({ name: 'NativeNavigation', packageName, output, config: { renderer: 'native' }, runtimeDir: null })
  await build({ output, nativeBundlePath: bundle, compile: false, runtimeDir: null })

  const testDirectory = join(output, 'app/src/androidTest/java', ...packageName.split('.'))
  mkdirSync(testDirectory, { recursive: true })
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeNavigationTest.kt'), join(testDirectory, 'NativeNavigationTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeMutationTest.kt'), join(testDirectory, 'NativeMutationTest.kt'))

  if (!process.argv.includes('--prepare-only')) {
    try {
      run(['gradle', '--no-daemon', ':app:connectedDebugAndroidTest'], output)
    }
    catch (error) {
      run(['adb', 'logcat', '-d', '-s', 'CraftNativeAndroid:E'], output)
      throw error
    }
  }
  console.log(process.argv.includes('--prepare-only') ? 'Android native navigation fixture prepared' : 'Android native navigation test passed')
}
finally {
  if (process.env.CRAFT_KEEP_ANDROID_NATIVE_PROJECT === '1') console.log(`Kept generated test project: ${workspace}`)
  else rmSync(workspace, { recursive: true, force: true })
}
