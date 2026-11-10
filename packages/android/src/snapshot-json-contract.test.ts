import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'
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
 * The oracle is Foundation itself, not a restatement of it. Every case below
 * is run through real `JSONSerialization` with `swiftc` and through the
 * scanner extracted from the Android template with Kotlin, and the two
 * verdicts must agree. That matters because Foundation's grammar is **not**
 * RFC 8259 and the difference is not guessable: it accepts one trailing comma
 * in an object or array, so a strict parser would have diverged in the
 * opposite direction to the defect it was fixing.
 *
 * A disagreement names the input and both verdicts rather than reporting a
 * count, because the whole point is which payload the hosts differ on.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

/**
 * Payloads, chosen to walk the grammar rather than to pass.
 *
 * Real snapshots, every scalar fragment, both trailing-comma forms and their
 * malformed neighbours, surrogate pairing, control characters, the number
 * grammar's edges, and the lenient spellings `org.json` would wrongly admit.
 */
const payloads: string[] = [
  // Ordinary documents.
  '{}', '[]', '{"a":1}', '{"a":[1,{"b":null}]}', '{"a":{"b":{"c":[1,2,3]}}}',
  '[{"a":1},{"b":2}]', '{"":1}', '{"a":1,"a":2}', '[[[[1]]]]',
  // Fragments: UIKit allows them, android.util.JsonReader in strict mode does not.
  '"text"', '42', '-0.5', '1e10', 'true', 'false', 'null',
  // Trailing commas: one is accepted, which is the surprising part.
  '{"a":1,}', '[1,]', '{"a":1,,}', '[1,,2]', '[,1]', '{,"a":1}',
  // Nothing at all.
  '', '   ',
  // Spellings org.json's JSONTokener would admit and Foundation will not.
  '{a:1}', "{'a':1}", "'single'", '`backtick`', 'undefined',
  // Numbers.
  '0', '00', '0.0', '-1', '-1.5e-3', '1E+2', '[01]', '[+1]', '[.5]', '[1.]',
  '[NaN]', '[Infinity]', '1.0e',
  // Strings and escapes.
  '"\\t"', '"\\/"', '"\\\\"', '"\\u0041"', '"\\u00zz"', '"\\q"',
  '"\\ud83d\\ude00"', '"\\ud83d"', '"\\ude00"', '"\\ud83da"',
  '"tab\there"', '"unterminated',
  // Trailing content.
  '[1,2]extra', '[]extra', '{"a":1}{"b":2}', 'truex', 'nul',
  // Surrounding whitespace is fine.
  ' {"a":1} ', '\t{"a":1}',
  // Malformed members.
  '{"a":}', '{:1}', '{"a"}',
]

/** The scanner's source, lifted from the template rather than retyped. */
function scannerSource(): string {
  const from = template.indexOf('private class CraftNativeJsonScanner(')
  expect(from, 'the shell must carry a JSON scanner').toBeGreaterThan(0)
  const to = template.indexOf('private fun craftNativeIsJsonText(')
  expect(to).toBeGreaterThan(from)
  return template.slice(from, to).replace(/^private /gm, '')
}

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

test.skipIf(process.platform !== 'darwin')('Kotlin and Foundation agree on every payload', async () => {
  const dir = createTempDir('craft-snapshot-json-')
  let expected: boolean[] = []
  try {
    // Foundation's own verdict, from the framework the host actually uses.
    const probe = join(dir, 'main.swift'), binary = join(dir, 'probe'), input = join(dir, 'cases.json')
    writeFileSync(probe, `import Foundation
let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try! JSONSerialization.jsonObject(with: raw) as! [String]
for text in cases {
    let ok = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    print(ok ? "accept" : "reject")
}
`)
    writeFileSync(input, JSON.stringify(payloads))
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary, input], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)
    const verdicts = run.stdout.toString().trim().split('\n')
    expect(verdicts.length, 'every payload must get a verdict').toBe(payloads.length)
    expected = verdicts.map(verdict => verdict === 'accept')

    // The grammar's surprise, asserted so a future reader cannot mistake
    // these for oversights in the table.
    expect(expected[payloads.indexOf('{"a":1,}')], 'Foundation accepts one trailing comma').toBe(true)
    expect(expected[payloads.indexOf('{"a":1,,}')], 'but not two').toBe(false)
    expect(expected[payloads.indexOf('42')], 'and accepts top-level fragments').toBe(true)
  }
  finally { removeTempDir(dir) }

  const literal = (text: string): string => JSON.stringify(text)
    .replace(/\$/g, '\\$')
  await runKotlinFixture(`
${scannerSource()}

fun craftNativeIsJsonText(text: String): Boolean = CraftNativeJsonScanner(text).validate()

fun main() {
    val cases = listOf(${payloads.map(literal).join(',\n        ')})
    val expected = listOf(${expected.join(', ')})
    val wrong = cases.indices.filter { craftNativeIsJsonText(cases[it]) != expected[it] }
    if (wrong.isNotEmpty()) {
        val detail = wrong.joinToString("; ") {
            val foundation = if (expected[it]) "accept" else "reject"
            val kotlin = if (expected[it]) "reject" else "accept"
            "\\"" + cases[it] + "\\" Foundation=" + foundation + " Kotlin=" + kotlin
        }
        throw AssertionError("Kotlin and Foundation disagree on " + wrong.size + " payload(s): " + detail)
    }
    println("Kotlin and Foundation agree on all " + cases.size + " snapshot payloads")
}
`)
}, 300_000)
