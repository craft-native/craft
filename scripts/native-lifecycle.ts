#!/usr/bin/env bun

import type { PackageResult } from '../packages/typescript/src/package'
import { createHash } from 'crypto'
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, rmSync, writeFileSync } from 'fs'
import { join, resolve } from 'path'
import { packageApp } from '../packages/typescript/src/package'
import { macOSRollbackPlan } from './native-lifecycle-plan'

type Step = {
  name: string
  command?: string[]
  status: 'passed' | 'failed' | 'skipped'
  output?: string
  error?: string
}

const root = resolve(import.meta.dir, '..')
const platform = process.platform === 'darwin' ? 'macos' : process.platform === 'win32' ? 'windows' : 'linux'
const evidenceLabel = process.env.CRAFT_EVIDENCE_LABEL || `${process.platform}-${process.arch}`
const reportDir = join(root, 'artifacts', 'native-lifecycle', evidenceLabel)
const workDir = join(reportDir, 'work')
const shouldInstall = process.argv.includes('--install')
const steps: Step[] = []

/**
 * Every file inside a bundle, deepest-last, in a stable order.
 *
 * Sorted at each level so the walk does not depend on directory order, which
 * differs between filesystems and would make the digest below unreproducible.
 */
function* bundleEntries(dir: string, prefix = ''): Generator<{ relativePath: string, absolutePath: string }> {
  for (const name of readdirSync(dir).sort()) {
    const absolutePath = join(dir, name)
    const relativePath = prefix ? `${prefix}/${name}` : name
    if (lstatSync(absolutePath).isDirectory()) yield* bundleEntries(absolutePath, relativePath)
    else yield { relativePath, absolutePath }
  }
}

/**
 * SHA-256 of a packaged artifact.
 *
 * Most artifacts are single files. A macOS `.app` is a directory, and reading
 * one as a file throws `EISDIR` — which is what took down both macOS legs of
 * this workflow, after every packaging, install, update and rollback step had
 * already passed. The report was never written and the evidence upload then
 * failed too, so a fully successful lifecycle run reported nothing at all.
 *
 * Bundles are hashed as a tree instead: each file's path, then its mode bit or
 * symlink target, then its contents. The path goes in as well as the contents
 * so that moving a file within the bundle changes the digest. `report.json`
 * says which of the two kinds each digest is, since they are not comparable.
 */
function sha256(path: string): { sha256: string, kind: 'file' | 'tree' } {
  if (!lstatSync(path).isDirectory())
    return { sha256: createHash('sha256').update(readFileSync(path)).digest('hex'), kind: 'file' }

  const hash = createHash('sha256')
  for (const { relativePath, absolutePath } of bundleEntries(path)) {
    const stats = lstatSync(absolutePath)
    hash.update(relativePath)
    if (stats.isSymbolicLink()) {
      // Read the link rather than follow it: bundles are full of internal
      // symlinks (Versions/Current and friends) and following them would both
      // double-count and, in the wrong bundle, loop.
      hash.update('\u0002')
      hash.update(readlinkSync(absolutePath))
    }
    else {
      hash.update(stats.mode & 0o111 ? '\u0001' : '\u0000')
      hash.update(readFileSync(absolutePath))
    }
  }
  return { sha256: hash.digest('hex'), kind: 'tree' }
}

async function command(name: string, argv: string[], expected?: string): Promise<string> {
  const entry: Step = { name, command: argv, status: 'failed' }
  steps.push(entry)
  const proc = Bun.spawn(argv, { stdout: 'pipe', stderr: 'pipe', env: process.env })
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  const output = `${stdout}${stderr}`.trim()
  entry.output = output
  if (exitCode !== 0) {
    entry.error = `${argv[0]} exited with ${exitCode}`
    throw new Error(`${name}: ${entry.error}\n${output}`)
  }
  if (expected !== undefined && !output.includes(expected)) {
    entry.error = `expected output to include ${JSON.stringify(expected)}`
    throw new Error(`${name}: ${entry.error}; got ${JSON.stringify(output)}`)
  }
  entry.status = 'passed'
  return output
}

function requireArtifact(results: PackageResult[], format: string): string {
  const result = results.find(candidate => candidate.format === format)
  if (!result) throw new Error(`packager did not return ${format}`)
  if (!result.success || !result.outputPath) throw new Error(`${format} packaging failed: ${result.error || 'missing output'}`)
  if (!existsSync(result.outputPath)) throw new Error(`${format} output does not exist: ${result.outputPath}`)
  return result.outputPath
}

async function buildFixture(version: string): Promise<string> {
  const source = join(workDir, `fixture-${version}.ts`)
  const binary = join(workDir, `craft-lifecycle-${version}${process.platform === 'win32' ? '.exe' : ''}`)
  writeFileSync(source, `console.log(${JSON.stringify(`craft-lifecycle ${version}`)})\n`)
  await command(`compile fixture ${version}`, ['bun', 'build', '--compile', source, '--outfile', binary])
  if (process.platform !== 'win32') chmodSync(binary, 0o755)
  return binary
}

async function createPackages(version: string, binaryPath: string): Promise<PackageResult[]> {
  const outDir = join(workDir, `packages-${version}`)
  const results = await packageApp({
    name: 'craft-lifecycle',
    version,
    description: 'Craft native package lifecycle contract fixture',
    author: 'Stacks.js',
    binaryPath,
    outDir,
    bundleId: 'dev.craft.lifecycle',
    platforms: [platform],
    macos: { dmg: true, pkg: true },
    windows: { msi: true, zip: true },
    linux: { deb: true, rpm: false, appImage: false, debDependencies: [] },
  })
  const failures = results.filter(result => !result.success)
  if (failures.length) throw new Error(failures.map(result => `${result.format}: ${result.error}`).join('\n'))
  steps.push({ name: `package fixture ${version}`, status: 'passed', output: results.map(result => result.outputPath).join('\n') })
  return results
}

async function exerciseLinux(v1: PackageResult[], v2: PackageResult[]): Promise<void> {
  const first = requireArtifact(v1, 'deb')
  const second = requireArtifact(v2, 'deb')
  await command('install v1', ['sudo', 'dpkg', '-i', first])
  await command('launch v1', ['/usr/bin/craft-lifecycle'], 'craft-lifecycle 1.0.0')
  await command('update to v2', ['sudo', 'dpkg', '-i', second])
  await command('launch v2', ['/usr/bin/craft-lifecycle'], 'craft-lifecycle 1.0.1')
  await command('rollback to v1', ['sudo', 'dpkg', '-i', first])
  await command('launch rollback', ['/usr/bin/craft-lifecycle'], 'craft-lifecycle 1.0.0')
  await command('uninstall', ['sudo', 'dpkg', '--remove', 'craft-lifecycle'])
  if (existsSync('/usr/bin/craft-lifecycle')) throw new Error('Linux uninstall left /usr/bin/craft-lifecycle behind')
  steps.push({ name: 'verify uninstall', status: 'passed' })
}

async function exerciseMacOS(v1: PackageResult[], v2: PackageResult[]): Promise<void> {
  const first = requireArtifact(v1, 'pkg')
  const second = requireArtifact(v2, 'pkg')
  const app = '/Applications/craft-lifecycle.app'
  const executable = join(app, 'Contents', 'MacOS', 'craft-lifecycle')
  // `installer` can report success and put the payload somewhere else entirely:
  // a package built with bundle relocation enabled is redirected to wherever the
  // system already has that bundle identifier registered. When that happened
  // here the only symptom was `launch` throwing ENOENT, which says nothing about
  // where the app went. The receipt does — `location:` is the path the payload
  // actually landed at — so record it as its own step, into report.json and the
  // uploaded evidence, every time.
  const receipt = (label: string) => command(`receipt after ${label}`, ['pkgutil', '--pkg-info', 'dev.craft.lifecycle'])

  if (existsSync(app)) await command('remove pre-existing fixture', ['sudo', 'rm', '-rf', app])
  await command('install v1', ['sudo', 'installer', '-pkg', first, '-target', '/'])
  await receipt('install v1')
  await command('launch v1', [executable], 'craft-lifecycle 1.0.0')
  await command('update to v2', ['sudo', 'installer', '-pkg', second, '-target', '/'])
  await receipt('update to v2')
  await command('launch v2', [executable], 'craft-lifecycle 1.0.1')
  for (const step of macOSRollbackPlan(app, 'dev.craft.lifecycle', first))
    await command(step.name, step.argv)
  await command('launch rollback', [executable], 'craft-lifecycle 1.0.0')
  await command('uninstall', ['sudo', 'rm', '-rf', app])
  await command('forget v1 receipt', ['sudo', 'pkgutil', '--forget', 'dev.craft.lifecycle'])
  if (existsSync(app)) throw new Error(`macOS uninstall left ${app} behind`)
  steps.push({ name: 'verify uninstall', status: 'passed' })
}

async function exerciseWindows(v1: PackageResult[], v2: PackageResult[]): Promise<void> {
  const first = requireArtifact(v1, 'msi')
  const second = requireArtifact(v2, 'msi')
  const programFiles = process.env.ProgramFiles || 'C:\\Program Files'
  const executable = join(programFiles, 'craft-lifecycle', 'craft-lifecycle.exe')
  await command('install v1', ['msiexec.exe', '/i', first, '/qn', '/norestart'])
  await command('launch v1', [executable], 'craft-lifecycle 1.0.0')
  await command('update to v2', ['msiexec.exe', '/i', second, '/qn', '/norestart'])
  await command('launch v2', [executable], 'craft-lifecycle 1.0.1')
  await command('rollback to v1', ['msiexec.exe', '/i', first, '/qn', '/norestart'])
  await command('launch rollback', [executable], 'craft-lifecycle 1.0.0')
  await command('uninstall', ['msiexec.exe', '/x', first, '/qn', '/norestart'])
  if (existsSync(executable)) throw new Error(`Windows uninstall left ${executable} behind`)
  steps.push({ name: 'verify uninstall', status: 'passed' })
}

async function main(): Promise<void> {
  rmSync(reportDir, { recursive: true, force: true })
  mkdirSync(workDir, { recursive: true })
  let error: string | undefined
  let packages: PackageResult[] = []
  try {
    const binaryV1 = await buildFixture('1.0.0')
    const binaryV2 = await buildFixture('1.0.1')
    const packagesV1 = await createPackages('1.0.0', binaryV1)
    const packagesV2 = await createPackages('1.0.1', binaryV2)
    packages = [...packagesV1, ...packagesV2]
    if (shouldInstall) {
      if (platform === 'macos') await exerciseMacOS(packagesV1, packagesV2)
      else if (platform === 'windows') await exerciseWindows(packagesV1, packagesV2)
      else await exerciseLinux(packagesV1, packagesV2)
    }
    else {
      steps.push({ name: 'install/update/rollback/uninstall', status: 'skipped', output: 'Pass --install to exercise privileged lifecycle operations.' })
    }
  }
  catch (caught) {
    error = caught instanceof Error ? caught.stack || caught.message : String(caught)
  }

  // Hashing runs after the try/catch above, so anything it throws used to
  // escape `main` before `report.json` was written — losing the record of
  // every step that had already passed. Failures are recorded per artifact
  // and still fail the run, but the evidence survives them.
  const artifacts = packages
    .filter(result => result.success && result.outputPath && existsSync(result.outputPath))
    .map((result) => {
      const artifact = {
        platform: result.platform,
        format: result.format,
        path: result.outputPath!.replace(`${root}/`, ''),
        sha256: null as string | null,
        sha256Kind: null as 'file' | 'tree' | null,
        error: undefined as string | undefined,
      }
      try {
        const digest = sha256(result.outputPath!)
        artifact.sha256 = digest.sha256
        artifact.sha256Kind = digest.kind
      }
      catch (caught) {
        artifact.error = caught instanceof Error ? caught.message : String(caught)
        error ||= `failed to hash ${result.format} artifact ${artifact.path}: ${artifact.error}`
      }
      return artifact
    })
  const report = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    revision: process.env.CRAFT_SOURCE_REVISION || process.env.GITHUB_SHA || 'local',
    orchestratorRevision: process.env.CRAFT_SOURCE_REVISION ? process.env.GITHUB_SHA || null : null,
    runner: { os: process.platform, arch: process.arch, bun: Bun.version },
    installLifecycleExercised: shouldInstall,
    status: error ? 'failed' : 'passed',
    artifacts,
    steps,
    error,
  }
  mkdirSync(reportDir, { recursive: true })
  writeFileSync(join(reportDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`)
  console.log(JSON.stringify(report, null, 2))
  if (error) throw new Error(error)
}

await main()
