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


test.skipIf(process.platform !== 'darwin')('honors successful HTTP hooks while rejecting HTTP and legacy shell failures', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const getStart = template.indexOf('    func get(')
  const getEnd = template.indexOf('    /// The journey,', getStart)
  const hookStart = template.indexOf('    func hookSucceeded(')
  const hookEnd = template.indexOf('    func switchFlipped(', hookStart)
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(request) {
    switch (new URL(request.url).pathname) {
      case '/message': return new Response('No original recordings remain after the native launch')
      case '/shell-success': return new Response('exit 0 fresh')
      case '/shell-failure': return new Response('exit 1 reinstall failed')
      case '/shell-malformed': return new Response('exit 01 not a zero exit status')
      case '/empty': return new Response(null, { status: 204 })
      case '/failure': return new Response('cleanup failed', { status: 500 })
      default: return new Response('no such hook', { status: 404 })
    }
  } })
  const dir = createTempDir('craft-driver-hook-http-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
import XCTest
final class HookHTTPTests: XCTestCase {
    let control = ${JSON.stringify(server.url.origin)}
${template.slice(getStart, getEnd)}
${template.slice(hookStart, hookEnd)}
    func accepted(_ path: String) -> Bool {
        guard let data = get(path), let answer = String(data: data, encoding: .utf8) else { return false }
        return hookSucceeded(answer)
    }
    @objc func testContract() {
        XCTAssertTrue(accepted("/message"), "a successful HTTP hook may return an ordinary message")
        XCTAssertTrue(accepted("/empty"), "HTTP 204 has no shell output")
        XCTAssertTrue(accepted("/shell-success"))
        XCTAssertFalse(accepted("/shell-failure"))
        XCTAssertFalse(accepted("/shell-malformed"))
        XCTAssertFalse(accepted("/failure"))
        XCTAssertFalse(accepted("/unknown"))
    }
}
let suite = XCTestSuite(name: "Owned control hooks")
suite.addTest(HookHTTPTests(selector: #selector(HookHTTPTests.testContract)))
suite.run()
if suite.testRun?.hasSucceeded != true { exit(1) }
`)
    const platform = Bun.spawnSync(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'])
    expect(platform.exitCode, platform.stderr.toString()).toBe(0)
    const frameworks = join(platform.stdout.toString().trim(), 'Developer/Library/Frameworks')
    const libraries = join(platform.stdout.toString().trim(), 'Developer/usr/lib')
    const child = Bun.spawn(['xcrun', '--sdk', 'macosx', 'swift', '-F', frameworks, '-I', libraries, '-L', libraries, '-Xlinker', '-rpath', '-Xlinker', frameworks, '-Xlinker', '-rpath', '-Xlinker', libraries, source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
  }
  finally { await server.stop(true); removeTempDir(dir) }
}, 60_000)
