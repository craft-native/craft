/** Execute the shipped lookup and registration across keyed replacements and reparenting. */
import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('retains authored keys and protocol identities without conflating sibling selectors', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const lookup = template.match(/        val protocolId = node\.optString\("id"\)[\s\S]*?(?=        val reusableInput =)/)?.[0]
  const registration = template.match(/        next\[identity\] = control[\s\S]*?(?=        applyViewStyle\(control, style\))/)?.[0]
  const authoredKey = template.match(/    private fun authoredKey\(node: JSONObject, props: JSONObject\): String\? \{[\s\S]*?\n    \}/)?.[0]
  if (!lookup || !registration || !authoredKey) throw new Error('Native retained identity implementation is missing')
  await runKotlinFixture(`
class JSONObject(private val values: Map<String, String>) {
    fun optString(name: String): String = values[name].orEmpty()
}
class View(var draft: String = "typed", var selection: Int = 3)
class MutationDocument(var ids: Set<String> = emptySet()) {
    fun containsNode(id: String): Boolean = id in ids
}
class Screen {
    val protocolIds = mutableMapOf<View, String>()
    val mutations = MutationDocument()
}
${authoredKey}

fun retain(screen: Screen, id: String, key: String?, testID: String, path: String, previousControls: Map<String, View>, next: MutableMap<String, View>): Pair<View, String> {
    val node = JSONObject(mapOf("id" to id, "key" to key.orEmpty()))
    val props = JSONObject(mapOf("testID" to testID))
${lookup}
    val control = previous ?: View()
${registration}
    return control to identity
}

fun main() {
    val screen = Screen()
    val first = mutableMapOf<String, View>()
    val plain = retain(screen, "plain-node", "container", "shared-selector", "root.0", emptyMap(), first).first
    plain.draft = "kept draft"
    plain.selection = 7
    val second = mutableMapOf<String, View>()
    screen.mutations.ids = setOf("safe-node")
    val safe = retain(screen, "safe-node", "container", "shared-selector", "root.0", first, second).first
    check(safe === plain) { "A keyed conditional replacement lost the retained view" }
    check(safe.draft == "kept draft" && safe.selection == 7)
    val third = mutableMapOf<String, View>()
    val moved = retain(screen, "safe-node", "container", "shared-selector", "popup.1", second, third).first
    check(moved === safe) { "A protocol node lost its view when reparented" }
    val duplicateSelector = retain(screen, "other-node", null, "shared-selector", "popup.2", second, third).first
    check(duplicateSelector !== safe) { "A repeated selector conflated distinct protocol nodes" }
    val otherParent = retain(screen, "other-parent-node", "container", "shared-selector", "other.0", second, third).first
    check(otherParent !== safe) { "An authored key escaped its parent scope" }
    val restored = retain(screen, "safe-node", "container", "shared-selector", "root.0", third, mutableMapOf()).first
    check(restored === safe) { "Returning to a keyed branch replaced the native view" }
    val removed = retain(screen, "fresh-node", "container", "shared-selector", "root.0", emptyMap(), mutableMapOf()).first
    check(removed !== safe) { "A removed tree leaked a stale retained alias" }
    for (moveFirst in listOf(true, false)) {
        val scene = Screen()
        val old = mutableMapOf<String, View>()
        val original = retain(scene, "moving", "container", "shared-selector", "root.0", emptyMap(), old).first
        scene.mutations.ids = setOf("moving", "replacement")
        val next = mutableMapOf<String, View>()
        var reparented: View? = null
        var replacement: View? = null
        val move = { reparented = retain(scene, "moving", "container", "shared-selector", "popup.0", old, next).first }
        val refill = { replacement = retain(scene, "replacement", "container", "shared-selector", "root.0", old, next).first }
        if (moveFirst) { move(); refill() } else { refill(); move() }
        check(reparented === original) { "Reparenting lost the protocol view (moveFirst=$moveFirst)" }
        check(replacement !== original) { "Refilling a vacated keyed slot stole a surviving protocol view (moveFirst=$moveFirst)" }
        check(next["id:moving"] === original) { "Reparenting lost the protocol alias (moveFirst=$moveFirst)" }
        check(next["id:replacement"] === replacement) { "Replacement was not registered under its protocol alias (moveFirst=$moveFirst)" }
        check(next["id:moving"] !== next["id:replacement"])
    }
    println("PASS keyed replacement, protocol reparenting, selector isolation, parent scoping, return, removal and both refill traversal orders")
}
`)
}, 180_000)

test('preserves modal viewport promotion and ordering across targeted reconciliation', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const promote = template.match(/    private fun promoteModalOverlays\(screen: Screen\) \{[\s\S]*?\n    \}/)?.[0]
  const targeted = template.match(/    private fun applyTargetedUpdates\(screen: Screen, ids: List<String>\): Boolean \{[\s\S]*?\n    \}/)?.[0]
  if (!promote || !targeted) throw new Error('Native modal reconciliation implementation is missing')
  await runKotlinFixture(`
import kotlin.math.min

open class View {
    var parent: ViewGroup? = null
    fun bringToFront() { val group = parent ?: return; group.children.remove(this); group.children.add(this) }
}
open class ViewGroup : View() {
    val children = mutableListOf<View>()
    val childStyles = mutableMapOf<View, JSONObject>()
    val childCount: Int get() = children.size
    fun getChildAt(index: Int): View = children[index]
    fun removeView(view: View) { children.remove(view); childStyles.remove(view); view.parent = null }
    fun setChildStyle(view: View, style: JSONObject, density: Float) { childStyles[view] = style }
    fun addView(view: View) { view.parent?.removeView(view); children.add(view); view.parent = this }
}
class CraftNativeModalView : ViewGroup() {
    val content = ViewGroup().also(::addView)
    var viewportStyle = JSONObject("popup-frame")
    var declarationPath = ""
}
class DisplayMetrics { val density = 1f }
class Resources { val displayMetrics = DisplayMetrics() }
val resources = Resources()
class JSONObject(val id: String = "") { fun optJSONObject(name: String): JSONObject? = null }
class MutationDocument(val parents: Map<String, String>) {
    fun parentId(id: String): String? = parents[id]
    fun node(id: String): JSONObject = JSONObject(id)
}
class Screen {
    val view = ViewGroup()
    val controls = linkedMapOf<String, View>()
    val nodeViews = mutableMapOf<String, View>()
    val nodePaths = mutableMapOf<String, String>()
    val inheritedFontFamilies = mutableMapOf<String, String>()
    val protocolIds = mutableMapOf<View, String>()
    val lastLayoutBounds = mutableMapOf<View, String>()
    val modalVisibility = mutableMapOf<View, Boolean>()
    val mutations = MutationDocument(mapOf("parent" to "root", "nested" to "parent", "standalone" to "root"))
    var layoutEvents = 0
}
fun drawnTarget(screen: Screen, id: String): String = id
fun makeView(screen: Screen, document: JSONObject, path: String, controls: MutableMap<String, View>, inheritedFontFamily: String? = null) {
    // Targeted parent reconciliation restores its logical child before promotion.
    if (document.id == "parent") (screen.nodeViews.getValue("parent") as CraftNativeModalView).content.addView(screen.nodeViews.getValue("nested"))
}
fun updateParentLayoutStyle(view: View, style: JSONObject): Boolean = true
fun scheduleLayoutEvents(screen: Screen) { screen.layoutEvents++ }
${promote}
${targeted}
fun main() {
    val screen = Screen()
    val root = ViewGroup()
    val parent = CraftNativeModalView()
    val nested = CraftNativeModalView()
    val standalone = CraftNativeModalView()
    screen.view.addView(root)
    root.addView(parent)
    parent.content.addView(nested)
    root.addView(standalone)
    for (modal in listOf(parent, nested, standalone)) screen.view.setChildStyle(modal, modal.viewportStyle, 1f)
    parent.declarationPath = "0"
    nested.declarationPath = "0.0"
    standalone.declarationPath = "1"
    for ((id, view) in listOf("root" to root, "nested" to nested, "parent" to parent, "standalone" to standalone)) {
        screen.nodeViews[id] = view
        screen.nodePaths[id] = id
        screen.protocolIds[view] = id
        screen.controls[id] = view
        screen.controls["id:" + id] = view
        if (view is CraftNativeModalView) screen.modalVisibility[view] = true
    }
    fun verify() {
        check(parent.parent === screen.view && nested.parent === screen.view && standalone.parent === screen.view) { "An overlay escaped its viewport" }
        for (modal in listOf(parent, nested, standalone)) check(screen.view.childStyles[modal] === modal.viewportStyle) { "A promoted overlay lost its viewport layout style" }
        val children = screen.view.children
        check(children.indexOf(parent) < children.indexOf(nested)) { "The parent scrim covered its nested popup" }
        check(children.indexOf(nested) < children.indexOf(standalone)) { "Sibling overlay order changed" }
    }
    promoteModalOverlays(screen)
    verify()
    check(applyTargetedUpdates(screen, listOf("parent")))
    verify()
    check(screen.layoutEvents == 1)
    check(applyTargetedUpdates(screen, listOf("standalone")))
    verify()
    root.addView(parent)
    parent.content.addView(nested)
    root.addView(standalone)
    screen.protocolIds.clear()
    promoteModalOverlays(screen)
    verify()
    println("PASS modal viewport, nested scrim ordering, sibling ordering, targeted updates and legacy renders")
}
`)
}, 180_000)
