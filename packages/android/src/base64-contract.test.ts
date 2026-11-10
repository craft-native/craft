import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * `craft.files.write` reads base64 on Android as `atob` does.
 *
 * The three hosts read the same `encoding: 'base64'` contents three ways.
 * The browser host calls `atob`. UIKit called Foundation, which refuses
 * unpadded text. Android called its own decoder, which skips every character
 * it does not know rather than refusing it — so the `-` and `_` of a URL-safe
 * encoding vanished, and a file with the wrong bytes was written and
 * reported as a success.
 *
 * Both native hosts now read it themselves, to `atob`'s grammar, and hand the
 * platform decoder only what is already known to be valid. The verdict for
 * each payload below is whatever `atob` gives when this runs, so nothing is
 * recorded that could drift; `packages/ios/src/base64-contract.test.ts` holds
 * UIKit to the same payloads.
 *
 * The function under test is the shipped one. `android.util.Base64` is not on
 * a JVM, so it is stood in for by the JDK's MIME decoder, chosen because it
 * is lenient in the same way: it skips what it does not know. A reader that
 * let a bad payload through would therefore pass it here as it would on a
 * device. What that stand-in cannot show is Android's decoder itself; the
 * device test asserts a URL-safe payload is refused for that.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
const { cases } = JSON.parse(readFileSync(join(import.meta.dir, 'base64-cases.json'), 'utf8')) as { cases: string[] }

/** What `atob` makes of it: the bytes in hex, or null where it refuses. */
function expected(payload: string): string | null {
  try { return [...atob(payload)].map(letter => letter.charCodeAt(0).toString(16).padStart(2, '0')).join('') }
  catch { return null }
}

test('the payloads ask both questions', () => {
  // A floor: a list `atob` accepted all of, or none of, would hold nothing.
  const verdicts = cases.map(expected)
  expect(verdicts.filter(verdict => verdict === null).length).toBeGreaterThan(15)
  expect(verdicts.filter(verdict => verdict !== null).length).toBeGreaterThan(15)
  // And the two that motivated this are among them, with the verdicts claimed.
  expect(expected('YW-j'), 'URL-safe text is not base64').toBeNull()
  expect(expected('YQ'), 'unpadded text is').toBe('61')
})

test('Android reads base64 as atob does', async () => {
  // Each payload crosses into Kotlin as its UTF-16 code units, so nothing
  // about escaping a string literal can change what is being asked.
  const rows = cases.map((payload) => {
    const units = [...Array.from({ length: payload.length }, (_, at) => payload.charCodeAt(at))].join(', ')
    const verdict = expected(payload)
    return `    Row(intArrayOf(${units}), ${verdict === null ? 'null' : `"${verdict}"`}),`
  }).join('\n')
  await runKotlinFixture(`
/** Lenient as Android's is: what it does not know, it skips. */
object Base64 {
    const val DEFAULT = 0
    fun decode(text: String, @Suppress("UNUSED_PARAMETER") flags: Int): ByteArray = java.util.Base64.getMimeDecoder().decode(text)
}

class Reader {
${liftKotlinMember(template, 'decodeBase64')}
    fun read(text: String): ByteArray? = decodeBase64(text)
}

class Row(val units: IntArray, val expected: String?)

val rows = listOf(
${rows}
)

fun main() {
    val reader = Reader()
    val wrong = mutableListOf<String>()
    for (row in rows) {
        val payload = String(CharArray(row.units.size) { row.units[it].toChar() })
        val answer = reader.read(payload)?.joinToString("") { "%02x".format(it) }
        if (answer != row.expected) wrong.add(row.units.joinToString(",") + " atob=" + row.expected + " android=" + answer)
    }
    if (wrong.isNotEmpty()) throw AssertionError("Android reads these differently from atob:\\n" + wrong.joinToString("\\n"))
    println("base64 fixture passed, " + rows.size + " payloads")
}
`)
}, 300_000)
