import { createHash } from 'node:crypto'
import { lstatSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const requiredAssets = ['craft-darwin-arm64.zip', 'craft-darwin-x64.zip', 'craft-linux-x64.zip', 'craft-windows-x64.zip']

type ReleaseIdentity = { repository: string, tag: string, commit: string }
type ReleaseAsset = { name: string, size: number, sha256: string }
type ReleaseManifest = ReleaseIdentity & { schemaVersion: 1, generatedAt: string, assets: ReleaseAsset[] }

export function createReleaseManifest(identity: ReleaseIdentity, directory: string): ReleaseManifest {
  if (!/^[\w.-]+\/[\w.-]+$/.test(identity.repository) || !/^v\d+\.\d+\.\d+(?:[-+][\w.+-]+)?$/.test(identity.tag) || !/^[a-f\d]{40}$/i.test(identity.commit))
    throw new Error('Release manifest requires repository, version tag, and full commit identity')
  const names = readdirSync(directory).filter(name => /^craft-.*\.zip$/.test(name)).sort()
  const missing = requiredAssets.filter(name => !names.includes(name))
  if (missing.length)
    throw new Error(`Missing release archives: ${missing.join(', ')}`)
  const assets = names.map((name) => {
    const path = join(directory, name)
    if (!lstatSync(path).isFile())
      throw new Error(`Release archive must be a regular file: ${name}`)
    const bytes = readFileSync(path)
    if (bytes.length === 0)
      throw new Error(`Release archive is empty: ${name}`)
    return { name, size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }
  })
  return { schemaVersion: 1, ...identity, generatedAt: new Date().toISOString(), assets }
}

export function verifyReleaseManifest(actual: unknown, expected: ReleaseManifest): void {
  if (!actual || typeof actual !== 'object')
    throw new Error('Release manifest must be an object')
  const manifest = actual as Partial<ReleaseManifest>
  for (const key of ['schemaVersion', 'repository', 'tag', 'commit'] as const) {
    if (manifest[key] !== expected[key])
      throw new Error(`Release manifest ${key} mismatch`)
  }
  if (!Array.isArray(manifest.assets) || manifest.assets.length !== expected.assets.length)
    throw new Error('Release manifest asset set mismatch')
  const seen = new Set<string>()
  for (const asset of manifest.assets) {
    const wanted = expected.assets.find(entry => entry.name === asset?.name)
    if (!wanted || seen.has(asset.name))
      throw new Error(`Unexpected or duplicate release asset: ${asset?.name}`)
    seen.add(asset.name)
    if (asset.size !== wanted.size || asset.sha256 !== wanted.sha256)
      throw new Error(`Release manifest size or SHA-256 mismatch: ${asset.name}`)
  }
}

if (import.meta.main) {
  const [mode, directory, path] = Bun.argv.slice(2)
  if (!directory || !path || !['create', 'verify'].includes(mode))
    throw new Error('Usage: bun scripts/release-manifest.ts <create|verify> <archive-directory> <manifest-path>')
  const manifest = createReleaseManifest({ repository: process.env.GITHUB_REPOSITORY ?? '', tag: process.env.GITHUB_REF_NAME ?? '', commit: process.env.GITHUB_SHA ?? '' }, directory)
  if (mode === 'create')
    writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`)
  else
    verifyReleaseManifest(JSON.parse(readFileSync(path, 'utf8')), manifest)
  console.log(`${mode === 'create' ? 'Created' : 'Verified'} manifest for ${manifest.assets.length} final release archives`)
}
