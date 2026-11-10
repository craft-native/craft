import { afterAll, expect, test } from 'bun:test'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { dedupeChangelogReferences, previewChangelog } from './changelog-preview'
import { generateReleaseChangelog } from './generate-release-changelog'
import { bumpxReleaseCommand } from './release-cli'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const cli = join(import.meta.dir, 'changelog-preview.ts')
const shellQuote = (value: string): string => `'${value.replaceAll("'", "'\\''")}'`
function fixture(run: (directory: string, git: (...args: string[]) => string) => void) {
  const directory = createTempDir('craft-changelog-fixture-')
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

// Real Git/Logsmith fixtures use the release CLI rehearsals' bounded budget.
test('real generator preview preserves a clean checkout and tracked changelog', () => {
  fixture((directory, git) => {
    const before = readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')
    const output = previewChangelog(directory)
    expect(output).toContain('preserve preview sentinel')
    expect(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')).toBe(before)
    expect(git('status', '--porcelain')).toBe('')
  })
}, 30_000)

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
}, 30_000)

test('rejects output overrides and invalid refs without mutating the repository', () => {
  fixture((directory, git) => {
    for (const args of [['--output', 'CHANGELOG.md'], ['--no-output'], ['--from', 'missing-ref'], ['--to', '--help']]) {
      const result = Bun.spawnSync([process.execPath, cli, ...args], { cwd: directory, stdout: 'pipe', stderr: 'pipe' })
      expect(result.exitCode).not.toBe(0)
      expect(result.stdout.toString()).toBe('')
      expect(git('status', '--porcelain')).toBe('')
    }
  })
}, 30_000)

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
}, 30_000)

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
}, 30_000)

test('failed release generation leaves the changelog unchanged', () => {
  fixture((directory, git) => {
    const changelog = readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')
    writeFileSync(join(directory, 'package.json'), '{"name":"fixture","version":"wrong"}')
    expect(() => generateReleaseChangelog(directory)).toThrow('valid release version')
    expect(readFileSync(join(directory, 'CHANGELOG.md'), 'utf8')).toBe(changelog)
    expect(git('status', '--porcelain')).toBe(' M package.json\n')
  })
}, 30_000)

test('release notes can include changes since the last published release after an abandoned tag', () => {
  fixture((directory, git) => {
    git('commit', '--allow-empty', '-qm', 'feat: native trail maps')
    git('tag', 'v1.0.1')
    writeFileSync(join(directory, 'package.json'), '{"name":"fixture","version":"1.0.2"}')
    const content = generateReleaseChangelog(directory, 'v1.0.0')
    expect(content).toContain('native trail maps')
    expect(content).toContain('/compare/v1.0.0...v1.0.2)')
    expect(git('tag', '--list', 'v1.0.1')).toBe('v1.0.1\n')
  })
}, 30_000)

test('patch release uses the guarded changelog generator before committing', () => {
  const project = JSON.parse(readFileSync(join(import.meta.dir, '..', 'package.json'), 'utf8'))
  expect(project.scripts['changelog:generate']).toBe('bun scripts/generate-release-changelog.ts')
  for (const [name, mode] of [['release', 'prompt'], ['release:patch', 'patch'], ['release:version', 'version']] as const) {
    expect(project.scripts[name]).toBe(`bun scripts/release-cli.ts ${mode}`)
    const command = bumpxReleaseCommand(mode, []).join(' ')
    expect(command).toContain('--no-changelog')
    expect(command).not.toContain('--files')
    expect(command).toContain('bun scripts/release-version.ts --pending && bun scripts/generate-release-changelog.ts')
  }
})

function nativeWorkspace(directory: string, git: (...args: string[]) => string): string[] {
  mkdirSync(join(directory, 'packages/zig'), { recursive: true })
  mkdirSync(join(directory, 'packages/sdk'), { recursive: true })
  writeFileSync(join(directory, 'package.json'), '{"name":"fixture","version":"1.0.1","workspaces":["packages/*"]}')
  writeFileSync(join(directory, 'packages/sdk/package.json'), '{"name":"fixture-sdk","version":"1.0.0"}')
  writeFileSync(join(directory, 'packages/zig/build.zig.zon'), '.{ .version = "1.0.0", }')
  writeFileSync(join(directory, 'packages/zig/pantry.json'), '{"version":"1.0.0"}')
  // This is the real repository's ignore rule; explicit additionalFiles must
  // retain the tracked native manifest while recursive workspace discovery runs.
  writeFileSync(join(directory, '.gitignore'), 'pantry\n')
  writeFileSync(join(directory, 'bumpx.config.ts'), readFileSync(join(import.meta.dir, '..', 'bumpx.config.ts')))
  git('add', '.')
  git('commit', '-qm', 'chore: register native and workspace release metadata')
  return ['package.json', 'packages/sdk/package.json', 'packages/zig/build.zig.zon', 'packages/zig/pantry.json']
}

// Each real CLI rehearsal needs its own bounded subprocess budget; Bun's
// five-second default can kill a successful Git/Bumpx/changelog run early.
function fixtureReleaseEnvironment(git: (...args: string[]) => string): NodeJS.ProcessEnv {
  // The caller's source pin belongs to its real checkout. Rehearsals keep the
  // same guard enabled, bound to the temporary repository they actually bump.
  return {
    ...process.env,
    BUMPX_EXPECTED_SOURCE: git('rev-parse', 'HEAD').trim(),
    // A real release may start after an abandoned tag. That range belongs
    // to its checkout; the rehearsal's own previous release is v1.0.0.
    CRAFT_CHANGELOG_FROM: 'v1.0.0',
  }
}

for (const release of ['1.0.2', 'patch']) {
  test(`the real ${release} release versions every workspace and native manifest before tagging`, () => {
    fixture((directory, git) => {
      const paths = nativeWorkspace(directory, git)
      const bumpx = Bun.resolveSync('@stacksjs/bumpx/bin/cli.js', import.meta.dir)
      const generator = join(import.meta.dir, 'generate-release-changelog.ts')
      const validator = join(import.meta.dir, 'release-version.ts')
      // The validator must read the fixture checkout rather than its own source root.
      mkdirSync(join(directory, 'scripts'))
      writeFileSync(join(directory, 'scripts/release-version.ts'), readFileSync(validator))
      git('add', 'scripts')
      git('commit', '-qm', 'chore: install actual release validator')
      const result = Bun.spawnSync([
        process.execPath, bumpx, '--recursive', '--commit', '--tag', '--no-push', '--yes', '--no-changelog',
        '--execute', `${shellQuote(process.execPath)} scripts/release-version.ts --pending && ${shellQuote(process.execPath)} ${shellQuote(generator)} && git add CHANGELOG.md`, release,
      ], { cwd: directory, env: fixtureReleaseEnvironment(git), stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
      expect(result.exitCode, result.stderr.toString()).toBe(0)
      expect(git('tag', '--list', 'v1.0.2')).toBe('v1.0.2\n')
      for (const path of paths) expect(git('show', `HEAD:${path}`)).toContain('1.0.2')
      expect(git('show', 'HEAD:CHANGELOG.md')).toContain('/compare/v1.0.0...v1.0.2)')
      expect(git('status', '--porcelain')).toBe('')
    })
  }, 30_000)
}

test('the published release tool restores all workspace and native versions on a failed command', () => {
  fixture((directory, git) => {
    const paths = nativeWorkspace(directory, git)
    const head = git('rev-parse', 'HEAD')
    const before = paths.map(path => readFileSync(join(directory, path), 'utf8'))
    const bumpx = Bun.resolveSync('@stacksjs/bumpx/bin/cli.js', import.meta.dir)
    const marker = join(createTempDir('craft-release-rollback-'), 'version.json')
    const hook = "const fs = require('node:fs'); fs.writeFileSync(process.env.CRAFT_REHEARSAL_VERSION, fs.readFileSync('package.json')); process.exit(23)"
    const result = Bun.spawnSync([
      process.execPath, bumpx, 'patch', '--recursive', '--commit', '--tag', '--no-push', '--yes', '--no-changelog',
      '--execute', `${shellQuote(process.execPath)} -e ${shellQuote(hook)}`,
    ], { cwd: directory, env: { ...fixtureReleaseEnvironment(git), CRAFT_REHEARSAL_VERSION: marker }, stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
    expect(result.exitCode).not.toBe(0)
    expect(JSON.parse(readFileSync(marker, 'utf8')).version).toBe('1.0.2')
    expect(paths.map(path => readFileSync(join(directory, path), 'utf8'))).toEqual(before)
    expect(git('rev-parse', 'HEAD')).toBe(head)
    expect(git('tag', '--list', 'v1.0.2')).toBe('')
    expect(git('status', '--porcelain')).toBe('')
  })
}, 30_000)

test('pending validation rejects an incomplete workspace before a tag or commit exists', () => {
  fixture((directory, git) => {
    const paths = nativeWorkspace(directory, git)
    mkdirSync(join(directory, 'scripts'))
    writeFileSync(join(directory, 'scripts/release-version.ts'), readFileSync(join(import.meta.dir, 'release-version.ts')))
    git('add', 'scripts')
    git('commit', '-qm', 'chore: install actual release validator')
    const head = git('rev-parse', 'HEAD')
    const before = paths.map(path => readFileSync(join(directory, path), 'utf8'))
    const bumpx = Bun.resolveSync('@stacksjs/bumpx/bin/cli.js', import.meta.dir)
    const result = Bun.spawnSync([
      process.execPath, bumpx, '1.0.2', '--files', 'package.json', '--commit', '--tag', '--no-push', '--yes', '--no-changelog',
      '--execute', `${shellQuote(process.execPath)} scripts/release-version.ts --pending`,
    ], { cwd: directory, env: fixtureReleaseEnvironment(git), stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
    expect(result.exitCode).not.toBe(0)
    expect(`${result.stdout.toString()}${result.stderr.toString()}`).toContain('packages/sdk/package.json')
    expect(paths.map(path => readFileSync(join(directory, path), 'utf8'))).toEqual(before)
    expect(git('rev-parse', 'HEAD')).toBe(head)
    expect(git('tag', '--list', 'v1.0.2')).toBe('')
    expect(git('status', '--porcelain')).toBe('')
  })
}, 30_000)
