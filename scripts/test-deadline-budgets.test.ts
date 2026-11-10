import { expect, test } from 'bun:test'
import { resolve } from 'node:path'
import { blankLiterals, bunDefaultTestTimeoutMs, describeConflict, findDeadlineBudgetConflicts, findUndeclaredSpawnBudgets, readBudgets, readHookBlocks, readTestBlocks, requiredHeadroomMs, spawnNames, spawningTestTimeoutMs, spawnsRealProcess } from './test-deadline-budgets'

const root = resolve(import.meta.dir, '..')

test('a bounded test under the inherited default is a conflict, and says what to write down', () => {
  const source = 'test(\'bounded\', async () => {\n  await run([], { timeoutMs: 10000 })\n})\n'
  const [conflict] = findDeadlineBudgetConflicts('a.test.ts', source)
  expect(conflict).toMatchObject({ test: 'bounded', testTimeoutMs: bunDefaultTestTimeoutMs, declared: false, budgetMs: 10000 })
  expect(describeConflict(conflict!)).toContain('under Bun\'s default 5000 ms timeout')
  expect(describeConflict(conflict!)).toContain('at least 11000 ms')
})

test('an explicit timeout only clears the budget once it leaves headroom', () => {
  const bounded = (timeout: string) => `test('bounded', async () => {\n  await run([], { timeoutMs: 5000 })\n}${timeout})\n`
  // Equal is still a conflict: the two deadlines expire together, and the
  // harness aborts the test rather than letting the command report.
  expect(findDeadlineBudgetConflicts('a.test.ts', bounded(', 5000'))).toHaveLength(1)
  expect(findDeadlineBudgetConflicts('a.test.ts', bounded(`, ${5000 + requiredHeadroomMs - 1}`))).toHaveLength(1)
  expect(findDeadlineBudgetConflicts('a.test.ts', bounded(`, ${5000 + requiredHeadroomMs}`))).toEqual([])
  expect(findDeadlineBudgetConflicts('a.test.ts', bounded(', 15_000'))).toEqual([])
})

test('a test that asserts no command budget is not this rule\'s business', () => {
  expect(findDeadlineBudgetConflicts('a.test.ts', 'test(\'plain\', () => { expect(1).toBe(1) })\n')).toEqual([])
})

test('a budget mentioned inside a literal or a comment is text, not a deadline', () => {
  // Otherwise this rule flags the fixtures that describe it, and every test
  // that embeds a script naming its own budget.
  expect(readBudgets('const sample = `test(\'x\', async () => { await run([], { timeoutMs: 10000 }) })`')).toEqual([])
  expect(readBudgets('// await run([], { timeoutMs: 10000 })')).toEqual([])
  expect(readBudgets('/* { timeoutMs: 10000 } */')).toEqual([])
  // Interpolated code is still code.
  expect(readBudgets('const sample = `prefix ${run({ timeoutMs: 10000 })} suffix`')).toEqual([10000])
  // And blanking preserves offsets, so a real budget after a literal is kept.
  expect(readBudgets('const sample = \'{ timeoutMs: 1 }\'\nawait run([], { timeoutMs: 9000 })')).toEqual([9000])
})

test('the largest budget in a body is the one that has to fit', () => {
  const source = 'test(\'two\', async () => {\n  await run([], { timeoutMs: 500 })\n  await run([], { timeoutMs: 9000 })\n})\n'
  expect(readBudgets(source)).toEqual([500, 9000])
  expect(findDeadlineBudgetConflicts('a.test.ts', source)[0]).toMatchObject({ budgetMs: 9000 })
})

test('the scanner survives this suite\'s embedded fixture sources', () => {
  // Real shapes from the Android fixtures: a template literal holding a whole
  // script, with its own braces, parens, interpolations and quotes, and a
  // regex-looking string. A brace counter without string handling ends the
  // block inside the template and reads the wrong trailing argument.
  const source = [
    'test(\'embedded\', async () => {',
    '  const script = `#!${process.execPath}',
    '  process.on(\'SIGTERM\', () => {}); if (x) { y(\')\') } // }, 1)',
    '  `',
    '  // a trailing comment mentioning timeoutMs: 1 and }, 2)',
    '  /* and a block one with ) and } */',
    '  await run([script], { timeoutMs: 10000 })',
    '}, 20000)',
    '',
    'test(\'after\', async () => { await run([], { timeoutMs: 10000 }) })',
  ].join('\n')
  const blocks = readTestBlocks(source)
  expect(blocks.map(block => block.name)).toEqual(['embedded', 'after'])
  expect(blocks.map(block => block.timeoutMs)).toEqual([20000, null])
  expect(findDeadlineBudgetConflicts('a.test.ts', source).map(conflict => conflict.test)).toEqual(['after'])
  // The template's script text is blanked; its line structure is not.
  expect(blankLiterals(source).split('\n')).toHaveLength(source.split('\n').length)
})

test('a nested test is read once, from its own block rather than its parent\'s', () => {
  const source = 'describe(\'group\', () => {\n  test(\'inner\', async () => { await run([], { timeoutMs: 10000 }) }, 20000)\n})\n'
  expect(readTestBlocks(source).map(block => block.name)).toEqual(['inner'])
  expect(findDeadlineBudgetConflicts('a.test.ts', source)).toEqual([])
})

test('no test in this repository asserts a command budget it cannot reach', async () => {
  // Derived rather than listed: a new bounded test is covered the moment it is
  // written. Measured behaviour behind the rule — a test that exceeds its own
  // timeout is aborted where it stands, so the command never reports its
  // `timedOut`/`elapsedMs`/`msSinceLastOutput` receipt and the body's
  // `finally` never runs, leaving its temporary directory and its
  // process-group disposal check unperformed.
  const files = [...new Bun.Glob('{scripts,packages,src,benchmarks}/**/*.test.ts').scanSync({ cwd: root })]
    .filter(file => !file.includes('node_modules') && !file.includes('/dist/'))
    .sort()
  expect(files.length).toBeGreaterThan(50)
  const conflicts = (await Promise.all(files.map(async file => findDeadlineBudgetConflicts(file, await Bun.file(resolve(root, file)).text())))).flat()
  expect(conflicts.map(describeConflict)).toEqual([])
})

/**
 * The second rule: a test that drives a real subprocess has a budget nobody
 * wrote down, so it inherits 5000 ms.
 *
 * `macOS signing reads credentials from the declared Stacks CLI…` spawns
 * fourteen processes and costs 2.2 s on an idle machine. Under this suite's
 * own load it took 111 s, and what it reported was not a slow test:
 * `expected 0, received null`, because Bun had killed the child on the cap and
 * a signalled process has no exit code. Its own file already had one spawning
 * test at 30000; this one had missed it.
 */
test('a test that spawns a real process is read as one, embedded scripts aside', () => {
  const body = (call: string) => `test('x', () => { ${call} })`
  for (const call of ['Bun.spawnSync([bin])', 'Bun.spawn([bin])', 'spawnSync(bin)', 'execFileSync(bin)', 'execSync(bin)']) {
    expect(spawnsRealProcess(body(call)), call).toBe(true)
  }
  // A fixture that writes a script mentioning a spawn does not itself spawn.
  expect(spawnsRealProcess('const fixture = `#!/usr/bin/env bun\nBun.spawnSync([x])`')).toBe(false)
  expect(spawnsRealProcess('// Bun.spawnSync([x]) used to be here')).toBe(false)
  expect(spawnsRealProcess('test(\'x\', () => { expect(1).toBe(1) })')).toBe(false)
})

test('a spawning test without its own timeout is reported', () => {
  const spawning = 'test(\'spawns\', () => { Bun.spawnSync([process.execPath, \'-e\', \'1\']) })\n'
  expect(findUndeclaredSpawnBudgets('a.test.ts', spawning)).toEqual([{ file: 'a.test.ts', test: 'spawns' }])
  expect(findUndeclaredSpawnBudgets('a.test.ts', `${spawning.trimEnd().slice(0, -1)}, ${spawningTestTimeoutMs})\n`)).toEqual([])
})

test('a lifecycle hook is read and budgeted like a test', () => {
  // A hook that overruns fails its whole block as one unnamed test saying only
  // `a beforeEach/afterEach hook timed out`. `hybrid.test.ts` compiled a Swift
  // probe in a `beforeAll` under the inherited default; declaring its budget
  // took that file from 35 pass / 1 fail to 42 pass / 0 fail.
  const hook = (trailing: string) => `beforeAll(() => {\n  Bun.spawnSync(['swiftc', '-o', binary, mainPath])\n}${trailing})\n`
  expect(readHookBlocks(hook('')).map(block => block.timeoutMs)).toEqual([null])
  expect(readHookBlocks(hook(', 180_000')).map(block => block.timeoutMs)).toEqual([180000])
  expect(findUndeclaredSpawnBudgets('a.test.ts', hook('')).map(entry => entry.test)).toHaveLength(1)
  expect(findUndeclaredSpawnBudgets('a.test.ts', hook(', 180_000'))).toEqual([])
  // A hook that spawns nothing is not this rule's business.
  expect(findUndeclaredSpawnBudgets('a.test.ts', 'afterEach(() => { reset() })\n')).toEqual([])
})

test('every test in this repository that spawns a process declares a budget', async () => {
  const files = [...new Bun.Glob('{scripts,packages,src,benchmarks}/**/*.test.ts').scanSync({ cwd: root })]
    .filter(file => !file.includes('node_modules') && !file.includes('/dist/'))
    .sort()
  const undeclared = (await Promise.all(files.map(async file => findUndeclaredSpawnBudgets(file, await Bun.file(resolve(root, file)).text())))).flat()
  expect(undeclared.map(entry => `${entry.file} › ${entry.test}`), 'these tests drive a real subprocess under Bun\'s inherited 5000 ms default').toEqual([])
})

/**
 * A spawn is recognised from the file's own imports, not from a list of names.
 *
 * The previous rule listed five: `Bun.spawnSync`, `Bun.spawn`, `spawnSync`,
 * `execFileSync` and `execSync`. `execFile`, `exec`, `fork`, node's bare
 * `spawn` and `Bun.$` all escaped it, so a test using any of them ran under
 * the inherited 5000 ms default — the very thing this rule exists to prevent.
 *
 * Extending the list is not the fix. `\bexec\b` matches every
 * `RegExp.prototype.exec` in the repository, and `exec` is far more often a
 * regex than a subprocess, so a bare name is only a spawn when the file
 * imported it from `child_process`.
 */
test('a spawn is derived from what the file imported', () => {
  const cases: [string, string, boolean][] = [
    // Each of these escaped the five-name list.
    ['import { execFile } from \'node:child_process\'', 'execFile(bin, [], () => {})', true],
    ['import { spawn } from \'node:child_process\'', 'const p = spawn(bin, [])', true],
    ['import { fork } from \'node:child_process\'', 'fork(worker)', true],
    ['import { exec } from \'child_process\'', 'exec("ls", () => {})', true],
    // Both spellings of the specifier. updater-macos-bundle.test.ts — the file
    // behind #490's 30002 ms occurrence — uses the unprefixed one, so a rule
    // keyed on `node:child_process` alone would miss it.
    ['import { execFileSync } from \'child_process\'', 'execFileSync(bin, [])', true],
    // Aliases bind a different local name.
    ['import { spawn as launch } from \'node:child_process\'', 'launch(bin, [])', true],
    // Namespace and require forms: any member call counts.
    ['import * as cp from \'node:child_process\'', 'cp.execFile(bin, [])', true],
    ['const cp = require(\'node:child_process\')', 'cp.spawnSync(bin, [])', true],
    // Bun's own routes, which need no import.
    ['', 'Bun.$`ls`', true],
    ['import { $ } from \'bun\'', '$`ls`', true],
    ['', 'Bun.spawnSync([bin])', true],
    // The false positives that forbid simply listing the names.
    ['', 'const m = /x/.exec(text)', false],
    ['', 'expect(pattern.exec(line)).toBeNull()', false],
    // And a regex `exec` stays a regex even where the file imports the real one.
    ['import { exec } from \'node:child_process\'', 'const m = /x/.exec(text)', false],
    // A spawn named inside an embedded fixture script is not performed.
    ['', 'const script = `Bun.spawnSync(["ls"])`', false],
    ['', 'expect(1).toBe(1)', false],
  ]
  const wrong = cases
    .filter(([imports, body, want]) => spawnsRealProcess(body, spawnNames(imports)) !== want)
    .map(([imports, body, want]) => `${want ? 'missed' : 'false positive on'} ${JSON.stringify(body)} with ${JSON.stringify(imports)}`)
  expect(wrong).toEqual([])
})

test('the derivation reads the local name, not the exported one', () => {
  expect(spawnNames('import { spawn as launch, execFile } from \'node:child_process\'')).toEqual(['execFile', 'launch'])
  // A namespace binding is recorded with its dot, so any member call matches.
  expect(spawnNames('import * as cp from \'node:child_process\'')).toEqual(['cp.'])
  // Unrelated modules contribute nothing, however similarly named.
  expect(spawnNames('import { spawn } from \'./my-child_process\'')).toEqual([])
  expect(spawnNames('import { join } from \'node:path\'')).toEqual([])
})
