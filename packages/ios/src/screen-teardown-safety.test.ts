import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Nothing on the deallocation path may force the controller's view.
 *
 * `UIViewController.view` is a `UIView!`. Inside `deinit` UIKit has already
 * cleared it, so reading it traps on the implicit unwrap — and on a screen
 * that never appeared, reading it instead runs `loadView`, which here assigns
 * `root.controller = self` and so hands out a reference to an object that is
 * being deallocated.
 *
 * This is not hypothetical. `view.endEditing(true)` was added to
 * `disposeRuntime()` for #497, to let a screen's keyboard go when the screen
 * does. `disposeRuntime()` also runs from `deinit`, and every mobile E2E run
 * from that commit onwards crashed `NativeNavigationUnitTests` with
 * `EXC_BREAKPOINT` inside `disposeRuntime()`, called from
 * `__deallocating_deinit` while UIKit released a `UINavigationController`'s
 * children. The comment above the line had already named the case that breaks
 * it — a screen torn down without ever appearing.
 *
 * The methods are found by following `deinit`'s own calls rather than listed,
 * so a new one added to the teardown path is covered without this test
 * being edited.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')

/** The template with comments stripped: a note naming `view` is not a use. */
const code = template.replace(/^\s*\/\/[^\n]*$/gm, '')

/** The body of a `func <name>(` or `deinit` declaration in the controller. */
function body(declaration: string): string {
  const from = code.indexOf(declaration)
  expect(from, `the controller must declare ${declaration.trim()}`).toBeGreaterThan(0)
  const open = code.indexOf('{', from)
  let depth = 0
  for (let index = open; index < code.length; index++) {
    if (code[index] === '{') depth++
    else if (code[index] === '}' && --depth === 0) return code.slice(open + 1, index)
  }
  throw new Error(`unbalanced braces in ${declaration}`)
}

/** `self.view`, written bare — not `root.view`, not `viewIfLoaded`. */
const forcesView = /(?<![.\w])view\s*[.?!]/g

test('the screen controller tears down without forcing its view', () => {
  // Derived: whatever deinit calls on self is on the deallocation path.
  const teardown = body('deinit {\n        disposeRuntime()')
  const called = [...teardown.matchAll(/^\s*(?:self\.)?([a-zA-Z][a-zA-Z0-9]*)\(\)/gm)].map(match => match[1]!)
  expect(called, 'deinit must still dispose the runtime').toContain('disposeRuntime')

  for (const method of new Set(called)) {
    const declaration = new RegExp(`func ${method}\\(\\)`).exec(code)
    if (!declaration) continue
    const source = body(declaration[0])
    const forced = source.match(forcesView)
    expect(forced, `${method}() runs from deinit and must not force self.view (found ${forced?.join(', ')})`).toBeNull()
  }
})

test('disposeRuntime lets the keyboard go through viewIfLoaded', () => {
  // The fix, stated positively: #497's behaviour is kept, by the accessor
  // that returns nil instead of loading or trapping.
  const source = body('private func disposeRuntime()')
  expect(source, 'a disposed screen still gives up the keyboard').toContain('viewIfLoaded?.endEditing(true)')
  expect(source, 'and still forgets the input it had focused').toContain('forgetFocusedInput()')
})

test('viewWillDisappear may still use the loaded view', () => {
  // Not a blanket ban: by viewWillDisappear the view is loaded by
  // definition, and #497 needs the keyboard dismissed there too. A test that
  // forbade `view` everywhere would push that onto the optional for no
  // reason and hide the one place it actually matters.
  const source = body('override func viewWillDisappear(')
  expect(source).toContain('view.endEditing(true)')
})
