import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * A switch has to answer `value as? String`.
 *
 * Both switch variants are read the same way — the driver's `tapid` flip check
 * and the agreement fixture both do `value as? String` — but only the solid
 * variant published a string. A UISwitch left to UIKit handed XCTest its value
 * as a number, so those reads found nothing and a switch that had flipped was
 * reported as never flipping. Intermittently, because it depends which
 * representation the accessibility snapshot was built from.
 */
test('a native switch publishes the same string value the solid variant does', () => {
  const swift = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')
  const start = swift.indexOf('    private func applyAccessibility(')
  const end = swift.indexOf('    private func updateDimension(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  const apply = swift.slice(start, end)

  const publish = apply.indexOf('if let toggle = view as? UISwitch, !authoredAccessibilityValues.contains(id) {')
  expect(publish).toBeGreaterThan(-1)
  expect(apply.slice(publish)).toContain('view.accessibilityValue = toggle.isOn ? "1" : "0"')

  // Ordering is the whole defect: applyAccessibility returns early for a
  // UISwitch, so publishing after that return would never run.
  const earlyReturn = apply.indexOf('if view is UITextView || view is UISwitch { return }')
  expect(earlyReturn).toBeGreaterThan(-1)
  expect(publish).toBeLessThan(earlyReturn)

  // And it must not run before the block that clears unauthored values, which
  // would nil the string straight back out.
  const clears = apply.indexOf('} else if type != "TextInput" {')
  expect(clears).toBeGreaterThan(-1)
  expect(publish).toBeGreaterThan(clears)

  // The solid variant keeps publishing its own value.
  expect(apply).toContain('if let toggle = view as? CraftNativeSolidSwitch { toggle.refreshAccessibility(); return }')
})
