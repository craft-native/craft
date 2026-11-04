/** Execute the shipped accessibility-action wiring: what TalkBack is offered, what it reports, and what goes away. */
import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('publishes a hold’s actions to TalkBack, names the one that ran, and removes them when they go', async () => {
  const source = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  // The whole function: its first line at four spaces of indent closes it.
  const wiring = source.match(/ {4}private fun applyAccessibilityActions\([\s\S]*?\n {4}\}\n/)?.[0]
  if (!wiring) throw new Error('Native accessibility-action wiring is missing')
  // Runs the shipped body verbatim; only its visibility is relaxed so the
  // fixture can call it.
  const cleanup = source.match(/ {4}private fun clearAccessibilityActions\([\s\S]*?\n {4}\}\n/)?.[0]
  if (!cleanup) throw new Error('Native accessibility cleanup is missing')
  const callable = `${cleanup.replace('private fun', 'fun')}\n${wiring.replace('private fun', 'fun')}`
  await runKotlinFixture(`
class View(val name: String)
class JSONArray(private val items: List<Any?>) {
    fun length(): Int = items.size
    fun optJSONObject(index: Int): JSONObject? = items.getOrNull(index) as? JSONObject
}
class JSONObject(initial: Map<String, Any?> = emptyMap()) {
    private val values = LinkedHashMap<String, Any?>(initial)
    fun opt(name: String): Any? = values[name]
    fun optJSONArray(name: String): JSONArray? = values[name] as? JSONArray
    fun put(name: String, value: Any?): JSONObject { values[name] = value; return this }
    override fun toString(): String = values.entries.joinToString(",") { "\${it.key}=\${it.value}" }
}
class Screen {
    val accessibilityActionHandlers = mutableMapOf<View, String>()
    val accessibilityActionRevisions = mutableMapOf<View, Any>()
    val accessibilityActionIds = mutableMapOf<View, List<Int>>()
}
val removed = mutableListOf<Int>()
val added = mutableListOf<String>()
val commands = mutableMapOf<Int, () -> Boolean>()
var nextId = 1
object ViewCompat {
    fun removeAccessibilityAction(view: View, id: Int) { removed += id }
    fun addAccessibilityAction(view: View, label: CharSequence, command: (View, Any?) -> Boolean): Int {
        added += label.toString()
        val id = nextId++
        commands[id] = { command(view, null) }
        return id
    }
}
val sent = mutableListOf<String>()
fun send(screen: Screen, type: String, payload: JSONObject, correlationId: String? = null) { sent += payload.toString() }
fun craftNativeOptionalString(value: Any?): String? = value as? String
fun craftNativeEventName(events: JSONObject, vararg names: String): String =
    names.firstNotNullOfOrNull { craftNativeOptionalString(events.opt(it)) }.orEmpty()

object Host {
${callable}
}

fun actions(vararg entries: Map<String, Any?>) = JSONArray(entries.map { JSONObject(it) })

fun main() {
    val screen = Screen()
    val bubble = View("bubble")
    val events = JSONObject(mapOf("onAccessibilityAction" to "acted"))

    Host.applyAccessibilityActions(screen, bubble, JSONObject(mapOf("accessibilityActions" to actions(
        mapOf("name" to "copy", "label" to "Copy"),
        // No label: TalkBack falls back to the name.
        mapOf("name" to "report"),
        // No name: nothing to tell the handler, so not an action at all.
        mapOf("label" to "Nameless"),
        mapOf("name" to "   ", "label" to "Blank"),
    ))), events, false)
    check(added == listOf("Copy", "report")) { "offered \$added" }
    check(screen.accessibilityActionHandlers[bubble] == "acted")

    // The event says which action ran, so one handler can serve them all.
    for (id in screen.accessibilityActionIds[bubble].orEmpty()) check(commands[id]!!())
    check(sent == listOf("handlerName=acted,nativeEvent=actionName=copy", "handlerName=acted,nativeEvent=actionName=report")) { "sent \$sent" }

    // A reconcile replaces the actions rather than stacking a second set.
    val firstIds = screen.accessibilityActionIds[bubble].orEmpty()
    Host.applyAccessibilityActions(screen, bubble, JSONObject(mapOf("accessibilityActions" to actions(
        mapOf("name" to "report", "label" to "Report message"),
    ))), events, false)
    for (id in firstIds) check(!commands[id]!!()) { "a replaced action still dispatched" }
    check(removed == firstIds) { "removed \$removed, added as \$firstIds" }
    check(added == listOf("Copy", "report", "Report message")) { "offered \$added" }

    // Taking the prop away takes the actions with it: a stale Report in the
    // menu would act on a message that no longer offers it.
    val secondIds = screen.accessibilityActionIds[bubble].orEmpty()
    Host.applyAccessibilityActions(screen, bubble, JSONObject(), events, false)
    check(removed == firstIds + secondIds) { "removed \$removed" }
    check(screen.accessibilityActionHandlers[bubble] == null)

    // A disabled node offers nothing, matching the long press beside it.
    Host.applyAccessibilityActions(screen, bubble, JSONObject(mapOf("accessibilityActions" to actions(
        mapOf("name" to "report"),
    ))), events, true)
    check(screen.accessibilityActionHandlers[bubble] == null)
    check(added.size == 3) { "a disabled node offered \$added" }

    // Actions with no handler to send to are not published either.
    Host.applyAccessibilityActions(screen, bubble, JSONObject(mapOf("accessibilityActions" to actions(
        mapOf("name" to "report"),
    ))), JSONObject(), false)
    check(added.size == 3) { "an unhandled node offered \$added" }

    Host.applyAccessibilityActions(screen, bubble, JSONObject(mapOf("accessibilityActions" to actions(mapOf("name" to "copy")))), events, false)
    val unmounted = screen.accessibilityActionIds[bubble].orEmpty()
    Host.clearAccessibilityActions(screen, bubble)
    for (id in unmounted) check(!commands[id]!!())
    check(screen.accessibilityActionIds.isEmpty() && screen.accessibilityActionHandlers.isEmpty() && screen.accessibilityActionRevisions.isEmpty())

    println("PASS accessibility actions: labels, name fallback, dispatch, replacement, removal, disabled and unhandled")
}
`)
}, 180_000)
