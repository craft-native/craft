import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * `craft.files.write` writes the string it was given, or refuses.
 *
 * Android read its name and contents with `optString`, which reads anything.
 * A number became its digits, `null` the four letters "null", and bytes
 * handed over as they were became JSON text, because that is how a
 * `Uint8Array` crosses the bridge:
 *
 *   craft.files.write('route.bin', bytes)   // a file reading {"0":104,"1":105}
 *
 * Each was written and answered as a success. With `encoding: 'base64'` a
 * `null` decoded, as the letters n-u-l-l, to three bytes of nothing anyone
 * wrote. UIKit refuses all of these with `INVALID_ARGUMENT`.
 *
 * The cases are shared by the three hosts (`files-write-cases.json`): the
 * arguments as they cross the bridge, and the bytes written or `null` where
 * the call must reject. The function under test is the shipped `write`, with
 * the shipped base64 reader; the disk is replaced by the bytes it was handed.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
const table = readFileSync(join(import.meta.dir, 'files-write-cases.json'), 'utf8')
const { cases } = JSON.parse(table) as { cases: { label: string, args: unknown[], bytes: string | null }[] }

test('the cases ask both questions', () => {
  // A floor: a table that only accepted, or only refused, would hold nothing.
  expect(cases.filter(row => row.bytes === null).length).toBeGreaterThan(10)
  expect(cases.filter(row => row.bytes !== null).length).toBeGreaterThan(10)
  expect(new Set(cases.map(row => row.label)).size, 'labels name a case').toBe(cases.length)
})

test('files.write is answered by that function', () => {
  expect(template).toContain('"write" -> write(args)')
  // Reading the name or the contents with optString is what let anything through.
  const write = liftKotlinMember(template, 'fun write')
  expect(write).not.toContain('args.optString(')
  expect(write).not.toContain('optString("encoding"')
})

test('Android writes what the shared cases say, and refuses the rest', async () => {
  // The table crosses into Kotlin as base64 of its UTF-8, so no string
  // literal's escaping can change what is being asked.
  const encoded = Buffer.from(table, 'utf8').toString('base64')
  await runKotlinFixture(`
import java.net.URLConnection
import org.json.JSONArray
import org.json.JSONObject

internal data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)

/** Lenient as Android's is: what it does not know, it skips. */
object Base64 {
    const val DEFAULT = 0
    fun decode(text: String, @Suppress("UNUSED_PARAMETER") flags: Int): ByteArray = java.util.Base64.getMimeDecoder().decode(text)
}

internal class Files {
    private fun success(data: Any?) = CraftNativeCapabilityResult(data = data)
    private fun failure(code: String, message: String) = CraftNativeCapabilityResult(code = code, message = message)
    /** The disk: what would have been written. */
    private fun store(bytes: ByteArray, @Suppress("UNUSED_PARAMETER") name: String, @Suppress("UNUSED_PARAMETER") type: String) =
        success(bytes.joinToString("") { "%02x".format(it) })

${liftKotlinMember(template, 'decodeBase64')}

${liftKotlinMember(template, 'fun write')}

    fun ask(args: JSONArray): CraftNativeCapabilityResult = write(args)
}

fun main() {
    val table = JSONObject(String(java.util.Base64.getDecoder().decode("${encoded}"), Charsets.UTF_8)).getJSONArray("cases")
    val files = Files()
    val wrong = mutableListOf<String>()
    for (at in 0 until table.length()) {
        val row = table.getJSONObject(at)
        val expected = if (row.isNull("bytes")) "INVALID_ARGUMENT" else "wrote " + row.getString("bytes")
        val answer = files.ask(row.getJSONArray("args"))
        val got = if (answer.code != null) answer.code else "wrote " + answer.data
        if (got != expected) wrong.add(row.getString("label") + ": expected " + expected + ", Android " + got)
    }
    if (wrong.isNotEmpty()) throw AssertionError("files.write differs from the shared cases:\\n" + wrong.joinToString("\\n"))
    println("files.write fixture passed, " + table.length() + " cases")
}
`, ['org.json:json:20240303'])
}, 300_000)
