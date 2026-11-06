import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * `craft.d.ts` types no navigation surface, so the doc comment above
 * `installHostAPIs` is the public description of `craft.navigation.setOptions`.
 * It drifted: `leftButtons`, `tabItem` and `titleColor` all shipped while the
 * list still named twelve keys (#489).
 */
const swift = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')

test('every option setOptions reads is named in its public doc comment', () => {
  // Only the option list itself, not the prose after it: an explanation that
  // happens to mention a key name must not count as documenting it.
  const opened = swift.indexOf('`craft.navigation.setOptions({')
  expect(opened).toBeGreaterThan(0)
  const doc = swift.slice(opened, swift.indexOf('})`', opened))
  expect(doc.length).toBeGreaterThan(100)

  // The applier's own body: every key it consults, however it consults it.
  const start = swift.indexOf('`craft.navigation.setOptions`: this screen\'s bar.')
  expect(start).toBeGreaterThan(0)
  const body = swift.slice(start, start + 6000)
  const handled = new Set([...body.matchAll(/options(?:\.keys\.contains\(|\[)"([a-zA-Z]+)"/g)].map(match => match[1]!))
  expect(handled.size).toBeGreaterThan(10)

  const undocumented = [...handled].filter(key => !doc.includes(key)).sort()
  expect(undocumented, 'these setOptions keys ship with no public documentation').toEqual([])
})
