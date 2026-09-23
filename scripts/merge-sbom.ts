import { randomUUID } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

type Component = { name: string, 'bom-ref'?: string, [key: string]: unknown }
type Bom = {
  bomFormat: string
  specVersion: string
  metadata?: { component?: Component, [key: string]: unknown }
  components: Component[]
  dependencies?: { ref: string, dependsOn?: string[] }[]
  [key: string]: unknown
}

export function mergeSbom(source: Bom, version: string, zigVersion: string): { combined: Bom, zig: Bom, platform: Bom } {
  if (source.bomFormat !== 'CycloneDX' || !Array.isArray(source.components) || source.components.length === 0)
    throw new Error('A populated CycloneDX inventory is required before merging')
  const timestamp = new Date().toISOString()
  const supplement = (name: string, components: Component[]): Bom => ({
    bomFormat: 'CycloneDX', specVersion: source.specVersion, version: 1,
    metadata: { timestamp, component: { type: 'application', name, version } },
    components,
  })
  const zig = supplement('craft-zig-core', [{
    'bom-ref': 'urn:craft:zig-std', type: 'library', name: 'zig-std', version: zigVersion,
    description: 'Standard library for the repository-declared Zig toolchain',
    properties: [{ name: 'craft:version-source', value: 'pantry.jsonc dependencies.ziglang.org' }],
    licenses: [{ license: { id: 'MIT' } }],
  }])
  const platform = supplement('craft-platform-deps', [
    { 'bom-ref': 'urn:craft:webkit', type: 'library', name: 'WebKit', description: 'macOS WebKit system framework', properties: [{ name: 'platform', value: 'macos' }] },
    { 'bom-ref': 'urn:craft:gtk3', type: 'library', name: 'GTK3', description: 'GTK 3 system toolkit', properties: [{ name: 'platform', value: 'linux' }] },
    { 'bom-ref': 'urn:craft:webkit2gtk', type: 'library', name: 'WebKit2GTK', description: 'WebKit2GTK 4.1 API system dependency', properties: [{ name: 'platform', value: 'linux' }] },
    { 'bom-ref': 'urn:craft:webview2', type: 'library', name: 'WebView2', description: 'Microsoft Edge WebView2 system runtime', properties: [{ name: 'platform', value: 'windows' }] },
  ])
  const combined = structuredClone(source)
  const extra = [...zig.components, ...platform.components]
  const existing = new Set(combined.components.map(component => component['bom-ref']).filter(Boolean))
  if (extra.some(component => existing.has(component['bom-ref']!)))
    throw new Error('Supplement component reference collides with the source inventory')
  const rootRef = source.metadata?.component?.['bom-ref'] ?? 'urn:craft:root'
  combined.serialNumber = `urn:uuid:${randomUUID()}`
  combined.metadata = {
    ...combined.metadata,
    timestamp,
    component: { 'bom-ref': rootRef, type: 'application', name: 'craft', version: `v${version}`, licenses: [{ license: { id: 'MIT' } }] },
  }
  combined.components.push(...extra)
  combined.dependencies ??= []
  let rootDependency = combined.dependencies.find(dependency => dependency.ref === rootRef)
  if (!rootDependency) {
    rootDependency = { ref: rootRef, dependsOn: [] }
    combined.dependencies.push(rootDependency)
  }
  rootDependency.dependsOn = [...new Set([...(rootDependency.dependsOn ?? []), ...extra.map(component => component['bom-ref']!)])]
  return { combined, zig, platform }
}

if (import.meta.main) {
  const directory = resolve(Bun.argv[2] ?? 'sbom')
  const root = resolve(import.meta.dir, '..')
  const { version } = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
  const toolchain = Bun.JSONC.parse(readFileSync(join(root, 'pantry.jsonc'), 'utf8')).dependencies['ziglang.org']
  const source = JSON.parse(readFileSync(join(directory, 'full-sbom.cyclonedx.json'), 'utf8'))
  const { combined, zig, platform } = mergeSbom(source, version, toolchain)
  for (const [name, document] of Object.entries({ 'craft-sbom.json': combined, 'zig-dependencies.json': zig, 'platform-dependencies.json': platform }))
    writeFileSync(join(directory, name), `${JSON.stringify(document, null, 2)}\n`)
  console.log(`Merged ${source.components.length} scanned and ${zig.components.length + platform.components.length} declared runtime components`)
}
