import { afterAll, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { macOSAppStoreRuntimePath, packageApp } from '../package'
import { createTempDir, removeAllTempDirs } from '../temp-dir'

afterAll(removeAllTempDirs)

test('App Store packaging refuses missing, direct and unresponsive native providers', () => {
  const directory = createTempDir('craft-store-provider-')
  const direct = join(directory, 'craft')
  const store = join(directory, 'craft-app-store')
  expect(() => macOSAppStoreRuntimePath(direct)).toThrow('Upgrade Craft with Pantry')
  writeFileSync(store, `#!${process.execPath}\nconsole.log('direct')\n`)
  chmodSync(store, 0o755)
  expect(() => macOSAppStoreRuntimePath(direct)).toThrow('private platform APIs')
  writeFileSync(store, `#!${process.execPath}\nprocess.exit(1)\n`)
  expect(() => macOSAppStoreRuntimePath(direct)).toThrow('private platform APIs')
  writeFileSync(store, `#!${process.execPath}\nif(process.argv[2] === '--distribution') console.log('app-store')\n`)
  expect(macOSAppStoreRuntimePath(direct)).toBe(store)
  expect(macOSAppStoreRuntimePath(store)).toBe(store)
})

test.each(['MenuBarClientCore', 'MBAssessmentMode', 'developerExtrasEnabled', 'javaScriptCanAccessClipboard', 'drawsBackground'])(
  'App Store packaging rejects a provider containing %s even when its distribution flag claims public APIs', (marker) => {
    const directory = createTempDir('craft-store-private-provider-')
    const runtime = join(directory, 'craft-app-store')
    writeFileSync(runtime, `#!${process.execPath}\nconsole.log('app-store')\n// ${marker}\n`)
    chmodSync(runtime, 0o755)
    expect(() => macOSAppStoreRuntimePath(runtime)).toThrow('private platform APIs')
  },
)


test('App Store selection preserves the webview profile and fails closed if its store variant is missing', () => {
  const directory = createTempDir('craft-store-webview-')
  const direct = join(directory, 'craft-webview')
  const store = join(directory, 'craft-webview-app-store')
  writeFileSync(join(directory, 'craft-app-store'), 'full runtime must not substitute for the requested profile')
  expect(() => macOSAppStoreRuntimePath(direct)).toThrow('Upgrade Craft with Pantry')
  writeFileSync(store, `#!${process.execPath}\nif(process.argv[2] === '--distribution') console.log('app-store')\n`)
  chmodSync(store, 0o755)
  expect(macOSAppStoreRuntimePath(direct)).toBe(store)
  expect(macOSAppStoreRuntimePath(store)).toBe(store)
})


test.skipIf(process.platform !== 'darwin')('prebuilt backend bundles replace the main runtime before App Store signing and preserve their backend', async () => {
  const directory = createTempDir('craft-store-prebuilt-')
  const contents = join(directory, 'Example.app/Contents')
  mkdirSync(join(contents, 'MacOS'), { recursive: true })
  mkdirSync(join(contents, 'Resources'))
  writeFileSync(join(contents, 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Example</string></dict></plist>')
  writeFileSync(join(contents, 'Resources/craft.json'), JSON.stringify({ backend: { executable: 'stx-backend' } }))
  writeFileSync(join(contents, 'MacOS/Example'), 'original direct runtime')
  writeFileSync(join(contents, 'MacOS/stx-backend'), 'original compiled backend')
  const store = join(directory, 'craft-webview-app-store')
  const source = `#!${process.execPath}\nif(process.argv[2] === '--distribution') console.log('app-store')\n`
  writeFileSync(store, source, { mode: 0o755 })
  const outDir = join(directory, 'dist')
  const result = await packageApp({
    name: 'Example', version: '1.0.0', binaryPath: join(contents, 'MacOS/Example'), platforms: ['macos'], outDir,
    macos: { appBundlePath: join(directory, 'Example.app'), appStore: true, dmg: false,
      entitlements: join(directory, 'not-an-entitlement'), provisioningProfile: join(directory, 'not-a-profile'),
      nativeRuntimePath: join(directory, 'craft-webview') },
  })
  // The deliberately absent signing assets stop packaging after the replacement.
  expect(result.every(item => !item.success)).toBe(true)
  expect(readFileSync(join(outDir, 'Example.app/Contents/MacOS/Example'), 'utf8')).toBe(source)
  expect(readFileSync(join(outDir, 'Example.app/Contents/MacOS/stx-backend'), 'utf8')).toBe('original compiled backend')
})
