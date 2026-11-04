import { expect, test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('background action storage preserves large replies and independent pending payloads', async () => {
  const source = await Bun.file(new URL('../templates/CraftNativeBackground.kt.template', import.meta.url)).text()
  const start = source.indexOf('internal object CraftNativeBackgroundPayload')
  const end = source.indexOf('internal object CraftNativeBackground {', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  await runKotlinFixture(`
import java.util.UUID
class Preferences {
    val data = mutableMapOf<String, String>()
    var writable = true
    fun getString(key: String, fallback: String?): String? = data[key] ?: fallback
    fun edit() = Editor(this)
    class Editor(val owner: Preferences) {
        var write: Pair<String, String>? = null
        var removed: String? = null
        fun putString(key: String, value: String) = apply { write = key to value }
        fun remove(key: String) = apply { removed = key }
        fun commit(): Boolean {
            if (!owner.writable) return false
            write?.let { owner.data[it.first] = it.second }
            removed?.let { owner.data.remove(it) }
            return true
        }
    }
}
class Context(val preferences: Preferences) {
    companion object { const val MODE_PRIVATE = 0 }
    fun getSharedPreferences(name: String, mode: Int): Preferences {
        check(name == "craft-native-background-payloads" && mode == MODE_PRIVATE)
        return preferences
    }
}
${source.slice(start, end)}
fun main() {
    val storage = Preferences()
    val firstProcess = Context(storage)
    val reply = "Hello 👋 — ".repeat(2000)
    check(reply.toByteArray().size > 10240)
    val first = requireNotNull(CraftNativeBackgroundPayload.write(firstProcess, reply))
    val second = requireNotNull(CraftNativeBackgroundPayload.write(firstProcess, "other notification"))
    check(first != second)
    val restarted = Context(storage)
    check(CraftNativeBackgroundPayload.read(restarted, first) == reply)
    CraftNativeBackgroundPayload.remove(restarted, first)
    check(CraftNativeBackgroundPayload.read(restarted, first) == null)
    check(CraftNativeBackgroundPayload.read(restarted, second) == "other notification")
    storage.writable = false
    check(CraftNativeBackgroundPayload.write(restarted, "uncommitted") == null)
    check(storage.data.size == 1)
}
`)
}, 60_000)
