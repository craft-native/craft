import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A scheduled notification that could not be saved is not scheduled, and one
 * that could not be removed is not cancelled.
 *
 * A local notification on Android is two things: an alarm, and the stored
 * text the receiver shows when the alarm fires, usually in a process started
 * for it. Each start schedules whatever is stored. Both writes ignored their
 * result:
 *
 * - `schedule` set the alarm and answered with the id whether or not the
 *   notification had been saved. Unsaved, the alarm fired, the receiver
 *   found nothing under the id, and nothing was shown.
 * - `cancel` cancelled the alarm and answered `true` whether or not the
 *   notification had been removed. Not removed, it was scheduled again by
 *   the next start and shown.
 *
 * UIKit hands the request to the system and answers `NOTIFICATION_ERROR`
 * when the system refuses it.
 *
 * The functions under test are the shipped `schedule`, `cancelNotification`
 * and `cancelEveryNotification`, over the shipped `CraftNativeStorage.commit`.
 * The preferences are a model of the one thing Android documents about a
 * commit: it applies to memory first and reports the disk afterwards. The
 * alarms are a list.
 */
const capabilities = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

test('the dispatcher answers a cancel that did not reach the disk as an error', () => {
  expect(capabilities).toContain(`else if (cancelNotification(id)) success(true)
                    else failure("NOTIFICATION_ERROR", "The notification could not be cancelled"), completion)`)
  expect(capabilities).toContain('"cancelAll" -> complete(requestToken, cancelEveryNotification(), completion)')
  // No notification write may go round the commit that reports and restores.
  expect(capabilities).not.toMatch(/notificationStorage\.edit\(\)/)
})

test('a notification is scheduled only once it is saved, and cancelled only once it is removed', async () => {
  const start = shell.indexOf('internal object CraftNativeStorage {')
  const object = shell.slice(start, shell.indexOf('internal class CraftNativeStores', start))
  expect(start, 'CraftNativeStorage must still be here to test').toBeGreaterThan(0)
  const commit = liftKotlinMember(object, 'commit').replaceAll('android.content.SharedPreferences', 'SharedPreferences')
  await runKotlinFixture(`
import org.json.JSONObject
import java.util.UUID

/** Android's contract: a commit applies to memory, then reports the disk write. */
class SharedPreferences {
    val disk = HashMap<String, Any?>()
    private val memory = HashMap<String, Any?>()
    var diskFull = false
    val all: Map<String, Any?> get() = HashMap(memory)
    fun getString(key: String, fallback: String?): String? = memory[key] as? String ?: fallback
    fun edit(): Editor = Editor()
    inner class Editor {
        private val puts = LinkedHashMap<String, Any?>()
        private val removes = HashSet<String>()
        private var clears = false
        fun putString(key: String, value: String?): Editor { puts[key] = value; return this }
        fun putBoolean(key: String, value: Boolean): Editor { puts[key] = value; return this }
        fun putLong(key: String, value: Long): Editor { puts[key] = value; return this }
        fun putInt(key: String, value: Int): Editor { puts[key] = value; return this }
        fun putFloat(key: String, value: Float): Editor { puts[key] = value; return this }
        fun remove(key: String): Editor { removes.add(key); return this }
        fun clear(): Editor { clears = true; return this }
        fun commit(): Boolean {
            if (clears) memory.clear()
            removes.forEach(memory::remove)
            memory.putAll(puts)
            if (diskFull) return false
            disk.clear(); disk.putAll(memory)
            return true
        }
    }
}

internal data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)
internal object CraftNativeStorage {
${commit}
}

object Build { object VERSION { const val SDK_INT = 30 }; object VERSION_CODES { const val TIRAMISU = 33 } }
object Manifest { object permission { const val POST_NOTIFICATIONS = "post" } }
object PackageManager { const val PERMISSION_GRANTED = 0 }
object ContextCompat { fun checkSelfPermission(context: Context, permission: String): Int = 0 }
class PendingIntent(val id: String) { fun cancel() {} }
class AlarmManager(private val alarms: MutableList<String>) { fun cancel(intent: PendingIntent) { alarms.remove(intent.id) } }
class NotificationManager { fun cancel(tag: String, id: Int) {} }
class Context(val alarms: MutableList<String>) {
    fun getSystemService(name: String): Any = if (name == ALARM_SERVICE) AlarmManager(alarms) else NotificationManager()
    companion object { const val ALARM_SERVICE = "alarm"; const val NOTIFICATION_SERVICE = "notification" }
}
object CraftNativeNotifications {
    fun invalidOptions(value: JSONObject): String? = null
    fun cancel(context: Context, id: String) {}
    fun cancelAll(context: Context) {}
}

internal class Capabilities(private val notificationStorage: SharedPreferences) {
    /** The alarms that are set, by notification id. */
    val alarms = mutableListOf<String>()
    private val context = Context(alarms)
    private fun scheduleStored(value: JSONObject) { alarms.add(value.getString("id")) }
    private fun notificationIntent(id: String) = PendingIntent(id)

${['fun schedule', 'cancelNotification', 'cancelEveryNotification', 'validKey', 'success', 'failure'].map(name => liftKotlinMember(capabilities, name)).join('\n\n')}

    fun ask(id: String) = schedule(JSONObject().put("id", id).put("title", "Reminder").put("delay", 60000))
    fun cancel(id: String) = cancelNotification(id)
    fun cancelAll() = cancelEveryNotification()
    /** What the next process start schedules: whatever is on the disk. */
    fun afterRestart(): List<String> = notificationStorage.disk.keys.sorted()
}

fun must(condition: Boolean, message: () -> String) { if (!condition) throw AssertionError(message()) }

fun main() {
    val store = SharedPreferences()
    val host = Capabilities(store)

    val kept = host.ask("water")
    must(kept.code == null && kept.data == "water" && host.alarms == listOf("water") && host.afterRestart() == listOf("water")) { "a notification that was saved answered " + kept }

    // The disk refuses the save.
    store.diskFull = true
    val unsaved = host.ask("stretch")
    must(unsaved.code == "NOTIFICATION_ERROR") { "a notification that could not be saved answered " + unsaved + "; nothing would be shown when its alarm fired" }
    must(host.alarms == listOf("water")) { "an alarm was set for a notification that was not saved: " + host.alarms }
    must(store.getString("stretch", null) == null) { "the unsaved notification is still listed as pending for the life of the process" }

    // The disk refuses the removal.
    must(!host.cancel("water")) { "a cancel that did not reach the disk answered true; the next start schedules it again" }
    must(host.alarms == listOf("water")) { "the alarm was cancelled though the notification is still stored: " + host.alarms }
    must(store.getString("water", null) != null && host.afterRestart() == listOf("water")) { "a failed cancel changed what is stored" }
    val all = host.cancelAll()
    must(all.code == "NOTIFICATION_ERROR" && host.alarms == listOf("water")) { "cancelAll with a disk that refuses answered " + all + " with alarms " + host.alarms }

    // And when the disk takes it, both go through.
    store.diskFull = false
    must(host.ask("stretch").code == null && host.alarms.sorted() == listOf("stretch", "water")) { "scheduling did not recover" }
    must(host.cancel("water") && host.alarms == listOf("stretch") && host.afterRestart() == listOf("stretch")) { "a cancel the disk took left " + host.alarms + " and " + host.afterRestart() }
    val cleared = host.cancelAll()
    must(cleared.code == null && cleared.data == true && host.alarms.isEmpty() && host.afterRestart().isEmpty()) { "cancelAll answered " + cleared + " leaving " + host.alarms }
    println("notification storage fixture passed")
}
`, ['org.json:json:20240303'])
}, 300_000)
