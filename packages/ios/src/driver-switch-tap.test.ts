import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

test.skipIf(process.platform !== 'darwin')('counts a switch tap only once the switch has flipped', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const start = template.indexOf('    func switchFlipped(')
  const end = template.indexOf('    func press(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  // tapid taps a switch again, up to three times, until this rule holds.
  expect(template).toContain('flipped = switchFlipped(from: before, to: target.value as? String)')
  expect(template).toContain('check(flipped, "tapid \\(arg) flips the switch")')
  const dir = createTempDir('craft-driver-switch-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
${template.slice(start, end)}
// HQ's agreement switch took a tap and stayed off (ReviewOS job 7570).
precondition(!switchFlipped(from: "0", to: "0"))
precondition(switchFlipped(from: "0", to: "1"))
precondition(switchFlipped(from: "1", to: "0"))
// Not a switch state: nothing to wait for.
precondition(switchFlipped(from: nil, to: "1"))
precondition(switchFlipped(from: "On", to: "On"))
print("driver switch tap passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('driver switch tap passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)
