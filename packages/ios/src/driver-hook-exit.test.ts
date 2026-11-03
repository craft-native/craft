import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

test.skipIf(process.platform !== 'darwin')('fails exec when the hook exits non-zero', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const start = template.indexOf('    func hookSucceeded(')
  const end = template.indexOf('    func switchFlipped(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  const exec = template.slice(template.indexOf('case "exec":'), template.indexOf('case "openurl":'))
  expect(exec).toContain('check(hookSucceeded(answer), "exec \\(arg): hook failed: \\(answer)")')
  const dir = createTempDir('craft-driver-hook-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
${template.slice(start, end)}
precondition(hookSucceeded("exit 0 fresh"))
precondition(hookSucceeded("  exit 0\\n"))
// HQ's fresh-install hook ran without HQ_SIM_APP and the journey carried on signed in.
precondition(!hookSucceeded("exit 1  HQ_SIM_APP: parameter null or not set"))
precondition(!hookSucceeded("exit 127"))
precondition(!hookSucceeded("no such hook"))
print("driver hook exit passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('driver hook exit passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)
