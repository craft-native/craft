import { expect, test } from 'bun:test'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

/**
 * A frame acknowledgement that fails says what it read instead.
 *
 * #452's single retained attempt carried no observed label. The debug
 * attachment holds the query chain and nothing else, so working out what the
 * status label actually said took a 136MB artifact, a frame-by-frame listing
 * of the screen recording's presentation timestamps, and reading the text out
 * of the video. The answer was that the label had read `Verified frame 60`
 * since 1.2 seconds before the ten-second wait began — which the assertion
 * could have printed.
 *
 * The assertions are found rather than listed. An acknowledgement added later
 * without the observed label is the regression this exists to catch, and a
 * fixed list of the current four would not catch it.
 */
const fixture = readFileSync(join(import.meta.dir, '../fixtures/metal-surface/MetalSurfaceUITests.swift'), 'utf8')

/** The fixture's source with comments removed, so prose cannot satisfy a scan. */
const code = fixture.replace(/^\s*\/\/[^\n]*$/gm, '')

/** Every `XCTAssert…(…)` call in the fixture, as source. */
function assertions(): string[] {
  const calls: string[] = []
  for (let at = code.indexOf('XCTAssert'); at >= 0; at = code.indexOf('XCTAssert', at + 1)) {
    const open = code.indexOf('(', at)
    if (open < 0) continue
    let depth = 0, quoted = false
    for (let index = open; index < code.length; index++) {
      const character = code[index]
      if (character === '"' && code[index - 1] !== '\\') quoted = !quoted
      if (quoted) continue
      if (character === '(') depth++
      else if (character === ')' && --depth === 0) { calls.push(code.slice(at, index + 1)); break }
    }
  }
  return calls
}

test('every frame acknowledgement reports the label it observed', () => {
  const acknowledgements = assertions().filter(call => call.includes('verifiedFrame('))
  // Four today: frame 60, and the held fixture's 59 / not-60 / resized 60.
  expect(acknowledgements.length, 'the fixture must still assert frame acknowledgements').toBeGreaterThanOrEqual(4)
  for (const call of acknowledgements) {
    expect(call, `this acknowledgement fails without saying what it read:\n${call}`).toContain('observedStatus(app)')
  }
})

test('the observed label distinguishes an absent element from an empty one', () => {
  const from = code.indexOf('private func observedStatus(')
  expect(from, 'the fixture must be able to report what it read').toBeGreaterThan(0)
  const reader = code.slice(from, code.indexOf('\n    }', from))
  // A missing element and a label reading nothing are different failures and
  // the message has to tell them apart.
  expect(reader).toContain('guard status.exists')
  expect(reader).toContain('status.label')
  // It is read after the deadline, so the message must not imply otherwise.
  expect(reader).toContain('when this was reported')
})

test('the reading stays out of the passing path', () => {
  // XCTAssert's message is an autoclosure, so the extra snapshot is only
  // taken on failure. Passing it eagerly would add an accessibility query to
  // every successful run — the very operation that took 9.292 seconds in the
  // attempt this came from.
  for (const call of assertions().filter(entry => entry.includes('observedStatus(app)'))) {
    const message = call.slice(call.indexOf(','))
    expect(message, `the observed label must sit inside the failure message:\n${call}`).toMatch(/"[^"]*\\\(observedStatus\(app\)\)[^"]*"/)
  }
})

test('the ten-second deadline and the frame count are untouched', () => {
  // #452 is explicit that the wait must not grow and the frames must not
  // shrink. The evidence says the renderer met the deadline with 1.2 seconds
  // to spare, so there is nothing here to relax.
  expect(code).toContain('verifiedFrame(60, in: app).waitForExistence(timeout: 10)')
  expect(code, 'no acknowledgement may wait longer than ten seconds').not.toMatch(/verifiedFrame\([0-9]+, in: app\)\.waitForExistence\(timeout: (1[1-9]|[2-9][0-9])/)
  const host = readFileSync(join(import.meta.dir, '../fixtures/metal-surface/HostApp.swift'), 'utf8')
  expect(host).toContain('withTimeInterval: 1.0 / 30')
  expect(host, 'all 61 native frames still run').toContain('frame == 61')
})

/**
 * Both halves of the fixture report, not just the one #452 was filed against.
 *
 * The iOS half gained the observed label; the macOS half kept the same
 * blindness for another week because it waits through `expectation(for:)` and
 * `waitForExpectations(timeout:)`, which takes no message, so a timeout
 * printed only the predicate's own description.
 *
 * Worse, its predicates were `NSPredicate { _, _ in … }` blocks that read
 * `status.value` *and* `status.label` on every evaluation — two fresh remote
 * queries onto the app's main run loop per poll. That is the operation #452
 * showed can stall and lose an observation that was already valid, so the
 * macOS half was running the exact pattern the iOS half was repaired for.
 *
 * The fixtures are discovered rather than named: a third host added here is
 * covered the moment its file lands.
 */
const fixtureDir = join(import.meta.dir, '../fixtures/metal-surface')
function uiFixtures(): { name: string, code: string }[] {
  return readdirSync(fixtureDir)
    .filter(name => name.endsWith('UITests.swift'))
    .sort()
    .map(name => ({ name, code: readFileSync(join(fixtureDir, name), 'utf8').replace(/^\s*\/\/[^\n]*$/gm, '') }))
}

/** Every `XCTAssert…(…)`/`XCTFail(…)` call in `source`, as source text. */
function callsIn(source: string, prefix: RegExp): string[] {
  const calls: string[] = []
  for (const found of source.matchAll(prefix)) {
    const open = source.indexOf('(', found.index!)
    if (open < 0) continue
    let depth = 0, quoted = false
    for (let index = open; index < source.length; index++) {
      const character = source[index]
      if (character === '"' && source[index - 1] !== '\\') quoted = !quoted
      if (quoted) continue
      if (character === '(') depth++
      else if (character === ')' && --depth === 0) { calls.push(source.slice(found.index!, index + 1)); break }
    }
  }
  return calls
}

test('both Metal UI fixtures exist and are scanned', () => {
  // A floor: a broken glob must not make every case below pass by finding
  // nothing, and the macOS half must not quietly stop being checked.
  expect(uiFixtures().map(entry => entry.name))
    .toEqual(['MacMetalSurfaceUITests.swift', 'MetalSurfaceUITests.swift'])
})

for (const { name } of uiFixtures()) {
  test(`${name} reports what it read when a wait fails`, () => {
    const { code } = uiFixtures().find(entry => entry.name === name)!
    expect(code.indexOf('private func observedStatus('), `${name} must be able to report what it read`).toBeGreaterThan(0)
    // Derived from the calls, not from a list of them: any wait that can fail
    // has to say what the element read instead.
    const waits = callsIn(code, /XCTAssert\w+/g).filter(call => call.includes('waitForExistence('))
    expect(waits.length, `${name} must still wait on something`).toBeGreaterThan(0)
    for (const call of waits)
      expect(call, `this wait fails without saying what it read:\n${call}`).toContain('observedStatus(app)')
    for (const call of callsIn(code, /XCTFail/g))
      expect(call, `this failure says nothing about the app:\n${call}`).toContain('observedStatus(app)')
  })

  test(`${name} does not re-query the status element inside a predicate`, () => {
    const { code } = uiFixtures().find(entry => entry.name === name)!
    // A block predicate runs locally and queries the app again on every
    // evaluation. The reading must come from the snapshot that matched, which
    // is what a format predicate does.
    for (const block of code.matchAll(/NSPredicate\s*\{[^}]*\}/g)) {
      expect(block[0], `this predicate re-queries the status element every evaluation:\n${block[0]}`)
        .not.toMatch(/status\s*\.\s*(?:value|label)/)
    }
    // And no wait may be left with no way to carry a message.
    expect(code, `${name} must not wait through waitForExpectations, which takes no message`)
      .not.toContain('waitForExpectations(')
  })

  test(`${name} keeps its ten-second waits`, () => {
    const { code } = uiFixtures().find(entry => entry.name === name)!
    // #452 forbids growing the wait. Every explicit timeout in these fixtures
    // is ten seconds or less, and the one-second negative check stays one.
    const timeouts = [...code.matchAll(/timeout: (\d+)/g)].map(found => Number(found[1]))
    expect(timeouts.length, `${name} must declare its deadlines`).toBeGreaterThan(0)
    expect(timeouts.filter(value => value > 10), `${name} grew a deadline`).toEqual([])
  })
}
