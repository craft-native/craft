/**
 * Record whether a release's native binaries are actually on the Pantry
 * binaries registry, separately from asking it to index them.
 *
 * The release workflow's `notify-registry` step POSTs `/api/rebuild` and logs
 * `queued for indexing`. That acknowledges a queue request. It is not
 * publication, and nothing downstream ever looked again — so a release can be
 * green end to end while `pantry install craft`, the documented distribution
 * channel, still serves an older version.
 *
 * This reads the canonical metadata route and writes a per-version,
 * per-platform receipt. It is deliberately not a gate: the issue that asked
 * for it (#454) is explicit that a strict consumer gate for this surface must
 * be intentional documented policy rather than an invented default. The
 * receipt makes the state visible; what to do about it stays a decision.
 *
 * Nothing in this repository uploads a platform binary to this registry, and
 * the receipt is worded accordingly. The `pantry` matrix builds the binaries
 * and stages them into a draft GitHub release; `publish-release` makes that
 * release public; `publish-pantry` publishes Zig source to a different
 * surface and, as its own comment says, "does not rebuild a platform binary".
 * The registry then repackages our published GitHub assets on its own
 * schedule: the 0.0.487 darwin-arm64 tarball it serves holds the same four
 * binaries as `craft-darwin-arm64.zip`, byte for byte, its tar entries are
 * owned by `runner`, and its `uploadedAt` is an hour and three quarters after
 * that release workflow finished. So an absent platform is the registry
 * declining to index an asset that is present and intact, not a publish of
 * ours that failed quietly (#454).
 *
 * The expected platforms are the matrix of the `pantry` job in release.yml —
 * the platforms this repository builds and ships archives for. That is a
 * statement of what ought to be available, not of what uploads them.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

/** The platforms release.yml's `pantry` job builds release archives for. */
export const publishedPantryPlatforms = ['darwin-arm64', 'linux-x86-64'] as const

export type PantryOutcome = 'available' | 'partial' | 'pending' | 'unavailable' | 'unreadable'

export interface PantryPlatformReceipt {
  platform: string
  present: boolean
  sha256?: string
  size?: number
  uploadedAt?: string
}

export interface PantryReceipt {
  version: string
  outcome: PantryOutcome
  latestVersion: string | null
  platforms: PantryPlatformReceipt[]
  note: string
}

/** Compare dotted numeric versions; unparseable segments order last. */
export function compareVersions(a: string, b: string): number {
  const parts = (value: string) => value.split('.').map(part => (/^\d+$/.test(part) ? Number(part) : Number.NaN))
  const left = parts(a), right = parts(b)
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const one = left[index] ?? 0, two = right[index] ?? 0
    if (Number.isNaN(one) || Number.isNaN(two)) return Number.isNaN(one) && Number.isNaN(two) ? 0 : Number.isNaN(one) ? 1 : -1
    if (one !== two) return one < two ? -1 : 1
  }
  return 0
}

/**
 * What the registry says about one version.
 *
 * An absent row is not one outcome but two, and the difference is the whole
 * point: a registry whose newest version is older than this one has not
 * reached it yet, while a registry that has already indexed something newer
 * skipped it. The first resolves itself; the second never will.
 */
export function assessPantryAvailability(
  metadata: unknown,
  version: string,
  expected: readonly string[] = publishedPantryPlatforms,
): PantryReceipt {
  if (!version || !expected.length) throw new Error('Pantry availability needs a version and at least one platform')
  const document = metadata as { latestVersion?: unknown, versions?: Record<string, { platforms?: Record<string, unknown> }> } | null
  if (!document || typeof document !== 'object' || typeof document.versions !== 'object' || document.versions === null || Array.isArray(document.versions)) {
    return { version, outcome: 'unreadable', latestVersion: null, platforms: [], note: 'Registry metadata is not in the documented shape; nothing is claimed about this version.' }
  }
  const latestVersion = typeof document.latestVersion === 'string' ? document.latestVersion : null
  const row = document.versions[version]
  const published = row && typeof row === 'object' ? row.platforms : undefined

  if (!published || typeof published !== 'object') {
    const behind = latestVersion !== null && compareVersions(latestVersion, version) < 0
    return {
      version,
      outcome: behind ? 'pending' : 'unavailable',
      latestVersion,
      platforms: expected.map(platform => ({ platform, present: false })),
      note: behind
        ? `The registry's newest version is ${latestVersion}, which is older than ${version}; indexing has not reached it. A reading taken as the release publishes is expected to say exactly this, because the registry indexes on its own schedule: 0.0.487's row appeared an hour and three quarters after its release workflow finished. Only a later reading distinguishes a slow index from a skipped one.`
        : `The registry has indexed ${latestVersion ?? 'an unknown version'} but has no row for ${version}; it was skipped rather than queued.`,
    }
  }

  const platforms = expected.map((platform) => {
    const entry = (published as Record<string, unknown>)[platform] as { sha256?: unknown, size?: unknown, uploadedAt?: unknown } | undefined
    const usable = !!entry && typeof entry === 'object' && typeof entry.sha256 === 'string' && /^[a-f0-9]{64}$/.test(entry.sha256) && typeof entry.size === 'number' && entry.size > 0
    return usable
      ? { platform, present: true, sha256: entry.sha256 as string, size: entry.size as number, uploadedAt: typeof entry.uploadedAt === 'string' ? entry.uploadedAt : undefined }
      : { platform, present: false }
  })
  const present = platforms.filter(entry => entry.present).length
  return {
    version,
    outcome: present === expected.length ? 'available' : present === 0 ? 'unavailable' : 'partial',
    latestVersion,
    platforms,
    note: present === expected.length
      ? `Every published platform is on the registry for ${version}.`
      : `${present} of ${expected.length} published platforms are on the registry for ${version}.`,
  }
}

/**
 * Which GitHub release asset a registry platform is repackaged from.
 *
 * The registry's names are Pantry's; the asset names are the release
 * workflow's. Every platform the `pantry` matrix builds needs an entry here
 * or the binding below has nothing to compare against, which is what the
 * accompanying test checks rather than trusting this list to stay complete.
 */
export const pantryPlatformAssets: Record<string, string> = {
  'darwin-arm64': 'craft-darwin-arm64.zip',
  'darwin-x86-64': 'craft-darwin-x64.zip',
  'linux-x86-64': 'craft-linux-x64.zip',
  'windows-x86-64': 'craft-windows-x64.zip',
}

export interface PantryByteBinding {
  platform: string
  bound: boolean
  binaries: { name: string, sha256: string | null, registrySha256: string | null, matches: boolean }[]
  note: string
}

/**
 * Bind the bytes the registry serves to the bytes this repository published.
 *
 * #454 asked for available bytes to be bound to the already verified GitHub
 * profiles, and an earlier pass on it recorded that as impossible: the
 * release's `.zip` digest and the registry's `.tar.gz` digest describe
 * different containers and will never agree. That is true of the containers
 * and false of the contents. The registry repackages our asset, so the
 * binaries inside the two archives are the same bytes under the same names,
 * and comparing them per binary is a real binding rather than a profile
 * match.
 *
 * Both sides must be non-empty and name the same binaries. A registry
 * archive holding a subset, a superset, or a binary of the same name with
 * different bytes is not bound, and the note says which.
 */
export function bindPantryBytes(
  platform: string,
  published: Record<string, string>,
  served: Record<string, string>,
): PantryByteBinding {
  const names = [...new Set([...Object.keys(published), ...Object.keys(served)])].sort()
  if (!names.length) {
    return { platform, bound: false, binaries: [], note: `Neither archive for ${platform} held a binary; nothing is claimed about its bytes.` }
  }
  const binaries = names.map((name) => {
    const ours = published[name] ?? null, theirs = served[name] ?? null
    return { name, sha256: ours, registrySha256: theirs, matches: ours !== null && ours === theirs }
  })
  const missing = binaries.filter(entry => entry.registrySha256 === null).map(entry => entry.name)
  const extra = binaries.filter(entry => entry.sha256 === null).map(entry => entry.name)
  const differing = binaries.filter(entry => entry.sha256 !== null && entry.registrySha256 !== null && entry.sha256 !== entry.registrySha256).map(entry => entry.name)
  const bound = !missing.length && !extra.length && !differing.length
  const faults = [
    missing.length ? `absent from the registry archive: ${missing.join(', ')}` : '',
    extra.length ? `in the registry archive only: ${extra.join(', ')}` : '',
    differing.length ? `different bytes under the same name: ${differing.join(', ')}` : '',
  ].filter(Boolean)
  return {
    platform,
    bound,
    binaries,
    note: bound
      ? `The registry serves the same ${binaries.length} ${binaries.length === 1 ? 'binary' : 'binaries'} this release published for ${platform}, byte for byte.`
      : `The registry's ${platform} archive is not the one this release published — ${faults.join('; ')}.`,
  }
}

/**
 * sha256 of every file in a directory tree, keyed by basename.
 *
 * Basename rather than path on purpose: the release asset holds the binaries
 * flat and the registry archive holds them under `bin/`, so the paths differ
 * while the binaries do not. A duplicate basename would silently collapse
 * two files into one, so it throws instead.
 */
export function digestBinaries(directory: string): Record<string, string> {
  const digests: Record<string, string> = {}
  for (const path of readdirSync(directory, { recursive: true, withFileTypes: true })) {
    if (!path.isFile()) continue
    const name = path.name
    if (name in digests) throw new Error(`Two files named ${name} under ${directory}; a basename digest would hide one`)
    digests[name] = new Bun.CryptoHasher('sha256').update(readFileSync(join(path.parentPath ?? path.path, name))).digest('hex')
  }
  return digests
}

/**
 * Fetch both archives for one platform and bind their bytes.
 *
 * Downloads are unpacked into their own directory and only read, never run.
 * `null` when either archive cannot be fetched: an unreachable registry is
 * not evidence of wrong bytes.
 */
export async function bindPublishedPlatform(version: string, platform: string, workspace: string): Promise<PantryByteBinding | null> {
  const asset = pantryPlatformAssets[platform]
  if (!asset) return null
  const { mkdirSync, rmSync } = await import('node:fs')
  const zip = join(workspace, asset), tarball = join(workspace, `${platform}.tar.gz`)
  const fromAsset = join(workspace, `asset-${platform}`), fromRegistry = join(workspace, `registry-${platform}`)
  try {
    mkdirSync(fromAsset, { recursive: true })
    mkdirSync(fromRegistry, { recursive: true })
    const release = await fetch(`https://github.com/craft-native/craft/releases/download/v${version}/${asset}`, { redirect: 'follow', signal: AbortSignal.timeout(300_000) })
    if (!release.ok) return null
    await Bun.write(zip, release)
    const served = await fetch(`https://registry.pantry.dev/binaries/craft-native.org/${version}/${platform}/craft-native.org-${version}.tar.gz`, { redirect: 'follow', signal: AbortSignal.timeout(300_000) })
    if (!served.ok) return null
    await Bun.write(tarball, served)
    for (const command of [['unzip', '-qo', zip, '-d', fromAsset], ['tar', 'xzf', tarball, '-C', fromRegistry]]) {
      const run = Bun.spawnSync(command, { stdout: 'pipe', stderr: 'pipe', timeout: 300_000 })
      if (run.exitCode !== 0) return null
    }
    return bindPantryBytes(platform, digestBinaries(fromAsset), digestBinaries(fromRegistry))
  }
  catch { return null }
  finally {
    for (const path of [zip, tarball, fromAsset, fromRegistry]) rmSync(path, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const argv = Bun.argv.slice(2)
  // Off by default: binding downloads both archives for every available
  // platform, which is tens of megabytes a release for a receipt that
  // deliberately gates nothing.
  const bind = argv.includes('--bind')
  const [version, output] = argv.filter(argument => argument !== '--bind')
  if (!version) throw new Error('Usage: pantry-availability.ts <version> [receipt path] [--bind]')
  const url = 'https://registry.pantry.dev/binaries/craft-native.org/metadata.json'
  let metadata: unknown = null
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(30_000) })
    metadata = response.ok ? await response.json() : null
  }
  catch { metadata = null }
  const receipt: PantryReceipt & { bindings?: PantryByteBinding[] } = assessPantryAvailability(metadata, version)
  if (bind) {
    const { mkdtempSync, rmSync } = await import('node:fs')
    const { tmpdir } = await import('node:os')
    const workspace = mkdtempSync(join(tmpdir(), 'pantry-bind-'))
    try {
      const bindings: PantryByteBinding[] = []
      for (const platform of receipt.platforms.filter(entry => entry.present)) {
        const binding = await bindPublishedPlatform(version, platform.platform, workspace)
        if (binding) bindings.push(binding)
      }
      receipt.bindings = bindings
    }
    finally { rmSync(workspace, { recursive: true, force: true }) }
  }
  const text = `${JSON.stringify(receipt, null, 2)}\n`
  if (output) await Bun.write(output, text)
  console.log(text)
  // Best effort by design: report, never fail the release.
}
