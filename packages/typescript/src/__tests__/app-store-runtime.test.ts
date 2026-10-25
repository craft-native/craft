import { afterAll, expect, test } from 'bun:test'
import { chmodSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { macOSAppStoreRuntimePath } from '../package'
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
