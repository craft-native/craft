import { expect, test } from 'bun:test'
import { resolve } from 'node:path'
import { blankLiterals, bunDefaultTestTimeoutMs, describeConflict, findDeadlineBudgetConflicts, readBudgets, readTestBlocks, requiredHeadroomMs } from './test-deadline-budgets'

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
