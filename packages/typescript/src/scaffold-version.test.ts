import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pinCraftNativeDependency } from './scaffold-version'

const temporaryDirectories: string[] = []

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0))
    rmSync(directory, { recursive: true, force: true })
})

function writeManifest(manifest: object): string {
  const directory = mkdtempSync(join(tmpdir(), 'craft-scaffold-version-'))
  temporaryDirectories.push(directory)
  const packagePath = join(directory, 'package.json')
  writeFileSync(packagePath, JSON.stringify(manifest))
  return packagePath
}

describe('scaffold dependency versions', () => {
  it('replaces a workspace dependency with the CLI version', () => {
    const packagePath = writeManifest({
      dependencies: { 'craft-native': 'workspace:*', other: '^1.0.0' },
    })

    pinCraftNativeDependency(packagePath, '0.0.90')

    const manifest = JSON.parse(readFileSync(packagePath, 'utf-8'))
    expect(manifest.dependencies).toEqual({
      'craft-native': '^0.0.90',
      other: '^1.0.0',
    })
  })

  it('pins an existing dev dependency without moving it', () => {
    const packagePath = writeManifest({
      devDependencies: { 'craft-native': '*' },
    })

    pinCraftNativeDependency(packagePath, '1.2.3')

    const manifest = JSON.parse(readFileSync(packagePath, 'utf-8'))
    expect(manifest.dependencies).toBeUndefined()
    expect(manifest.devDependencies['craft-native']).toBe('^1.2.3')
  })

  it('adds the SDK when a template omits it', () => {
    const packagePath = writeManifest({ private: true })

    pinCraftNativeDependency(packagePath, '2.0.0')

    const manifest = JSON.parse(readFileSync(packagePath, 'utf-8'))
    expect(manifest.dependencies['craft-native']).toBe('^2.0.0')
  })
})
