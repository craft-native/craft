import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The opt-in solid switch draws the thumb iOS 26 draws.
 *
 * `CraftNativeSolidSwitch` exists because a real `UISwitch` loses its thumb
 * for whole frames under Craft's rendering (#416), and an app that hits that
 * turns it on for every switch it has. iOS 26 then changed the shape: it
 * draws a wide pill where every system before it drew a circle, so the
 * remedy cost the app its native look on the newest system (#498).
 *
 * The numbers below were measured, not guessed — a real `UISwitch` walked on
 * an iPhone 17 Pro simulator running iOS 26.5:
 *
 *     UISwitch                 frame=(0, 0, 63, 28)
 *       UISwitchModernVisualElement
 *         _UILiquidLensView    frame=(2, 2, 37, 24)   ← the thumb
 *
 * and x=24 with the switch on, so it is inset 2 on every side and travels 22.
 *
 * The geometry is read out of the template and recomputed here rather than
 * asserted as a string, so a change that keeps the constant but drops it from
 * the rect still fails.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')

/** iOS 26.5, iPhone 17 Pro. `UISwitch().intrinsicContentSize` is 61x28. */
const system = { natural: { width: 61, height: 28 }, thumb: { width: 37, height: 24 } }

function thumbGeometry(): { aspect: number, rect: (position: number) => { x: number, width: number, height: number } } {
  const aspect = /private static let thumbAspect: CGFloat = ([0-9.]+) \/ ([0-9.]+)/.exec(template)
  expect(aspect, 'the solid switch must declare the thumb aspect it draws').toBeTruthy()

  const from = template.indexOf('private func thumbRect(at position: CGFloat) -> CGRect {')
  expect(from).toBeGreaterThan(0)
  const code = template.slice(from, template.indexOf('\n    }', from)).replace(/^\s*\/\/[^\n]*$/gm, '')
  // The rect has to use the aspect. A constant nothing reads is decoration,
  // and a square thumb is exactly what this test exists to reject.
  expect(code, 'the thumb rect must take its width from the aspect').toContain('track.height * Self.thumbAspect')
  expect(code, 'a thumb as wide as it is tall is the pre-iOS-26 circle').not.toContain('width: track.height, height: track.height')
  expect(code, 'the thumb stays inset by 2, as the system\'s is').toContain('trackRect.insetBy(dx: 2, dy: 2)')
  expect(code).toContain('(track.width - width) * position')

  const ratio = Number(aspect![1]) / Number(aspect![2])
  return {
    aspect: ratio,
    rect(position) {
      const track = { x: 2, width: system.natural.width - 4, height: system.natural.height - 4 }
      const width = Math.min(track.width, track.height * ratio)
      return { x: track.x + (track.width - width) * position, width, height: track.height }
    },
  }
}

test('the solid switch thumb is the pill iOS 26 draws, at the size it draws it', () => {
  const geometry = thumbGeometry()
  const resting = geometry.rect(0)
  expect(resting.width).toBeCloseTo(system.thumb.width, 5)
  expect(resting.height).toBeCloseTo(system.thumb.height, 5)
  // Inset 2 from the left when off, as the system's is.
  expect(resting.x).toBeCloseTo(2, 5)
  // Wider than tall is the whole point: the old shape was square.
  expect(geometry.aspect).toBeGreaterThan(1.2)
  expect(resting.width).toBeGreaterThan(resting.height)
})

test('the thumb is drawn as a pill rather than a rounded rectangle', () => {
  // A half-height corner radius on a wider-than-tall rect is a pill; on the
  // square it used to be it was a circle. Same line, different shape, which
  // is why the rect is what this had to change.
  expect(template).toContain('let thumbPath = UIBezierPath(roundedRect: thumb, cornerRadius: thumb.height / 2)')
})

test('the switch still takes its size from the real UISwitch', () => {
  // The aspect follows the thumb's height, and the height follows this. A
  // hardcoded 37x24 would stop tracking the system the next time it changes.
  expect(template).toContain('private let naturalSize = UISwitch().intrinsicContentSize')
})
