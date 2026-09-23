import { expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { previewChangelog } from './changelog-preview'

const cli = join(import.meta.dir, 'changelog-preview.ts')
function fixture(run: (directory: string, git: (...args: string[]) => string) => void) {
  const directory = mkdtempSync(join(tmpdir(), 'craft-changelog-fixture-'))
  const git = (...args: string[]) => {
    const result = Bun.spawnSync(['git', ...args], { cwd: directory, stdout: 'pipe', stderr: 'pipe' })
    if (result.exitCode !== 0) throw new Error(result.stderr.toString())
    return result.stdout.toString()
  }
  try {
    git('init', '-q')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    git('config', 'commit.gpgsign', 'false')
    git('remote', 'add', 'origin', 'https://github.com/example/fixture.git')
    writeFileSync(join(directory, 'package.json'), '{"name":"fixture","version":"1.0.1"}')
    writeFileSync(join(directory, 'CHANGELOG.md'), '# Existing release notes\n')
    git('add', '.')
    git('commit', '-qm', 'chore: initial fixture')
    git('tag', 'v1.0.0')
    git('commit', '--allow-empty', '-qm', 'fix: preserve preview sentinel')
    run(directory, git)
  }
  finally { rmSync(directory, { recursive: true, force: true }) }
}

test('real generator preview preserves a clean checkout and tracked changelog', () => {
  fixture((directory, git) => {
    const before = readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')
    const output = previewChangelog(directory)
    expect(output).toContain('preserve preview sentinel')
    expect(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')).toBe(before)
    expect(git('status', '--porcelain')).toBe('')
  })
})

test('CLI emits only the preview and preserves pre-existing local edits', () => {
  fixture((directory, git) => {
    const notes = '# Uncommitted user notes\n'
    writeFileSync(join(directory, 'CHANGELOG.md'), notes)
    const before = git('status', '--porcelain')
    const result = Bun.spawnSync([process.execPath, cli, '--from', 'v1.0.0', '--to', 'HEAD'], { cwd: directory, stdout: 'pipe', stderr: 'pipe' })
    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString()).toContain('preserve preview sentinel')
    expect(result.stdout.toString()).not.toContain('Changelog written')
    expect(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')).toBe(notes)
    expect(git('status', '--porcelain')).toBe(before)
  })
})

test('rejects output overrides and invalid refs without mutating the repository', () => {
  fixture((directory, git) => {
    for (const args of [['--output', 'CHANGELOG.md'], ['--no-output'], ['--from', 'missing-ref'], ['--to', '--help']]) {
      const result = Bun.spawnSync([process.execPath, cli, ...args], { cwd: directory, stdout: 'pipe', stderr: 'pipe' })
      expect(result.exitCode).not.toBe(0)
      expect(result.stdout.toString()).toBe('')
      expect(git('status', '--porcelain')).toBe('')
    }
  })
})
