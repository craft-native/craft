/**
 * Copy the root package.json version into the manifests bumpx does not know:
 * packages/zig/build.zig.zon and packages/zig/pantry.json.
 *
 * The Releaser's first gate (scripts/release-version.ts) requires every one of
 * them to equal the tag. bumpx only rewrites package.json files, so a release
 * cut with `bun run release:patch` tagged v0.0.93 with the Zig manifests still
 * at 0.0.92 and was refused before anything built. release:patch runs this
 * through bumpx's --execute, after the bump and before the commit.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

export function syncReleaseVersion(root: string): string {
  const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version as string

  const zonPath = join(root, 'packages/zig/build.zig.zon')
  const zon = readFileSync(zonPath, 'utf8')
  if (!/\.version\s*=\s*"[^"]+"/.test(zon))
    throw new Error(`${zonPath} has no .version field to update`)
  writeFileSync(zonPath, zon.replace(/(\.version\s*=\s*")[^"]+(")/, `$1${version}$2`))

  const pantryPath = join(root, 'packages/zig/pantry.json')
  const pantry = readFileSync(pantryPath, 'utf8')
  // Replace in place rather than re-serialising, so formatting and key order survive.
  if (!/"version"\s*:\s*"[^"]+"/.test(pantry))
    throw new Error(`${pantryPath} has no "version" field to update`)
  writeFileSync(pantryPath, pantry.replace(/("version"\s*:\s*")[^"]+(")/, `$1${version}$2`))

  return version
}

if (import.meta.main)
  console.log(`Synced Zig manifests to ${syncReleaseVersion(resolve(import.meta.dir, '..'))}`)
