/**
 * macOS application bundle mechanics for the updater.
 *
 * Replacing a running `.app` is not a file copy. Three things make it its own
 * problem, and every one of them has a wrong answer that looks like it works:
 *
 *   **Trust.** A downloaded bundle is only safe to run if macOS itself says
 *   so. A SHA-256 from the manifest proves the bytes match what the manifest
 *   claimed — it says nothing about who published them, because whoever
 *   controls the manifest controls both numbers. `codesign` and `spctl` are
 *   the checks Gatekeeper performs on first launch; doing them *before* the
 *   swap turns "the user gets a scary dialog after we already deleted their
 *   app" into "we declined to install it."
 *
 *   **Copying.** `cp -r` — and `fs.cpSync` — drop extended attributes and
 *   ACLs, which is enough to invalidate a code signature. `ditto` is the only
 *   copy on macOS that preserves everything a signed bundle needs.
 *
 *   **Atomicity.** Deleting the installed app and then copying the new one in
 *   leaves the user with no app at all if anything fails in between: a full
 *   disk, a kernel panic, a killed process. Two renames within one directory
 *   are the closest thing POSIX offers to an exchange, and they leave the old
 *   bundle intact until the new one is in place.
 */

import { execFile, execFileSync } from 'child_process'
import { accessSync, constants, existsSync, mkdtempSync, renameSync, rmSync, statSync } from 'fs'
import { tmpdir } from 'os'
import { basename, dirname, join } from 'path'
import { promisify } from 'util'

const execFileAsync = promisify(execFile)

/** What a bundle's code signature says about who produced it. */
export interface BundleIdentity {
  /** Bundle identifier, e.g. `org.stacksjs.system-cleaner`. */
  identifier: string | null
  /** Apple Developer Team ID, e.g. `3JJRNQW6B7`. */
  teamId: string | null
  /** Leaf signing authority, e.g. `Developer ID Application: Jane Doe (ABCDE12345)`. */
  authority: string | null
}

export interface BundleTrustPolicy {
  /**
   * Team ID the bundle must be signed by.
   *
   * This is the check that matters. Notarization proves Apple scanned the
   * bundle; it does not prove *you* published it, and any Developer ID
   * account can get a build notarized. Pinning the team turns "signed by
   * someone" into "signed by us".
   */
  teamId?: string
  /**
   * Require Gatekeeper to accept the bundle outright. Defaults to true.
   *
   * Turn it off only where the assessment cannot succeed by construction —
   * a locally built, ad-hoc signed bundle under test.
   */
  requireNotarized?: boolean
}

export type BundleTrustFailure =
  | 'unreadable'
  | 'codesign-invalid'
  | 'gatekeeper-rejected'
  | 'team-mismatch'

export interface BundleTrustResult {
  ok: boolean
  identity: BundleIdentity
  /** Gatekeeper's verdict line, e.g. `source=Notarized Developer ID`. */
  gatekeeperSource: string | null
  reason?: BundleTrustFailure
  detail?: string
}

/** True on macOS, where every function in this module is meaningful. */
export function isMacOS(): boolean {
  return process.platform === 'darwin'
}

/**
 * Read the code signature's own account of a bundle.
 *
 * `codesign -dv` writes its report to stderr, not stdout — an easy detail to
 * get wrong, and the failure mode is a parser that silently matches nothing
 * and reports every field as null.
 */
export async function readBundleIdentity(appPath: string): Promise<BundleIdentity> {
  const empty: BundleIdentity = { identifier: null, teamId: null, authority: null }
  if (!isMacOS())
    return empty

  let report: string
  try {
    const { stderr, stdout } = await execFileAsync('codesign', ['-dv', '--verbose=4', appPath])
    report = `${stderr}\n${stdout}`
  }
  catch (error) {
    // An unsigned bundle exits non-zero and still prints what it knows.
    const e = error as { stderr?: string, stdout?: string }
    report = `${e.stderr ?? ''}\n${e.stdout ?? ''}`
    if (!report.trim())
      return empty
  }

  const field = (name: string): string | null => {
    const match = report.match(new RegExp(`^${name}=(.+)$`, 'm'))
    if (!match)
      return null
    const value = match[1].trim()
    // `codesign` writes the literal `not set` for a field a signature does not
    // carry — an ad-hoc signature has no team, and so does a platform binary.
    // Passing that through makes `not set` look like a Team ID, which is a
    // string a trust policy could be misconfigured to match.
    return value === 'not set' || value.length === 0 ? null : value
  }

  return {
    identifier: field('Identifier'),
    teamId: field('TeamIdentifier'),
    // The leaf comes first; the two above it are the intermediate and root.
    authority: field('Authority'),
  }
}

/**
 * Decide whether a bundle is safe to install, using the checks macOS itself
 * would run at launch.
 *
 * Order matters. The signature has to be structurally valid before its claims
 * about a team mean anything, and Gatekeeper's assessment subsumes the
 * signature check but reports a coarser reason — so run `codesign` first and
 * let it produce the specific complaint.
 */
export async function verifyBundleTrust(
  appPath: string,
  policy: BundleTrustPolicy = {},
): Promise<BundleTrustResult> {
  const identity = await readBundleIdentity(appPath)
  const requireNotarized = policy.requireNotarized ?? true

  if (!existsSync(appPath)) {
    return { ok: false, identity, gatekeeperSource: null, reason: 'unreadable', detail: `No such bundle: ${appPath}` }
  }

  try {
    await execFileAsync('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath])
  }
  catch (error) {
    return {
      ok: false,
      identity,
      gatekeeperSource: null,
      reason: 'codesign-invalid',
      detail: describe(error),
    }
  }

  let gatekeeperSource: string | null = null
  if (requireNotarized) {
    try {
      // `-t exec` is the assessment an application gets. `-vv` is what prints
      // the `source=` line; without it a pass says only "accepted".
      const { stderr, stdout } = await execFileAsync('spctl', ['-a', '-t', 'exec', '-vv', appPath])
      const report = `${stderr}\n${stdout}`
      gatekeeperSource = report.match(/^source=(.+)$/m)?.[1]?.trim() ?? null
    }
    catch (error) {
      return {
        ok: false,
        identity,
        gatekeeperSource: null,
        reason: 'gatekeeper-rejected',
        detail: describe(error),
      }
    }
  }

  if (policy.teamId && identity.teamId !== policy.teamId) {
    return {
      ok: false,
      identity,
      gatekeeperSource,
      reason: 'team-mismatch',
      detail: `Expected Team ID ${policy.teamId}, bundle is signed by ${identity.teamId ?? 'nobody'}`,
    }
  }

  return { ok: true, identity, gatekeeperSource }
}

/**
 * Drop the quarantine flag a download carries.
 *
 * Only ever call this on a bundle that has already passed
 * `verifyBundleTrust` — the flag exists so Gatekeeper gets a chance to run,
 * and clearing it beforehand is how an updater becomes a way to install
 * anything at all. Afterwards it is redundant: the assessment it would have
 * triggered has already happened, and leaving it set makes the app the user
 * just updated ask permission to open.
 */
export async function clearQuarantine(appPath: string): Promise<void> {
  if (!isMacOS())
    return
  try {
    await execFileAsync('xattr', ['-d', '-r', 'com.apple.quarantine', appPath])
  }
  catch {
    // `xattr -d` exits non-zero when the attribute was not there, which is
    // the common case for a bundle we extracted ourselves.
  }
}

/**
 * Copy a bundle the way macOS expects, preserving what the signature covers.
 *
 * `ditto` rather than `cp -R` or `fs.cpSync`: both of those drop extended
 * attributes and ACLs, and a bundle missing them fails `codesign --verify`
 * even though every byte of every file is identical.
 */
export async function dittoBundle(source: string, destination: string): Promise<void> {
  await execFileAsync('ditto', [source, destination])
}

/** Where an extracted bundle ended up, and how to clean up after it. */
export interface StagedBundle {
  /** Path to the `.app` inside the staging directory. */
  appPath: string
  /** Directory holding it. Remove this when done. */
  stagingDir: string
}

/**
 * Pull the single `.app` out of a mounted image or an archive directory.
 *
 * Depth-limited on purpose: an `.app` contains other bundles (helpers, XPC
 * services, and in a Craft app the runtime), so an unbounded search finds a
 * nested one and installs a fragment of the update over the whole app.
 */
function findTopLevelApp(root: string): string | null {
  // `find -maxdepth 2` covers both shapes we produce: `Foo.app` at the root of
  // a DMG, and `payload/Foo.app` from an archive that carried a wrapper dir.
  const out = execFileSync('find', [root, '-maxdepth', '2', '-name', '*.app', '-type', 'd', '-print0'])
  const parts = out.toString('utf-8').split('\0').filter(s => s.length > 0)
  // Shallowest wins, so a wrapper directory never outranks the real bundle.
  parts.sort((a, b) => a.split('/').length - b.split('/').length)
  return parts[0] ?? null
}

/**
 * Mount a disk image, copy the app out, unmount.
 *
 * The mount point is one we create rather than one we parse out of
 * `hdiutil`'s output. Reading it back invites two bugs that only appear in
 * the field: a volume name with a newline in it, and a second copy of the
 * same image already mounted at `/Volumes/Name 1`.
 */
export async function extractBundleFromDmg(dmgPath: string, stagingDir?: string): Promise<StagedBundle> {
  const staging = stagingDir ?? mkdtempSync(join(tmpdir(), 'craft-update-'))
  const mountPoint = mkdtempSync(join(tmpdir(), 'craft-mount-'))
  let mounted = false

  try {
    await execFileAsync('hdiutil', ['attach', dmgPath, '-nobrowse', '-readonly', '-mountpoint', mountPoint])
    mounted = true

    const source = findTopLevelApp(mountPoint)
    if (!source)
      throw new Error(`No .app found in disk image: ${dmgPath}`)

    const appPath = join(staging, basename(source))
    await dittoBundle(source, appPath)
    return { appPath, stagingDir: staging }
  }
  finally {
    if (mounted) {
      try { await execFileAsync('hdiutil', ['detach', mountPoint, '-force']) }
      catch { /* the image is gone either way; leaking a mount is worse than ignoring this */ }
    }
    try { rmSync(mountPoint, { recursive: true, force: true }) }
    catch { /* best effort */ }
  }
}

/**
 * Unpack a zipped bundle.
 *
 * `ditto -x -k` rather than `unzip`: it is the counterpart of the `ditto -c
 * -k` that produces these archives, and it is the only unzip on macOS that
 * restores the extended attributes a code signature is computed over.
 */
export async function extractBundleFromZip(zipPath: string, stagingDir?: string): Promise<StagedBundle> {
  const staging = stagingDir ?? mkdtempSync(join(tmpdir(), 'craft-update-'))
  const unpacked = join(staging, 'payload')

  await execFileAsync('ditto', ['-x', '-k', zipPath, unpacked])

  const source = findTopLevelApp(unpacked)
  if (!source)
    throw new Error(`No .app found in archive: ${zipPath}`)

  return { appPath: source, stagingDir: staging }
}

/** Extract whichever container the download turned out to be. */
export async function extractBundle(archivePath: string, stagingDir?: string): Promise<StagedBundle> {
  if (archivePath.endsWith('.dmg'))
    return extractBundleFromDmg(archivePath, stagingDir)
  if (archivePath.endsWith('.zip'))
    return extractBundleFromZip(archivePath, stagingDir)
  throw new Error(`Cannot extract an app bundle from ${archivePath}`)
}

export interface SwapResult {
  /** Where the replaced bundle was moved to, if it is still there. */
  previousPath: string | null
}

/**
 * Put `stagedPath` where `installedPath` is, without ever leaving that path
 * empty for longer than a rename takes.
 *
 * The sequence is: get the new bundle onto the destination's own volume,
 * rename the old one aside, rename the new one in, then delete the old one.
 * Only the middle two steps touch the path the user launches, they are both
 * renames within one directory, and if the second fails the first is undone.
 *
 * `rename` is what buys that. It is atomic within a filesystem, so there is no
 * moment where a half-copied bundle sits at the app's path — which is exactly
 * what `rm -rf app && cp -R new app` produces when it is interrupted.
 */
export async function swapBundle(stagedPath: string, installedPath: string): Promise<SwapResult> {
  if (!existsSync(stagedPath))
    throw new Error(`Staged bundle is missing: ${stagedPath}`)

  const parent = dirname(installedPath)
  const stamp = `${Date.now()}.${process.pid}`
  const incoming = join(parent, `.${basename(installedPath)}.${stamp}.incoming`)
  const retired = join(parent, `.${basename(installedPath)}.${stamp}.retired`)

  // Step 1: land the new bundle on the destination volume. `rename` across
  // filesystems fails with EXDEV, which is the common case here — staging
  // happens in the OS temp directory, and on macOS that is frequently a
  // different volume from /Applications.
  try {
    renameSync(stagedPath, incoming)
  }
  catch {
    await dittoBundle(stagedPath, incoming)
  }

  const hadPrevious = existsSync(installedPath)

  try {
    // Step 2 and 3: the only window where the launch path is not a bundle.
    if (hadPrevious)
      renameSync(installedPath, retired)

    try {
      renameSync(incoming, installedPath)
    }
    catch (error) {
      if (hadPrevious) {
        // Put the user's app back before reporting the failure. A rollback
        // that throws its own error would hide the real one, so it is
        // deliberately best-effort.
        try { renameSync(retired, installedPath) }
        catch { /* nothing further we can do; the original error is the useful one */ }
      }
      throw error
    }
  }
  catch (error) {
    try { rmSync(incoming, { recursive: true, force: true }) }
    catch { /* best effort */ }
    throw error
  }

  // Step 4: the old bundle is no longer reachable by anyone who did not
  // already have it open, so removing it cannot break a running process.
  if (hadPrevious) {
    try {
      rmSync(retired, { recursive: true, force: true })
      return { previousPath: null }
    }
    catch {
      // A file still in use, or a permission we do not have. The update
      // succeeded; the leftover is cosmetic, and naming it lets a caller say so.
      return { previousPath: retired }
    }
  }

  return { previousPath: null }
}

/**
 * Whether the process can replace a bundle at this path without asking for
 * privileges.
 *
 * The swap is a rename *in the parent directory*, so what has to be writable
 * is `/Applications`, not the bundle. An app installed under `~/Applications`
 * is always replaceable; one in `/Applications` usually is too, because the
 * installer that put it there left it owned by the installing user.
 */
export function canReplaceBundle(installedPath: string): boolean {
  try {
    const parent = dirname(installedPath)
    accessSync(parent, constants.W_OK)
    if (existsSync(installedPath))
      statSync(installedPath)
    return true
  }
  catch {
    return false
  }
}

function describe(error: unknown): string {
  if (error && typeof error === 'object') {
    const e = error as { stderr?: string, message?: string }
    const stderr = e.stderr?.trim()
    if (stderr) return stderr
    if (e.message) return e.message
  }
  return String(error)
}
