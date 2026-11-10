import { createHash } from 'node:crypto'
import { join, resolve } from 'node:path'
import { readArchiveManifest } from './scan-release-artifacts'

type Command = (args: string[]) => { exitCode: number | null, stdout: string, stderr: string }

const npmCommand: Command = args => {
  const result = Bun.spawnSync(['npm', ...args], { stdout: 'pipe', stderr: 'pipe' })
  return { exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() }
}

export function publishNpmArchives(directory: string, command: Command = npmCommand, dryRun = false): void {
  const root = resolve(directory)
  const archives = readArchiveManifest(root)
  for (const archive of archives) {
    const path = join(root, archive.file)
    if (!dryRun) {
      const lookup = command(['view', `${archive.name}@${archive.version}`, 'version', '--json'])
      if (lookup.exitCode === 0) {
        if (JSON.parse(lookup.stdout) !== archive.version)
          throw new Error(`${archive.name}: npm returned an unexpected published version`)
        console.log(`${archive.name}@${archive.version} already published; skipping`)
        continue
      }
      if (!lookup.stderr.includes('E404'))
        throw new Error(`${archive.name}: npm version lookup failed: ${lookup.stderr}`)
    }
    // A failed or changed archive must never be published after the scan.
    readArchiveManifest(root)
    const args = ['publish', path, '--access', 'public', '--ignore-scripts', '--provenance']
    if (dryRun) args.push('--dry-run')
    const publish = command(args)
    if (publish.exitCode !== 0)
      throw new Error(`${archive.name}: npm publish failed: ${publish.stderr}`)
    console.log(`${dryRun ? 'Dry-run checked' : 'Upload accepted for'} ${archive.name}@${archive.version}`)
  }
}

/** An accepted upload can remain unavailable during npm's publish-time scan. */
export async function verifyNpmAvailability(directory: string, options: {
  request?: (url: string | URL, init?: RequestInit) => Promise<Response>
  sleep?: (ms: number) => Promise<void>
  now?: () => number
  timeoutMs?: number
  intervalMs?: number
} = {}): Promise<void> {
  const archives = readArchiveManifest(resolve(directory))
  const request = options.request ?? fetch
  const sleep = options.sleep ?? (ms => Bun.sleep(ms))
  const now = options.now ?? Date.now
  const deadline = now() + (options.timeoutMs ?? 60 * 60_000)
  const pending = new Map(archives.map(archive => [archive.name, archive]))
  const get = async (url: string | URL, init: RequestInit): Promise<Response> => {
    try { return await request(url, { ...init, signal: AbortSignal.timeout(30_000) }) }
    catch { return new Response(null, { status: 503 }) }
  }
  const retryDelay = (response: Response): number => {
    const retry = response.headers.get('retry-after')
    if (!retry) return 0
    const seconds = Number(retry)
    const until = Number.isFinite(seconds) ? now() + seconds * 1000 : Date.parse(retry)
    return Number.isFinite(until) ? Math.max(0, until - now()) : 0
  }
  const unavailable = (): Error => new Error(`npm accepted uploads, but these versions are still unavailable: ${[...pending.values()].map(archive => `${archive.name}@${archive.version}`).join(', ')}. Inspect npm's publish-time scanning/review status. Re-run with --verify-only after npm makes them available; do not create another version just to retry availability.`)
  while (pending.size) {
    if (now() >= deadline) throw unavailable()
    let delay = options.intervalMs ?? 15_000
    for (const [name, archive] of pending) {
      const url = `https://registry.npmjs.org/${encodeURIComponent(name)}/${archive.version}`
      const response = await get(url, { headers: { 'cache-control': 'no-cache' }, redirect: 'error' })
      if (response.status === 404 || response.status === 429 || response.status >= 500) {
        delay = Math.max(delay, retryDelay(response))
        await response.body?.cancel()
        continue
      }
      if (!response.ok) throw new Error(`${name}: public npm lookup failed (${response.status})`)
      const metadata = await response.json() as { name?: string, version?: string, dist?: { tarball?: string } }
      if (metadata.name !== name || metadata.version !== archive.version || !metadata.dist?.tarball)
        throw new Error(`${name}: npm returned unexpected package metadata`)
      const tarball = new URL(metadata.dist.tarball)
      if (tarball.protocol !== 'https:' || tarball.hostname !== 'registry.npmjs.org' || tarball.username || tarball.password || tarball.port)
        throw new Error(`${name}: unexpected npm archive URL`)
      const download = await get(tarball, { redirect: 'error' })
      if (download.status === 404 || download.status === 429 || download.status >= 500) {
        delay = Math.max(delay, retryDelay(download))
        await download.body?.cancel()
        continue
      }
      if (!download.ok) throw new Error(`${name}: public npm archive download failed (${download.status})`)
      const hash = createHash('sha256').update(new Uint8Array(await download.arrayBuffer())).digest('hex')
      if (hash !== archive.sha256) throw new Error(`${name}@${archive.version}: public npm archive hash differs from the scanned release`)
      pending.delete(name)
      console.log(`Verified publicly installable ${name}@${archive.version}`)
    }
    if (!pending.size) return
    if (now() >= deadline) throw unavailable()
    console.log(`Waiting for npm availability: ${[...pending.keys()].join(', ')}`)
    await sleep(Math.min(delay, Math.max(0, deadline - now())))
  }
}

if (import.meta.main) {
  const directory = Bun.argv[2]
  if (!directory || Bun.argv.slice(3).some(arg => !['--dry-run', '--verify-only'].includes(arg)))
    throw new Error('Usage: publish-npm-archives.ts <archive-dir> [--dry-run | --verify-only]')
  const dryRun = Bun.argv.includes('--dry-run')
  if (!Bun.argv.includes('--verify-only')) publishNpmArchives(directory, npmCommand, dryRun)
  if (!dryRun) await verifyNpmAvailability(directory)
}
