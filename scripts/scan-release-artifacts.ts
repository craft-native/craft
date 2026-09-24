import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { enforceScanPolicy, scanSbom } from './scan-sbom'

type Archive = { name: string, version: string, file: string, sha256: string }
type Component = { name: string, version?: string, 'bom-ref'?: string, [key: string]: unknown }
type Inventory = { bomFormat: string, components: Component[], [key: string]: unknown }

const root = resolve(import.meta.dir, '..')
const sha256 = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex')

function run(args: string[], cwd = root) {
  const result = Bun.spawnSync(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
  if (result.exitCode !== 0)
    throw new Error(`${args[0]} failed (${result.exitCode}): ${result.stderr.toString()}`)
  return result.stdout.toString()
}

export function expectedNpmPackages(): string[] {
  const names: string[] = []
  for (const path of new Bun.Glob('packages/*/package.json').scanSync({ cwd: root })) {
    const pkg = JSON.parse(readFileSync(join(root, path), 'utf8')) as { name?: string, private?: boolean }
    if (!pkg.private) {
      if (!pkg.name) throw new Error(`${path}: public package has no name`)
      names.push(pkg.name)
    }
  }
  return names.sort()
}

export function readArchiveManifest(directory: string, expected: string[] = expectedNpmPackages()): Archive[] {
  const manifest = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8')) as { packages?: Archive[] }
  if (!Array.isArray(manifest.packages) || manifest.packages.length !== expected.length)
    throw new Error('Release archive manifest does not cover every public npm package')
  const names = new Set<string>()
  const files = new Set<string>()
  for (const archive of manifest.packages) {
    if (!archive || typeof archive.name !== 'string' || !archive.name || typeof archive.version !== 'string' || !archive.version
      || typeof archive.file !== 'string' || !/^\d+\.tgz$/.test(archive.file)
      || typeof archive.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(archive.sha256))
      throw new Error('Malformed release archive manifest')
    if (names.has(archive.name) || files.has(archive.file)) throw new Error('Duplicate release archive identity')
    names.add(archive.name)
    files.add(archive.file)
    const path = join(directory, archive.file)
    if (!existsSync(path) || !statSync(path).isFile() || sha256(path) !== archive.sha256)
      throw new Error(`${archive.name}: release archive hash mismatch`)
  }
  if (expected.some(name => !names.has(name)))
    throw new Error('Release archive manifest does not cover every public npm package')
  return manifest.packages
}

export function summarizeBunAudit(report: unknown): { Critical: number, High: number } {
  if (!report || typeof report !== 'object' || Array.isArray(report)) throw new Error('Invalid Bun audit report')
  const counts = { Critical: 0, High: 0 }
  for (const advisories of Object.values(report)) {
    if (!Array.isArray(advisories)) throw new Error('Invalid Bun audit advisories')
    for (const advisory of advisories) {
      const severity = advisory?.severity
      if (!['critical', 'high', 'moderate', 'low', 'info'].includes(severity))
        throw new Error('Invalid Bun audit severity')
      if (severity === 'critical') counts.Critical++
      if (severity === 'high') counts.High++
    }
  }
  return counts
}

function scanNpm(directory: string, output: string, syft: string, grype: string) {
  const archives = readArchiveManifest(directory)
  const consumer = mkdtempSync(join(tmpdir(), 'craft-release-consumer-'))
  try {
    const dependencies = Object.fromEntries(archives.map(({ name, file }) => [name, `file:${join(resolve(directory), file)}`]))
    writeFileSync(join(consumer, 'package.json'), `${JSON.stringify({ private: true, dependencies }, null, 2)}\n`)
    run([process.execPath, 'install', '--ignore-scripts', '--save', '--save-text-lockfile'], consumer)
    const audit = Bun.spawnSync([process.execPath, 'audit', '--production', '--json'], { cwd: consumer, stdout: 'pipe', stderr: 'pipe' })
    const auditText = audit.stdout.toString()
    let auditCounts: ReturnType<typeof summarizeBunAudit>
    try {
      const report = JSON.parse(auditText)
      auditCounts = summarizeBunAudit(report)
      if (audit.exitCode !== 0 && Object.keys(report).length === 0)
        throw new Error('Bun audit failed without reporting any advisories')
    }
    catch { throw new Error(`Bun production audit did not return a valid report: ${audit.stderr.toString()}`) }
    mkdirSync(output, { recursive: true })
    writeFileSync(join(output, 'bun-audit.json'), auditText)

    const sbom = join(output, 'npm.cyclonedx.json')
    run([syft, join(consumer, 'node_modules'), '--select-catalogers', '+javascript-package-cataloger', '-o', `cyclonedx-json=${sbom}`])
    const inventory = JSON.parse(readFileSync(sbom, 'utf8')) as Inventory
    if (inventory.bomFormat !== 'CycloneDX' || !Array.isArray(inventory.components))
      throw new Error('Invalid npm release inventory')
    for (const archive of archives) {
      if (!inventory.components.some(component => component.name === archive.name && component.version === archive.version))
        throw new Error(`${archive.name}: package missing from installed release inventory`)
    }
    const summary = scanSbom(sbom, join(output, 'grype'), grype)
    enforceScanPolicy(summary.counts, true)
    if (auditCounts.Critical || auditCounts.High)
      throw new Error('High or Critical findings in npm production dependencies block this release')
    readArchiveManifest(directory)
    console.log(`Scanned ${archives.length} packed npm packages and their resolved production dependencies`)
  }
  finally { rmSync(consumer, { recursive: true, force: true }) }
}

export function nativeInventory(binaryRoot: string, platform: 'macos' | 'linux', version: string, zigVersion: string, discovered: Component[][] = []): Inventory {
  const entries = platform === 'macos'
    ? [{ path: 'bin/craft', name: 'craft-darwin-arm64', magic: ['cffaedfe', 'feedfacf'] }, { path: 'cross/darwin-x64/craft', name: 'craft-darwin-x64', magic: ['cffaedfe', 'feedfacf'] }]
    : [{ path: 'bin/craft', name: 'craft-linux-x64', magic: ['7f454c46'] }, { path: 'cross/windows-x64/craft.exe', name: 'craft-windows-x64', magic: ['4d5a'] }]
  const binaries: Component[] = entries.map(({ path, name, magic }) => {
    const absolute = join(binaryRoot, path)
    if (!existsSync(absolute) || !statSync(absolute).isFile() || statSync(absolute).size < 1024)
      throw new Error(`${name}: missing or empty release binary`)
    const bytes = readFileSync(absolute)
    if (!magic.some(prefix => bytes.subarray(0, prefix.length / 2).toString('hex') === prefix))
      throw new Error(`${name}: unexpected executable format`)
    return { 'bom-ref': `urn:craft:binary:${name}`, type: 'application', name, version,
      hashes: [{ alg: 'SHA-256', content: createHash('sha256').update(bytes).digest('hex') }],
      properties: [{ name: 'craft:artifact-path', value: path }],
    }
  })
  const zig = { 'bom-ref': 'urn:craft:zig-std', type: 'library', name: 'zig-std', version: zigVersion }
  return {
    bomFormat: 'CycloneDX', specVersion: '1.6', version: 1,
    metadata: { component: { type: 'application', name: 'craft-native-release', version } },
    components: [...binaries, zig, ...discovered.flat()],
    dependencies: binaries.map(binary => ({ ref: binary['bom-ref'], dependsOn: [zig['bom-ref']] })),
  }
}

function scanNative(binaryRoot: string, platform: 'macos' | 'linux', output: string, syft: string, grype: string) {
  mkdirSync(output, { recursive: true })
  const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as { version: string }
  const zigVersion = Bun.JSONC.parse(readFileSync(join(root, 'pantry.jsonc'), 'utf8')).dependencies['ziglang.org'] as string
  const paths = platform === 'macos' ? ['bin/craft', 'cross/darwin-x64/craft'] : ['bin/craft', 'cross/windows-x64/craft.exe']
  const discovered = paths.map((path, index) => {
    const report = join(output, `native-${index}.cyclonedx.json`)
    run([syft, join(binaryRoot, path), '-o', `cyclonedx-json=${report}`])
    const inventory = JSON.parse(readFileSync(report, 'utf8')) as Inventory
    if (inventory.bomFormat !== 'CycloneDX' || (inventory.components !== undefined && !Array.isArray(inventory.components)))
      throw new Error(`${path}: invalid binary scanner inventory`)
    return inventory.components ?? []
  })
  const inventory = nativeInventory(binaryRoot, platform, version, zigVersion, discovered)
  const sbom = join(output, 'native.cyclonedx.json')
  writeFileSync(sbom, `${JSON.stringify(inventory, null, 2)}\n`)
  const summary = scanSbom(sbom, join(output, 'grype'), grype)
  enforceScanPolicy(summary.counts, true)
  const after = nativeInventory(binaryRoot, platform, version, zigVersion)
  for (const [index, binary] of after.components.slice(0, 2).entries()) {
    if (JSON.stringify(binary.hashes) !== JSON.stringify(inventory.components[index]!.hashes))
      throw new Error(`${binary.name}: release binary changed after scanning`)
  }
  console.log(`Scanned ${platform} release binaries and declared Zig runtime dependencies`)
}

if (import.meta.main) {
  const [mode, input, output] = Bun.argv.slice(2)
  if (!mode || !input || !output) throw new Error('Usage: scan-release-artifacts.ts <npm|macos|linux> <input> <output>')
  const syft = process.env.CRAFT_SYFT ?? 'syft'
  const grype = process.env.CRAFT_GRYPE ?? 'grype'
  if (mode === 'npm') scanNpm(resolve(input), resolve(output), syft, grype)
  else if (mode === 'macos' || mode === 'linux') scanNative(resolve(input), mode, resolve(output), syft, grype)
  else throw new Error(`Unknown release artifact mode: ${mode}`)
}
