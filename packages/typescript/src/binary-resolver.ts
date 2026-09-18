/**
 * Locate the `craft` native binary.
 *
 * The shipping contract is: **Craft is distributed via the pantry
 * registry**. `pantry install craft` (or any pantry-managed environment
 * that includes craft) puts the binary on PATH; the SDK and CLI then
 * just spawn `'craft'` directly. The previous "look in zig-out, then
 * fall back to PATH" probing is gone — it was load-bearing in the
 * monorepo dev loop, but consumers of the SDK / CLI should never see it.
 *
 * Two escape hatches remain, in order of precedence:
 *
 *   1. `config.craftPath` (SDK only): an explicit absolute path the
 *      caller pinned. Validated to exist; otherwise we throw.
 *   2. `CRAFT_BIN` env var: same idea, useful for tests and for the
 *      monorepo dev loop where the binary lives at
 *      `packages/zig/zig-out/bin/craft` and isn't yet a registry build.
 *
 * Everything else delegates to `'craft'` and lets the OS resolve PATH.
 * If the spawn produces ENOENT we surface a single, deterministic error
 * pointing at pantry — no path probing, no matrix of "we tried these
 * locations" output, just one canonical answer.
 */

import { existsSync } from 'node:fs'

/**
 * Resolve a `craft` binary path.
 *
 * @param explicit Optional caller-supplied absolute path (e.g. SDK
 *   `AppConfig.craftPath`). Required to exist when present.
 * @returns The string to pass to `spawn(...)`. Either `explicit`,
 *   `process.env.CRAFT_BIN`, or the bare `'craft'` for PATH lookup.
 */
export function resolveCraftBinary(explicit?: string): string {
  if (explicit) {
    if (!existsSync(explicit)) {
      throw new Error(`Custom Craft binary path not found: ${explicit}`)
    }
    return explicit
  }
  const fromEnv = typeof process !== 'undefined' ? process.env.CRAFT_BIN : undefined
  if (fromEnv) {
    if (!existsSync(fromEnv)) {
      throw new Error(`CRAFT_BIN points to ${fromEnv}, which does not exist`)
    }
    return fromEnv
  }
  // PATH lookup. The OS resolves `'craft'` to whatever pantry installed.
  return 'craft'
}

/**
 * Set on the child environment whenever the CLI spawns what it believes is
 * the native binary.
 *
 * `resolveCraftBinary()` returns the bare string `'craft'` and lets the OS
 * resolve it, which is the pantry contract and stays that way. But `craft` on
 * PATH is not always the native binary: install the SDK with a package manager
 * that publishes a `bin` entry and PATH may resolve `craft` to this very CLI
 * (`~/.bun/bin/craft`, a `#!/usr/bin/env bun` script). Spawning that re-enters
 * the TypeScript entry point with native-binary flags, and the user sees
 * `Unknown option --url` for an option they never typed.
 *
 * Probing for the binary elsewhere would answer it, but that is exactly the
 * path-matrix behaviour the pantry contract exists to remove. So instead the
 * spawn is marked, and a CLI that starts up already marked knows it *is* the
 * thing that was spawned, and says so.
 *
 * Both spawners set it: `runCraftBinary()` in the CLI, and `CraftApp.show()`
 * in the SDK. The SDK one was missing until #236, so every SDK caller on such
 * a machine still met the raw parser error this marker exists to replace.
 */
export const CRAFT_CLI_SPAWN_MARKER = 'CRAFT_CLI_SPAWNED_FROM'

/**
 * The message for that case. Names the offending PATH entry, because the whole
 * difficulty of the original report was that nothing pointed at PATH at all.
 */
export function craftBinaryIsCliShimMessage(spawnedFrom: string): string {
  return [
    `"${spawnedFrom}" on PATH is the Craft CLI, not the native binary.`,
    '',
    'Craft spawned it expecting the native build and reached this CLI instead —',
    'which is why an option you never typed (--url) came back as unknown.',
    '',
    'Fix it in one of two ways:',
    '',
    '  1. Install the native binary and make sure it comes first on PATH:',
    '',
    '       pantry install craft',
    '',
    '  2. Point CRAFT_BIN at a build directly:',
    '',
    '       CRAFT_BIN=/path/to/craft craft <url>',
    '',
    'For monorepo development, CRAFT_BIN is the supported way in.',
  ].join('\n')
}

/**
 * Build a deterministic, pantry-aware error for the case where the
 * spawn errored with ENOENT (binary not found on PATH). Used as the
 * `process.on('error', …)` handler in both the SDK and the CLI.
 */
export function craftBinaryNotFoundMessage(triedPath: string): string {
  return [
    `Craft native binary not found (tried "${triedPath}").`,
    '',
    'Craft ships through the pantry package registry. Install it with:',
    '',
    '  pantry install craft',
    '',
    'or, in a project, declare it in deps.yaml / pantry.jsonc and run',
    '  pantry install',
    '',
    'See https://pantry.dev/quickstart for pantry installation instructions.',
    'For monorepo development you can also point CRAFT_BIN at a local build.',
  ].join('\n')
}
