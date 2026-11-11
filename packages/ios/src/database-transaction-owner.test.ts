import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

/**
 * A transaction a screen began and never finished ends when the screen does.
 *
 * `craft.database` is one SQLite connection shared by every screen. A
 * transaction left open on it — the screen was popped between
 * `beginTransaction` and `commit`, or its script threw and never rolled back
 * — did not end with the screen. From then until the app was restarted:
 *
 *   - every later write, from any screen, joined that transaction, read back
 *     as written, and was gone at exit, since nobody was left to commit;
 *   - every later `beginTransaction` was refused.
 *
 * Whose transaction is open is now read off the database around each call
 * (`sqlite3_get_autocommit`), so a `BEGIN` sent through `execute` is owned
 * like one sent through `beginTransaction`, and a screen's disposal rolls
 * back the one it owns. That loses what the closed screen had not committed,
 * which is what closing mid-transaction means, and nothing else.
 *
 * The functions under test are the shipped ones, lifted from the template and
 * run on the system's SQLite, which is the engine the app uses. Only the
 * database's location is supplied by the fixture. Each scenario ends by
 * closing the connection and opening the file again, because "is it durable"
 * is a question for a new connection, not for the one that wrote it.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftNativeActions.swift'), 'utf8')
const screen = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')

/** One static member of `CraftNativeActions`, as shipped. */
function lift(signature: string): string {
  const start = template.indexOf(`    ${signature}`)
  expect(start, `${signature} must still be here to test`).toBeGreaterThan(0)
  expect(template.indexOf(`    ${signature}`, start + 1), `${signature} is declared twice`).toBe(-1)
  // A stored property is its own line; a function runs to its closing brace.
  if (!signature.includes('func ')) return template.slice(start, template.indexOf('\n', start))
  const end = template.indexOf('\n    }\n', start)
  return template.slice(start, end + '\n    }'.length)
}

const members = [
  'static func endScope(_ scope: String)',
  'private static var transactionScope: String?',
  'private static func database(requestToken: String, method: String, args: [Any])',
  'private static func databaseCall(method: String, args: [Any])',
  'private static func transaction(sql: String)',
  'private static func bind(_ params: [Any], to statement: OpaquePointer?)',
  'private static func execute(sql: String, params: [Any])',
  'private static func query(sql: String, params: [Any])',
  'private static func databaseFailure()',
]

test('every way a screen ends rolls back the transaction it owns', () => {
  // Both the disposal and the deinit cancel the screen's requests; each must
  // also end its scope, or a screen that goes one way keeps its transaction.
  const cancels = [...screen.matchAll(/pendingCapabilityRequests\.forEach \{ CraftNativeActions\.cancel\(requestToken: \$0\) \}\n( *)(.*)\n/g)]
  expect(cancels.length, 'the places a screen cancels its native requests').toBeGreaterThan(1)
  for (const found of cancels) expect(found[2], 'a screen that cancels its requests must end its scope too').toBe('CraftNativeActions.endScope(capabilityScope)')
  // And the scope it ends is the one its request tokens carry.
  expect(screen).toContain('let requestToken = "\\(capabilityScope)/\\(id)"')
})

test.skipIf(process.platform !== 'darwin')('a closed screen\'s transaction is rolled back and later writes are durable', () => {
  const dir = createTempDir('craft-database-owner-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'probe')
    writeFileSync(probe, `import Foundation
import SQLite3

struct CraftNativeActionError: Error { let code: String; let message: String }

enum CraftNativeActions {
    static let databaseQueue = DispatchQueue(label: "fixture.database")
    static var database: OpaquePointer?
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var path = ""
    static func failure(_ code: String, _ message: String) -> Result<Any, CraftNativeActionError> { .failure(CraftNativeActionError(code: code, message: message)) }
    /// The fixture's only stand-in: where the file is.
    static func openDatabase() -> Bool {
        if database != nil { return true }
        guard sqlite3_open(path, &database) == SQLITE_OK else { return false }
        sqlite3_busy_timeout(database, 5_000)
        return true
    }

${members.map(lift).join('\n\n')}

    /// A request from a screen, as the dispatcher makes one, and its answer.
    static func ask(_ scope: String, _ method: String, _ args: [Any] = []) -> Result<Any, CraftNativeActionError> {
        databaseQueue.sync { database(requestToken: scope + "/" + UUID().uuidString, method: method, args: args) }
    }
    static func settle() { databaseQueue.sync {} }
    /// The app exits and starts again: what a new connection finds.
    static func restart() -> [String] {
        databaseQueue.sync { if let open = database { sqlite3_close(open) }; database = nil; transactionScope = nil }
        guard case .success(let rows) = ask("reader", "query", ["SELECT body FROM notes ORDER BY rowid"]) else { return ["<unreadable>"] }
        return (rows as? [[String: Any]] ?? []).map { $0["body"] as? String ?? "?" }
    }
}

var report: [String: Any] = [:]
func ok(_ answer: Result<Any, CraftNativeActionError>) -> Bool { if case .success = answer { return true }; return false }
func code(_ answer: Result<Any, CraftNativeActionError>) -> String { if case .failure(let error) = answer { return error.code + ": " + error.message }; return "ok" }
func insert(_ scope: String, _ body: String) -> Bool { ok(CraftNativeActions.ask(scope, "execute", ["INSERT INTO notes VALUES (?)", [body]])) }
func fresh(_ name: String) {
    CraftNativeActions.databaseQueue.sync { if let open = CraftNativeActions.database { sqlite3_close(open) }; CraftNativeActions.database = nil }
    CraftNativeActions.path = CommandLine.arguments[1] + "/" + name + ".sqlite"
    _ = CraftNativeActions.ask("setup", "execute", ["CREATE TABLE notes (body TEXT)"])
    _ = insert("setup", "before")
}

// 1. A screen begins, writes, and is closed before it commits. Another screen writes afterwards.
fresh("abandoned")
report["abandoned.begin"] = code(CraftNativeActions.ask("A", "beginTransaction"))
_ = insert("A", "A, never committed")
CraftNativeActions.endScope("A")
CraftNativeActions.settle()
report["abandoned.laterBegin"] = code(CraftNativeActions.ask("B", "beginTransaction"))
_ = insert("B", "B, in its own transaction")
report["abandoned.laterCommit"] = code(CraftNativeActions.ask("B", "commit"))
_ = insert("C", "C, with no transaction")
report["abandoned.afterRestart"] = CraftNativeActions.restart()

// 2. The same, with the BEGIN sent as SQL instead of through beginTransaction.
fresh("raw")
_ = CraftNativeActions.ask("A", "execute", ["BEGIN IMMEDIATE"])
_ = insert("A", "A, never committed")
CraftNativeActions.endScope("A")
CraftNativeActions.settle()
_ = insert("C", "C, with no transaction")
report["raw.afterRestart"] = CraftNativeActions.restart()

// 3. A screen that closes does not end a transaction another screen owns.
fresh("bystander")
_ = CraftNativeActions.ask("A", "beginTransaction")
_ = insert("A", "A, committed later")
CraftNativeActions.endScope("B")
CraftNativeActions.settle()
report["bystander.commit"] = code(CraftNativeActions.ask("A", "commit"))
report["bystander.afterRestart"] = CraftNativeActions.restart()

// 4. A finished transaction is nobody's: closing afterwards rolls nothing back,
//    whichever way it finished and whoever finished it.
fresh("finished")
_ = CraftNativeActions.ask("A", "beginTransaction")
_ = insert("A", "A, committed")
_ = CraftNativeActions.ask("A", "commit")
_ = CraftNativeActions.ask("B", "beginTransaction")
_ = insert("B", "B, open when A closes")
CraftNativeActions.endScope("A")
CraftNativeActions.settle()
report["finished.commit"] = code(CraftNativeActions.ask("B", "commit"))
report["finished.afterRestart"] = CraftNativeActions.restart()

// 5. A second begin is refused while one is open, by SQLite itself.
fresh("nested")
_ = CraftNativeActions.ask("A", "beginTransaction")
report["nested.second"] = code(CraftNativeActions.ask("B", "beginTransaction"))
_ = CraftNativeActions.ask("A", "rollback")

print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
`)
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary, '-lsqlite3'], { stdout: 'pipe', stderr: 'pipe', timeout: 180_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)
    const run = Bun.spawnSync([binary, dir], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)
    const report = JSON.parse(run.stdout.toString()) as Record<string, unknown>

    // The closed screen's uncommitted row is gone; everyone else's is kept.
    expect(report['abandoned.begin']).toBe('ok')
    expect(report['abandoned.laterBegin'], 'another screen could not begin after the owner closed').toBe('ok')
    expect(report['abandoned.laterCommit']).toBe('ok')
    expect(report['abandoned.afterRestart'], 'what survived a restart after a screen closed mid-transaction')
      .toEqual(['before', 'B, in its own transaction', 'C, with no transaction'])
    expect(report['raw.afterRestart'], 'a BEGIN sent as SQL must be owned like any other')
      .toEqual(['before', 'C, with no transaction'])

    // Closing ends only your own.
    expect(report['bystander.commit']).toBe('ok')
    expect(report['bystander.afterRestart']).toEqual(['before', 'A, committed later'])
    expect(report['finished.commit']).toBe('ok')
    expect(report['finished.afterRestart']).toEqual(['before', 'A, committed', 'B, open when A closes'])

    // And SQLite's own refusal, which Android is held to.
    expect(String(report['nested.second'])).toContain('cannot start a transaction within a transaction')
  }
  finally { removeTempDir(dir) }
}, 300_000)
