import { expect, test } from 'bun:test'
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

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
  const root = mkdtempSync(join(tmpdir(), 'craft-error-types-'))
  try {
    copyFileSync(declarations, join(root, 'craft.d.ts'))
    writeFileSync(join(root, 'consumer.ts'), `
import type { CraftErrorCode, CraftError, NativeBridgeErrorCode } from './craft'
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
})
