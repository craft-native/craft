import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const source = readFileSync(join(import.meta.dir, 'verify-packaged-app.ts'), 'utf8')

test('installed multi-window acceptance is reported before notification checks', () => {
  const checkpoint = source.indexOf("await fetch('/multi-window-verified', { method: 'POST' })")
  const adoption = source.lastIndexOf('if (${testWindowAdoption}) {', checkpoint)
  const notification = source.indexOf('if (${testLinuxNotification}) {', checkpoint)

  expect(adoption).toBeGreaterThan(-1)
  expect(checkpoint).toBeGreaterThan(adoption)
  expect(notification).toBeGreaterThan(checkpoint)
  expect(source).toContain("request.url === '/multi-window-verified'")
  expect(source).toContain('multi-window and parent/modal smoke passed before notification checks')
  expect(source).toContain('if (testMultiWindow && !multiWindowVerified)')
})
