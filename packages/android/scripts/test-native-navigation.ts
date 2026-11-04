import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { build, init } from '../src/index'
import { createTempDir, keepTempDir, removeTempDir } from '../../typescript/src/temp-dir'
import { retainNativeNavigationEvidence } from './native-navigation-evidence'

const fixture = resolve(import.meta.dir, '../../ios/fixtures/native-navigation')
// The @stacksjs/stx CLI (`stx native compile`), from a sibling checkout unless CI pins one.
const stxCli = process.env.STX_CLI || resolve(import.meta.dir, '../../../../stx/packages/stx/bin/cli.ts')
const workspace = createTempDir('craft-android-native-navigation-')
const output = join(workspace, 'NativeNavigation')
const bundle = join(workspace, 'routes.js')
const packageName = 'dev.craft.navigationtest'

function run(args: string[], cwd: string): void {
  console.log(args.join(' '))
  const result = Bun.spawnSync(args, { cwd, stdout: 'inherit', stderr: 'inherit' })
  if (result.exitCode !== 0) throw new Error(`${args[0]} exited with ${result.exitCode}`)
}

function assertMutationBundle(path: string): void {
  const source = readFileSync(path, 'utf8')
  const hasSharedRuntime = source.includes('__stxNativeUnmount') || source.includes('mutationProtocolVersion')
  if (!hasSharedRuntime || !/["']MUTATE["']/.test(source))
    throw new Error('stx native compile did not emit the native mutation protocol')
}

try {
  run([process.execPath, stxCli, 'native', 'compile', '--format', 'bundle', '--output', bundle], fixture)
  assertMutationBundle(bundle)
  await init({
    name: 'NativeNavigation', packageName, output,
    config: {
      renderer: 'native',
      nativeApp: '__app',
      notificationCategories: [{ id: 'fixture-message', actions: [
        { id: 'reply', title: 'Reply', textInput: { buttonTitle: 'Send', placeholder: 'Fixture reply' } },
        { id: 'open', title: 'Open', foreground: true },
      ] }],
      enablePedometer: true,
      enableHealthServices: true,
      mapProvider: 'maplibre',
      nativeScreens: {
        '/': 'home',
        '/identity': 'identity',
        '/details': 'details',
        '/linked-details': 'details',
        '/summary': 'summary',
        '/capabilities': 'capabilities',
      },
      tabs: [
        { id: '/', title: 'Home', symbol: 'house' },
        { id: '/details', title: 'Details', symbol: 'doc.text' },
        { id: '/summary', title: 'Summary', symbol: 'list.bullet' },
      ],
      enableDeepLinks: true,
      enableAudioRecording: true,
      enableLocalDatabase: true,
      enableLocalNotifications: true,
      enableSecureStorage: true,
      enableBiometric: true,
      enableLocalNetwork: true,
      urlSchemes: ['craft-native-test'],
    },
    runtimeDir: null,
  })
  await build({ output, nativeBundlePath: bundle, compile: false, runtimeDir: null })

  const testDirectory = join(output, 'app/src/androidTest/java', ...packageName.split('.'))
  mkdirSync(testDirectory, { recursive: true })
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeNavigationTest.kt'), join(testDirectory, 'NativeNavigationTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeMutationTest.kt'), join(testDirectory, 'NativeMutationTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeFlatListTest.kt'), join(testDirectory, 'NativeFlatListTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeCapabilitiesTest.kt'), join(testDirectory, 'NativeCapabilitiesTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativePassiveStepsTest.kt'), join(testDirectory, 'NativePassiveStepsTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeRecordingTest.kt'), join(testDirectory, 'NativeRecordingTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeVoiceRecordingTest.kt'), join(testDirectory, 'NativeVoiceRecordingTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeCapabilityUiTest.kt'), join(testDirectory, 'NativeCapabilityUiTest.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeMapTest.kt'), join(testDirectory, 'NativeMapTest.kt'))
  const debugDirectory = join(output, 'app/src/debug/java', ...packageName.split('.'))
  mkdirSync(debugDirectory, { recursive: true })
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeSystemBarsReferenceActivity.kt'), join(debugDirectory, 'NativeSystemBarsReferenceActivity.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeViewTestActivity.kt'), join(debugDirectory, 'NativeViewTestActivity.kt'))
  copyFileSync(join(import.meta.dir, '../fixtures/native-navigation/NativeImportProvider.kt'), join(debugDirectory, 'NativeImportProvider.kt'))
  writeFileSync(join(output, 'app/src/debug/AndroidManifest.xml'), `<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application><activity android:name=".NativeViewTestActivity" android:exported="false" /><activity android:name=".NativeSystemBarsReferenceActivity" android:exported="false" /><provider android:name=".NativeImportProvider" android:authorities="${packageName}.imports" android:exported="false" /></application></manifest>`)

  if (!process.argv.includes('--prepare-only')) {
    try {
      const selection = process.env.CRAFT_ANDROID_TEST_CLASS
      run(['gradle', '--no-daemon', ':app:connectedDebugAndroidTest', ...(selection ? [`-Pandroid.testInstrumentationRunnerArguments.class=${selection}`] : [])], output)
    }
    finally {
      // The emulator action stops its device before the next workflow step.
      // Retain provider/system evidence and Gradle reports here, before either
      // that teardown or our own project cleanup. Diagnostic errors must never
      // replace the original instrumentation failure.
      try {
        retainNativeNavigationEvidence({
          project: output,
          directory: resolve(process.env.CRAFT_ANDROID_NATIVE_ARTIFACTS || 'artifacts/android-native-navigation'),
          serial: process.env.ANDROID_SERIAL,
        })
      }
      catch (error) { console.error(`Could not retain Android native evidence: ${error}`) }
    }
  }
  console.log(process.argv.includes('--prepare-only') ? 'Android native navigation fixture prepared' : 'Android native navigation test passed')
}
finally {
  if (process.env.CRAFT_KEEP_ANDROID_NATIVE_PROJECT === '1') {
    keepTempDir(workspace)
    console.log(`Kept generated test project: ${workspace}`)
  }
  else {
    removeTempDir(workspace)
  }
}
