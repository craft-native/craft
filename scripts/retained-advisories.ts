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

/**
 * Svelte is a peer and dev dependency of `@craft-native/svelte`, whose
 * published `files` are `dist` and `src`. The framework itself is never
 * bundled, so an installed Craft package carries no Svelte code; the version a
 * consumer runs is the one they chose, and these advisories are theirs to
 * resolve against their own Svelte.
 *
 * Every one is an SSR or DOM-clobbering issue in Svelte's own renderer, which
 * the binding does not call: it wraps the Craft bridge, not Svelte's compiler
 * or its server renderer.
 *
 * Kept rather than remedied because there is nothing to move to inside the
 * supported range. The advisories reach up to 5.55.6, so the first unaffected
 * version is 5.55.7 — outside the declared peer range `^3.0.0 || ^4.0.0`
 * entirely. Closing them means widening that range to Svelte 5, which breaks
 * every consumer on 3.x or 4.x. That is an API decision about what the binding
 * supports, and it should be made for its own reasons rather than to satisfy a
 * scanner about code Craft does not ship.
 */
const svelteRenderer: RetainedAdvisory[] = [
  { id: 1113416, package: 'svelte', ghsa: 'GHSA-crpf-4hrx-3jrp', reason: 'SSR attribute spreading; Svelte is a peer dependency and is bundled in no published artifact.', reviewed: '2026-09-25', expires: '2026-12-31' },
  { id: 1113418, package: 'svelte', ghsa: 'GHSA-m56q-vw4c-c2cp', reason: 'SSR dynamic element tag names; peer dependency only, and the binding never invokes Svelte SSR.', reviewed: '2026-09-25', expires: '2026-12-31' },
  { id: 1113419, package: 'svelte', ghsa: 'GHSA-f7gr-6p89-r883', reason: 'XSS via SSR spread attributes; peer dependency only, not bundled.', reviewed: '2026-09-25', expires: '2026-12-31' },
  { id: 1120446, package: 'svelte', ghsa: 'GHSA-rcqx-6q8c-2c42', reason: 'DOM clobbering of Svelte internal state; peer dependency only, and no patched version exists inside the supported range.', reviewed: '2026-09-25', expires: '2026-12-31' },
  { id: 1120449, package: 'svelte', ghsa: 'GHSA-pr6f-5x2q-rwfp', reason: 'XSS via SSR spread attributes; peer dependency only, and no patched version exists inside the supported range.', reviewed: '2026-09-25', expires: '2026-12-31' },
  { id: 1114402, package: 'svelte', ghsa: 'GHSA-phwv-c562-gvmh', reason: 'XSS during SSR with contenteditable bindings; peer dependency only, and the binding exposes no such binding.', reviewed: '2026-09-25', expires: '2026-12-31' },
]

export const retainedAdvisories: RetainedAdvisory[] = [...esbuildDevServer, ...svelteRenderer]
