import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A screen opened right after a checkpoint is seeded with that checkpoint,
 * and one opened right after a sign-out is not seeded with the account that
 * just left (#507).
 *
 * Android's isolates cannot read the host synchronously, so each starts with
 * a copy of every snapshot (`preloadText`). That copy was taken from a cache
 * the store updated only after the disk write had landed, on another thread.
 * So in the window between `craft.snapshots.set` and the write:
 *
 *   set('home', v2) → push a screen     Android seeded v1      UIKit reads v2
 *   clear() on sign-out → push login    Android seeded every   UIKit reads none
 *                                       snapshot of the old
 *                                       account
 *
 * UIKit's `CraftSnapshots` keeps what has been asked for and is not on disk
 * yet in `pending`, and a read finds it first; its `clear` is a delete of
 * every name, so it goes through the same door. Android now keeps the same
 * overlay, and tells every isolate what a read gives once a write settles —
 * the checkpoint when it was kept, the confirmed value when it was not, and a
 * newer one still on its way in either case.
 *
 * The members under test are the shipped ones, lifted out of
 * `CraftNativeStores` by name, with the real `CraftSnapshotFile` underneath.
 * The writer thread and the main looper are replaced by queues the test
 * steps, so "after the set and before the write" is a place the test can
 * stand rather than a race it has to win.
 *
 * What this does not reach is the other half of #507: a `SYNC_UPDATE` sent to
 * an isolate whose prelude has not run yet. That is between the hub and the
 * sandbox and needs a device. With the seed right, the update lost in that
 * window is now the same value the isolate already has, except after a write
 * that failed.
 */
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')
const snapshotFile = readFileSync(join(import.meta.dir, '../templates/CraftSnapshotFile.kt.template'), 'utf8')

/** Only the store's class: other classes in the template have a `main` and a `changed` of their own. */
function storesClass(): string {
  const start = shell.indexOf('internal class CraftNativeStores private constructor(')
  const end = shell.indexOf('internal object CraftNativePrelude', start)
  expect(start, 'CraftNativeStores must still be here to test').toBeGreaterThan(0)
  expect(end, 'the class after CraftNativeStores moved; find its end another way').toBeGreaterThan(start)
  return shell.slice(start, end)
}

const members = ['pendingSnapshots', 'snapshotRevision', 'currentSnapshots', 'snapshotCache', 'preloadText', 'snapshot', 'setSnapshot', 'clearSnapshots', 'changed', 'isSnapshotName', 'snapshotFile', 'snapshotName']

function fixture(lifted: string[], strict: boolean): string {
  const stores = storesClass()
  const realFile = snapshotFile.replace(/^package [^\n]*\n/m, '').replace(/^import [^\n]*\n/gm, '')
  expect(realFile).toContain('internal class CraftSnapshotFile(')
  return `
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

${realFile}

/** What was sent to the isolates, in order. */
object CraftNativeHub {
    val sent = mutableListOf<String>()
    fun broadcast(type: String, payload: JSONObject, except: String? = null) {
        sent.add(payload.getString("key") + "=" + (if (payload.isNull("value")) "null" else payload.getString("value")))
    }
}
object CraftNativeStorage { val lock = Any() }
class Preferences { val all: Map<String, Any?> = emptyMap() }
/** JSON checking has a test of its own; every payload here is JSON. */
fun craftNativeIsJsonText(@Suppress("UNUSED_PARAMETER") text: String): Boolean = true

/** A queue the test steps: the writer thread, or the main looper. */
class Steps : java.util.concurrent.Executor {
    private val queue = ArrayDeque<Runnable>()
    override fun execute(task: Runnable) { queue.addLast(task) }
    fun post(task: Runnable): Boolean { queue.addLast(task); return true }
    fun one() { queue.removeFirst().run() }
    fun all() { while (queue.isNotEmpty()) one() }
    val waiting: Int get() = queue.size
}

internal class Stores(private val snapshotsDir: File, private val snapshotFiles: CraftSnapshotFile) {
    val writer = Steps()
    val main = Steps()
    private val storage = Preferences()
    private val secure: Preferences? = null

${lifted.map(name => liftKotlinMember(stores, name)).join('\n\n')}

    fun seeded(name: String): String? = JSONObject(preloadText()).getJSONObject("snapshots").let { if (it.has(name)) it.getString(name) else null }
    fun seededNames(): List<String> = JSONObject(preloadText()).getJSONObject("snapshots").keys().asSequence().sorted().toList()
    /** The write lands and everything it posted to the main thread runs. */
    fun settle() { while (writer.waiting > 0) { writer.one(); main.all() } }
}

val defects = mutableListOf<String>()
fun must(condition: Boolean, message: () -> String) {
    if (condition) return
    if (${strict}) throw AssertionError(message())
    defects.add(message())
}

fun main() {
    val folder = File(System.getProperty("java.io.tmpdir"), "craft-snapshots-" + UUID.randomUUID()).apply { mkdirs() }
    var diskFull = false
    val files = CraftSnapshotFile(write = { file, bytes ->
        if (diskFull) throw IOException("No space left on device")
        FileOutputStream(file).use { it.write(bytes) }
    })
    try {
        for (name in listOf("home", "profile", "device")) File(folder, name + ".json").writeText("\\"" + name + " v1\\"")
        val stores = Stores(folder, files)
        val results = mutableListOf<Boolean>()
        fun sent(): List<String> = CraftNativeHub.sent.toList().also { CraftNativeHub.sent.clear() }
        must(stores.seeded("home") == "\\"home v1\\"") { "the fixture did not start from what is on disk: " + stores.seeded("home") }

        // A checkpoint, and a screen opened before the write has landed.
        stores.setSnapshot("home", "\\"home v2\\"", null) { results.add(it) }
        must(stores.snapshot("home") == "\\"home v2\\"") { "a read right after a checkpoint gave " + stores.snapshot("home") + ", not the checkpoint" }
        must(stores.seeded("home") == "\\"home v2\\"") { "a screen opened right after a checkpoint was seeded " + stores.seeded("home") + ", not the checkpoint" }
        must(File(folder, "home.json").readText() == "\\"home v1\\"") { "the write had already landed, so this proved nothing" }
        stores.settle()
        must(results == listOf(true) && sent() == listOf("home=\\"home v2\\"")) { "a kept checkpoint answered " + results + " and told the isolates " + CraftNativeHub.sent }
        must(stores.seeded("home") == "\\"home v2\\"" && File(folder, "home.json").readText() == "\\"home v2\\"") { "the checkpoint did not settle" }

        // One that cannot be kept reads as asked for until it fails, then as it was.
        results.clear(); diskFull = true
        stores.setSnapshot("home", "\\"home v3\\"", null) { results.add(it) }
        must(stores.seeded("home") == "\\"home v3\\"") { "a checkpoint on its way was seeded " + stores.seeded("home") }
        stores.settle()
        must(results == listOf(false)) { "a failed checkpoint answered " + results }
        must(sent() == listOf("home=\\"home v2\\"")) { "after a failed checkpoint the isolates were not restored to the confirmed value" }
        must(stores.snapshot("home") == "\\"home v2\\"" && stores.seeded("home") == "\\"home v2\\"") { "after a failed checkpoint a read gave " + stores.snapshot("home") }

        // Two on their way: the newer is what a read gives, and the older one
        // settling, kept or not, does not put an isolate back behind it.
        results.clear(); diskFull = true
        stores.setSnapshot("home", "\\"home v4\\"", null) { results.add(it) }
        stores.setSnapshot("home", "\\"home v5\\"", null) { results.add(it) }
        must(stores.seeded("home") == "\\"home v5\\"") { "with two checkpoints on their way a screen was seeded " + stores.seeded("home") }
        stores.writer.one(); stores.main.all()
        must(results == listOf(false)) { "the older checkpoint answered " + results }
        must(sent() == listOf("home=\\"home v5\\"")) { "an older checkpoint failing set the isolates back behind a newer one still on its way" }
        must(stores.seeded("home") == "\\"home v5\\"") { "after the older checkpoint failed a screen was seeded " + stores.seeded("home") }
        diskFull = false
        stores.settle()
        must(results == listOf(false, true) && sent() == listOf("home=\\"home v5\\"") && stores.seeded("home") == "\\"home v5\\"") { "the newer checkpoint did not settle: " + results }

        // A delete on its way is already gone for a reader.
        results.clear()
        stores.setSnapshot("profile", null, null) { results.add(it) }
        must(stores.snapshot("profile") == null && "profile" !in stores.seededNames()) { "a snapshot being deleted was still seeded" }
        stores.settle()
        must(results == listOf(true) && sent() == listOf("profile=null") && !File(folder, "profile.json").exists()) { "the delete did not settle" }

        // A sign-out, and the screen that follows it.
        results.clear()
        stores.setSnapshot("profile", "\\"profile v2\\"", null) { results.add(it) }
        stores.clearSnapshots(setOf("device")) { results.add(it) }
        must(stores.seededNames() == listOf("device")) { "a screen opened right after a sign-out was seeded with " + stores.seededNames() }
        must(stores.snapshot("home") == null && stores.snapshot("profile") == null) { "a read right after a sign-out still gave the old account's snapshots" }
        // And what the next account writes straight away survives the clear.
        stores.setSnapshot("home", "\\"next account\\"", null) { results.add(it) }
        must(stores.seeded("home") == "\\"next account\\"") { "a checkpoint made right after a sign-out was seeded " + stores.seeded("home") }
        stores.settle()
        must(results == listOf(true, true, true)) { "the sign-out answered " + results }
        must(stores.seededNames() == listOf("device", "home") && stores.seeded("home") == "\\"next account\\"") { "after the sign-out settled a screen was seeded with " + stores.seededNames() }
        must(folder.list()!!.sorted() == listOf("device.json", "home.json")) { "after the sign-out the disk held " + folder.list()!!.sorted() }
        val told = sent()
        must(told.last() == "home=\\"next account\\"" && "home=null" !in told.dropWhile { it != "home=\\"next account\\"" }) { "the isolates were left with: " + told }
        must("profile=null" in told) { "the isolates were never told profile was cleared: " + told }

        if (defects.isNotEmpty()) { defects.forEach { println("DEFECT: " + it) }; throw AssertionError(defects.size.toString() + " defects") }
        println("snapshot fixture passed")
    } finally {
        folder.deleteRecursively()
    }
}
`
}

test('a screen opened after a checkpoint or a sign-out is seeded with what was asked for', async () => {
  await runKotlinFixture(fixture(members, true), ['org.json:json:20240303'])
}, 300_000)
