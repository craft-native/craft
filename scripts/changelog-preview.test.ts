import { expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { dedupeChangelogReferences, previewChangelog } from './changelog-preview'
import { generateReleaseChangelog } from './generate-release-changelog'

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
    writeFileSync(join(directory, 'CHANGELOG.md'), '# Changelog\n\n[Compare changes](https://github.com/example/fixture/compare/v0.9.0...v1.0.0)\n\n## Existing release notes\n')
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

test('keeps one link per issue or pull request without dropping distinct references', () => {
  const first = '[#326](https://github.com/craft-native/craft/issues/326)'
  const second = '[#325](https://github.com/craft-native/craft/issues/325)'
  const line = `- Merge pull request #326 ([36af50e](https://github.com/craft-native/craft/commit/36af50e)) (${first}, ${first}, ${second}, ${first})`
  expect(dedupeChangelogReferences(line)).toBe(`- Merge pull request #326 ([36af50e](https://github.com/craft-native/craft/commit/36af50e)) (${first}, ${second})`)
  expect(dedupeChangelogReferences('A regular sentence with #326')).toBe('A regular sentence with #326')
})

test('real merge commit preview has only one linked reference', () => {
  fixture((directory, git) => {
    git('commit', '--allow-empty', '-qm', 'Merge pull request #326 from example/feature')
    const output = previewChangelog(directory, 'v1.0.0')
    expect(output).toContain('Merge pull request #326')
    expect(output.match(/\[#326\]\(https:\/\/github\.com\/example\/fixture\/issues\/326\)/g)).toHaveLength(1)
    expect(git('status', '--porcelain')).toBe('')
  })
})

test('release generation prepends a deduplicated section with the future tag', () => {
  fixture((directory, git) => {
    git('commit', '--allow-empty', '-qm', 'Merge pull request #326 from example/feature')
    const content = generateReleaseChangelog(directory)
    expect(content).toContain('[Compare changes](https://github.com/example/fixture/compare/v1.0.0...v1.0.1)')
    expect(content.match(/\[#326\]\(https:\/\/github\.com\/example\/fixture\/issues\/326\)/g)).toHaveLength(1)
    expect(content).toContain('## Existing release notes')
    expect(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')).toBe(content)
    expect(git('status', '--porcelain')).toBe(' M CHANGELOG.md\n')
    expect(() => generateReleaseChangelog(directory)).toThrow('already in the changelog')
  })
})

test('failed release generation leaves the changelog unchanged', () => {
  fixture((directory, git) => {
    const changelog = readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')
    writeFileSync(join(directory, 'package.json'), '{"name":"fixture","version":"wrong"}')
    expect(() => generateReleaseChangelog(directory)).toThrow('valid release version')
    expect(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')).toBe(changelog)
    expect(git('status', '--porcelain')).toBe(' M package.json\n')
  })
})

test('patch release uses the guarded changelog generator before committing', () => {
  const project = JSON.parse(readFileSync(join(import.meta.dir, '..', 'package.json'), 'utf8'))
  const command = project.scripts['release:patch'] as string
  expect(project.scripts['changelog:generate']).toBe('bun scripts/generate-release-changelog.ts')
  expect(command).toContain('--no-changelog')
  expect(command).toContain('bun scripts/generate-release-changelog.ts')
  expect(command).toContain('git add packages/zig/build.zig.zon packages/zig/pantry.json CHANGELOG.md')
})
