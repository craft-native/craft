import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

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
