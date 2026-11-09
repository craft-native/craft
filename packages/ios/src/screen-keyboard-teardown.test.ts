import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * A screen that goes away does not take the keyboard with it.
 *
 * A field that is still first responder when its screen is replaced keeps the
 * keyboard up, and nothing on the next screen can put it away: the tap-outside
 * handler calls `container.window?.endEditing(true)`, and once the outgoing
 * view has left the window hierarchy that no longer reaches its field. The
 * keyboard then stays until the app is backgrounded (#497).
 *
 * It reads as intermittent because it depends on focus still being live at the
 * moment of navigation — a password manager filling a sign-in form and the
 * person tapping the button straight from the keyboard hits it, while filling
 * by hand usually involves a tap elsewhere that dismisses the keyboard first.
 *
 * An app-side blur cannot close it: it runs before teardown, so anything that
 * restores focus in between wins, and after teardown the keyboard is out of
 * reach. It also only covers fields the app knows the names of.
 *
 * Both hooks are checked, because neither covers the other. `viewWillDisappear`
 * does not run for a screen torn down without ever appearing, and
 * `disposeRuntime` does not run for a screen that is merely covered by a push.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')

/**
 * The code of a method, by its declaration line, with its comments removed.
 *
 * The comments go because these assertions are about what the method does.
 * The first version of this test failed on its own explanation: the comment
 * beside the fix names `window?.endEditing` as the thing that cannot reach a
 * detached field, and the check below forbids exactly that string. A region
 * that includes prose is satisfied, or broken, by prose.
 */
function body(declaration: string): string {
  const from = template.indexOf(declaration)
  expect(from, `${declaration} must exist`).toBeGreaterThan(0)
  const to = template.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  return template.slice(from, to).replace(/^\s*\/\/[^\n]*$/gm, '')
}

test('a screen puts the keyboard away as it disappears', () => {
  const disappear = body('override func viewWillDisappear(_ animated: Bool) {')
  expect(disappear, 'a departing screen must end editing while its view still owns the responder')
    .toContain('view.endEditing(true)')
  // Specifically this screen's own view. `window?.endEditing` is what the
  // next screen already tries and what cannot reach a detached field.
  expect(disappear).not.toContain('window?.endEditing')
})

test('a screen torn down without appearing puts it away too', () => {
  const dispose = body('private func disposeRuntime() {')
  expect(dispose).toContain('view.endEditing(true)')
  // Nothing comes back from dispose, so the remembered input goes as well —
  // otherwise restoreFocus can put the keyboard back on a later render.
  expect(dispose).toContain('forgetFocusedInput()')
})

test('a screen that is only covered keeps what it was focused on', () => {
  // The fix must not cost a push-and-return its focus restoration: a screen
  // covered by a push comes back, and restoreFocus putting the person where
  // they were is behaviour that predates this.
  const disappear = body('override func viewWillDisappear(_ animated: Bool) {')
  expect(disappear, 'viewWillDisappear must not forget the input: covered screens come back')
    .not.toContain('forgetFocusedInput')
  expect(template).toContain('private func restoreFocus(_ focused: UIView?) {')
})
