import { expect, test } from 'bun:test'
import { mergeSbom } from './merge-sbom'

const source = {
  bomFormat: 'CycloneDX', specVersion: '1.7',
  metadata: { component: { name: '.', 'bom-ref': 'source-root' }, tools: { components: [{ name: 'syft', version: '1.52.0' }] } },
  components: [{ name: 'first', 'bom-ref': 'one' }, { name: 'second', 'bom-ref': 'two' }],
  dependencies: [{ ref: 'source-root', dependsOn: ['one'] }, { ref: 'one', dependsOn: ['two'] }],
}

test('preserves the scanned inventory and dependency graph when adding runtime supplements', () => {
  const original = structuredClone(source)
  const { combined, zig, platform } = mergeSbom(source, '0.0.93', '0.17.0-dev.1963')
  expect(combined.components).toHaveLength(7)
  expect(combined.components.slice(0, 2)).toEqual(source.components)
  expect(combined.dependencies?.find(dependency => dependency.ref === 'one')).toEqual(source.dependencies[1])
  expect(combined.dependencies?.find(dependency => dependency.ref === 'source-root')?.dependsOn).toContain('one')
  expect(combined.dependencies?.find(dependency => dependency.ref === 'source-root')?.dependsOn).toHaveLength(6)
  expect(combined.metadata?.tools).toEqual(source.metadata.tools)
  expect(combined.metadata?.component).toMatchObject({ name: 'craft', version: 'v0.0.93', 'bom-ref': 'source-root' })
  expect(zig.metadata?.component?.version).toBe('0.0.93')
  expect(platform.metadata?.component?.version).toBe('0.0.93')
  expect(zig.components[0].version).toBe('0.17.0-dev.1963')
  expect(Number.isNaN(Date.parse(String(zig.metadata?.timestamp)))).toBe(false)
  expect(source).toEqual(original)
})

test('refuses missing inventory and colliding component references', () => {
  expect(() => mergeSbom({ ...source, components: [] }, '1.0.0', 'dev')).toThrow('populated')
  expect(() => mergeSbom({ ...source, bomFormat: 'SPDX' }, '1.0.0', 'dev')).toThrow('CycloneDX')
  expect(() => mergeSbom({ ...source, components: [{ name: 'collision', 'bom-ref': 'urn:craft:zig-std' }] }, '1.0.0', 'dev')).toThrow('collides')
})
