import { expect, test } from 'bun:test'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A stored value that cannot be read is `STORAGE_CORRUPT`, and it does not
 * stop the rest of storage from working.
 *
 * `craft.storage` on UIKit keeps each value in a file. A file whose contents
 * parsed to the wrong thing answered `STORAGE_CORRUPT`, the code Android and
 * the browser host give and the one an app catches to start that value again.
 * A file that did not parse at all answered `STORAGE_ERROR`, the code for a
 * disk that could not be read or written, which an app retries.
 *
 * And one such file anywhere in the directory failed two calls that never
 * named it. `keys()` rejected, and `clear()` with it, since it clears what
 * `keys()` lists: a sign-out that could not clear storage, on every launch,
 * with no call left that could repair it short of knowing the damaged key.
 *
 * The code under test is the shipped `CraftPersistentStorage`, compiled
 * against real Foundation. The process is given a home directory of its own,
 * so its files and its defaults are the test's and not this machine's.
 */
const templates = join(import.meta.dir, '../templates')
const storage = readFileSync(join(templates, 'CraftPersistentStorage.swift'), 'utf8')
const archive = readFileSync(join(templates, 'CraftRecordingArchive.swift'), 'utf8')

test.skipIf(process.platform !== 'darwin')('a corrupt entry is STORAGE_CORRUPT, and keys and clear still work beside it', () => {
  const dir = createTempDir('craft-storage-corrupt-')
  try {
    const home = join(dir, 'home'), binary = join(dir, 'probe')
    const sources = { 'Storage.swift': storage, 'Archive.swift': archive, 'main.swift': `import Foundation
import CryptoKit
struct CraftNativeActionError: Error { let code: String; let message: String }

let prefix = "craft.test."
func code(_ work: () throws -> Any?) -> String {
    do { return "ok " + String(describing: try work() ?? "nil") }
    catch let error as CraftNativeActionError { return error.code }
    catch { return "other error" }
}
func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }
func entry(_ key: String) -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("craft-native-storage")
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return support.appendingPathComponent(digest + ".json")
}

try CraftPersistentStorage.set("kept", data: Data("1".utf8), prefix: prefix)
try CraftPersistentStorage.set("garbled", data: Data("2".utf8), prefix: prefix)
try CraftPersistentStorage.set("wrong-shape", data: Data("3".utf8), prefix: prefix)
print("home " + entry("kept").path)
// One file cut short, as a damaged disk leaves it, and one that parses to something else.
try Data("{\\"key\\":\\"garbl".utf8).write(to: entry("garbled"))
try Data("[1,2,3]".utf8).write(to: entry("wrong-shape"))
// And one that belongs to no key at all.
let stray = entry("kept").deletingLastPathComponent().appendingPathComponent("stray.json")
try Data("not an entry".utf8).write(to: stray)

print("get garbled: " + code { text(try CraftPersistentStorage.get("garbled", prefix: prefix)) })
print("get wrong-shape: " + code { text(try CraftPersistentStorage.get("wrong-shape", prefix: prefix)) })
print("get kept: " + code { text(try CraftPersistentStorage.get("kept", prefix: prefix)) })
print("compareAndSet garbled: " + code { try CraftPersistentStorage.compareAndSet("garbled", expected: 2, value: 5, prefix: prefix) })
print("keys: " + code { try CraftPersistentStorage.keys(prefix: prefix).joined(separator: ",") })
print("clear: " + code { try CraftPersistentStorage.clear(prefix: prefix); return "done" })
print("after clear, get kept: " + code { text(try CraftPersistentStorage.get("kept", prefix: prefix)) })
print("after clear, get garbled: " + code { text(try CraftPersistentStorage.get("garbled", prefix: prefix)) })
print("after clear, keys: " + code { try CraftPersistentStorage.keys(prefix: prefix).joined(separator: ",") })
print("after clear, the stray file is " + (FileManager.default.fileExists(atPath: stray.path) ? "still there" : "gone"))
// And storage goes on working under the same names.
try CraftPersistentStorage.set("garbled", data: Data("7".utf8), prefix: prefix)
print("set again, get garbled: " + code { text(try CraftPersistentStorage.get("garbled", prefix: prefix)) })
` }
    for (const [name, source] of Object.entries(sources)) writeFileSync(join(dir, name), source)
    const build = Bun.spawnSync(['swiftc', ...Object.keys(sources).map(name => join(dir, name)), '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000, env: { ...process.env, CFFIXED_USER_HOME: home, HOME: home } })
    expect(run.exitCode, run.stderr.toString()).toBe(0)
    const lines = run.stdout.toString().trimEnd().split('\n')
    // The probe's storage must be inside the test's directory, or this test is writing to the machine's own.
    expect(lines[0], 'the probe was not confined to its own home').toStartWith(`home ${home}/`)
    expect(existsSync(join(home, 'Library'))).toBe(true)
    expect(lines.slice(1)).toEqual([
      'get garbled: STORAGE_CORRUPT',
      'get wrong-shape: STORAGE_CORRUPT',
      'get kept: ok 1',
      'compareAndSet garbled: STORAGE_CORRUPT',
      // Each key is listed, the damaged ones too: the listing is of names.
      'keys: ok garbled,kept,wrong-shape',
      'clear: ok done',
      'after clear, get kept: ok nil',
      'after clear, get garbled: ok nil',
      'after clear, keys: ok ',
      'after clear, the stray file is gone',
      'set again, get garbled: ok 7',
    ])
  }
  finally { removeTempDir(dir) }
}, 300_000)
