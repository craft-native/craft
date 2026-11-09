import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'

const root = join(import.meta.dir, '..')
const workflow = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8')

/**
 * Every package whose tests are gated on a Mac runs its whole suite on one.
 *
 * `packages/ios` used to run its suite on ubuntu, where those gates skip, and
 * its only macOS job named three files. Thirteen darwin-gated blocks across
 * eleven files therefore executed nowhere, and `packages/macos/src/engine.ts`
 * was in the same position: the macOS matrix leg named `renderer.test.ts` and
 * no job ran a bare `bun test` for that package.
 *
 * A test that runs nowhere cannot go red, so nothing distinguishes coverage
 * that passes from coverage that has been broken since it was written —
 * `hybrid.test.ts` had seven contract tests that had never passed in either
 * place. The hand-written file list is what hid them, which is the same
 * enumerate-instead-of-derive shape as #454, #489 and #493.
 *
 * Derived from the test files, so a darwin gate added to a package nothing
 * runs on macOS fails here rather than going quiet.
 */
const gates = /process\.platform\s*[!=]==\s*'darwin'|Bun\.which\('(?:swiftc|xcodebuild|xcrun|codesign)'\)/

/** Packages with at least one darwin-gated test file. */
function gatedPackages(): string[] {
  const found = new Set<string>()
  for (const path of new Bun.Glob('packages/*/src/**/*.test.ts').scanSync({ cwd: root })) {
    if (gates.test(readFileSync(join(root, path), 'utf8'))) found.add(path.split('/')[1]!)
  }
  return [...found].sort()
}

/** Each job in a workflow, with the text of its steps. */
function jobs(source: string): { name: string, macos: boolean, body: string }[] {
  return source.split(/^  (?=[a-z][\w-]*:)/m).slice(1).map(block => ({
    name: block.slice(0, block.indexOf(':')),
    // zig-core picks its runner from a matrix, so the runner is read from the
    // whole block rather than from `runs-on:` alone.
    macos: block.includes('macos-latest'),
    body: block,
  }))
}

/** `bun run <script>` resolved through the package.json it would run in. */
function expand(command: string, workingDirectory: string): string {
  const script = /^bun run ([\w:-]+)$/.exec(command.trim())?.[1]
  if (!script) return command
  const manifest = JSON.parse(readFileSync(join(root, workingDirectory, 'package.json'), 'utf8'))
  return manifest.scripts?.[script] ?? command
}

/** Every command a job runs, paired with the directory it runs in. */
function commands(body: string): { command: string, directory: string }[] {
  const out: { command: string, directory: string }[] = []
  for (const step of body.split(/\n      - /).slice(1)) {
    const directory = /working-directory:\s*(\S+)/.exec(step)?.[1] ?? '.'
    const run = /\n?\s*run:\s*(\|[-\s]*\n([\s\S]*?)(?=\n\s*(?:env|with|if|name):|\n\n|$)|([^\n]+))/.exec(step)
    if (!run) continue
    for (const line of (run[2] ?? run[3] ?? '').split('\n'))
      if (line.trim()) out.push({ command: line.trim(), directory })
  }
  return out
}

/**
 * Whether a command runs every test in `pkg` rather than a chosen few.
 *
 * `bun test` with no arguments in the package, or with a directory inside it.
 * A `.test.ts` argument is the thing this check exists to reject, so a path
 * ending in one never counts however many of them are listed.
 */
function runsWholeSuite(command: string, directory: string, pkg: string): boolean {
  let here = directory
  for (const part of expand(command, directory).split('&&').map(piece => piece.trim())) {
    // `bun run test:sdk` expands to `cd packages/typescript && bun test`, so
    // the directory has to carry across the parts rather than being read from
    // each one on its own.
    const moved = /^cd\s+(\S+)/.exec(part)
    if (moved) { here = moved[1]!; continue }
    const test = /(?:^|\s)bun test\s*(.*)$/.exec(part)
    if (!test) continue
    const args = test[1]!.trim()
    if (args === '') { if (here.replace(/^\.\//, '') === `packages/${pkg}`) return true; continue }
    // A `.test.ts` argument is exactly what this check exists to reject, so a
    // command naming one never counts however many it lists.
    if (!args.includes('.test.ts') && new RegExp(`packages/${pkg}(?:/|\\s|$)`).test(args)) return true
  }
  return false
}

/** The macOS jobs in `source` that run every test in `pkg`. */
function covering(source: string, pkg: string): string[] {
  return jobs(source)
    .filter(job => job.macos && commands(job.body).some(({ command, directory }) => runsWholeSuite(command, directory, pkg)))
    .map(job => job.name)
}

describe('darwin-gated tests', () => {
  it('finds the packages that have them', () => {
    // A floor, so a broken scan cannot make this file vacuously pass.
    expect(gatedPackages()).toEqual(['ios', 'macos', 'typescript'])
  })

  for (const pkg of gatedPackages()) {
    it(`runs the whole packages/${pkg} suite on a macOS runner`, () => {
      expect(covering(workflow, pkg),
        `no macOS job runs every test in packages/${pkg}, so its darwin-gated cases run nowhere`).not.toEqual([])
    })
  }

  it('bites when a macOS job goes back to naming files', () => {
    // The same resolution against an edited copy. A check that has never been
    // seen to fail is not known to be a check at all, and two of the ratchets
    // this repository added last week passed with the thing they guard
    // deleted.
    const step = '      - name: Test the iOS builder including its Darwin-gated cases\n        working-directory: packages/ios\n        run: bun test\n'
    expect(workflow).toContain(step)
    const named = workflow.replace(step, step.replace('run: bun test\n', 'run: bun test ./src/index.test.ts\n'))
    expect(covering(named, 'ios')).toEqual([])
    expect(covering(workflow, 'ios')).toEqual(['ios-native-templates'])
  })
})


/**
 * Every `scripts/` test is named by something that runs it.
 *
 * A test outside a package runs only where it is named — no job runs a bare
 * `bun test ./scripts`. Three of them had been in no workflow and no
 * package.json script, one of them covering the `decide()` that accepts or
 * refuses every release commit, and the step that now runs them says so in a
 * comment. The list was complete again after that and nothing kept it so.
 *
 * This is the same enumerate-instead-of-derive shape as the darwin gap above:
 * a hand-written list that silently stops covering whatever is added next.
 */
describe('scripts tests', () => {
  const named = [
    ...new Bun.Glob('.github/workflows/*.yml').scanSync({ cwd: root }),
  ].map(path => readFileSync(join(root, path), 'utf8')).join('\n')
    + readFileSync(join(root, 'package.json'), 'utf8')

  const files = [...new Bun.Glob('scripts/**/*.test.ts').scanSync({ cwd: root })].sort()

  it('has tests to check', () => {
    expect(files.length).toBeGreaterThan(30)
  })

  it('names every one of them in a workflow or a package script', () => {
    const unreachable = files.filter(path => !named.includes(path))
    expect(unreachable, 'these tests are in no workflow and no package script, so they run nowhere').toEqual([])
  })
})
