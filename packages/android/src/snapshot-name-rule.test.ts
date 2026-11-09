/**
 * Run the real `isSnapshotName` pattern through Kotlin's own regex engine.
 *
 * The cross-host contract test in `scripts/native-renderer-contract.test.ts`
 * compares the two hosts' rules by re-implementing them in TypeScript and
 * evaluating Android's pattern with JavaScript's `RegExp`. That proves the rule
 * agrees with UIKit's; it does not prove Kotlin reads the pattern the same way
 * JavaScript does. A character class holding `:` and a trailing `-` is the kind
 * of thing two engines can disagree about, and the pattern is a string literal
 * the Kotlin compiler never inspects — a green `android-builder` says it parses
 * as a string, not that it matches the same names.
 *
 * So this extracts the pattern from the template and compares it against a
 * transcription of `CraftSnapshots.isValidName`, inside Kotlin, over generated
 * names rather than a hand-picked list.
 */
import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { runKotlinFixture } from './testing'

const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

test('Kotlin accepts exactly the snapshot names UIKit does', async () => {
  const pattern = /private fun isSnapshotName\([^)]*\): Boolean = name\.matches\(Regex\("([^"]+)"\)\)/.exec(shell)?.[1]
  expect(pattern, 'isSnapshotName must be a single Regex literal this test can extract').toBeTruthy()

  await runKotlinFixture(`
// Extracted from CraftNativeShell.kt.template, not retyped.
private val snapshotName = Regex(${JSON.stringify(pattern)})
private fun androidValid(name: String): Boolean = snapshotName.matches(name)

/**
 * \`CraftSnapshots.isValidName\`, transcribed:
 *   !name.isEmpty && name.count <= 128 && !name.hasPrefix(".")
 *     && name.unicodeScalars.allSatisfy { $0.isASCII && (alphanumerics.contains($0) || "-_.:".contains($0)) }
 *
 * Swift counts grapheme clusters and Kotlin counts UTF-16 units; every name
 * that can pass is ASCII, where the two agree, and a non-ASCII name is
 * rejected by both before length matters.
 */
private fun iosValid(name: String): Boolean {
    if (name.isEmpty() || name.length > 128 || name.startsWith(".")) return false
    return name.all { it.code < 128 && (it.isLetterOrDigit() || it in "-_.:") }
}

fun main() {
    val alphabet = listOf("a", "Z", "0", "9", "-", "_", ".", ":", "/", " ", "+", "*", "%", "\\u00e9", "\\t", "\\n")
    val names = mutableListOf("")
    for (piece in alphabet) {
        names += piece
        names += "a" + piece
        names += piece + "a"
        names += "a" + piece + "b"
        names += piece.repeat(3)
    }
    names += listOf("account:slot", "a.b", "a-b_c.d:e", "a".repeat(127), "a".repeat(128), "a".repeat(129), ":".repeat(128))

    val disagreements = names.filter { androidValid(it) != iosValid(it) }
    if (disagreements.isNotEmpty()) {
        for (name in disagreements) {
            println("DISAGREE " + name.map { it.code } + " android=" + androidValid(name) + " ios=" + iosValid(name))
        }
        throw IllegalStateException("The hosts disagree on " + disagreements.size + " of " + names.size + " snapshot names")
    }

    // The cases that motivated this: the colon must be accepted, and the rule
    // must still refuse what it always refused.
    for (name in listOf("account:slot", ":lead", "a", "a".repeat(128))) {
        if (!androidValid(name)) throw IllegalStateException("Kotlin refused a valid name: " + name.take(16))
    }
    for (name in listOf("", ".lead", "has space", "has/slash", "a".repeat(129))) {
        if (androidValid(name)) throw IllegalStateException("Kotlin accepted an invalid name: " + name.take(16))
    }
    println("Kotlin and UIKit agree on all " + names.size + " snapshot names")
}
`)
}, 240_000)
