#!/usr/bin/env bun
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

type PackageJson = {
  name: string
  private?: boolean
  bin?: Record<string, string>
  exports?: Record<string, any>
  files?: string[]
  main?: string
  module?: string
  types?: string
  typesVersions?: Record<string, Record<string, string[]>>
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const checks: string[] = []

function readPackage(path: string): PackageJson {
  return JSON.parse(readFileSync(path, 'utf-8'))
}

function fail(message: string): never {
  throw new Error(message)
}

function assertFile(path: string): void {
  if (!existsSync(path) || !statSync(path).isFile())
    fail(`Expected file: ${path}`)
  checks.push(path)
}

function assertDir(path: string): void {
  if (!existsSync(path) || !statSync(path).isDirectory())
    fail(`Expected directory: ${path}`)
  checks.push(path)
}

function assertPublicPackage(pkg: PackageJson, packageDir: string): void {
  if (pkg.private === true)
    fail(`${pkg.name} is marked private but is expected to publish`)

  for (const entry of pkg.files ?? [])
    assertDirOrFile(join(packageDir, entry))
}

function assertDirOrFile(path: string): void {
  if (!existsSync(path))
    fail(`Expected package file entry to exist: ${path}`)
  checks.push(path)
}

function assertNoTestDeclarations(packageDir: string): void {
  const dist = join(packageDir, 'dist')
  if (!existsSync(dist))
    return

  const stack = [dist]
  while (stack.length > 0) {
    const dir = stack.pop()!
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) {
        stack.push(path)
        continue
      }
      if (/(__tests__|\.test\.d\.(?:ts|cts)|\.spec\.d\.(?:ts|cts))$/.test(path))
        fail(`Test declaration leaked into dist: ${path}`)
    }
  }
}

/**
 * Every relative specifier in a shipped declaration must carry a file
 * extension.
 *
 * TypeScript only enforces this on the *consumer* side, under
 * `moduleResolution: node16` or `nodenext` — which is what a modern Node
 * project uses. Emit is happy either way, so `dist/index.d.ts` shipped 15
 * extensionless re-exports and every such consumer got:
 *
 *     error TS2834: Relative import paths need explicit file extensions in
 *     ECMAScript imports when '--moduleResolution' is 'node16' or 'nodenext'
 *
 * followed by TS2305 on symbols the package genuinely exports. Nothing in the
 * repo noticed, because the repo builds itself with `moduleResolution:
 * bundler`, where extensionless is fine.
 */
function assertDeclarationsCarryExtensions(packageDir: string): void {
  const dist = join(packageDir, 'dist')
  if (!existsSync(dist))
    return

  // `from './x'` / `import('./x')`, capturing the specifier.
  const specifier = /(?:from|import)\s*\(?\s*['"](\.[^'"]*)['"]/g

  const stack = [dist]
  while (stack.length > 0) {
    const dir = stack.pop()!
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) {
        stack.push(path)
        continue
      }
      if (!/\.d\.(?:ts|cts|mts)$/.test(path))
        continue
      for (const match of readFileSync(path, 'utf-8').matchAll(specifier)) {
        if (!/\.(?:js|cjs|mjs|json)$/.test(match[1]))
          fail(`Declaration ${path} imports "${match[1]}" without a file extension, which does not resolve under moduleResolution node16/nodenext`)
      }
    }
  }
}

/**
 * Whether npm publishes `target` under this `files` list. A target that exists
 * here but is not listed resolves in the monorepo and is missing from the
 * tarball: `types/craft.d.ts` was exactly that (#554).
 */
export function publishedBy(files: string[] | undefined, target: string): boolean {
  if (!files)
    return true
  const path = target.replace(/^\.\//, '')
  return files.some((entry) => {
    const listed = entry.replace(/^\.\//, '').replace(/\/$/, '')
    return path === listed || path.startsWith(`${listed}/`)
  })
}

function verifyExportTargets(pkg: PackageJson, packageDir: string): void {
  const target = (value: string): void => {
    assertFile(join(packageDir, value))
    if (!publishedBy(pkg.files, value))
      fail(`${pkg.name} points at ${value}, which its "files" list does not publish`)
  }
  const visit = (value: any): void => {
    if (typeof value === 'string' && value.startsWith('./'))
      target(value)
    else if (value && typeof value === 'object')
      Object.values(value).forEach(visit)
  }

  if (pkg.main)
    target(pkg.main)
  if (pkg.module)
    target(pkg.module)
  if (pkg.types)
    target(pkg.types)
  if (pkg.exports)
    Object.values(pkg.exports).forEach(visit)
  for (const paths of Object.values(pkg.typesVersions ?? {}))
    Object.values(paths).flat().filter(path => !path.includes('*')).forEach(visit)
}

function verifyBinTargets(pkg: PackageJson, packageDir: string): void {
  for (const [name, target] of Object.entries(pkg.bin ?? {})) {
    assertFile(join(packageDir, target))
    checks.push(`${pkg.name}:bin:${name}`)
  }
}

function verifyPackage(relativePath: string): void {
  const packageDir = join(root, relativePath)
  const pkg = readPackage(join(packageDir, 'package.json'))
  assertPublicPackage(pkg, packageDir)
  verifyBinTargets(pkg, packageDir)
  verifyExportTargets(pkg, packageDir)
  assertNoTestDeclarations(packageDir)
  assertDeclarationsCarryExtensions(packageDir)
}

if (import.meta.main) {
  for (const packagePath of [
    'packages/typescript',
    'packages/create-craft',
    'packages/ts-maps',
  ]) {
    verifyPackage(packagePath)
  }

  assertFile(join(root, 'bin/craft'))

  console.log(`Verified package publish surfaces (${checks.length} checks).`)
}
