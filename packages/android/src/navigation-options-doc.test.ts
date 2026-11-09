import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The Android counterpart of `packages/ios/src/navigation-options-doc.test.ts`.
 *
 * `craft.d.ts` types no navigation surface, so the comment above
 * `CraftNativeChrome` is the public description of what
 * `craft.navigation.setOptions` does on this host. It had drifted the same way
 * the iOS one did in #489, and further: it named six keys while `apply` reads
 * twelve.
 *
 * Derived from `apply` rather than listed, so the next option is covered when
 * it is read instead of when someone notices.
 */
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

/** Every `setOptions` key `CraftNativeChrome.apply` consults. */
function appliedOptions(): Set<string> {
  const from = shell.indexOf('fun apply(options: JSONObject, depth: Int')
  expect(from).toBeGreaterThan(0)
  // The applier ends where the next member's doc comment or signature starts.
  const to = shell.indexOf('\n    fun selectTab(', from)
  expect(to).toBeGreaterThan(from)
  const body = shell.slice(from, to)
  return new Set([...body.matchAll(/options\.(?:opt|optBoolean|optString|optJSONObject|optJSONArray|has)\("([a-zA-Z]+)"/g)].map(match => match[1]!))
}

test('every option the Android chrome reads is named in its public comment', () => {
  // Only the option list itself. A first attempt at the iOS ratchet matched
  // the whole comment and passed with keys deleted, because the explanation
  // underneath named them; the prose here deliberately names none.
  const opened = shell.indexOf('`craft.navigation.setOptions({')
  expect(opened).toBeGreaterThan(0)
  const doc = shell.slice(opened, shell.indexOf('})`', opened))
  expect(doc.length).toBeGreaterThan(100)

  const handled = appliedOptions()
  expect(handled.size).toBeGreaterThan(10)
  const undocumented = [...handled].filter(key => !doc.includes(key)).sort()
  expect(undocumented, 'these setOptions keys ship with no public documentation on Android').toEqual([])
})

/** Every key declared on `CraftNavigationOptions`. */
function declaredOptions(): Set<string> {
  const types = readFileSync(join(import.meta.dir, '../../typescript/types/craft.d.ts'), 'utf8')
  const from = types.indexOf('export interface CraftNavigationOptions {')
  expect(from).toBeGreaterThan(0)
  const to = types.indexOf('\n}', from)
  expect(to).toBeGreaterThan(from)
  // Doc comments carry `backgroundColor` and the rest in prose, so read the
  // property lines only — a comment that happens to name a key is not a
  // declaration of it.
  const body = types.slice(from, to).replace(/\/\*[\s\S]*?\*\//g, '')
  return new Set([...body.matchAll(/^ {2}([a-zA-Z]+)\??:/gm)].map(match => match[1]!))
}

test('every option either host reads is declared on CraftNavigationOptions', () => {
  // The type exists because the two host comments used to be the only public
  // description of this surface, which is how `tabBarHiddenWhenPushed` came to
  // be honoured on one host and ignored on the other (#493). Derived from the
  // hosts so the next key is typed when it is read, not when someone notices.
  const swift = readFileSync(join(import.meta.dir, '../../ios/templates/CraftNativeScreen.swift'), 'utf8')
  const start = swift.indexOf('`craft.navigation.setOptions`: this screen\'s bar.')
  expect(start).toBeGreaterThan(0)
  const ios = new Set([...swift.slice(start, start + 6000).matchAll(/options(?:\.keys\.contains\(|\[)"([a-zA-Z]+)"/g)].map(match => match[1]!))
  const read = new Set([...ios, ...appliedOptions()])
  expect(read.size).toBeGreaterThan(14)

  const declared = declaredOptions()
  expect([...read].filter(key => !declared.has(key)).sort(), 'these options ship with no SDK type').toEqual([])
  expect([...declared].filter(key => !read.has(key)).sort(), 'these options are typed and no host reads them').toEqual([])
})

test('the hosts agree on which navigation options exist, or the difference is recorded', () => {
  // A key one host honours and the other silently ignores is not a platform
  // difference a caller can see; it reads as a broken option. The iOS-only
  // entries are UIKit surfaces with no Android equivalent — the back button's
  // own title, the interactive back-swipe, and the bar's material. There are
  // no Android-only entries: `tabBarHiddenWhenPushed` was the one, and #493
  // gave UIKit the same depth-gated behaviour rather than dropping it.
  const swift = readFileSync(join(import.meta.dir, '../../ios/templates/CraftNativeScreen.swift'), 'utf8')
  const start = swift.indexOf('`craft.navigation.setOptions`: this screen\'s bar.')
  expect(start).toBeGreaterThan(0)
  const ios = new Set([...swift.slice(start, start + 6000).matchAll(/options(?:\.keys\.contains\(|\[)"([a-zA-Z]+)"/g)].map(match => match[1]!))
  expect(ios.size).toBeGreaterThan(10)
  const android = appliedOptions()

  expect([...ios].filter(key => !android.has(key)).sort()).toEqual(['backTitle', 'contentSwipeBack', 'navigationBarSolid', 'swipeBack'])
  expect([...android].filter(key => !ios.has(key)).sort()).toEqual([])
})
