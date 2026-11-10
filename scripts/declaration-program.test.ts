import { expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

/**
 * A published package's declaration build cannot see a test file.
 *
 * `@craft-native/svelte` builds with `tsup … && tsc --emitDeclarationOnly`,
 * and its tsconfig included `src/**` with nothing excluded but `node_modules`
 * and `dist`. Adding `src/peer-range.test.ts` therefore put a test inside the
 * program `tsc` compiles, and the build failed on `bun:test`, `node:fs`,
 * `node:path` and `import.meta.dir` — types that package does not depend on
 * and should not have to.
 *
 * It stayed broken across five commits on main, because `bun run build:npm`
 * is named in exactly one place in CI: `media-cache.yml`, which runs in the
 * `media-cache / sdk` leg of Mobile E2E. No job in `ci.yml` builds the npm
 * packages at all, so `lint`, `typescript-sdk`, `ios-builder` and
 * `android-builder` were all green while the thing a release has to do was
 * red.
 *
 * So this rule is derived twice over, in the shape the repository keeps
 * needing (#454, #489, #493, #494):
 *
 *  - the packages come from `packages/*` minus the private ones, the same
 *    scope `scripts/npm-packages.ts` publishes, rather than a list here;
 *  - it checks that a test file *cannot* enter the program, not that none is
 *    there today. `@craft-native/react` and `@craft-native/vue` have the same
 *    tsconfig and no test file yet; the first one written would have broken
 *    their builds the same way, and this fails before that rather than after.
 */
const root = resolve(import.meta.dir, '..')

/** `packages/*` minus the private entries — npm-packages.ts's own scope. */
function publicPackages(): { dir: string, name: string, build: string }[] {
  return [...new Bun.Glob('packages/*/package.json').scanSync({ cwd: root })]
    .map((path) => {
      const manifest = JSON.parse(readFileSync(join(root, path), 'utf8'))
      return { dir: path.slice(0, path.lastIndexOf('/')), name: manifest.name as string, private: manifest.private === true, build: (manifest.scripts?.build ?? '') as string }
    })
    .filter(entry => !entry.private)
    .sort((a, b) => a.dir.localeCompare(b.dir))
}

/** The packages whose build emits declarations with `tsc`. */
function declarationBuilders(): { dir: string, name: string, build: string }[] {
  return publicPackages().filter(entry => /(?:^|&&|\s)tsc\b/.test(entry.build))
}

function tsconfigOf(dir: string): { path: string, config: Record<string, unknown> } {
  const path = join(root, dir, 'tsconfig.json')
  expect(existsSync(path), `${dir} builds with tsc but has no tsconfig.json`).toBe(true)
  // Comments are legal in tsconfig and this file has them.
  const text = readFileSync(path, 'utf8').replace(/^\s*\/\/[^\n]*$/gm, '')
  return { path, config: JSON.parse(text) as Record<string, unknown> }
}

test('the scan finds the declaration builders it is about', () => {
  // A floor, so a broken glob or a changed script shape cannot make every
  // case below pass by finding nothing.
  expect(declarationBuilders().map(entry => entry.dir))
    .toEqual(['packages/react', 'packages/svelte', 'packages/vue'])
  for (const entry of declarationBuilders())
    expect(entry.build, `${entry.name} must still emit declarations`).toContain('--emitDeclarationOnly')
})

for (const { dir, name } of declarationBuilders()) {
  test(`${name} keeps test files out of its declaration program`, () => {
    const { config } = tsconfigOf(dir)
    // `extends` would move the answer into a file this rule has not read, and
    // a rule that quietly reads the wrong file is worse than no rule.
    expect(config.extends, `${dir}/tsconfig.json extends another config; teach this rule to resolve it`).toBeUndefined()
    const exclude = (config.exclude ?? []) as string[]
    const include = (config.include ?? []) as string[]
    // Not "there is no test file today": a test file must be unable to enter
    // the program at all, since the next one is written without reading this.
    const covered = include.length === 0 || include.every(pattern =>
      exclude.some(skip => skip === '**/*.test.ts' || skip === `${pattern.replace(/\/\*\*\/\*$/, '')}/**/*.test.ts`))
    expect(covered, `${dir}/tsconfig.json includes ${include.join(', ')} without excluding *.test.ts, so a test file there would be compiled into the published declarations and fail the build on bun:test and node:* types`)
      .toBe(true)
  })
}

test('the rule bites on the configuration that broke the build', () => {
  // The same resolution against the shape main actually carried, so this is
  // known to be a check rather than assumed to be one.
  const before = { include: ['src/**/*'], exclude: ['node_modules', 'dist'] }
  const after = { include: ['src/**/*'], exclude: ['node_modules', 'dist', 'src/**/*.test.ts'] }
  const covers = (config: { include: string[], exclude: string[] }): boolean => config.include.every(pattern =>
    config.exclude.some(skip => skip === '**/*.test.ts' || skip === `${pattern.replace(/\/\*\*\/\*$/, '')}/**/*.test.ts`))
  expect(covers(before)).toBe(false)
  expect(covers(after)).toBe(true)
})

test('build:npm is reachable from a job that is not a mobile leg', () => {
  // The reason this went unnoticed for five commits. `media-cache / sdk` is a
  // Mobile E2E leg: it runs late, behind the native queue, and a red npm
  // build looked like mobile flakiness rather than a broken package.
  const ci = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8')
  expect(ci, 'ci.yml must build the npm packages, so a broken package build is not only visible from a mobile leg')
    .toContain('bun run build:npm')
})
