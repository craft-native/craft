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

test('the hosts agree on which navigation options exist, or the difference is recorded', () => {
  // A key one host honours and the other silently ignores is not a platform
  // difference a caller can see; it reads as a broken option. The iOS-only
  // entries are UIKit surfaces with no Android equivalent — the back button's
  // own title, the interactive back-swipe, and the bar's material. The
  // Android-only entry is not: `tabBarHiddenWhenPushed` exists once in the
  // whole repository, with no iOS behaviour, no type and no test (#493).
  const swift = readFileSync(join(import.meta.dir, '../../ios/templates/CraftNativeScreen.swift'), 'utf8')
  const start = swift.indexOf('`craft.navigation.setOptions`: this screen\'s bar.')
  expect(start).toBeGreaterThan(0)
  const ios = new Set([...swift.slice(start, start + 6000).matchAll(/options(?:\.keys\.contains\(|\[)"([a-zA-Z]+)"/g)].map(match => match[1]!))
  expect(ios.size).toBeGreaterThan(10)
  const android = appliedOptions()

  expect([...ios].filter(key => !android.has(key)).sort()).toEqual(['backTitle', 'contentSwipeBack', 'navigationBarSolid', 'swipeBack'])
  expect([...android].filter(key => !ios.has(key)).sort()).toEqual(['tabBarHiddenWhenPushed'])
})
