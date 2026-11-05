import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

test.skipIf(process.platform !== 'darwin')('keeps Safari page gestures and controls outside its browser bars', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const contentStart = template.indexOf('    func browserContentFrame(')
  const contentEnd = template.indexOf('    func scrollViewport(', contentStart)
  const visibleStart = template.indexOf('    func visibleScrollFrame(')
  const visibleEnd = template.indexOf('    func scrollTargetVisible(', visibleStart)
  expect(contentStart).toBeGreaterThan(0)
  expect(contentEnd).toBeGreaterThan(contentStart)
  const dir = createTempDir('craft-browser-scroll-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
import CoreGraphics
${template.slice(contentStart, contentEnd)}
${template.slice(visibleStart, visibleEnd)}
// Recorded from an actual SFSafariViewController on a 375x667 phone.
let web = CGRect(x: 0, y: 40, width: 375, height: 627)
let topBar = CGRect(x: 0, y: 40, width: 375, height: 70)
let bottomBar = CGRect(x: 7, y: 591, width: 361, height: 48)
let content = browserContentFrame(web, topBar: topBar, bottomBar: bottomBar)
precondition(content == CGRect(x: 0, y: 110, width: 375, height: 481))
// XCTest can call a field hittable when Safari's chrome still covers it.
precondition(!visibleScrollFrame(CGRect(x: 24, y: 80, width: 327, height: 44), in: content))
precondition(!visibleScrollFrame(CGRect(x: 24, y: 580, width: 327, height: 44), in: content))
precondition(visibleScrollFrame(CGRect(x: 24, y: 200, width: 327, height: 44), in: content))
// The old app-relative drag started at y=100, inside the top bar.
let upper = content.minY + content.height * 0.15
let lower = content.minY + content.height * 0.55
precondition(upper > topBar.maxY && lower < bottomBar.minY)
precondition(browserContentFrame(web, topBar: nil, bottomBar: nil) == web)
// A side toolbar does not obscure this vertical gesture's center line.
precondition(browserContentFrame(web, topBar: CGRect(x: 0, y: 40, width: 30, height: 70), bottomBar: nil) == web)
print("browser scroll viewport passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('browser scroll viewport passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)

test.skipIf(process.platform !== 'darwin')('runs the generated Swift visibility rule against clipped native controls', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const start = template.indexOf('    func visibleScrollFrame(')
  const end = template.indexOf('    func scrollTargetVisible(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  const dir = createTempDir('craft-scroll-visibility-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
import CoreGraphics
${template.slice(start, end)}
let viewport = CGRect(x: 0, y: 74, width: 375, height: 510)
// Captured from a real recorder: XCTest called this clipped control hittable.
precondition(!visibleScrollFrame(CGRect(x: 24, y: 549.5, width: 327, height: 52), in: viewport))
precondition(visibleScrollFrame(CGRect(x: 24, y: 400, width: 327, height: 52), in: viewport))
precondition(!visibleScrollFrame(CGRect(x: 24, y: 60, width: 327, height: 52), in: viewport))
precondition(!visibleScrollFrame(CGRect(x: 24, y: 600, width: 327, height: 52), in: viewport))
precondition(visibleScrollFrame(CGRect(x: 24, y: 0, width: 327, height: 700), in: viewport))
precondition(!visibleScrollFrame(CGRect(x: 24, y: 400, width: 327, height: 700), in: viewport))
precondition(!visibleScrollFrame(.zero, in: viewport))
precondition(!visibleScrollFrame(CGRect(x: 24, y: 400, width: 327, height: 52), in: .zero))
print("native scroll visibility passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('native scroll visibility passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)
