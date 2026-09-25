/**
 * Decides which vulnerability findings are Craft's to answer for.
 *
 * The full-repository SBOM covers the checkout, which means it inventories the
 * benchmark comparison apps and the development install as well as Craft. Every
 * High finding in it today comes from one of those: the Electron and Electrobun
 * benchmark lockfiles, and the Go runtime compiled into the TypeScript compiler
 * binary under `node_modules`. None reaches a published artifact.
 *
 * Counting them together produced the worst of both readings. The scan could not
 * fail on High without going permanently red over a benchmark's dependencies, so
 * High was left behind an opt-in flag and the job stayed green no matter what
 * arrived — the state #279 describes.
 *
 * Scope is the thing that separates them, so scope is what this decides. A
 * finding located only under a path that ships nothing is tooling inventory and
 * is reported. Anything else is Craft's, and fails.
 *
 * Deliberately not a retention list. Benchmark lockfiles and `node_modules`
 * versions move constantly, so a list of package-and-version entries would be
 * stale within days and its own ratchet would cry wolf every time a benchmark
 * dependency bumped. A path rule stays true across those bumps.
 *
 * The shipped side has its own gate: `scripts/scan-release-artifacts.ts` scans
 * the exact release archives with their resolved production dependencies. This
 * is the repository-wide half, and the two together are the division of labour
 * #279 asked for.
 */

/** Prefixes that ship nothing: a finding located only here is inventory. */
export const toolingPrefixes = [
  '/benchmarks/',
  '/node_modules/',
  '/examples/',
  '/artifacts/',
  '/.github/',
]

export type Finding = {
  package: string
  version: string
  severity: string
  id: string
  locations: string[]
}

const severities = ['Critical', 'High', 'Medium', 'Low', 'Negligible', 'Unknown'] as const

/** Severities Craft answers for. Below these, the report is inventory either way. */
const gated = ['Critical', 'High']

/**
 * Flatten a Grype report.
 *
 * Shares `scan-sbom.ts`'s refusal to read an absent or malformed result as a
 * clean scan: a scanner that fell over must not look like good news.
 */
export function collectFindings(report: unknown): Finding[] {
  if (!report || typeof report !== 'object' || Array.isArray(report))
    throw new Error('Invalid Grype report: expected an object')
  const matches = (report as { matches?: unknown }).matches
  if (!Array.isArray(matches))
    throw new Error('Invalid Grype report: matches must be an array; absent results are not a clean scan')
  return matches.map((match) => {
    const vulnerability = (match as { vulnerability?: Record<string, unknown> })?.vulnerability ?? {}
    const artifact = (match as { artifact?: Record<string, unknown> })?.artifact ?? {}
    const severity = vulnerability.severity
    if (typeof severity !== 'string' || !severities.includes(severity as typeof severities[number]))
      throw new Error(`Invalid Grype severity: ${JSON.stringify(severity)}`)
    if (typeof vulnerability.id !== 'string' || typeof artifact.name !== 'string')
      throw new Error('Malformed Grype match: vulnerability id and package name are required')
    const locations = Array.isArray(artifact.locations)
      ? artifact.locations.map(entry => (entry as { path?: unknown })?.path).filter((path): path is string => typeof path === 'string')
      : []
    return {
      package: artifact.name,
      version: typeof artifact.version === 'string' ? artifact.version : '',
      severity,
      id: vulnerability.id,
      locations,
    }
  })
}

/**
 * True when every location is under a prefix that ships nothing.
 *
 * "Every", not "any": a package present both in a benchmark and in Craft is
 * Craft's problem. A finding with no location at all is not classifiable and so
 * is never tooling — an unlocatable High should be looked at, not waved through.
 */
export function isToolingOnly(finding: Finding): boolean {
  if (!finding.locations.length) return false
  return finding.locations.every(path => toolingPrefixes.some(prefix => path.startsWith(prefix)))
}

export type ScopeReview = {
  /** Gated severities that reach a published artifact, or cannot be located. */
  shipped: Finding[]
  /** Gated severities confined to paths that ship nothing. */
  tooling: Finding[]
}

export function reviewScope(findings: Finding[]): ScopeReview {
  const review: ScopeReview = { shipped: [], tooling: [] }
  for (const finding of findings) {
    if (!gated.includes(finding.severity)) continue
    if (isToolingOnly(finding)) review.tooling.push(finding)
    else review.shipped.push(finding)
  }
  return review
}

export function assertShippingScope(report: unknown): ScopeReview {
  const review = reviewScope(collectFindings(report))
  if (review.shipped.length) {
    const detail = review.shipped
      .map(f => `${f.severity} ${f.package}@${f.version} ${f.id} (${f.locations.join(', ') || 'no recorded location'})`)
      .join('\n  - ')
    throw new Error(`${review.shipped.length} High or Critical findings are not confined to tooling paths:\n  - ${detail}`)
  }
  return review
}

if (import.meta.main) {
  const [path] = Bun.argv.slice(2)
  if (!path)
    throw new Error('Usage: bun scripts/sbom-scope.ts <grype-report.json>')
  const review = assertShippingScope(await Bun.file(path).json())
  const byPackage = new Map<string, number>()
  for (const finding of review.tooling)
    byPackage.set(`${finding.package}@${finding.version}`, (byPackage.get(`${finding.package}@${finding.version}`) ?? 0) + 1)
  const inventory = [...byPackage].map(([name, count]) => `${name} (${count})`).join(', ')
  console.log(`No High or Critical finding reaches a published artifact. Tooling inventory: ${review.tooling.length} findings across ${byPackage.size} packages${inventory ? ` — ${inventory}` : ''}`)
}
