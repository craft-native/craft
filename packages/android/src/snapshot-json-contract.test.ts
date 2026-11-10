import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { runKotlinFixture } from './testing'

/**
 * Android accepts exactly the snapshot payloads UIKit accepts.
 *
 * UIKit refuses a snapshot whose payload is not JSON before it touches the
 * disk — `JSONSerialization.jsonObject(with:options: [.fragmentsAllowed])`
 * returning nil fails the write. Android had no such check, so a payload iOS
 * rejected was written here and the two hosts disagreed about whether a
 * checkpoint had been kept (#396).
 *
 * The verdicts in `snapshot-json-cases.json` are Foundation's own, not a
 * restatement of the JSON standard — which matters, because Foundation's
 * grammar is **not** RFC 8259: it accepts one trailing comma in an object or
 * array, so a strict parser would have diverged in the opposite direction to
 * the defect it was fixing.
 *
 * The contract has two halves and they run in different places, because no
 * CI job has both Swift and Kotlin:
 *
 *  - this file runs the scanner against the recorded verdicts wherever Gradle
 *    is, which is the Linux `Test Android builder` job;
 *  - `packages/ios/src/snapshot-json-oracle.test.ts` re-runs the payloads
 *    through real `JSONSerialization` on macOS and requires the recording to
 *    still be right.
 *
 * An earlier version of this did both at once behind a `darwin` gate, which
 * meant it ran in no CI job at all — `packages/android`'s suite is Linux.
 * `scripts/test-reachability.test.ts` caught that.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

interface Recorded { note: string, cases: { payload: string, accepted: boolean }[] }
const recorded = JSON.parse(readFileSync(join(import.meta.dir, 'snapshot-json-cases.json'), 'utf8')) as Recorded

/** The scanner's source, lifted from the template rather than retyped. */
function scannerSource(): string {
  const from = template.indexOf('private class CraftNativeJsonScanner(')
  expect(from, 'the shell must carry a JSON scanner').toBeGreaterThan(0)
  const to = template.indexOf('private fun craftNativeIsJsonText(')
  expect(to).toBeGreaterThan(from)
  return template.slice(from, to).replace(/^private /gm, '')
}

test('the recorded payloads still walk the grammar', () => {
  const payloads = recorded.cases.map(entry => entry.payload)
  expect(payloads.length).toBeGreaterThanOrEqual(60)
  // Both verdicts well represented: a table that is all accepts, or all
  // rejects, would pass against a scanner that always says one thing.
  const accepted = recorded.cases.filter(entry => entry.accepted).length
  expect(accepted).toBeGreaterThan(20)
  expect(recorded.cases.length - accepted).toBeGreaterThan(20)
  // The surprise, named so nobody "corrects" the recording to match the
  // standard instead of Foundation.
  expect(recorded.cases.find(entry => entry.payload === '{"a":1,}')?.accepted,
    'Foundation accepts one trailing comma').toBe(true)
  expect(recorded.cases.find(entry => entry.payload === '{"a":1,,}')?.accepted, 'but not two').toBe(false)
  expect(recorded.cases.find(entry => entry.payload === '42')?.accepted,
    'and accepts top-level fragments').toBe(true)
})

test('the Android snapshot write refuses what UIKit refuses', () => {
  // Comments stripped: a note about validating is not a validation.
  const code = template.replace(/^\s*\/\/[^\n]*$/gm, '')
  const setSnapshot = code.slice(code.indexOf('fun setSnapshot('), code.indexOf('fun clearSnapshots('))
  expect(setSnapshot, 'a non-JSON payload must fail before the disk is touched')
    .toContain('craftNativeIsJsonText(json)')
  // Before the writer, as UIKit fails before its queue.
  expect(setSnapshot.indexOf('craftNativeIsJsonText(json)'))
    .toBeLessThan(setSnapshot.indexOf('writer.execute'))
  // The existing name guard is not replaced by it.
  expect(setSnapshot).toContain('isSnapshotName(name)')
})

test('the Kotlin scanner agrees with every recorded verdict', async () => {
  const literal = (text: string): string => JSON.stringify(text).replace(/\$/g, '\\$')
  await runKotlinFixture(`
${scannerSource()}

fun craftNativeIsJsonText(text: String): Boolean = CraftNativeJsonScanner(text).validate()

fun main() {
    val cases = listOf(${recorded.cases.map(entry => literal(entry.payload)).join(',\n        ')})
    val expected = listOf(${recorded.cases.map(entry => entry.accepted).join(', ')})
    val wrong = cases.indices.filter { craftNativeIsJsonText(cases[it]) != expected[it] }
    if (wrong.isNotEmpty()) {
        val detail = wrong.joinToString("; ") {
            val foundation = if (expected[it]) "accept" else "reject"
            val kotlin = if (expected[it]) "reject" else "accept"
            "\\"" + cases[it] + "\\" Foundation=" + foundation + " Kotlin=" + kotlin
        }
        throw AssertionError("Kotlin and Foundation disagree on " + wrong.size + " payload(s): " + detail)
    }
    println("Kotlin matches Foundation on all " + cases.size + " snapshot payloads")
}
`)
}, 300_000)
