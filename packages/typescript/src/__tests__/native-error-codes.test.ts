import { afterAll, expect, test } from 'bun:test'
import { copyFileSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { createTempDir, removeAllTempDirs } from '../temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const sdk = resolve(import.meta.dir, '../..')
const declarations = join(sdk, 'types/craft.d.ts')

test('mobile native error types exactly match the Zig wire vocabulary', () => {
  const zig = readFileSync(join(sdk, '../zig/src/bridge_error.zig'), 'utf8')
  const mapping = zig.match(/pub fn errorCodeString[\s\S]*?\n}/)?.[0]
  expect(mapping).toBeDefined()
  const nativeCodes = [...mapping!.matchAll(/BridgeError\.\w+\s*=>\s*"([A-Z_]+)"/g)].map(match => match[1]).sort()
  const types = readFileSync(declarations, 'utf8')
  const declaration = types.match(/export type NativeBridgeErrorCode\s*=([\s\S]*?);/)?.[1]
  expect(declaration).toBeDefined()
  const typedCodes = [...declaration!.matchAll(/'([A-Z_]+)'/g)].map(match => match[1]).sort()
  expect(nativeCodes.length).toBeGreaterThan(0)
  expect(typedCodes).toEqual(nativeCodes)
  expect(new Set(typedCodes).size).toBe(typedCodes.length)
})

test('isolated mobile consumers accept native and legacy codes but reject misspellings', () => {
  const root = createTempDir('craft-error-types-')
  try {
    copyFileSync(declarations, join(root, 'craft.d.ts'))
    writeFileSync(join(root, 'consumer.ts'), `
import type { CraftErrorCode, CraftError, NativeBridgeErrorCode, CraftBridge } from './craft'
declare const accessibility: NonNullable<CraftBridge['accessibility']>
const spoken: Promise<void> = accessibility.announce('Saved', { polite: true })
// @ts-expect-error Speech priority is a Boolean, not an arbitrary string.
accessibility.announce('Saved', { polite: 'yes' })
// @ts-expect-error Announcement text must be a string.
accessibility.announce(42)
void spoken
const native: NativeBridgeErrorCode[] = ['BUSY', 'WEBVIEW_HANDLE_NOT_SET', 'INVALID_PARAMETER', 'NATIVE_CALL_FAILED', 'CAPABILITY_DISABLED']
const compatible: CraftErrorCode[] = [...native, 'INVALID_PARAMS', 'NOT_AVAILABLE', 'STORAGE_FULL']
const error: CraftError = { code: 'BUSY', message: 'Try later', timestamp: 0 }
// @ts-expect-error Misspelled native codes must not widen the public union.
const typo: CraftErrorCode = 'INVALID_PARAMTER'
// @ts-expect-error A legacy mobile name is not a canonical native wire code.
const legacy: NativeBridgeErrorCode = 'INVALID_PARAMS'
void [compatible, error, typo, legacy]
`)
    writeFileSync(join(root, 'tsconfig.json'), JSON.stringify({ compilerOptions: { strict: true, noEmit: true, module: 'esnext', moduleResolution: 'bundler', lib: ['es2022', 'dom'], types: [] }, files: ['consumer.ts'] }))
    const check = Bun.spawnSync([process.execPath, join(sdk, 'scripts/tsc.ts'), '-p', join(root, 'tsconfig.json')], { cwd: root, stdout: 'pipe', stderr: 'pipe' })
    expect(check.stdout.toString() + check.stderr.toString()).toBe('')
    expect(check.exitCode).toBe(0)
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 30_000)

/**
 * Every error code the native screen hosts emit is declared.
 *
 * The test above derives `NativeBridgeErrorCode` from `bridge_error.zig`, which
 * is the Zig bridge's wire vocabulary. The native screen hosts are a second
 * source: their capability dispatchers construct codes as literals, and 18 of
 * them — `RECORDING_BUSY`, `VIEW_NOT_FOUND`, `APP_INACTIVE`, `IO_ERROR` and the
 * rest — reached callers without appearing in either union, so an exhaustive
 * handler could not account for them.
 *
 * Derived from the hosts, so a new code has to be declared when it is added.
 */
test('every code the native screen hosts emit is in the public union', async () => {
  const host = async (path: string) => Bun.file(resolve(sdk, '..', path)).text()
  const swift = (await Promise.all([
    'ios/templates/CraftNativeScreen.swift',
    'ios/templates/CraftNativeActions.swift',
    'ios/templates/CraftVoiceRecording.swift',
  ].map(host))).join('\n')
  const kotlin = (await Promise.all([
    'android/templates/MainActivityNative.kt.template',
    'android/templates/CraftNativeServices.kt.template',
  ].map(host))).join('\n')

  const emitted = new Set<string>()
  for (const found of swift.matchAll(/CraftNativeActionError\(code:\s*"([A-Z_]+)"/g)) emitted.add(found[1]!)
  for (const found of swift.matchAll(/fail\("([A-Z_]+)"/g)) emitted.add(found[1]!)
  for (const found of kotlin.matchAll(/CraftNativeCapabilityResult\(code\s*=\s*"([A-Z_]+)"/g)) emitted.add(found[1]!)
  for (const found of kotlin.matchAll(/failure\("([A-Z_]+)"/g)) emitted.add(found[1]!)
  expect(emitted.size).toBeGreaterThan(20)

  // Comments are stripped before the union is sliced: a `//` comment holding a
  // semicolon ends the non-greedy match early and silently truncates the
  // declared set, which is how the first version of this test reported every
  // code as undeclared while the declarations were right there.
  const types = readFileSync(declarations, 'utf8').replace(/\/\/[^\n]*/g, '')
  const declared = new Set<string>()
  for (const name of ['NativeBridgeErrorCode', 'CraftErrorCode']) {
    const body = new RegExp(`export type ${name}\\s*=([^;]*);`).exec(types)?.[1]
    expect(body, `${name} must be declared`).toBeTruthy()
    for (const found of body!.matchAll(/'([A-Z_]+)'/g)) declared.add(found[1]!)
  }
  // The slice must reach the end of the union, not stop inside it.
  expect(declared.size).toBeGreaterThan(55)

  const undeclared = [...emitted].filter(code => !declared.has(code)).sort()
  expect(undeclared, 'these codes reach callers with no public declaration').toEqual([])
}, 30_000)
