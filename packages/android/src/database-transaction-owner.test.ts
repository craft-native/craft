import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A transaction a screen began and never finished ends when the screen does,
 * and a second one is refused while the first is open.
 *
 * `craft.database` is one connection shared by every screen. Two things went
 * wrong on Android when a transaction outlived its moment:
 *
 * - **A second `beginTransaction` nested.** SQLite refuses a transaction
 *   inside a transaction, and that is what UIKit answers. Android's wrapper
 *   counts them instead, so the inner `commit` made nothing durable while
 *   reporting that it had, and whether it ever became durable was up to
 *   whoever held the outer one.
 * - **A screen closed between `beginTransaction` and `commit` left it open.**
 *   Every later write, from any screen, then joined it, read back as written,
 *   and was gone when the process exited, since nobody was left to commit.
 *
 * The functions under test are the shipped ones: `database`, `databaseCall`
 * and `endScope`. The database underneath is a model, and what it models is
 * Android's documented transaction contract — transactions nest by count, an
 * inner one that ends without being marked successful fails the outer, and
 * only the outermost end makes anything durable. Whether a device's SQLite
 * behaves as documented is what the device test is for; it asserts the
 * refused second begin and the rollback on a real database.
 * `packages/ios/src/database-transaction-owner.test.ts` runs the same
 * scenarios for UIKit on the real engine.
 */
const capabilities = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
const activity = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')

test('a closing screen ends its scope wherever it cancels its native requests', () => {
  // closeScreen cancels a screen's requests twice, before the isolate's
  // teardown and after it, because one can be issued in between. A
  // transaction can be begun in between too.
  const cancels = [...activity.matchAll(/screen\.pendingCapabilities\.forEach\(capabilities::cancel\)\n\s*screen\.pendingCapabilities\.clear\(\)\n((?:\s*\/\/[^\n]*\n)*)\s*(.*)\n/g)]
  expect(cancels.length, 'the places a screen cancels its native requests').toBe(2)
  for (const found of cancels) expect(found[2], 'a screen that cancels its requests must end its scope too').toBe('capabilities.endScope(screen.capabilityScope)')
  // And the scope it ends is the one its request tokens carry.
  expect(activity).toContain('val token = "${screen.capabilityScope}/$id"')
})

test('a closed screen\'s transaction is rolled back and a nested one is refused', async () => {
  await runKotlinFixture(`
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

internal data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)
object Context { const val MODE_PRIVATE = 0 }
object Log { fun w(tag: String, message: String, error: Throwable): Int = 0 }

/** Android's transaction contract over a list of rows. */
class SQLiteDatabase {
    /** What a new connection would find. */
    var durable = listOf<String>()
    private var working = mutableListOf<String>()
    private var depth = 0
    private var marked = false
    private var failed = false
    fun inTransaction(): Boolean = depth > 0
    fun beginTransaction() { depth += 1; marked = false }
    fun setTransactionSuccessful() { check(depth > 0) { "no transaction" }; marked = true }
    fun endTransaction() {
        check(depth > 0) { "no transaction" }
        if (!marked) failed = true
        marked = false
        depth -= 1
        if (depth > 0) return
        if (failed) working = durable.toMutableList() else durable = working.toList()
        failed = false
    }
    fun insert(body: String) { working.add(body); if (depth == 0) durable = working.toList() }
    fun rows(): List<String> = working.toList()
    /** The process exits: whatever was not durable is gone. */
    fun restart(): List<String> { depth = 0; marked = false; failed = false; working = durable.toMutableList(); return durable }
}

/** Runs what is queued when the test says so, in order. */
class Queue {
    private val tasks = ArrayDeque<() -> Unit>()
    fun execute(task: () -> Unit) { tasks.addLast(task) }
    fun drain() { while (tasks.isNotEmpty()) tasks.removeFirst()() }
}

internal class Capabilities(private var database: SQLiteDatabase?) {
    val closed = AtomicBoolean(false)
    val databaseExecutor = Queue()
    private val context = object { fun openOrCreateDatabase(name: String, mode: Int, factory: Any?): SQLiteDatabase = error("the fixture supplies the database") }
    private fun success(data: Any?) = CraftNativeCapabilityResult(data = data)
    private fun failure(code: String, message: String) = CraftNativeCapabilityResult(code = code, message = message)
    /** Statement execution has tests of its own; here a statement is a row to add. */
    private fun execute(db: SQLiteDatabase, sql: String, @Suppress("UNUSED_PARAMETER") params: JSONArray): CraftNativeCapabilityResult { db.insert(sql); return success(JSONObject().put("rowsAffected", 1)) }
    private fun query(db: SQLiteDatabase, @Suppress("UNUSED_PARAMETER") sql: String, @Suppress("UNUSED_PARAMETER") params: JSONArray): CraftNativeCapabilityResult = success(JSONArray(db.rows()))

${['endScope', 'transactionScope', 'fun database', 'databaseCall'].map(name => liftKotlinMember(capabilities, name)).join('\n\n').replaceAll('android.util.Log.w(', 'Log.w(')}

    /** A request from a screen, as the activity makes one. */
    fun ask(scope: String, method: String, sql: String? = null): CraftNativeCapabilityResult =
        database(scope + "/" + java.util.UUID.randomUUID(), method, JSONArray().apply { if (sql != null) put(sql) })
    fun close(scope: String) { endScope(scope); databaseExecutor.drain() }
}

fun must(condition: Boolean, message: () -> String) { if (!condition) throw AssertionError(message()) }

fun main() {
    // A second begin is refused while one is open, as SQLite refuses it.
    run {
        val db = SQLiteDatabase(); val host = Capabilities(db)
        must(host.ask("A", "beginTransaction").code == null) { "the first begin was refused" }
        val second = host.ask("B", "beginTransaction")
        must(second.code == "DATABASE_ERROR" && second.message == "cannot start a transaction within a transaction") { "a second begin while one is open answered " + second }
        host.ask("A", "execute", "A")
        must(host.ask("A", "commit").code == null) { "the commit was refused" }
        must(db.restart() == listOf("A")) { "one begin and one commit left " + db.durable + " durable" }
        must(host.ask("A", "commit").code == "DATABASE_ERROR" && host.ask("A", "rollback").code == "DATABASE_ERROR") { "ending a transaction that is not open was not refused" }
    }

    // A screen begins, writes, and is closed before it commits.
    run {
        val db = SQLiteDatabase(); val host = Capabilities(db)
        db.insert("before")
        host.ask("A", "beginTransaction")
        host.ask("A", "execute", "A, never committed")
        host.close("A")
        must(!db.inTransaction()) { "a closed screen's transaction was left open" }
        must(host.ask("B", "beginTransaction").code == null) { "another screen could not begin after the owner closed" }
        host.ask("B", "execute", "B, in its own transaction")
        must(host.ask("B", "commit").code == null) { "the later commit was refused" }
        host.ask("C", "execute", "C, with no transaction")
        must(db.restart() == listOf("before", "B, in its own transaction", "C, with no transaction")) { "after a screen closed mid-transaction a restart found " + db.durable }
    }

    // Closing ends only your own.
    run {
        val db = SQLiteDatabase(); val host = Capabilities(db)
        host.ask("A", "beginTransaction")
        host.ask("A", "execute", "A, committed later")
        host.close("B")
        must(db.inTransaction()) { "a bystander closing ended someone else's transaction" }
        host.ask("A", "commit")
        must(db.restart() == listOf("A, committed later")) { "a bystander closing cost " + db.durable }
    }

    // A finished transaction is nobody's: its screen closing later touches nothing.
    run {
        val db = SQLiteDatabase(); val host = Capabilities(db)
        host.ask("A", "beginTransaction"); host.ask("A", "execute", "A, committed"); host.ask("A", "commit")
        host.ask("B", "beginTransaction"); host.ask("B", "execute", "B, open when A closes")
        host.close("A")
        must(db.inTransaction()) { "a screen closing after it committed ended the next screen's transaction" }
        host.ask("B", "commit")
        must(db.restart() == listOf("A, committed", "B, open when A closes")) { "a screen closing after it committed cost " + db.durable }
        // Rolled back by its owner, then the owner closes: the same.
        host.ask("A", "beginTransaction"); host.ask("A", "rollback")
        host.ask("B", "beginTransaction"); host.ask("B", "execute", "B again")
        host.close("A")
        must(db.inTransaction()) { "a screen closing after it rolled back ended the next screen's transaction" }
        host.ask("B", "commit")
    }

    // What the closing screen asked for last still runs before its scope ends.
    run {
        val db = SQLiteDatabase(); val host = Capabilities(db)
        host.databaseExecutor.execute { host.ask("A", "beginTransaction"); host.ask("A", "execute", "queued") }
        host.endScope("A")
        host.databaseExecutor.drain()
        must(!db.inTransaction() && db.restart().isEmpty()) { "a transaction begun just before the close outlived it: " + db.durable }
    }

    // A host that has shut down has nothing to roll back and does not try.
    run {
        val host = Capabilities(SQLiteDatabase())
        host.closed.set(true)
        host.endScope("A")
        host.databaseExecutor.drain()
    }
    println("database fixture passed")
}
`, ['org.json:json:20240303'])
}, 300_000)
