import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

export const releaseSboms = ['craft-sbom.json', 'full-sbom.cyclonedx.json', 'full-sbom.spdx.json'] as const

export function verifySbomFiles(directory: string, tag: string): void {
  for (const name of releaseSboms) {
    const document = JSON.parse(readFileSync(join(directory, name), 'utf8'))
    if (name.endsWith('.spdx.json')) {
      if (!/^SPDX-2\.\d+$/.test(document.spdxVersion ?? '') || document.SPDXID !== 'SPDXRef-DOCUMENT' || !Array.isArray(document.packages) || document.packages.length === 0)
        throw new Error(`${name}: expected a populated SPDX document`)
    }
    else {
      if (document.bomFormat !== 'CycloneDX' || !/^1\.\d+$/.test(document.specVersion ?? ''))
        throw new Error(`${name}: expected a CycloneDX document`)
      if (name === 'craft-sbom.json') {
        if (document.metadata?.component?.name !== 'craft' || document.metadata.component.version !== tag)
          throw new Error(`${name}: release identity does not match ${tag}`)
      }
      else if (!Array.isArray(document.components) || document.components.length === 0) {
        throw new Error(`${name}: expected dependency components`)
      }
    }
  }
}

if (import.meta.main) {
  const [directory, tag] = Bun.argv.slice(2)
  if (!directory || !/^v\d+\.\d+\.\d+/.test(tag ?? ''))
    throw new Error('Usage: bun scripts/verify-sbom.ts <directory> <version-tag>')
  verifySbomFiles(resolve(directory), tag)
  console.log(`Verified ${releaseSboms.length} SBOM attachments for ${tag}`)
}
