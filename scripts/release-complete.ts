import { readFileSync } from 'node:fs'
import { join } from 'node:path'

type Command = (args: string[]) => { exitCode: number | null, stdout: string, stderr: string }
type Run = { databaseId: number, headBranch: string, headSha: string, event: string, status: string, conclusion: string | null, url: string }
const command: Command = args => {
  const result = Bun.spawnSync(args, { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
  return { exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString() }
}

/** Success means the exact tag's full release, including public npm downloads. */
export async function waitForRelease(tag: string, sha: string, execute: Command = command, options: {
  now?: () => number
  sleep?: (ms: number) => Promise<void>
  timeoutMs?: number
  intervalMs?: number
} = {}): Promise<string> {
  const now = options.now ?? Date.now
  const sleep = options.sleep ?? (ms => Bun.sleep(ms))
  const deadline = now() + (options.timeoutMs ?? 12 * 60 * 60_000)
  let previous = ''
  let errors = 0
  while (now() < deadline) {
    const result = execute(['gh', 'run', 'list', '--workflow', 'release.yml', '--commit', sha, '--event', 'push', '--limit', '20', '--json', 'databaseId,headBranch,headSha,event,status,conclusion,url'])
    if (result.exitCode !== 0) {
      if (++errors >= 3) throw new Error(`Cannot check ${tag}'s release. Check gh auth status, then resume with bun run release:finish. The version was already pushed; do not bump again.\n${result.stderr}`)
    }
    else {
      errors = 0
      const runs: Run[] = JSON.parse(result.stdout)
      if (!Array.isArray(runs)) throw new Error('GitHub returned an invalid release run list')
      const run = runs.find(run => run.headSha === sha && run.headBranch === tag && run.event === 'push')
      if (run?.status === 'completed') {
        if (run.conclusion !== 'success') throw new Error(`${tag}'s release ${run.conclusion ?? 'did not succeed'}: ${run.url}. Fix or retry that run, then use bun run release:finish; do not create another version to retry delivery.`)
        console.log(`Released ${tag}: ${run.url}`)
        return run.url
      }
      const state = run ? `${run.status}: ${run.url}` : 'waiting for the tag workflow to start'
      if (state !== previous) { console.log(`${tag}: ${state}`); previous = state }
    }
    await sleep(Math.min(options.intervalMs ?? 30_000, Math.max(0, deadline - now())))
  }
  throw new Error(`Still waiting for ${tag}'s release. Resume with bun run release:finish; the existing version and tag are retained.`)
}

if (import.meta.main) {
  const version = JSON.parse(readFileSync(join(process.cwd(), 'package.json'), 'utf8')).version
  const tag = `v${version}`
  const head = command(['git', 'rev-parse', 'HEAD'])
  const tagged = command(['git', 'rev-parse', `${tag}^{commit}`])
  if (head.exitCode !== 0 || tagged.exitCode !== 0 || head.stdout.trim() !== tagged.stdout.trim())
    throw new Error(`HEAD must be the existing ${tag} release commit. Check out that release before using release:finish; it does not change versions or tags.`)
  await waitForRelease(tag, head.stdout.trim())
}
