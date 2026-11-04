import { expect, test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('registered notification actions retain nested data and Unicode replies without trusting payload metadata', async () => {
  const source = await Bun.file(new URL('../templates/CraftNativeNotificationReceiver.kt.template', import.meta.url)).text()
  const start = source.indexOf('    internal fun actions(')
  const end = source.indexOf('    @Synchronized', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  await runKotlinFixture(`
import org.json.JSONObject
class Preferences {
    val values = mutableMapOf<String, String>()
    var writable = true
    fun getString(key: String, fallback: String?): String? = values[key] ?: fallback
    fun edit() = Editor(this)
    class Editor(val owner: Preferences) {
        var key = ""
        fun remove(value: String) = apply { key = value }
        fun commit(): Boolean { if (!owner.writable) return false; owner.values.remove(key); return true }
    }
}
object Notifications {
${source.slice(start, end).replaceAll('android.content.SharedPreferences', 'Preferences')}
}
fun main() {
    val config = JSONObject("""{"notificationCategories":[{"id":"message","actions":[
        {"id":"reply","title":"Reply","textInput":{"buttonTitle":"Send"}},
        {"id":"open","title":"Open","foreground":true}]}]}""")
    val value = JSONObject("""{"id":"notification-1","categoryId":"message","data":{"nested":{"thread":42},"actionId":"forged"}}""")
    val storage = Preferences()
    storage.values["private-token"] = JSONObject().put("actionId", "reply").put("value", value).toString()
    check(Notifications.consumeAction(storage, "forged-token") == null)
    storage.writable = false
    check(Notifications.consumeAction(storage, "private-token") == null)
    storage.writable = true
    check(Notifications.consumeAction(storage, "private-token")?.getString("actionId") == "reply")
    check(Notifications.consumeAction(storage, "private-token") == null) // replay
    val reply = "Hello 👋 — ".repeat(2000)
    val detail = requireNotNull(Notifications.actionDetail(config, value, "reply", reply))
    check(detail.getString("actionId") == "reply" && detail.getString("notificationId") == "notification-1")
    check(detail.getString("categoryId") == "message" && detail.getString("userText") == reply)
    check(detail.getJSONObject("data").getJSONObject("nested").getInt("thread") == 42)
    check(!detail.has("id")) // worker supplies its own stable completion id
    check(!requireNotNull(Notifications.actionDetail(config, value, "open", "unexpected")).has("userText"))
    check(Notifications.actionDetail(config, value, "unknown", null) == null)
    check(Notifications.actionDetail(JSONObject(), value, "reply", reply) == null)
    for (level in listOf("passive", "active", "timeSensitive")) {
        check(Notifications.invalidOptions(JSONObject().put("interruptionLevel", level).put("threadIdentifier", "thread")) == null)
    }
    for (invalid in listOf(JSONObject().put("interruptionLevel", "critical"), JSONObject().put("threadIdentifier", 42),
        JSONObject().put("categoryId", JSONObject.NULL))) check(Notifications.invalidOptions(invalid) != null)
}
`, ['org.json:json:20250517'])
}, 60_000)

test('notification cancellation uses intended group membership while Android removal is queued', async () => {
  const source = await Bun.file(new URL('../templates/CraftNativeNotificationReceiver.kt.template', import.meta.url)).text()
  const start = source.indexOf('    fun clearEmptyGroup(')
  const end = source.indexOf('    private fun pending(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  await runKotlinFixture(`
const val GROUP_SUMMARY = 512
class Notification(val group: String, val flags: Int = 0)
class Entry(val tag: String?, val id: Int, val notification: Notification)
class NotificationManager(var activeNotifications: Array<Entry>) {
    val cancelled = mutableListOf<Pair<String, Int>>()
    var cleared = false
    // Android's service processes cancellation asynchronously. A read made
    // after cancel() can still return the original notification snapshot.
    fun cancel(tag: String, id: Int) { cancelled.add(tag to id) }
    fun cancelAll() { cleared = true }
}
class Preferences {
    val all = mutableMapOf<String, Any>()
    fun getBoolean(key: String, fallback: Boolean) = all[key] as? Boolean ?: fallback
    fun getString(key: String, fallback: String?) = all[key] as? String ?: fallback
    fun edit() = Editor(this)
    class Editor(val owner: Preferences) {
        val updates = mutableMapOf<String, Any?>()
        var clearing = false
        fun clear() = apply { clearing = true }
        fun putBoolean(key: String, value: Boolean) = apply { updates[key] = value }
        fun putString(key: String, value: String) = apply { updates[key] = value }
        fun remove(key: String) = apply { updates[key] = null }
        fun commit(): Boolean {
            if (clearing) owner.all.clear()
            updates.forEach { (key, value) -> if (value == null) owner.all.remove(key) else owner.all[key] = value }
            return true
        }
    }
}
class Context(val manager: NotificationManager, val preferences: Preferences = Preferences()) {
    companion object { const val NOTIFICATION_SERVICE = "notifications"; const val MODE_PRIVATE = 0 }
    fun getSystemService(name: String): Any = manager
    fun getSharedPreferences(name: String, mode: Int) = preferences
}
object Notifications {
    fun revoke(context: Context, id: String? = null) {}
${source.slice(start, end).replaceAll('android.app.Notification.FLAG_GROUP_SUMMARY', 'GROUP_SUMMARY').replaceAll('android.content.SharedPreferences', 'Preferences')}
}
fun main() {
    val child = Entry("first", 0, Notification("thread"))
    val second = Entry("second", 0, Notification("thread"))
    val summary = Entry("craft.group:thread", 1, Notification("thread", GROUP_SUMMARY))
    val manager = NotificationManager(arrayOf(child, summary))
    val context = Context(manager)
    Notifications.cancel(context, "first")
    check(manager.cancelled == listOf("first" to 0, "craft.group:thread" to 1)) {
        "The cancelled child must not keep its own summary alive"
    }
    val multiple = NotificationManager(arrayOf(child, second, summary))
    val shared = Context(multiple)
    Notifications.cancel(shared, "first")
    check(multiple.cancelled == listOf("first" to 0)) { "Another child still owns the group" }
    // A second receiver instance/process reads the same durable membership.
    Notifications.cancel(Context(multiple, shared.preferences), "second")
    check(multiple.cancelled == listOf("first" to 0, "second" to 0, "craft.group:thread" to 1))
    // Cancelling an unrelated identifier must not dismiss another group.
    val unrelated = NotificationManager(arrayOf(second, summary))
    Notifications.cancel(Context(unrelated), "unknown")
    check(unrelated.cancelled == listOf("unknown" to 0))
    Notifications.cancelAll(shared)
    check(multiple.cleared)
    check(shared.preferences.all == mapOf("initialized" to true))
}
`)
}, 60_000)
