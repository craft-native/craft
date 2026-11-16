import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// `touches` placed a path on a tab by looking for the tab once, and failed
// "Timed native input cannot find tab One" on a runner whose tab bar was not
// up yet (#548). Finding the tab is the input's precondition, not what it
// times, so it waits as the `tab` and `holdtab` steps do.
test('timed touches wait for a tab before placing a path on it, like the other tab steps', () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const touches = template.slice(template.indexOf('        case "touches":'), template.indexOf('Timed touch points must contain numeric coordinates'))
  expect(touches).toContain('Timed native input cannot find tab')
  expect(touches).toContain('guard let button = poll(10, { tabButton(name) }), frame.width > 0, frame.height > 0 else {')
  // No single look left in the step.
  expect(touches.match(/tabButton\(name\)/g)).toHaveLength(1)
  // The waits it matches.
  const holdtab = template.slice(template.indexOf('        case "holdtab":'), template.indexOf('        case "touches":'))
  expect(holdtab).toContain('poll(10, { tabButton(name) })')
})
