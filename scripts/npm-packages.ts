import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve, sep } from 'node:path'

type Manifest = {
  name: string
  version: string
  private?: boolean
  scripts?: Record<string, string>
  peerDependencies?: Record<string, string>
  main?: string
  module?: string
  types?: string
  svelte?: string
  bin?: string | Record<string, string>
  exports?: unknown
}

const root = resolve(import.meta.dir, '..')

function run(args: string[], cwd: string): string {
  const result = Bun.spawnSync(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
  if (result.exitCode !== 0)
    throw new Error(`${args.join(' ')} failed in ${cwd}\n${result.stdout}\n${result.stderr}`)
  return result.stdout.toString()
}

export function manifestTargets(pkg: Manifest): string[] {
  const targets = new Set<string>()
  const add = (value: unknown): void => {
    if (typeof value === 'string') {
      if (value.includes('*'))
        throw new Error(`${pkg.name}: wildcard targets require explicit archive validation: ${value}`)
      const target = value.replace(/^\.\//, '')
      if (target.startsWith('/') || target.split('/').includes('..') || target.includes('\\'))
        throw new Error(`${pkg.name}: invalid package target ${value}`)
      targets.add(target)
    }
    else if (value && typeof value === 'object') {
      Object.values(value).forEach(add)
    }
  }
  for (const value of [pkg.main, pkg.module, pkg.types, pkg.svelte, pkg.bin, pkg.exports])
    add(value)
  return [...targets]
}

export function verifyArchiveTargets(pkg: Manifest, entries: string[]): void {
  const files = new Set(entries.filter(entry => !entry.endsWith('/')))
  for (const target of manifestTargets(pkg)) {
    if (!files.has(`package/${target}`))
      throw new Error(`${pkg.name}: packed artifact is missing ${target}`)
  }
}

function publicPackages(): { dir: string, pkg: Manifest }[] {
  const packages: { dir: string, pkg: Manifest }[] = []
  // Match Pantry's monorepo publish scope: packages/, excluding private entries.
  // Other workspaces such as benchmarks are development tools, not npm products.
  for (const path of new Bun.Glob('packages/*/package.json').scanSync({ cwd: root })) {
    const pkg: Manifest = JSON.parse(readFileSync(join(root, path), 'utf8'))
    if (!pkg.private)
      packages.push({ dir: dirname(join(root, path)), pkg })
  }
  // The SDK generates the shared declarations used by package consumers.
  return packages.sort((a, b) => a.pkg.name === 'craft-native' ? -1 : b.pkg.name === 'craft-native' ? 1 : a.pkg.name.localeCompare(b.pkg.name))
}

function importSpecifiers(pkg: Manifest): string[] {
  if (!pkg.exports)
    return pkg.main || pkg.module ? [pkg.name] : []
  if (typeof pkg.exports === 'object' && pkg.exports !== null) {
    const keys = Object.keys(pkg.exports)
    if (keys.some(key => key.startsWith('.')))
      return keys.filter(key => key !== './package.json').map(key => key === '.' ? pkg.name : `${pkg.name}${key.slice(1)}`)
  }
  return [pkg.name]
}

export async function verifyNpmPackages(buildOnly = false, archiveDir?: string): Promise<void> {
  const packages = publicPackages()
  if (packages.length === 0)
    throw new Error('No public npm workspaces found')
  if (buildOnly && archiveDir) throw new Error('Cannot export archives in build-only mode')
  const output = archiveDir ? resolve(archiveDir) : undefined
  if (output) {
    if (output === root || output.startsWith(`${root}${sep}`))
      throw new Error('Archive output must be outside the repository')
    mkdirSync(output, { recursive: true })
    if (readdirSync(output).length) throw new Error('Archive output must be empty')
  }
  const temp = mkdtempSync(join(tmpdir(), 'craft-npm-verify-'))
  try {
    for (const { dir, pkg } of packages) {
      if (pkg.scripts?.build) {
        console.log(`Building ${pkg.name}`)
        // Generated outputs must come from this build, not a previous checkout.
        rmSync(join(dir, 'dist'), { recursive: true, force: true })
        run([process.execPath, 'run', 'build'], dir)
      }
    }

    if (buildOnly)
      return

    const specifiers: string[] = []
    const archives: { name: string, version: string, file: string, sha256: string }[] = []
    for (const [index, { dir, pkg }] of packages.entries()) {
      const file = `${index}.tgz`
      const archive = join(output ?? temp, file)
      run([process.execPath, 'pm', 'pack', '--filename', archive], dir)
      const entries = run(['tar', '-tzf', archive], temp).trim().split('\n')
      const packed: Manifest = JSON.parse(run(['tar', '-xOzf', archive, 'package/package.json'], temp))
      verifyArchiveTargets(packed, entries)
      if (packed.name !== pkg.name || packed.version !== pkg.version)
        throw new Error(`${pkg.name}: packed identity differs from the source manifest`)
      archives.push({ name: packed.name, version: packed.version, file, sha256: createHash('sha256').update(readFileSync(archive)).digest('hex') })
      const installed = join(temp, 'node_modules', pkg.name)
      mkdirSync(installed, { recursive: true })
      run(['tar', '-xzf', archive, '--strip-components=1', '-C', installed], temp)
      specifiers.push(...importSpecifiers(packed))
      console.log(`Verified ${pkg.name}: ${manifestTargets(packed).length} packed targets`)
    }

    // Supply only declared external peers. Craft packages themselves must resolve
    // to the extracted archives, never to workspace symlinks or tsconfig paths.
    for (const { dir, pkg } of packages) {
      for (const peer of Object.keys(pkg.peerDependencies ?? {})) {
        const destination = join(temp, 'node_modules', peer)
        if (existsSync(destination))
          continue
        let source = join(dir, 'node_modules', peer)
        if (!existsSync(source)) source = join(root, 'node_modules', peer)
        if (!existsSync(source)) throw new Error(`${pkg.name}: missing installed peer ${peer}`)
        mkdirSync(dirname(destination), { recursive: true })
        symlinkSync(source, destination, 'dir')
      }
    }
    const runtimeImports = specifiers.map(specifier => `await import(${JSON.stringify(specifier)})`).join('\n')
    writeFileSync(join(temp, 'runtime.mjs'), runtimeImports)
    run([process.execPath, 'runtime.mjs'], temp)
    const typeImports = specifiers.map((specifier, index) => `import * as entry${index} from ${JSON.stringify(specifier)}; void entry${index}`).join('\n')
    writeFileSync(join(temp, 'consumer.mts'), typeImports)
    run([
      process.execPath, join(root, 'packages/typescript/scripts/tsc.ts'), 'consumer.mts',
      '--noEmit', '--strict', '--module', 'esnext', '--moduleResolution', 'bundler',
      '--target', 'esnext', '--skipLibCheck', '--ignoreConfig',
      '--typeRoots', join(root, 'node_modules/@types'),
    ], temp)
    if (output)
      writeFileSync(join(output, 'manifest.json'), `${JSON.stringify({ packages: archives }, null, 2)}\n`)
    console.log(`Verified ${packages.length} npm archives and ${specifiers.length} installed import/type entry points.`)
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const index = Bun.argv.indexOf('--archive-dir')
  if (index >= 0 && (!Bun.argv[index + 1] || Bun.argv[index + 1]!.startsWith('--')))
    throw new Error('--archive-dir requires an output path')
  await verifyNpmPackages(Bun.argv.includes('--build-only'), index >= 0 ? Bun.argv[index + 1] : undefined)
}
