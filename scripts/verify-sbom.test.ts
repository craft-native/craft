import { expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { releaseSboms, verifySbomFiles } from './verify-sbom'

const documents = {
  'craft-sbom.json': { bomFormat: 'CycloneDX', specVersion: '1.5', metadata: { component: { name: 'craft', version: 'v0.0.93' } }, components: [{ name: 'dependency', version: '1.0.0' }] },
  'full-sbom.cyclonedx.json': { bomFormat: 'CycloneDX', specVersion: '1.6', components: [{ name: 'dependency', version: '1.0.0' }] },
  'full-sbom.spdx.json': { spdxVersion: 'SPDX-2.3', SPDXID: 'SPDXRef-DOCUMENT', packages: [{ name: 'dependency' }] },
}

test('requires all three valid documents from the matching release', () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-sbom-'))
  try {
    for (const [name, value] of Object.entries(documents)) writeFileSync(join(directory, name), JSON.stringify(value))
    expect(() => verifySbomFiles(directory, 'v0.0.93')).not.toThrow()
    expect(() => verifySbomFiles(directory, 'v0.0.94')).toThrow('release identity')
    for (const name of releaseSboms) {
      rmSync(join(directory, name))
      expect(() => verifySbomFiles(directory, 'v0.0.93')).toThrow()
      writeFileSync(join(directory, name), '{')
      expect(() => verifySbomFiles(directory, 'v0.0.93')).toThrow()
      writeFileSync(join(directory, name), '{}')
      expect(() => verifySbomFiles(directory, 'v0.0.93')).toThrow()
      writeFileSync(join(directory, name), JSON.stringify(documents[name]))
    }
    for (const name of ['craft-sbom.json', 'full-sbom.cyclonedx.json'] as const) {
      for (const components of [undefined, []]) {
        writeFileSync(join(directory, name), JSON.stringify({ ...documents[name], components }))
        expect(() => verifySbomFiles(directory, 'v0.0.93')).toThrow('dependency components')
      }
      writeFileSync(join(directory, name), JSON.stringify(documents[name]))
    }
    for (const packages of [undefined, [], 'not-an-inventory']) {
      writeFileSync(join(directory, 'full-sbom.spdx.json'), JSON.stringify({ ...documents['full-sbom.spdx.json'], packages }))
      expect(() => verifySbomFiles(directory, 'v0.0.93')).toThrow('populated SPDX')
    }
  }
  finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
