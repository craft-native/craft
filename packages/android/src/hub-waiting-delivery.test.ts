import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { runKotlinFixture } from './testing'

/**
 * What is broadcast to an isolate before its prelude has run is kept and
 * handed over in order, not lost (#507, second half).
 *
 * A screen is registered with the hub first and given its copy of the stores
 * later, off the main thread. A change broadcast in that window was sent to
 * an isolate with nothing defined to receive it — on the console path the
 * message is literally `__stxNativeCallback && __stxNativeCallback(…)`, and
 * the prelude is what defines the callback — so it was discarded, and the
 * screen then started from a copy that could predate the change and was
 * never told otherwise. The same window swallowed anything else the hub
 * sends: a push that arrived, a location fix, the network coming back.
 *
 * The hub under test is the shipped object, whole. Its main looper is a queue
 * the test steps, so a broadcast "from another thread" and a `ready` "from
 * another thread" can be put in a definite order.
 *
 * What this cannot show is that the two hosts call `registerWaiting` and
 * `ready` at the right moments; that is pinned from their source below, and
 * the device suites are what would notice a screen that never became ready,
 * since it would hear nothing at all.
 */
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')
const activity = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')
const background = readFileSync(join(import.meta.dir, '../templates/CraftNativeBackground.kt.template'), 'utf8')

function hubObject(): string {
  const start = shell.indexOf('internal object CraftNativeHub {')
  const end = shell.indexOf('\n}\n', start)
  expect(start, 'CraftNativeHub must still be here to test').toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  return shell.slice(start, end + 3)
}

test('both hosts register an isolate as waiting and open it once its prelude has run', () => {
  // The foreground screen.
  expect(activity).toContain('CraftNativeHub.registerWaiting(activeScreen.capabilityScope)')
  expect(activity, 'a screen registered as able to hear before its prelude runs loses what is sent meanwhile')
    .not.toContain('CraftNativeHub.register(activeScreen.capabilityScope)')
  const setup = activity.slice(activity.indexOf('val setup = com.google.common.util.concurrent.Futures.transformAsync(preludeReady'))
  const ran = setup.indexOf('setup.get()')
  const opened = setup.indexOf('CraftNativeHub.ready(activeScreen.capabilityScope)')
  const bundle = setup.indexOf('CraftNativeBundle.source(this, route)')
  expect(ran).toBeGreaterThan(0)
  expect(opened, 'the screen is opened only after its prelude has run').toBeGreaterThan(ran)
  expect(opened, 'and before the bundle reads anything').toBeLessThan(bundle)

  // The background refresh.
  expect(background).toContain('CraftNativeHub.registerWaiting(scope)')
  expect(background).not.toContain('CraftNativeHub.register(scope)')
  const refresh = background.slice(background.indexOf('val setup = created.evaluateJavaScriptAsync(prelude)'))
  expect(refresh.indexOf('CraftNativeHub.ready(scope)')).toBeGreaterThan(refresh.indexOf('setup.get()'))
  expect(refresh.indexOf('CraftNativeHub.ready(scope)')).toBeLessThan(refresh.indexOf('created.evaluateJavaScriptAsync(bundle)'))

  // And no host is left out: every registration of an isolate in the templates is one of these two.
  const registrations = [activity, background].flatMap(source => source.match(/CraftNativeHub\.register\w*\(/g) ?? [])
  expect(registrations).toEqual(['CraftNativeHub.registerWaiting(', 'CraftNativeHub.registerWaiting('])
})

test('a broadcast made before an isolate can hear reaches it, in order, once it can', async () => {
  await runKotlinFixture(`
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

object Log { fun w(tag: String, message: String, error: Throwable): Int = 0 }
/** The main looper, as a queue the test steps. \`onMain\` says which thread the test is pretending to be. */
class Looper {
    companion object {
        private val main = Looper()
        private val other = Looper()
        var onMain = true
        fun getMainLooper(): Looper = main
        fun myLooper(): Looper = if (onMain) main else other
    }
}
class Handler(@Suppress("UNUSED_PARAMETER") looper: Looper) {
    fun post(task: () -> Unit): Boolean { posted.addLast(task); return true }
    companion object {
        val posted = ArrayDeque<() -> Unit>()
        /** The main thread takes its next turn. */
        fun drain() { val was = Looper.onMain; Looper.onMain = true; while (posted.isNotEmpty()) posted.removeFirst()(); Looper.onMain = was }
    }
}

${hubObject()}

fun must(condition: Boolean, message: () -> String) { if (!condition) throw AssertionError(message()) }
fun update(key: String, value: String): JSONObject = JSONObject().put("store", "snapshots").put("key", key).put("value", value)

fun main() {
    val heard = mutableListOf<String>()
    fun listener(name: String): (String, JSONObject) -> Unit = { type, payload -> heard.add(name + ":" + type + ":" + payload.optString("key") + "=" + payload.optString("value")) }
    fun taken(): List<String> = heard.toList().also { heard.clear() }

    // An isolate that can already hear is told at once, as before.
    CraftNativeHub.register("old", listener("old"))
    CraftNativeHub.registerWaiting("new", listener("new"))
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v2"))
    CraftNativeHub.broadcast("CRAFT_EVENT", JSONObject().put("key", "push"))
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v3"))
    must(taken() == listOf("old:SYNC_UPDATE:home=v2", "old:CRAFT_EVENT:push=", "old:SYNC_UPDATE:home=v3")) { "an isolate that can hear was not told as each was made, or one that cannot was: " + heard }

    // Its prelude runs: everything kept, in the order it was made, ending on the latest.
    CraftNativeHub.ready("new")
    must(taken() == listOf("new:SYNC_UPDATE:home=v2", "new:CRAFT_EVENT:push=", "new:SYNC_UPDATE:home=v3")) { "what was kept arrived as " + heard }
    // And from then on it hears like any other, once each.
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v4"))
    must(taken().sorted() == listOf("new:SYNC_UPDATE:home=v4", "old:SYNC_UPDATE:home=v4")) { "after it could hear it was told " + heard }
    CraftNativeHub.ready("new")
    must(taken().isEmpty()) { "being told it is ready twice delivered again: " + heard }

    // The writer is not told its own change, kept or not.
    CraftNativeHub.registerWaiting("writer", listener("writer"))
    CraftNativeHub.broadcast("SYNC_UPDATE", update("draft", "mine"), except = "writer")
    CraftNativeHub.broadcast("SYNC_UPDATE", update("draft", "theirs"), except = "old")
    taken()
    CraftNativeHub.ready("writer")
    must(taken() == listOf("writer:SYNC_UPDATE:draft=theirs")) { "a waiting writer was handed " + heard }

    // One that closes before it could hear is handed nothing, then or later.
    CraftNativeHub.registerWaiting("closed", listener("closed"))
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v5"))
    CraftNativeHub.unregister("closed")
    CraftNativeHub.ready("closed")
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v6"))
    must(taken().none { it.startsWith("closed:") }) { "an isolate that closed while waiting was told " + heard }

    // Across threads the order is still the order things were made in. A
    // broadcast from a worker is posted to the main thread; so is the
    // opening, so it cannot overtake a broadcast made before it.
    CraftNativeHub.registerWaiting("late", listener("late"))
    Looper.onMain = false
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v7"))
    CraftNativeHub.ready("late")
    CraftNativeHub.broadcast("SYNC_UPDATE", update("home", "v8"))
    must(taken().isEmpty()) { "something was delivered off the main thread: " + heard }
    Handler.drain()
    Looper.onMain = true
    must(taken().filter { it.startsWith("late:") } == listOf("late:SYNC_UPDATE:home=v7", "late:SYNC_UPDATE:home=v8")) { "across threads the late isolate heard " + heard }

    // Opening one that was never waiting, or never registered, does nothing.
    CraftNativeHub.ready("old")
    CraftNativeHub.ready("nobody")
    must(taken().isEmpty()) { "opening an isolate that was not waiting delivered " + heard }
    println("hub fixture passed")
}
`, ['org.json:json:20240303'])
}, 300_000)
