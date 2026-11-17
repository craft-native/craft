import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

// Exercises the shipped Swift gesture boundary. The real Settings regression
// also verifies AutoFillToggle 0 -> 1 -> 0 on the pinned iOS simulator.
test.skipIf(process.platform !== 'darwin')('one gesture reaches the inner switch of an accessible labelled row', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const start = template.indexOf('    func press(')
  const end = template.indexOf('\n    }', start) + 6
  const dir = createTempDir('craft-nested-switch-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
import CoreGraphics
enum Kind { case textField, secureTextField, textView, searchField, \`switch\`, button }
var gestures: [String] = []
final class XCUIElement: Equatable {
    static func == (a: XCUIElement, b: XCUIElement) -> Bool { a === b }
    let identifier: String
    let elementType: Kind
    let frame: CGRect
    let exists: Bool
    let isHittable = true
    var children: [XCUIElement] = []
    init(_ name: String, _ kind: Kind, _ frame: CGRect, exists: Bool = true) { self.identifier = name; self.elementType = kind; self.frame = frame; self.exists = exists }
    func descendants(matching kind: Kind) -> Query { Query(children.filter { $0.elementType == kind }) }
    func tap() { gestures.append(identifier) }
    func coordinate(withNormalizedOffset offset: CGVector) -> XCUIElement { self }
}
struct Query {
    let rows: [XCUIElement]
    init(_ rows: [XCUIElement]) { self.rows = rows }
    var firstMatch: XCUIElement { rows.first ?? XCUIElement("missing", .button, .zero, exists: false) }
}
final class Driver {
    let app = XCUIElement("app", .button, CGRect(x: 0, y: 0, width: 402, height: 874))
    var lastTappedInput: XCUIElement?
    func settledFrame(_ target: XCUIElement) -> CGRect { target.frame }
    func visibleScrollFrame(_ frame: CGRect, in viewport: CGRect) -> Bool { viewport.intersects(frame) }
    func check(_ passed: Bool, _ message: String) { precondition(passed, message) }
${template.slice(start, end)}
}
let row = XCUIElement("AutoFillToggle", .switch, CGRect(x: 16, y: 151, width: 370, height: 52))
let knob = XCUIElement("inner-knob", .switch, CGRect(x: 305, y: 163, width: 63, height: 28))
row.children = [knob]
let plain = XCUIElement("plain-switch", .switch, CGRect(x: 20, y: 240, width: 51, height: 31))
let button = XCUIElement("button", .button, CGRect(x: 20, y: 310, width: 300, height: 52))
button.children = [knob]
let driver = Driver()
precondition(driver.press(row) == row.frame, "keep the identified row frame for before/after observation")
_ = driver.press(plain)
_ = driver.press(button)
precondition(gestures == ["inner-knob", "plain-switch", "button"], "one gesture must reach each actual control")
print("nested switch gesture passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('nested switch gesture passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)
