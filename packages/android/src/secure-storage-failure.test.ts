import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

/**
 * A secure-storage write that did not reach the disk is a failure, and
 * nothing behaves as though it happened.
 *
 * `SecureStorage.remove` and `clear` answered with whatever `commit()`
 * returned and told every isolate the value was gone either way:
 *
 *   success(editor.remove(key).commit().also { storeObserver("secure", key, null) })
 *
 * So when the disk refused the write — the case #396 names: a full disk, a
 * failed write — a sign-out resolved `false` instead of rejecting, every
 * screen dropped the token and announced the session had ended, and the token
 * was still on disk for the next launch to sign back in with. UIKit refuses a
 * Keychain delete that failed and tells nobody.
 *
 * A failed `set` had the mirror image. `commit()` changes the preferences'
 * memory before it writes, and a failed write does not change it back, so the
 * rejected token stayed readable for the life of the process — including to
 * the seed every new screen starts from. `Storage` already put its memory
 * back after a failed commit; the secure store now goes through the same door.
 *
 * The functions under test are the shipped ones: `secureStorage` from the
 * capabilities class and `commit` from `CraftNativeStorage`. The preferences
 * are a model, and the one property of it that matters is the one Android
 * documents and `CraftNativeStorage.commit` was written around: a commit
 * applies to memory first and reports the disk write afterwards. Whether
 * `EncryptedSharedPreferences` on a device follows that model is not shown
 * here; the device test covers the calls that succeed.
 */
const capabilities = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

function storageObject(): string {
  const start = shell.indexOf('internal object CraftNativeStorage {')
  const end = shell.indexOf('internal class CraftNativeStores', start)
  expect(start, 'CraftNativeStorage must still be here to test').toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  return shell.slice(start, end)
}

function fixture(strict: boolean): string {
  const commit = liftKotlinMember(storageObject(), 'commit').replaceAll('android.content.SharedPreferences', 'SharedPreferences')
  expect(commit, 'no Android type may survive into the JVM fixture').not.toContain('android.')
  const hasLock = storageObject().includes('val secureLock = Any()')
  return `
import org.json.JSONArray
import org.json.JSONObject

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
    val lock = Any()
${hasLock ? '    val secureLock = Any()' : ''}
${commit}
}

internal class Capabilities(private val encryptedSecureStorage: SharedPreferences) {
    val told = mutableListOf<String>()
    var storeObserver: ((String, String?, String?) -> Unit)? = { store, key, value -> told.add(store + ":" + key + "=" + value) }

${['secureStorage', 'validKey', 'success', 'failure'].map(name => liftKotlinMember(capabilities, name)).join('\n\n')}

    fun call(method: String, vararg args: Any?): CraftNativeCapabilityResult = secureStorage(method, JSONArray(args.toList()))
}

val defects = mutableListOf<String>()
fun must(condition: Boolean, message: () -> String) {
    if (condition) return
    if (${strict}) throw AssertionError(message())
    defects.add(message())
}

fun main() {
    val store = SharedPreferences()
    val host = Capabilities(store)
    fun told(): List<String> = host.told.toList().also { host.told.clear() }
    fun read(): Any? = host.call("get", "auth.token").data

    val kept = host.call("set", "auth.token", "t1")
    must(kept.code == null && kept.data == true && told() == listOf("secure:auth.token=t1")) { "a kept token answered " + kept }
    must(read() == "t1" && store.disk["auth.token"] == "t1") { "the token was not kept" }

    // A sign-out the disk refuses.
    store.diskFull = true
    val removed = host.call("remove", "auth.token")
    must(removed.code == "SECURE_STORAGE_ERROR") { "a remove that did not reach the disk answered " + removed }
    must(told().isEmpty()) { "a remove that did not reach the disk told every isolate the token was gone" }
    must(read() == "t1") { "after a remove that did not reach the disk a read gave " + read() + ", and the disk still holds " + store.disk["auth.token"] }

    val cleared = host.call("clear")
    must(cleared.code == "SECURE_STORAGE_ERROR") { "a clear that did not reach the disk answered " + cleared }
    must(told().isEmpty()) { "a clear that did not reach the disk told every isolate the store was empty" }
    must(read() == "t1") { "after a clear that did not reach the disk a read gave " + read() }

    // A token the disk refuses is not readable afterwards.
    val refused = host.call("set", "auth.token", "t2")
    must(refused.code == "SECURE_STORAGE_ERROR" && told().isEmpty()) { "a set that did not reach the disk answered " + refused }
    must(read() == "t1") { "a token that was refused is what a read gives: " + read() + ", while the disk holds " + store.disk["auth.token"] }
    must(store.all["auth.token"] == "t1") { "a token that was refused is what a new screen would be seeded with: " + store.all["auth.token"] }

    // With the disk back, each does what it says, once.
    store.diskFull = false
    val gone = host.call("remove", "auth.token")
    must(gone.code == null && gone.data == true && told() == listOf("secure:auth.token=null")) { "a remove answered " + gone }
    must(read() == JSONObject.NULL && !store.disk.containsKey("auth.token")) { "the token survived its removal" }
    val again = host.call("remove", "auth.token")
    must(again.code == null && again.data == true) { "removing what is not there answered " + again }
    told()
    host.call("set", "a", "1"); host.call("set", "b", "2"); told()
    val emptied = host.call("clear")
    must(emptied.code == null && emptied.data == true && told() == listOf("secure:null=null")) { "a clear answered " + emptied }
    must(store.disk.isEmpty() && store.all.isEmpty()) { "a clear left " + store.disk.keys }

    // Arguments are still refused before anything is touched.
    must(host.call("set", "auth.token", 5).code == "INVALID_ARGUMENT" && host.call("remove", "").code == "INVALID_ARGUMENT") { "a malformed call was not refused" }
    must(host.call("rotate", "auth.token").code == "UNKNOWN_ACTION") { "an unknown method was not refused" }

    if (defects.isNotEmpty()) { defects.forEach { println("DEFECT: " + it) }; throw AssertionError(defects.size.toString() + " defects") }
    println("secure storage fixture passed")
}
`
}

test('a secure write that did not reach the disk is refused and leaves nothing behind', async () => {
  await runKotlinFixture(fixture(true), ['org.json:json:20240303'])
}, 300_000)
