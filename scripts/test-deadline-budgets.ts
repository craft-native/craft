/**
 * Keep a test's own deadline larger than the deadlines it asserts about.
 *
 * Several of this repository's tests drive a real subprocess through a bounded
 * command helper — `nativeFixtureCommand`, `NativeFixtureCommandScope.run`,
 * `retainNativeNavigationEvidence` — and pass it an explicit `timeoutMs`. That
 * inner budget is the thing under test: when it elapses, the helper kills the
 * process group and returns a receipt that now records `timedOut`, `elapsedMs`
 * and `msSinceLastOutput`, which is what separates a starved run from a stalled
 * one (#447).
 *
 * None of that can happen if the enclosing test is allowed to expire first.
 * Bun's per-test default is 5000 ms, and a test that exceeds it is aborted
 * where it stands: the failure is the bare line `this test timed out after
 * 5000ms`, the helper never reports, and — measured, not assumed — the test
 * body's own `finally` does not run, so its temporary directory and its
 * assertion that the owned process group was disposed are both skipped.
 *
 * So an inner budget at or above the enclosing budget is not a tight deadline
 * to be loosened; it is a deadline that can never be observed. #490 recorded
 * `real compiler failure preserves exit status and full log without starting
 * an emulator` failing at 5000.43 ms, which is Bun's cap to the millisecond
 * rather than that test's 10000 ms command budget.
 *
 * This derives the rule from the source instead of listing the files that
 * happen to break it today, so a new bounded test cannot quietly reintroduce
 * it. `scripts/native/windows-command.test.ts` is the shape that passes: every
 * bounded test there carries its own larger timeout.
 */

/** Bun's per-test timeout when a test declares none. */
export const bunDefaultTestTimeoutMs = 5000

/** How much room a test needs beyond the budget it is asserting about. */
export const requiredHeadroomMs = 1000

export interface DeadlineBudgetConflict {
  file: string
  test: string
  /** The enclosing test's timeout, explicit or Bun's default. */
  testTimeoutMs: number
  /** Whether that timeout was written down or inherited. */
  declared: boolean
  /** The largest inner command budget the test passes. */
  budgetMs: number
}

interface TestBlock { name: string, body: string, timeoutMs: number | null, start: number, end: number }

/**
 * Find each `test(...)`/`it(...)` call, its body and its trailing timeout.
 *
 * Deliberately a scanner rather than a parser: it tracks strings, template
 * literals and comments so that braces and parens inside them — this suite's
 * fixtures embed whole scripts in template literals — do not end a block
 * early.
 */
export function readTestBlocks(source: string): TestBlock[] {
  const blocks: TestBlock[] = []
  const opening = /\b(?:test|it)(?:\.\w+)*\s*\(/g
  let match: RegExpExecArray | null
  while ((match = opening.exec(source)) !== null) {
    const open = match.index + match[0].length - 1
    if (blocks.some(block => open > block.start && open < block.end)) continue
    const end = matchingParen(source, open)
    if (end === null) continue
    const inside = source.slice(open + 1, end)
    const name = /^\s*(['"`])((?:\\.|(?!\1).)*)\1/.exec(inside)?.[2] ?? ''
    const trailing = /,\s*([0-9][0-9_]*)\s*$/.exec(inside)
    blocks.push({ name, body: inside, timeoutMs: trailing ? Number(trailing[1]!.replace(/_/g, '')) : null, start: open, end })
    opening.lastIndex = end
  }
  return blocks
}

function matchingParen(source: string, open: number): number | null {
  let depth = 0
  for (let index = open; index < source.length; index++) {
    const character = source[index]!
    if (character === '/' && source[index + 1] === '/') { index = indexOrEnd(source.indexOf('\n', index)); continue }
    if (character === '/' && source[index + 1] === '*') { index = indexOrEnd(source.indexOf('*/', index)) + 1; continue }
    if (character === '\'' || character === '"' || character === '`') { index = skipString(source, index); continue }
    if (character === '(' || character === '[' || character === '{') depth++
    else if (character === ')' || character === ']' || character === '}') {
      depth--
      if (depth === 0) return character === ')' ? index : null
    }
  }
  return null

  function indexOrEnd(found: number) { return found === -1 ? source.length : found }
}

function skipString(source: string, start: number): number {
  const quote = source[start]!
  for (let index = start + 1; index < source.length; index++) {
    const character = source[index]!
    if (character === '\\') { index++; continue }
    if (quote === '`' && character === '$' && source[index + 1] === '{') {
      let depth = 1
      index += 2
      for (; index < source.length && depth > 0; index++) {
        if (source[index] === '{') depth++
        else if (source[index] === '}') depth--
        else if (source[index] === '\'' || source[index] === '"' || source[index] === '`') index = skipString(source, index)
      }
      index--
      continue
    }
    if (character === quote) return index
  }
  return source.length
}

/**
 * Blank out comments and string contents, keeping the source's length and its
 * template interpolations, which are code.
 *
 * A budget only counts when the test actually passes it. This suite's fixtures
 * embed whole scripts — and this rule's own tests embed sample test sources —
 * so a `timeoutMs:` inside a literal is text about a deadline, not a deadline.
 */
export function blankLiterals(source: string): string {
  const out = source.split('')
  const blank = (from: number, to: number) => {
    for (let index = from; index < Math.min(to, out.length); index++) if (out[index] !== '\n') out[index] = ' '
  }
  for (let index = 0; index < source.length; index++) {
    const character = source[index]!
    if (character === '/' && source[index + 1] === '/') {
      const end = source.indexOf('\n', index)
      blank(index, end === -1 ? source.length : end)
      index = end === -1 ? source.length : end
      continue
    }
    if (character === '/' && source[index + 1] === '*') {
      const end = source.indexOf('*/', index)
      blank(index, end === -1 ? source.length : end + 2)
      index = end === -1 ? source.length : end + 1
      continue
    }
    if (character === '\'' || character === '"' || character === '`') {
      const end = skipString(source, index)
      if (character === '`') {
        // Keep `${ … }` contents: they are expressions, not text.
        let cursor = index + 1
        while (cursor < end) {
          const open = source.indexOf('${', cursor)
          if (open === -1 || open >= end) break
          blank(cursor, open)
          let depth = 1, scan = open + 2
          for (; scan < end && depth > 0; scan++) {
            if (source[scan] === '{') depth++
            else if (source[scan] === '}') depth--
            else if (source[scan] === '\'' || source[scan] === '"' || source[scan] === '`') scan = skipString(source, scan)
          }
          cursor = scan
        }
        blank(cursor, end)
      }
      else { blank(index + 1, end) }
      index = end
      continue
    }
  }
  return out.join('')
}

/** Every inner command budget a test body declares. */
export function readBudgets(body: string): number[] {
  return [...blankLiterals(body).matchAll(/\btimeoutMs:\s*([0-9][0-9_]*)\b/g)].map(found => Number(found[1]!.replace(/_/g, '')))
}

/** Tests whose own deadline leaves no room for the deadline they assert about. */
export function findDeadlineBudgetConflicts(file: string, source: string): DeadlineBudgetConflict[] {
  return readTestBlocks(source).flatMap((block) => {
    const budgets = readBudgets(block.body)
    if (!budgets.length) return []
    const budgetMs = Math.max(...budgets)
    const testTimeoutMs = block.timeoutMs ?? bunDefaultTestTimeoutMs
    if (testTimeoutMs >= budgetMs + requiredHeadroomMs) return []
    return [{ file, test: block.name, testTimeoutMs, declared: block.timeoutMs !== null, budgetMs }]
  })
}

/** One line per conflict, saying what to write down rather than what to loosen. */
export function describeConflict(conflict: DeadlineBudgetConflict): string {
  const own = conflict.declared ? `its own ${conflict.testTimeoutMs} ms timeout` : `Bun's default ${conflict.testTimeoutMs} ms timeout`
  return `${conflict.file} › ${conflict.test}: asserts a ${conflict.budgetMs} ms command budget under ${own}; give the test at least ${conflict.budgetMs + requiredHeadroomMs} ms so the budget can report instead of being cut off.`
}
