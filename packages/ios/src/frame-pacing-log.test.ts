import { expect, it } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

it.skipIf(process.platform !== 'darwin')('writes the shipped frame trace into a fresh cache and appends after reopening', () => {
  const root = mkdtempSync(join(tmpdir(), 'craft-frame-trace-'))
  try {
    const main = join(root, 'main.swift')
    writeFileSync(main, `import Foundation
let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? manager.removeItem(at: root) }
do {
    let caches = root.appendingPathComponent("Library/Caches")
    precondition(!manager.fileExists(atPath: caches.path))
    let first = try CraftFramePacingLog.open(in: caches)
    try first.write(contentsOf: Data("first\\n".utf8))
    try first.close()
    let second = try CraftFramePacingLog.open(in: caches)
    try second.write(contentsOf: Data("second\\n".utf8))
    try second.close()
    let contents = try String(contentsOf: caches.appendingPathComponent("craft-frame-pacing.log"), encoding: .utf8)
    precondition(contents == "first\\nsecond\\n")
    let blocked = root.appendingPathComponent("blocked")
    try Data("keep".utf8).write(to: blocked)
    var refused = false
    do { _ = try CraftFramePacingLog.open(in: blocked) } catch { refused = true }
    precondition(refused)
    let retained = try String(contentsOf: blocked, encoding: .utf8)
    precondition(retained == "keep")
    print("fresh trace, append and invalid-parent checks passed")
} catch {
    fputs("Trace filesystem check failed: \\(error)\\n", stderr)
    exit(1)
}
`)
    const binary = join(root, 'trace-check')
    const compiled = Bun.spawnSync(['xcrun', 'swiftc', join(import.meta.dir, '../templates/CraftFramePacingLog.swift'), main, '-o', binary], { stdout: 'pipe', stderr: 'pipe' })
    expect(compiled.exitCode, compiled.stderr.toString()).toBe(0)
    const result = Bun.spawnSync([binary], { stdout: 'pipe', stderr: 'pipe' })
    expect(result.exitCode, result.stderr.toString()).toBe(0)
    expect(result.stdout.toString()).toBe('fresh trace, append and invalid-parent checks passed\n')
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 60_000)
