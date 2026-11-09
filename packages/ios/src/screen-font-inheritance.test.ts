import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * A configured `fontFamily` reaches a screen's own text, not only its chrome.
 *
 * The navigation bar, the tab labels and the bar buttons are UIKit's, styled
 * through `UIAppearance` proxies. A screen's text is the stx tree's, styled by
 * the inherited `fontFamily` the tree carries. Both existed and were correct;
 * nothing connected the configured face to the second one, so a branded app
 * drew its chrome in its own face and every label, button and field inside its
 * screens in the system face (#500).
 *
 * The fix is one argument, so these assertions are about the two properties
 * that make it correct rather than about the line: the chain is seeded from
 * the configured body face, and a node that names its own family still wins.
 */
const screen = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')
const chromeFonts = readFileSync(join(import.meta.dir, '../templates/CraftNativeUI.swift'), 'utf8')

/** A method's code, without its comments — these assertions are about what it does. */
function code(declaration: string): string {
  const from = screen.indexOf(declaration)
  expect(from, `${declaration} must exist`).toBeGreaterThan(0)
  const to = screen.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  return screen.slice(from, to).replace(/^\s*\/\/[^\n]*$/gm, '')
}

test('the screen tree inherits the app\'s configured body face from its root', () => {
  const committed = code('    private func renderCommitted(_ document: [String: Any]) {')
  expect(committed, 'the root reconcile must seed the inheritance chain')
    .toContain('inheritedFontFamily: CraftChromeFonts.body')
  // The heading face is deliberately not seeded: a tree has no notion of a
  // heading to key one on, so it stays chrome-only.
  expect(committed).not.toContain('CraftChromeFonts.heading')
})

test('a node that names its own family still wins', () => {
  const reconcile = code('    private func reconcile(_ node: [String: Any], identity: String, path: String, previous: RenderedNode?, adopting: Bool = false, inheritedFontFamily: String? = nil) -> RenderedNode {')
  // The seed fills only where a node said nothing, or said `inherit`. Without
  // this guard, seeding the root would override every element that set a face.
  expect(reconcile).toContain('if own == nil || own == "inherit" { style["fontFamily"] = inheritedFontFamily }')
})

test('the configured face is readable where the tree is built', () => {
  // `private(set)` restricts the setter only, which is what makes the seed
  // possible without widening anything.
  expect(chromeFonts).toContain('private(set) static var body: String?')
  // The chrome proxies stay: this adds a second consumer, it does not move
  // the face off the bars.
  expect(chromeFonts).toContain('UINavigationBar.appearance()')
})
