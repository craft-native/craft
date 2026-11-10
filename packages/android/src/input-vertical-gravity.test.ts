import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { runKotlinFixture } from './testing'

/**
 * A multiline field starts its text where iOS and the web start theirs.
 *
 * The platform's `Widget.EditText` carries `gravity = center_vertical`, and
 * nothing in this app's theme chain overrides it — verified against the
 * artifacts the generated app actually depends on, not from memory:
 *
 *   `Theme.CraftApp` → `Theme.Material3.DayNight.NoActionBar`; no
 *   `Theme.Material3*` style in material-1.11.0 binds `android:editTextStyle`;
 *   appcompat-1.6.1 binds it to `Widget.AppCompat.EditText` →
 *   `Base.Widget.AppCompat.EditText` → `Base.V7.Widget.AppCompat.EditText`,
 *   whose `parent` is `android:Widget.EditText` and which sets background,
 *   text colour, text appearance and cursor — no gravity. AOSP's
 *   `Widget.EditText` sets `<item name="gravity">center_vertical</item>`.
 *
 * A single-line field is never taller than its text, so the centring cannot
 * show. A field given a `minHeight` drew its first line, and its hint, halfway
 * down the box (#502). This is the iOS defect from #501 with the other
 * symptom: there the placeholder disagreed with the text, here they agree
 * with each other and both sit in the wrong place.
 *
 * The function is extracted and run through Kotlin against the real `Gravity`
 * constants, because the whole question is bit arithmetic on them.
 */
const template = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')

function verticalGravityRule(): string {
  const from = template.indexOf('private fun craftNativeVerticalGravity(')
  expect(from, 'the renderer must decide a field\'s vertical gravity').toBeGreaterThan(0)
  const to = template.indexOf('\n\n', from)
  expect(to).toBeGreaterThan(from)
  return template.slice(from, to)
}

test('the renderer sets a field\'s vertical gravity from whether it is multiline', () => {
  // Comments stripped: a note naming gravity is not a call that sets it.
  const code = template.replace(/^\s*\/\/[^\n]*$/gm, '')
  const branch = code.slice(code.indexOf('val multiline = craftNativeBoolean(props.opt("multiline"))'))
    .slice(0, 600)
  expect(branch, 'an input must take a gravity rather than inheriting the theme\'s')
    .toContain('craftNativeVerticalGravity(gravity, multiline)')
  // The surrounding branch only assigns when the value differs; a reused
  // EditText must not be written to on every render.
  expect(branch).toContain('if (gravity != wantedGravity) gravity = wantedGravity')
})

test('multiline fields start at the top and single-line fields stay centred', async () => {
  // Real Gravity bits: TOP 0x30, CENTER_VERTICAL 0x10, START 0x800003,
  // VERTICAL_GRAVITY_MASK 0x70. A shim here would only prove the arithmetic
  // agrees with my own copy of the constants.
  await runKotlinFixture(`
object Gravity {
    const val TOP = 0x30
    const val BOTTOM = 0x50
    const val CENTER_VERTICAL = 0x10
    const val START = 0x00800003
    const val END = 0x00800005
    const val CENTER_HORIZONTAL = 0x01
    const val VERTICAL_GRAVITY_MASK = 0x70
}

${verticalGravityRule()}

fun main() {
    val centredStart = Gravity.CENTER_VERTICAL or Gravity.START

    // The defect: the theme's own value, on a field taller than its text.
    check(craftNativeVerticalGravity(centredStart, true) == (Gravity.TOP or Gravity.START)) {
        "a multiline field must start at the top"
    }
    // A single-line field is centred, which is correct for it and is what
    // every other Android app does. The fix must not take that away.
    check(craftNativeVerticalGravity(centredStart, false) == centredStart) {
        "a single-line field must stay vertically centred"
    }

    // The horizontal bits survive untouched, whatever they are: textAlign
    // resolves through textAlignment, whose TEXT_ALIGNMENT_INHERIT default
    // can still fall back to this gravity.
    for (horizontal in listOf(Gravity.START, Gravity.END, Gravity.CENTER_HORIZONTAL, 0)) {
        for (multiline in listOf(true, false)) {
            val result = craftNativeVerticalGravity(Gravity.CENTER_VERTICAL or horizontal, multiline)
            check((result and Gravity.VERTICAL_GRAVITY_MASK.inv()) == horizontal) {
                "horizontal gravity \$horizontal must survive, got \$result"
            }
        }
    }

    // Idempotent, because a reused EditText is reconciled on every render.
    val once = craftNativeVerticalGravity(centredStart, true)
    check(craftNativeVerticalGravity(once, true) == once) { "re-applying must not drift" }

    // An already-bottom-aligned field is corrected rather than ORed into
    // something that is both top and bottom.
    val fromBottom = craftNativeVerticalGravity(Gravity.BOTTOM or Gravity.START, true)
    check(fromBottom == (Gravity.TOP or Gravity.START)) { "stale vertical bits must be cleared, got \$fromBottom" }

    println("input vertical gravity passed")
}
`)
}, 300_000)
