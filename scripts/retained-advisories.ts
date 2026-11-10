/**
 * Advisories this repository knowingly ships with, and why each is unreachable.
 *
 * An entry here is a review, not a mute. `scripts/advisory-policy.ts` fails the
 * build when one expires, when it stops matching a real advisory, and when an
 * advisory appears that nobody has reviewed — so the list cannot quietly become
 * the reason a scan is green.
 *
 * What may be retained: an advisory in a package that reaches no published
 * artifact. What may not: anything high or critical, which the policy refuses
 * regardless of what is written here.
 *
 * Adding an entry means answering one question in `reason`: by what path would
 * an installed Craft package reach this code? If the answer is "it would", the
 * advisory gets fixed instead.
 */

export type RetainedAdvisory = {
  /** Bun's numeric advisory id, which is what the report is keyed by. */
  id: number
  /** The package the advisory is against, as the report names it. */
  package: string
  /** The GHSA identifier, for a human following this up. */
  ghsa: string
  /** Why an installed Craft package cannot reach it. */
  reason: string
  /** When this was last reviewed, ISO date. */
  reviewed: string
  /** When the reasoning must be re-examined, ISO date. Past this, the build fails. */
  expires: string
}

/**
 * `esbuild` arrives under `tsup`, which builds `@craft-native/react` and is a
 * devDependency of that workspace. No published tarball contains esbuild, and
 * the advisory is a development-server file read on Windows — a machine and a
 * process that no consumer of a Craft package runs.
 *
 * Not fixed rather than fixed, deliberately: the only in-range remedy bun
 * offers is a *downgrade* to 0.27.2, which falls below the advisory window
 * instead of rising above it. Moving the build toolchain backwards to satisfy a
 * scanner is a worse position than this entry. A `tsup` release that resolves
 * esbuild >= 0.28.1 removes the finding properly, and buddy-bot will carry it.
 */
const esbuildDevServer: RetainedAdvisory[] = [
  {
    id: 1120680,
    package: 'esbuild',
    ghsa: 'GHSA-g7r4-m6w7-qqqr',
    reason: 'Dev-only under tsup, in no published tarball; the advisory needs a Windows dev server, and the only in-range fix is a downgrade to 0.27.2.',
    reviewed: '2026-09-25',
    expires: '2026-12-31',
  },
]

/*
 * The six Svelte renderer advisories that lived here are gone, not waived.
 *
 * They were retained because "there is nothing to move to inside the supported
 * range": the first unaffected version was 5.55.7 and the declared peer range
 * stopped at `^4.0.0`. The note added that closing them "means widening that
 * range to Svelte 5, which breaks every consumer on 3.x or 4.x", and left it as
 * an API decision.
 *
 * That premise was wrong. Widening to `^3.0.0 || ^4.0.0 || ^5.0.0` adds a major
 * rather than dropping two, so no consumer on 3.x or 4.x loses anything — the
 * cap was what held them on a vulnerable Svelte, which is the opposite of what
 * the retention assumed. The range was widened in ba5cb82f and the adapter's
 * own devDependency now resolves 5.57.3, so the advisories no longer match any
 * installed version and this file's own stale-retention check reported them.
 *
 * The retention's other reasoning held up and is worth keeping on record:
 * Svelte is never bundled into a published Craft artifact, so a consumer's
 * exposure was always their own Svelte rather than ours.
 */

export const retainedAdvisories: RetainedAdvisory[] = [...esbuildDevServer]
