/**
 * Turns `bun audit --json` into a decision, so a dependency advisory is either
 * fixed or reviewed, never merely unnoticed.
 *
 * The scan this replaces reported counts and stayed green. Counting is not a
 * policy: a report of six moderate findings looks the same on the day a seventh
 * arrives. This fails on anything nobody has looked at, and on any review that
 * has gone stale, so the green state means "reviewed" rather than "nothing
 * critical today".
 *
 * Note what is deliberately absent: `bun audit fix`. It is willing to *downgrade*
 * a package to fall below an advisory window and report that as fixed, which is
 * why remediation stays a human decision and this only ever reports.
 */

import type { RetainedAdvisory } from './retained-advisories'

/** One advisory against one package, flattened out of the report's per-package keys. */
export type Advisory = {
  package: string
  id: number
  severity: string
  title: string
  url: string
}

const severities = ['critical', 'high', 'moderate', 'low', 'info'] as const

/** Severities that may never be retained, whatever the reasoning says. */
const unretainable = ['critical', 'high']

/**
 * Flatten and validate the report.
 *
 * Validation is not ceremony here: a scanner that fails, or a future Bun that
 * changes this shape, must not read as an empty report. Anything unrecognised
 * throws rather than defaulting to zero findings.
 */
export function collectAdvisories(report: unknown): Advisory[] {
  if (!report || typeof report !== 'object' || Array.isArray(report))
    throw new Error('Invalid bun audit report: expected an object keyed by package name')
  const advisories: Advisory[] = []
  for (const [name, list] of Object.entries(report as Record<string, unknown>)) {
    if (!Array.isArray(list))
      throw new Error(`Invalid bun audit report: ${name} does not list advisories`)
    for (const entry of list) {
      const advisory = entry as Partial<Advisory>
      if (typeof advisory?.id !== 'number' || typeof advisory?.severity !== 'string')
        throw new Error(`Invalid bun audit advisory for ${name}: missing id or severity`)
      if (!severities.includes(advisory.severity as typeof severities[number]))
        throw new Error(`Invalid bun audit severity for ${name}: ${advisory.severity}`)
      advisories.push({
        package: name,
        id: advisory.id,
        severity: advisory.severity,
        title: typeof advisory.title === 'string' ? advisory.title : '',
        url: typeof advisory.url === 'string' ? advisory.url : '',
      })
    }
  }
  return advisories
}

export type AdvisoryReview = {
  /** Reviewed, unreachable, and still in date. */
  retained: Advisory[]
  /** Nobody has reviewed these. Any one of them fails the gate. */
  unreviewed: Advisory[]
  /** Reviewed once, but the review is past its expiry date. */
  expired: RetainedAdvisory[]
  /** Retained entries that match no current advisory, so the note is stale. */
  stale: RetainedAdvisory[]
  /** High or critical findings, which are never retainable. */
  blocking: Advisory[]
}

export function reviewAdvisories(advisories: Advisory[], retained: RetainedAdvisory[], today: string): AdvisoryReview {
  const byId = new Map(retained.map(entry => [`${entry.package}#${entry.id}`, entry]))
  const seen = new Set<string>()
  const review: AdvisoryReview = { retained: [], unreviewed: [], expired: [], stale: [], blocking: [] }

  for (const advisory of advisories) {
    const key = `${advisory.package}#${advisory.id}`
    const entry = byId.get(key)
    if (unretainable.includes(advisory.severity)) {
      review.blocking.push(advisory)
      if (entry) seen.add(key)
      continue
    }
    if (!entry) {
      review.unreviewed.push(advisory)
      continue
    }
    seen.add(key)
    if (entry.expires < today) review.expired.push(entry)
    else review.retained.push(advisory)
  }

  for (const entry of retained) {
    if (!seen.has(`${entry.package}#${entry.id}`)) review.stale.push(entry)
  }
  return review
}

/** Throw a message that says which of the four ways the policy was broken. */
export function assertAdvisoryPolicy(report: unknown, retained: RetainedAdvisory[], today: string): AdvisoryReview {
  const review = reviewAdvisories(collectAdvisories(report), retained, today)
  const problems: string[] = []
  if (review.blocking.length)
    problems.push(`${review.blocking.length} high or critical advisories, which cannot be retained: ${review.blocking.map(a => `${a.package} ${a.url || a.id}`).join(', ')}`)
  if (review.unreviewed.length)
    problems.push(`${review.unreviewed.length} advisories nobody has reviewed; add them to scripts/retained-advisories.ts with a reason, or fix them: ${review.unreviewed.map(a => `${a.package} ${a.url || a.id}`).join(', ')}`)
  if (review.expired.length)
    problems.push(`${review.expired.length} retentions are past review; re-examine and move the expiry: ${review.expired.map(e => `${e.package} ${e.ghsa} expired ${e.expires}`).join(', ')}`)
  if (review.stale.length)
    problems.push(`${review.stale.length} retentions match no current advisory and should be deleted: ${review.stale.map(e => `${e.package} ${e.ghsa}`).join(', ')}`)
  if (problems.length)
    throw new Error(`Dependency advisory policy failed.\n- ${problems.join('\n- ')}`)
  return review
}

if (import.meta.main) {
  const { retainedAdvisories } = await import('./retained-advisories')
  const audit = Bun.spawnSync(['bun', 'audit', '--json'], { stdout: 'pipe', stderr: 'pipe' })
  const text = audit.stdout.toString().trim()
  // No advisories at all is a valid, empty report rather than a scanner failure.
  const report: unknown = text.length ? JSON.parse(text) : {}
  const today = new Date().toISOString().slice(0, 10)
  const review = assertAdvisoryPolicy(report, retainedAdvisories, today)
  console.log(`Advisory policy satisfied: ${review.retained.length} reviewed and unreachable, 0 unreviewed, 0 expired`)
}
