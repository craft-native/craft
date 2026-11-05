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
 * The expected platforms are not guessed either. They are the matrix of the
 * `pantry` job in release.yml, which is what actually publishes binaries —
 * `publish-pantry` is a different surface that packages Zig source and, as
 * its own comment says, "does not rebuild a platform binary".
 */

/** The platforms release.yml's `pantry` job publishes binaries for. */
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
        ? `The registry's newest version is ${latestVersion}, which is older than ${version}; indexing has not reached it.`
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

if (import.meta.main) {
  const [version, output] = Bun.argv.slice(2)
  if (!version) throw new Error('Usage: pantry-availability.ts <version> [receipt path]')
  const url = 'https://registry.pantry.dev/binaries/craft-native.org/metadata.json'
  let metadata: unknown = null
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(30_000) })
    metadata = response.ok ? await response.json() : null
  }
  catch { metadata = null }
  const receipt = assessPantryAvailability(metadata, version)
  const text = `${JSON.stringify(receipt, null, 2)}\n`
  if (output) await Bun.write(output, text)
  console.log(text)
  // Best effort by design: report, never fail the release.
}
