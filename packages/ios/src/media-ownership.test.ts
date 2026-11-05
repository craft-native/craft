import { expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

test.skipIf(process.platform !== 'darwin')('media retirement survives a new Swift process, preserves other identities and fails closed on filesystem errors', async () => {
  const root = mkdtempSync(join(tmpdir(), 'craft-media-ownership-'))
  try {
    const source = join(root, 'main.swift')
    const ownership = readFileSync(join(import.meta.dir, '../templates/CraftNativeMediaOwnership.swift'), 'utf8')
    writeFileSync(source, `${ownership}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let url = root.appendingPathComponent("ownership.json")
let owner = try CraftNativeMediaOwnership(url: url)
let stamps = root.appendingPathComponent("stamps.json")
if CommandLine.arguments[2] == "seed" {
    let a = try owner.activate("A") {}
    let b = try owner.activate("B") {}
    try JSONEncoder().encode([a, b]).write(to: stamps)
    try owner.retire("A")
    assert(!owner.permitsLocal("A") && owner.accepts("B", stamp: b))
} else {
    let old = try JSONDecoder().decode([CraftNativeMediaOwnership.Stamp].self, from: Data(contentsOf: stamps))
    assert(!owner.permitsLocal("A") && !owner.accepts("A", stamp: old[0]))
    assert(owner.accepts("B", stamp: old[1]), "another identity survives process restart")
    var rejected = false
    do { _ = try owner.activate("A") { throw CocoaError(.fileWriteNoPermission) } }
    catch { rejected = true }
    assert(rejected && !owner.permitsLocal("A"), "failed retired-file cleanup cannot reauthorize old bytes")
    let fresh = try owner.activate("A") {}
    assert(owner.accepts("A", stamp: fresh) && !owner.accepts("A", stamp: old[0]))
    assert(owner.accepts("B", stamp: old[1]))
    try owner.clear()
    let relaunched = try CraftNativeMediaOwnership(url: url)
    assert(!relaunched.accepts("A", stamp: fresh) && !relaunched.accepts("B", stamp: old[1]))
    let next = try relaunched.activate("A") {}
    assert(relaunched.accepts("A", stamp: next) && !relaunched.accepts("A", stamp: fresh))
    // A real atomic-write failure: the journal path becomes a directory.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    var writeFailed = false
    do { try relaunched.retire("A") } catch { writeFailed = true }
    assert(writeFailed && !relaunched.permitsLocal("A"))
    try FileManager.default.removeItem(at: url)
    try relaunched.retire("A")
    let recovered = try CraftNativeMediaOwnership(url: url)
    assert(!recovered.permitsLocal("A") && !recovered.accepts("A", stamp: next))
}
print("media ownership OK")
`)
    const executable = join(root, 'ownership')
    const compile = Bun.spawn(['xcrun', 'swiftc', source, '-o', executable], { stdout: 'pipe', stderr: 'pipe' })
    const [compiled, diagnostics] = await Promise.all([compile.exited, new Response(compile.stderr).text()])
    expect(compiled, diagnostics).toBe(0)
    for (const phase of ['seed', 'recover']) {
      const child = Bun.spawn([executable, root, phase], { stdout: 'pipe', stderr: 'pipe' })
      const [status, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
      expect(status, stderr).toBe(0)
      expect(stdout).toContain('media ownership OK')
    }
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 30_000)
