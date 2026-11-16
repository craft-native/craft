import { afterAll, describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { publishedBy } from './verify-packages'

/**
 * An app can type `window.craft` from the published `craft-native` (#554).
 *
 * `packages/typescript/types/craft.d.ts` declares the mobile bridge that
 * `docs/api/mobile/` documents, but `files` published only `dist`, so every
 * release shipped new bridge options to the native packages and none of them
 * to an app's type checker. It is now `craft-native/window`, and this compiles
 * an app against it the way an installed package resolves.
 */
const root = resolve(import.meta.dir, '..')
const sdk = join(root, 'packages/typescript')
const manifest = JSON.parse(readFileSync(join(sdk, 'package.json'), 'utf8'))
const scratch = mkdtempSync(join(tmpdir(), 'craft-window-types-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

function compile(source: string, options: Record<string, unknown>): { code: number, output: string } {
  const app = mkdtempSync(join(scratch, 'app-'))
  mkdirSync(join(app, 'node_modules'))
  symlinkSync(sdk, join(app, 'node_modules/craft-native'), 'dir')
  writeFileSync(join(app, 'app.ts'), source)
  writeFileSync(join(app, 'tsconfig.json'), JSON.stringify({
    compilerOptions: { strict: true, noEmit: true, target: 'es2022', lib: ['es2022', 'dom'], types: [], ...options },
    files: ['app.ts'],
  }))
  const run = Bun.spawnSync([join(root, 'node_modules/.bin/tsc'), '-p', app], { stdout: 'pipe', stderr: 'pipe' })
  return { code: run.exitCode, output: `${run.stdout}${run.stderr}` }
}

const app = `/// <reference types="craft-native/window" />
const info = window.craft.getDeviceInfo()
const language: string | undefined = info.languages?.[0]
export const chosen = language ?? 'en'
`

describe('craft-native/window', () => {
  it('is published: the export, its typesVersions entry and the files list agree', () => {
    expect(manifest.exports['./window']).toEqual({ types: './types/craft.d.ts' })
    expect(manifest.typesVersions['*'].window).toEqual(['./types/craft.d.ts'])
    expect(publishedBy(manifest.files, './types/craft.d.ts')).toBe(true)
  })

  for (const [name, options] of [
    ['bundler', { module: 'esnext', moduleResolution: 'bundler' }],
    ['node16', { module: 'node16', moduleResolution: 'node16' }],
  ] as const) {
    it(`types window.craft for an app resolving with ${name}`, () => {
      const result = compile(app, options)
      expect(result.output).toBe('')
      expect(result.code).toBe(0)
    })
  }

  it('works from tsconfig "types" and as an import of its types', () => {
    const listed = compile(`const info = window.craft.getDeviceInfo()\nexport const tags: readonly string[] = info.languages ?? []\n`, { module: 'esnext', moduleResolution: 'bundler', types: ['craft-native/window'] })
    expect(listed.output).toBe('')
    const imported = compile(`import type { CraftErrorCode, DeviceInfo } from 'craft-native/window'\nexport function first(info: DeviceInfo, code: CraftErrorCode): string { return info.languages?.[0] ?? code }\n`, { module: 'esnext', moduleResolution: 'bundler' })
    expect(imported.output).toBe('')
  })

  it('still catches a wrong call, so the compile is not vacuous', () => {
    const result = compile(`/// <reference types="craft-native/window" />\nwindow.craft.getDeviceInfo().noSuchField.trim()\nexport {}\n`, { module: 'esnext', moduleResolution: 'bundler' })
    expect(result.output).toContain('noSuchField')
    expect(result.code).not.toBe(0)
  })
})

describe('publishedBy', () => {
  it('matches a listed file or anything under a listed directory, and nothing else', () => {
    const files = ['dist', 'types/craft.d.ts', 'README.md']
    expect(publishedBy(files, './dist/index.d.ts')).toBe(true)
    expect(publishedBy(files, './types/craft.d.ts')).toBe(true)
    expect(publishedBy(files, './types/other.d.ts')).toBe(false)
    expect(publishedBy(files, './distribution/index.js')).toBe(false)
    expect(publishedBy(['dist/'], './dist/index.js')).toBe(true)
    expect(publishedBy(undefined, './anything.js')).toBe(true)
  })
})
