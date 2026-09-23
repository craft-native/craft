import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { parseArgs } from 'node:util'

function git(cwd: string, args: string[]): string {
  const result = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' })
  if (result.exitCode !== 0)
    throw new Error(`Cannot resolve changelog range: ${result.stderr.toString().trim()}`)
  return result.stdout.toString().trim()
}

export function previewChangelog(cwd: string, from?: string, to = 'HEAD'): string {
  // Resolve refs before invoking the generator, so only commit hashes reach it.
  const start = from ?? git(cwd, ['describe', '--tags', '--abbrev=0'])
  const commits = [start, to].map(ref => git(cwd, ['rev-parse', '--verify', '--end-of-options', `${ref}^{commit}`]))
  const directory = mkdtempSync(join(tmpdir(), 'craft-changelog-preview-'))
  try {
    const output = join(directory, 'preview.md')
    // logsmith 0.2.3's --no-output writes CHANGELOG.md. An explicit temporary
    // output avoids that parser bug without changing the intentional write command.
    const cli = Bun.resolveSync('@stacksjs/logsmith/bin/cli.js', import.meta.dir)
    const result = Bun.spawnSync([
      process.execPath, cli, '--dir', resolve(cwd), '--from', commits[0]!, '--to', commits[1]!,
      '--output', output, '--hide-author-email', '--no-dates', '--theme', 'default',
    ], { cwd, env: { ...process.env, DO_NOT_TRACK: '1' }, stdout: 'pipe', stderr: 'pipe' })
    if (result.exitCode !== 0)
      throw new Error(`Changelog generation failed: ${result.stderr.toString().trim()}`)
    // The dependency can log an error and exit zero; a missing output is still failure.
    return readFileSync(output, 'utf8')
  }
  finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

if (import.meta.main) {
  const { values } = parseArgs({ args: Bun.argv.slice(2), options: { from: { type: 'string' }, to: { type: 'string' } }, strict: true, allowPositionals: false })
  process.stdout.write(previewChangelog(process.cwd(), values.from, values.to))
}
