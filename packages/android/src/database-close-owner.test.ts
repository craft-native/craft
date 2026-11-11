import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A host that closes with a transaction open gives the database back.
 *
 * Each host has its own connection to the one database file: the activity's,
 * and the app script started with no activity for a background refresh or a
 * silent push. `close()` shut the database thread down and closed the
 * database from the caller's thread. A transaction belongs to the thread that
 * began it, so that close could not end one: its connection stayed open where
 * nothing could reach it, holding the write lock. On an API 35 emulator the
 * next host's first call then answered
 *
 *   DATABASE_ERROR database is locked (code 5 SQLITE_BUSY): , while compiling: PRAGMA journal_mode
 *
 * which is the device test `aHostClosedMidTransactionLeavesTheDatabaseToTheNext`.
 * A screen that closes mid-transaction was already handled (`endScope`); this
 * is the host itself closing: an activity destroyed while its process lives
 * on, or a background script that ran out of time.
 *
 * The function under test is the shipped `closeDatabase`, run on a real
 * database thread. The database is a model of the one thing the device
 * showed: a transaction is held by a thread, and closing from another thread
 * does not release the lock it holds.
 */
const capabilities = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')

test('closing a host rolls back its open transaction on the database thread before closing the database', async () => {
  const closeDatabase = liftKotlinMember(capabilities, 'closeDatabase').replaceAll('android.util.Log.w(', 'Log.w(')
  expect(closeDatabase, 'no Android type may survive into the JVM fixture').not.toContain('android.')
  await runKotlinFixture(`
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

object Log { fun w(tag: String, message: String, error: Throwable): Int = 0 }

class DatabaseFile { @Volatile var lockedBy: SQLiteDatabase? = null }

/** A transaction is held by the thread that began it, and holds the file's write lock. */
class SQLiteDatabase(private val file: DatabaseFile) {
    @Volatile private var owner: Thread? = null
    @Volatile var open = true
    fun inTransaction(): Boolean = owner === Thread.currentThread()
    fun beginTransaction() {
        check(file.lockedBy == null) { "database is locked" }
        owner = Thread.currentThread()
        file.lockedBy = this
    }
    fun endTransaction() {
        check(inTransaction()) { "no transaction on this thread" }
        owner = null
        file.lockedBy = null
    }
    /** Closing does not end a transaction another thread holds: its lock stays. */
    fun close() { open = false }
}

internal class Capabilities(private val file: DatabaseFile) {
    val databaseExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    @Volatile var database: SQLiteDatabase? = null
    @Volatile var transactionScope: String? = null

${closeDatabase}

    fun onDatabaseThread(work: (SQLiteDatabase) -> Unit) {
        databaseExecutor.submit { work(database ?: SQLiteDatabase(file).also { database = it }) }.get()
    }
    /** As the activity closes it: from a thread that is not the database's. */
    fun close(): Boolean { closeDatabase(); return databaseExecutor.awaitTermination(5, TimeUnit.SECONDS) }
}

fun must(condition: Boolean, message: () -> String) { if (!condition) throw AssertionError(message()) }

fun main() {
    val file = DatabaseFile()

    // A host begins a transaction and is closed before finishing it.
    val first = Capabilities(file)
    first.onDatabaseThread { it.beginTransaction() }
    first.transactionScope = "screen"
    val held = first.database!!
    must(file.lockedBy === held) { "the fixture's transaction did not take the lock" }
    must(first.close()) { "the database thread did not finish after the host closed" }
    must(file.lockedBy == null) { "a closed host still holds the write lock" }
    must(!held.open) { "a closed host left its database open" }
    must(first.database == null && first.transactionScope == null) { "a closed host kept its database or its transaction's owner" }

    // The next host has the file to itself.
    val second = Capabilities(file)
    second.onDatabaseThread { it.beginTransaction(); it.endTransaction() }
    val idle = second.database!!
    must(second.close()) { "the database thread did not finish after the host closed" }
    must(!idle.open && file.lockedBy == null) { "a host with no transaction open did not close cleanly" }

    // A host that never used the database closes without opening it.
    val unused = Capabilities(file)
    must(unused.close() && unused.database == null) { "a host that never opened the database did not close cleanly" }
}
`)
}, 300_000)

test('a call that reaches the database thread after its host closed does nothing', () => {
  // Calls already queued run before the close does. One that reopened the
  // database there would leave a connection nobody closes.
  expect(capabilities).toMatch(/else databaseExecutor\.execute \{\n(?:\s*\/\/[^\n]*\n)*\s*if \(closed\.get\(\)\) return@execute\n\s*complete\(requestToken, database\(requestToken, method, args\), completion\)/)
  // And the host closes its database through the function above, not from the caller's thread.
  const close = liftKotlinMember(capabilities, 'fun close')
  expect(close).toContain('closeDatabase()')
  expect(close).not.toContain('database?.close()')
  expect(close).not.toContain('databaseExecutor.shutdownNow()')
})
