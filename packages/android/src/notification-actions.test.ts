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
