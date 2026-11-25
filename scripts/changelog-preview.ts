import { readFileSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { parseArgs } from 'node:util'
import { createTempDir } from '../packages/typescript/src/temp-dir'

// #597: a blocking spawn holds its caller (and a test's limit can't stop it),
// so every child here is bounded and says when it was stopped.
export const changelogGitLimitMs = 30_000
export const changelogGenerateLimitMs = 120_000

export function spawnFailure(result: { exitedDueToTimeout?: boolean, stderr: Uint8Array | { toString: () => string } }, limitMs: number): string {
  const stderr = result.stderr.toString().trim()
  return result.exitedDueToTimeout ? `stopped after ${limitMs / 1000} s${stderr ? `: ${stderr}` : ''}` : stderr
}

function git(cwd: string, args: string[]): string {
  const result = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe', timeout: changelogGitLimitMs })
  if (result.exitCode !== 0)
    throw new Error(`Cannot resolve changelog range: ${spawnFailure(result, changelogGitLimitMs)}`)
  return result.stdout.toString().trim()
}

/** Logsmith can report the same #ref from a commit subject and its body. */
export function dedupeChangelogReferences(markdown: string): string {
  const trailing = /^(.*) \((\[#\d+\]\(https?:\/\/[^)]+\/(?:issues|pull)\/\d+\)(?:, \[#\d+\]\(https?:\/\/[^)]+\/(?:issues|pull)\/\d+\))*)\)$/
  return markdown.split('\n').map((line) => {
    const match = line.match(trailing)
    if (!match) return line
    const references = match[2]!.split(', ')
    return `${match[1]} (${[...new Set(references)].join(', ')})`
  }).join('\n')
}

export function previewChangelog(cwd: string, from?: string, to = 'HEAD'): string {
  // Resolve refs before invoking the generator, so only commit hashes reach it.
  const start = from ?? git(cwd, ['describe', '--tags', '--abbrev=0'])
  const commits = [start, to].map(ref => git(cwd, ['rev-parse', '--verify', '--end-of-options', `${ref}^{commit}`]))
  const directory = createTempDir('craft-changelog-preview-')
  try {
    const output = join(directory, 'preview.md')
    // logsmith 0.2.3's --no-output writes CHANGELOG.md. An explicit temporary
    // output avoids that parser bug without changing the intentional write command.
    const cli = Bun.resolveSync('@stacksjs/logsmith/bin/cli.js', import.meta.dir)
    const result = Bun.spawnSync([
      process.execPath, cli, '--dir', resolve(cwd), '--from', commits[0]!, '--to', commits[1]!,
      '--output', output, '--hide-author-email', '--no-dates', '--theme', 'default',
    ], { cwd, env: { ...process.env, DO_NOT_TRACK: '1' }, stdout: 'pipe', stderr: 'pipe', timeout: changelogGenerateLimitMs })
    if (result.exitCode !== 0)
      throw new Error(`Changelog generation failed: ${spawnFailure(result, changelogGenerateLimitMs)}`)
    // The dependency can log an error and exit zero; a missing output is still failure.
    return dedupeChangelogReferences(readFileSync(output, 'utf8'))
  }
  finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const { values } = parseArgs({ args: Bun.argv.slice(2), options: { from: { type: 'string' }, to: { type: 'string' } }, strict: true, allowPositionals: false })
  process.stdout.write(previewChangelog(process.cwd(), values.from, values.to))
}
