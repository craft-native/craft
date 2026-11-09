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

  // Both comment forms are stripped before the union is sliced: a comment
  // holding a semicolon ends the match early and silently truncates the
  // declared set. A `//` one did that when this test was written, reporting
  // every code as undeclared while the declarations were right there; a
  // `/** @deprecated … */` one did it again later, and only the size floor
  // below caught it.
  const types = readFileSync(declarations, 'utf8').replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '')
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

/**
 * A declared code only one host constructs says which host, in its own note.
 *
 * #496 asked for this after a comparison of the two hosts' codes turned out to
 * be wrong in both directions: it called `IO_ERROR`, `POSITION_UNAVAILABLE`
 * and `PRESENTATION_FAILED` Android-only and `EMPTY_RECORDING` iOS-only, when
 * three of those were on both hosts and the fourth should have been. A
 * one-host code is a real thing — `MEASURE_FAILED` cannot occur on Android,
 * whose geometry is Int pixels that cannot be NaN — but it has to be stated,
 * because a caller branching on the code takes a branch that is dead on one
 * platform and has nothing to tell them so.
 *
 * Derived from the hosts, so the next one-host code has to say which host
 * when it is added, not when someone next compares the two by hand.
 */
test('a declared code only one host constructs says so in its note', async () => {
  const templates = async (dir: string, extension: string) => {
    const glob = new Bun.Glob(`**/*${extension}`)
    const root = resolve(sdk, '..', dir)
    const files = [...glob.scanSync({ cwd: root, absolute: true })]
    expect(files.length, `${dir} must have templates to read`).toBeGreaterThan(10)
    return (await Promise.all(files.map(file => Bun.file(file).text()))).join('\n')
  }
  const swift = await templates('ios/templates', '.swift')
  const kotlin = await templates('android/templates', '.template')

  // Constructors only. Both hosts also carry a `getErrorMessage` lookup table
  // in the JavaScript they inject, and its keys are not emissions — reading
  // those as constructed codes makes four codes nothing produces look live.
  // `code: "X"`, `code = "X"`, a Swift default (`var code: String = "X"`),
  // Kotlin's `.put("code", "X")`, and the error/failure constructors.
  const constructed = (source: string) => new Set(
    [...source.matchAll(/(?:\bcode\b\s*(?::\s*\w+\s*)?[:=]\s*|\.put\("code",\s*|\b(?:fail|failure|Failure|\w*Exception|\w*Error)\(\s*)"([A-Z][A-Z0-9_]*)"/g)].map(found => found[1]!),
  )
  const ios = constructed(swift), android = constructed(kotlin)
  expect(ios.size).toBeGreaterThan(30)
  expect(android.size).toBeGreaterThan(30)

  const types = readFileSync(declarations, 'utf8')
  const stripped = types.replace(/\/\/[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '')
  const codesIn = (name: string) => new Set(
    [...new RegExp(`export type ${name}\\s*=([^;]*);`).exec(stripped)![1]!.matchAll(/'([A-Z_]+)'/g)].map(found => found[1]!),
  )
  // `NativeBridgeErrorCode` is the Zig bridge's own wire vocabulary, derived
  // from bridge_error.zig by the first test in this file. Both hosts reach it
  // through the bridge rather than constructing it, so a wire code appearing
  // in one host's templates says nothing about the other and is not this
  // test's business.
  const wire = codesIn('NativeBridgeErrorCode')
  const declared = [...codesIn('CraftErrorCode')].filter(code => !wire.has(code))
  expect(wire.size).toBeGreaterThan(15)
  expect(declared.length).toBeGreaterThan(30)

  /**
   * A code's own line plus everything written above it, back to the previous
   * member — a note sits either after the code or on the lines before it.
   *
   * The region is bounded at both ends. It starts below the previous member's
   * line, because that line's own trailing `// iOS only` would otherwise be
   * read as this code's note — which it did, making three codes on both hosts
   * look like they claimed to be one-host. And the search for that previous
   * member starts above this code's own line, because `\n  |` matches this
   * line's own separator otherwise and cuts off the note above it.
   */
  const noteFor = (code: string) => {
    const at = types.indexOf(`| '${code}'`)
    expect(at, `${code} must appear in the union`).toBeGreaterThan(0)
    const line = types.lastIndexOf('\n', at)
    const previous = types.lastIndexOf('\n  |', line - 1)
    const from = previous < 0 ? 0 : types.indexOf('\n', previous + 1)
    return types.slice(from, types.indexOf('\n', at))
  }

  const unstated: string[] = []
  for (const code of declared) {
    const onIos = ios.has(code), onAndroid = android.has(code)
    if (onIos === onAndroid) {
      // Both or neither. Neither is covered by the deprecation note above the
      // four unreachable codes; what must not happen is a code both hosts
      // construct claiming to belong to one of them.
      if (onIos && /\b(iOS|Android) only\b/.test(noteFor(code))) unstated.push(`${code} is on both hosts and claims to be one-host`)
      continue
    }
    const expected = onIos ? 'iOS only' : 'Android only'
    if (!noteFor(code).includes(expected)) unstated.push(`${code} is ${expected} and does not say so`)
  }
  expect(unstated.sort(), 'these codes differ between the hosts with nothing in the type to say so').toEqual([])
}, 30_000)
