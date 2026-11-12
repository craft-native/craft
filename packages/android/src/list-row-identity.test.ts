import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * Every row of a list has an identity of its own, whatever its key.
 *
 * Rows that share a key are told apart by a suffix: `run`, then `run#1`. A
 * row whose own key was `run#1` then had the identity of the second `run`.
 * On Android two rows shared a stable id, which a RecyclerView requires to
 * be unique; on iOS the list's table trapped and the process ended
 * (`Fatal error: Duplicate values for key: 'run#1'`). Keys are data: a list
 * of tags keyed by their text is enough.
 *
 * The function under test is the shipped one, lifted from the list. The
 * same rows are drawn on an emulator in NativeFlatListTest
 * (rowsWhoseKeysCollideWithTheSuffixOfARepeatKeepIdentitiesOfTheirOwn), and
 * UIKit's copy of the rule is run in packages/ios/src/list-row-identity.test.ts
 * against the same table (`list-row-identity-cases.json`).
 */
const list = readFileSync(join(import.meta.dir, '../templates/CraftNativeFlatList.kt.template'), 'utf8')

/** Row keys in order, and the identity each row must get. UIKit's copy is run on the same file. */
const cases: { keys: string[], identities: string[], why: string }[] = JSON.parse(readFileSync(join(import.meta.dir, 'list-row-identity-cases.json'), 'utf8'))

test('rows whose keys collide with the suffix of a repeat get identities of their own', async () => {
  const literal = (keys: string[]) => `listOf<String>(${keys.map(key => JSON.stringify(key).replaceAll('$', '\\$')).join(', ')})`
  const source = `
class Rows {
${liftKotlinMember(list, 'fun uniqueIdentity')}

    fun identities(keys: List<String>): List<String> {
        val seen = mutableMapOf<String, Int>()
        val taken = mutableSetOf<String>()
        return keys.map { uniqueIdentity(it, seen, taken) }
    }
}

fun main() {
    val cases = listOf(
${cases.map(({ keys, identities }) => `        ${literal(keys)} to ${literal(identities)},`).join('\n')}
    )
    for ((keys, expected) in cases) {
        val got = Rows().identities(keys)
        check(got == expected) { "$keys: expected $expected, got $got" }
        check(got.toSet().size == got.size) { "$keys: two rows share an identity: $got" }
    }
}
`
  await runKotlinFixture(source)
}, 300_000)

test('the list gives each row the identity that function returns', () => {
  expect(list).toContain('val unique = uniqueIdentity(base, seen, taken)')
  expect(list).not.toContain('val unique = if (occurrence == 0) base else "$base#$occurrence"')
})
