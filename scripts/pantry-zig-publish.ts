/**
 * Decide whether a Zig publish whose reply was lost actually published.
 *
 * The release's `publish-pantry` job makes one POST through Pantry's action,
 * and any curl exit fails it. v0.0.500's upload ended with `curl: (16) Error
 * in the HTTP2 framing layer`, but the registry had taken the tarball and
 * published 0.0.500 seven seconds later (#524). The release was complete
 * and recorded as failed, and the channel message after it was skipped.
 *
 * When the upload step fails, this reads the registry's own record of the
 * package. The step counts as published only if that record names this
 * version, was published after this job started (so it is this run's upload,
 * not an earlier one), and passed the registry's malware scan. Anything else
 * still fails the job. It never uploads anything, so it cannot publish twice.
 *
 *   bun scripts/pantry-zig-publish.ts confirm --version 0.0.507 --since 2026-11-16T10:00:00Z
 */

/** The fields of `GET /zig/packages/<name>` this check reads. */
export interface ZigPackageRecord {
  name?: unknown
  version?: unknown
  publishedAt?: unknown
  artifactSha256?: unknown
  malwareScan?: { verdict?: unknown } | null
}

export interface ZigPublicationExpectation {
  name: string
  version: string
  /** When this job started: an earlier `publishedAt` is not this run's upload. */
  since: Date
}

export type ZigPublication = { published: true, publishedAt: string, artifactSha256?: string } | { published: false, reason: string }

export function confirmZigPublication(record: ZigPackageRecord | undefined, expected: ZigPublicationExpectation): ZigPublication {
  if (!record || typeof record !== 'object') return { published: false, reason: 'the registry returned no package record' }
  if (record.name !== expected.name) return { published: false, reason: `the registry record is for ${JSON.stringify(record.name)}, not ${expected.name}` }
  if (record.version !== expected.version) return { published: false, reason: `the registry's latest ${expected.name} is ${JSON.stringify(record.version)}, not ${expected.version}` }
  const publishedAt = typeof record.publishedAt === 'string' ? new Date(record.publishedAt) : undefined
  if (!publishedAt || Number.isNaN(publishedAt.getTime())) return { published: false, reason: 'the registry record has no publication time' }
  if (publishedAt.getTime() < expected.since.getTime())
    return { published: false, reason: `${expected.version} was published at ${record.publishedAt}, before this job started at ${expected.since.toISOString()}` }
  if (record.malwareScan?.verdict !== 'clean') return { published: false, reason: `the registry's malware scan verdict is ${JSON.stringify(record.malwareScan?.verdict)}, not "clean"` }
  return { published: true, publishedAt: record.publishedAt as string, ...(typeof record.artifactSha256 === 'string' ? { artifactSha256: record.artifactSha256 } : {}) }
}

/** The registry's record of a Zig package. */
export function zigPackageUrl(name: string): string {
  return `https://registry.pantry.dev/zig/packages/${encodeURIComponent(name)}`
}

async function readRecord(name: string): Promise<ZigPackageRecord | undefined> {
  const response = await fetch(zigPackageUrl(name), { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(20_000) })
  if (!response.ok) return undefined
  return await response.json() as ZigPackageRecord
}

if (import.meta.main) {
  const args = process.argv.slice(2)
  const option = (flag: string): string | undefined => { const at = args.indexOf(flag); return at >= 0 ? args[at + 1] : undefined }
  const version = option('--version')
  const since = option('--since')
  const name = option('--name') ?? 'craft'
  if (args[0] !== 'confirm' || !version || !since || Number.isNaN(new Date(since).getTime())) {
    console.error('Usage: bun scripts/pantry-zig-publish.ts confirm --version <version> --since <ISO time the job started> [--name craft]')
    process.exit(2)
  }
  // The registry published 0.0.500 seven seconds after the client gave up;
  // give it a minute and a half to appear before calling the upload lost.
  let outcome: ZigPublication = { published: false, reason: 'not checked' }
  for (let attempt = 1; attempt <= 10; attempt++) {
    try { outcome = confirmZigPublication(await readRecord(name), { name, version, since: new Date(since) }) }
    catch (error) { outcome = { published: false, reason: `reading ${zigPackageUrl(name)} failed: ${String(error)}` } }
    if (outcome.published) break
    if (attempt < 10) await Bun.sleep(9_000)
  }
  if (!outcome.published) {
    console.error(`::error::The Zig upload failed and the registry does not show this run's ${name} ${version}: ${outcome.reason}`)
    process.exit(1)
  }
  console.log(`::warning::The Zig upload's reply was lost, but the registry published ${name} ${version} at ${outcome.publishedAt}${outcome.artifactSha256 ? ` (artifact ${outcome.artifactSha256})` : ''}, after this job started. Counting it as published.`)
}
