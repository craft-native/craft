import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * `autoFocus` focuses a field when it mounts, or when its author turns it on.
 *
 * It was applied on every render: `if (autoFocus && !isFocused) post { focus }`
 * ran each time the field was reconciled. Put the keyboard away, let a timer
 * or a badge anywhere on the screen update, and the field took focus back
 * (#511). A screen that flips `autoFocus` on to ask for focus and off again a
 * moment later, as an "Edit" button that focuses a draft does, still works:
 * off to on is a request, on staying on is not.
 *
 * The members under test are the shipped ones, lifted from the field class.
 */
const activity = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')

test('a field takes focus when autoFocus turns on, not each time it is drawn with it on', async () => {
  const source = `
class Field {
${liftKotlinMember(activity, 'var autoFocus')}
${liftKotlinMember(activity, 'fun autoFocusTurnedOn')}
}

fun main() {
    val mounted = Field()
    // Mounts with it on, then four renders while something else changes.
    val renders = listOf(true, true, true, true, true).map(mounted::autoFocusTurnedOn)
    check(renders == listOf(true, false, false, false, false)) { "focus was asked for on later renders: $renders" }

    // Turned off, then on: its author asking for focus again.
    val toggled = listOf(false, false, true, true, false, true).map(mounted::autoFocusTurnedOn)
    check(toggled == listOf(false, false, true, false, false, true)) { "off to on did not ask once each time: $toggled" }

    // A field that never has it never asks, and each field keeps its own.
    val plain = Field()
    check(listOf(false, false).map(plain::autoFocusTurnedOn) == listOf(false, false))
    check(Field().autoFocusTurnedOn(true)) { "a second field shared the first one's state" }
}
`
  await runKotlinFixture(source)
}, 300_000)

test('the input asks that question before it posts a focus request', () => {
  expect(activity).toContain('if (autoFocusTurnedOn(craftNativeBoolean(props.opt("autoFocus"))) && !isFocused) post {')
  // The every-render form must not come back beside it.
  expect(activity).not.toContain('if (craftNativeBoolean(props.opt("autoFocus")) && !isFocused)')
})
