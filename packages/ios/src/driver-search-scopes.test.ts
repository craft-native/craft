import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

test.skipIf(process.platform !== 'darwin')('looks for a label in the presented alert or sheet before the screen behind it', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const start = template.indexOf('    func searchScopes<Scope>(')
  const end = template.indexOf('    func presentedScopes()', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  // Exact selection prefers the modal; dismissal excludes the body altogether.
  expect(template).toContain('for scope in presentedScopes()')
  expect(template).toContain('self.presentedScopes().filter { $0.elementType == .alert || $0.elementType == .sheet }')
  expect(template).toContain('scope.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex')
  const dir = createTempDir('craft-driver-scopes-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
${template.slice(start, end)}
// Me's "Sign out" row stays hittable behind its own "Sign out?" sheet.
precondition(searchScopes(alerts: [String](), sheets: ["sign-out-sheet"], app: "app") == ["sign-out-sheet", "app"])
precondition(searchScopes(alerts: ["alert"], sheets: ["sheet"], app: "app") == ["alert", "sheet", "app"])
precondition(searchScopes(alerts: ["older", "newest"], sheets: [String](), app: "app") == ["newest", "app"])
precondition(searchScopes(alerts: [String](), sheets: [String](), app: "app") == ["app"])
print("driver search scopes passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('driver search scopes passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)
