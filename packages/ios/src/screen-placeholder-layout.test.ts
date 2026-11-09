import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A multiline field's placeholder starts where its first character will.
 *
 * `UILabel` centres its text block vertically inside its frame; `UITextView`
 * lays its glyphs out from the top. The placeholder label used to be handed
 * the whole remaining height of the box, so a four-row notes field drew
 * "How should this session feel?" halfway down it, and tapping the field
 * moved it to the top as a caret — the placeholder was never where the text
 * it stood in for would be (#501). The two rules agreed only when the box
 * was exactly one line tall, which is why single-line fields looked right
 * and every `textarea` did not.
 *
 * The geometry is extracted from the template and run through Swift rather
 * than restated here: `min`, `max` and `CGRect` on `CGFloat` are the actual
 * arithmetic, and a TypeScript copy would only prove that two things I wrote
 * agree.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')

/** Source of one `static func` in the text view, comments excluded. */
function staticFunc(name: string): string {
  const from = template.indexOf(`    static func ${name}(`)
  expect(from, `the text view must declare ${name}`).toBeGreaterThan(0)
  const to = template.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  const code = template.slice(from, to + '\n    }'.length)
  // UIKit here would mean the probe needs the whole shell to compile.
  expect(code, `${name} must stay geometry only`).not.toContain('UIKit')
  return code
}

/** The part of `layoutSubviews` that positions the placeholder. */
function layoutRule(): string {
  const from = template.indexOf('        let inset = textContainerInset')
  expect(from, 'the text view must read its own text inset to place the placeholder').toBeGreaterThan(0)
  const to = template.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  // Comments are stripped before anything is read out of the region: a note
  // naming the old rule is not the old rule.
  return template.slice(from, to).replace(/^\s*\/\/[^\n]*$/gm, '')
}

/**
 * width, height, inset top/left/bottom/right, lineFragmentPadding, the
 * height the label reports for its text at that width.
 *
 * The first row is the field from the report: `UITextView`'s own default
 * inset (8 top and bottom) and padding (5), a `min-height` of 110, and one
 * line of 16pt system text.
 */
const cases: { label: string, box: [number, number], inset: [number, number, number, number], padding: number, fitted: number }[] = [
  { label: 'a four-row notes field with a one-line placeholder', box: [343, 110], inset: [8, 0, 8, 0], padding: 5, fitted: 20.3 },
  { label: 'the same field with a placeholder that wraps to three lines', box: [343, 110], inset: [8, 0, 8, 0], padding: 5, fitted: 60.9 },
  // One line tall: the case that always looked right, and must keep doing so.
  { label: 'a single-line field', box: [343, 36], inset: [8, 0, 8, 0], padding: 5, fitted: 20.3 },
  // Authored padding replaces the inset and zeroes the fragment padding.
  { label: 'a field with authored padding', box: [343, 140], inset: [12, 16, 12, 16], padding: 0, fitted: 20.3 },
  // Longer than the box: it has to stay inside it rather than overflow.
  { label: 'a placeholder taller than the field', box: [200, 60], inset: [8, 0, 8, 0], padding: 5, fitted: 200 },
  // Before the first real layout there is no box at all.
  { label: 'a field that has not been laid out yet', box: [0, 0], inset: [8, 0, 8, 0], padding: 5, fitted: 20.3 },
  // No placeholder: the label is hidden, and must not claim height either.
  { label: 'a field with no placeholder', box: [343, 110], inset: [8, 0, 8, 0], padding: 5, fitted: 0 },
]

test('the placeholder is measured, not given the whole box', () => {
  const rule = layoutRule()
  // The measure pass is the fix. Keeping the helper but feeding it the box's
  // own height would put the placeholder back in the middle.
  expect(rule, 'the label must be asked how tall its text is').toContain('placeholderLabel\n            .sizeThatFits(')
  expect(rule, 'the measured height is what decides the frame').toContain('fittedHeight: measured.height')
  expect(rule, 'the frame comes from the geometry this test compiles').toContain('Self.placeholderFrame(bounds: bounds, inset: inset, padding: padding,')
  // The old rule, which is what centred it.
  expect(rule, 'handing the label the box\'s height centres the placeholder in it')
    .not.toContain('height: max(0, bounds.height - inset.top - inset.bottom)')
  // A label that wraps is still wanted; only its height changed.
  expect(template).toContain('placeholderLabel.numberOfLines = 0')
})

test.skipIf(process.platform !== 'darwin')('the shipped geometry anchors the placeholder at the top of the box', () => {
  const dir = createTempDir('craft-placeholder-layout-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'layout')
    writeFileSync(probe, `import CoreGraphics
import Foundation

struct UIEdgeInsets {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat
}

enum Layout {
${staticFunc('placeholderWidth')}

${staticFunc('placeholderFrame')}
}

for line in (try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)).split(separator: "\\n") {
    let n = line.split(separator: "\\t").map { CGFloat(Double($0)!) }
    let rect = Layout.placeholderFrame(bounds: CGRect(x: 0, y: 0, width: n[0], height: n[1]),
                                       inset: UIEdgeInsets(top: n[2], left: n[3], bottom: n[4], right: n[5]),
                                       padding: n[6],
                                       fittedHeight: n[7])
    print("\\(rect.origin.x)\\t\\(rect.origin.y)\\t\\(rect.width)\\t\\(rect.height)")
}
`)
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)

    const input = join(dir, 'cases.tsv')
    writeFileSync(input, cases
      .map(c => [c.box[0], c.box[1], ...c.inset, c.padding, c.fitted].join('\t'))
      .join('\n'))
    const run = Bun.spawnSync([binary, input], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)

    const rows = run.stdout.toString().trim().split('\n')
    expect(rows.length, 'every case must get a rect').toBe(cases.length)

    for (const [index, probed] of cases.entries()) {
      const [x, y, width, height] = rows[index].split('\t').map(Number)
      const [boxWidth, boxHeight] = probed.box
      const [top, left, bottom, right] = probed.inset
      const available = Math.max(0, boxHeight - top - bottom)

      // The caret appears at the inset's top edge, so the placeholder does.
      expect(y, `${probed.label}: the placeholder starts at the top of the text`).toBeCloseTo(top, 5)
      expect(x, `${probed.label}: it lines up with the first glyph`).toBeCloseTo(left + probed.padding, 5)
      expect(width, `${probed.label}: it spans the writable width`).toBeCloseTo(Math.max(0, boxWidth - left - right - probed.padding * 2), 5)
      // The height its text needs, never more than the box has left.
      expect(height, `${probed.label}: it is as tall as its text`).toBeCloseTo(Math.min(probed.fitted, available), 5)
      expect(height, `${probed.label}: it must not draw past the bottom`).toBeLessThanOrEqual(available + 1e-6)

      if (probed.fitted > 0 && available > probed.fitted) {
        // The defect, stated as geometry: a label with spare height centres
        // its text in it, so the only way the first line can be at the top
        // is for the frame to have no spare height to centre within.
        expect(available - height, `${probed.label}: spare height is where the text got lost`).toBeGreaterThan(0)
        expect(y + height / 2, `${probed.label}: the text must not sit at the box's middle`)
          .toBeLessThan(top + available / 2)
      }
    }
  } finally {
    removeTempDir(dir)
  }
})
