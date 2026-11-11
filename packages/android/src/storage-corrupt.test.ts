import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A stored value that cannot be read is `STORAGE_CORRUPT` wherever it is
 * read, and the rest of storage works beside it.
 *
 * `STORAGE_CORRUPT` is the code an app catches to start a value again;
 * `STORAGE_ERROR` is a disk that failed, which it retries. `Storage.get`
 * answered the first for a value that is not JSON. `Storage.compareAndSet`
 * parsed the same value with nothing around it, threw, and reached the
 * screen as the second. UIKit had the mirror image and more
 * (`packages/ios/src/persistent-storage-corrupt.test.ts`).
 *
 * The function under test is the shipped `storage`, with the shipped
 * `CraftNativeStorage`. The preferences are a model that holds strings.
 */
const capabilities = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

test('every storage method answers a corrupt value the same way, and the others still work', async () => {
  const start = shell.indexOf('internal object CraftNativeStorage {')
  const object = shell.slice(start, shell.indexOf('internal class CraftNativeStores', start))
  expect(start, 'CraftNativeStorage must still be here to test').toBeGreaterThan(0)
  const members = ['commit', 'jsonEqual'].map(name => liftKotlinMember(object, name).replaceAll('android.content.SharedPreferences', 'SharedPreferences')).join('\n\n')
  expect(members, 'no Android type may survive into the JVM fixture').not.toContain('android.')
  await runKotlinFixture(`
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

class SharedPreferences {
    private val memory = HashMap<String, Any?>()
    val all: Map<String, Any?> get() = HashMap(memory)
    fun getString(key: String, fallback: String?): String? = memory[key] as? String ?: fallback
    fun contains(key: String): Boolean = memory.containsKey(key)
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
        fun commit(): Boolean { if (clears) memory.clear(); removes.forEach(memory::remove); memory.putAll(puts); return true }
    }
}

internal data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)

internal object CraftNativeStorage {
    val lock = Any()
${members}
}

internal class Capabilities(private val storage: SharedPreferences) {
    var storeObserver: ((String, String?, String?) -> Unit)? = null

${['fun storage', 'validKey', 'jsonString', 'success', 'failure'].map(name => liftKotlinMember(capabilities, name)).join('\n\n')}

    /** As the dispatcher calls it: what throws reaches the screen as STORAGE_ERROR. */
    fun call(method: String, vararg args: Any?): String = runCatching { storage(method, JSONArray(args.toList())) }
        .map { it.code ?: ("ok " + it.data) }.getOrElse { "STORAGE_ERROR (threw " + it.javaClass.simpleName + ")" }
}

fun main() {
    val store = SharedPreferences()
    val host = Capabilities(store)
    check(host.call("set", "kept", 1) == "ok true")
    // A value that is not JSON, as an older build or a damaged file leaves it.
    store.edit().putString("damaged", "{\\"visits\\":").commit()

    val answers = listOf(
        "get damaged" to host.call("get", "damaged"),
        "compareAndSet damaged" to host.call("compareAndSet", "damaged", 1, 2),
        "setIfAbsent damaged" to host.call("setIfAbsent", "damaged", 3),
        "get kept" to host.call("get", "kept"),
        "keys" to host.call("keys"),
        "remove damaged" to host.call("remove", "damaged"),
        "get damaged, removed" to host.call("get", "damaged"),
    )
    val wanted = listOf(
        "STORAGE_CORRUPT", "STORAGE_CORRUPT", "ok false", "ok 1", "ok [\\"damaged\\",\\"kept\\"]", "ok true", "ok null",
    )
    val wrong = answers.zip(wanted).filter { it.first.second != it.second }.map { it.first.first + ": " + it.first.second + ", not " + it.second }
    if (wrong.isNotEmpty()) throw AssertionError("storage answered a corrupt value differently:\\n" + wrong.joinToString("\\n"))

    // And clear takes a corrupt value with the rest.
    store.edit().putString("damaged", "{\\"visits\\":").commit()
    check(host.call("clear") == "ok true") { "clear beside a corrupt value" }
    check(host.call("keys") == "ok []") { "clear left " + host.call("keys") }
    println("storage corrupt fixture passed")
}
`, ['org.json:json:20240303'])
}, 300_000)
