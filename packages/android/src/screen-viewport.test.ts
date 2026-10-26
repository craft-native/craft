/** Exercise the shipped root sizing through the same path as reactive style updates. */
import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('keeps a native screen root in its viewport while respecting authored heights', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const normalize = template.match(/internal fun craftNativeScreenRootStyle\(style: JSONObject\): JSONObject \{[\s\S]*?\n\}/)?.[0]
  const select = template.match(/    fun setViewportChild\(view: View\?\) \{[\s\S]*?\n    \}/)?.[0]
  const update = template.match(/    fun setChildStyle\(view: View, style: JSONObject, density: Float\) \{[\s\S]*?\n    \}/)?.[0]
  const length = template.match(/private data class CraftNativeLength\([\s\S]*?\n\}/)?.[0]
  if (!normalize || !select || !update || !length) throw new Error('Native viewport root sizing is missing')
  await runKotlinFixture(`
import kotlin.math.roundToInt
import kotlin.math.max

class JSONObject(private val values: MutableMap<String, Any?> = mutableMapOf()) {
    companion object { val NULL = Any() }
    fun keys(): Iterator<String> = values.keys.iterator()
    fun opt(name: String): Any? = values[name]
    fun has(name: String): Boolean = values.containsKey(name)
    fun isNull(name: String): Boolean = values[name] == null || values[name] === NULL
    fun put(name: String, value: Any?): JSONObject { values[name] = value; return this }
}
class View
object CraftNativeLayoutStyle {
    fun from(style: JSONObject, density: Float): JSONObject { check(density > 0); return style }
}
${length}
${normalize}
class Host {
    private var viewportChild: View? = null
    val styles = mutableMapOf<View, JSONObject>()
    val parent: Any? = null
    private fun invalidateMeasurements() = Unit
    private fun invalidateMeasurementAncestors(parent: Any?) = Unit
${select}
${update}
}
fun main() {
    val host = Host()
    val root = View()
    val scroll = View()
    host.setViewportChild(root)
    val authored = JSONObject().put("flexDirection", "column")
    host.setChildStyle(root, authored, 2.625f)
    var effective = host.styles[root]!!
    check(CraftNativeLength.from(effective.opt("height"), 2.625f)?.resolve(1630) == 1630) {
        "An unstyled screen root collapsed instead of filling the viewport"
    }
    check(effective.opt("flex") == 1)
    check(!authored.has("height") && !authored.has("flex")) { "The protocol document was mutated" }
    check(effective.opt("flexDirection") == "column")
    host.setChildStyle(scroll, JSONObject().put("flex", 1), 2.625f)
    check(!host.styles[scroll]!!.has("height")) { "Ordinary flex children gained viewport constraints" }
    for (height in listOf<Any>(0, 80, "42%")) {
        host.setChildStyle(root, JSONObject().put("height", height), 2.625f)
        check(host.styles[root]!!.opt("height") == height) { "An authored root height was replaced" }
        check(!host.styles[root]!!.has("flex"))
    }
    // The same setter is used by targeted MUTATE style updates, including
    // removing a previously explicit root height.
    host.setChildStyle(root, JSONObject().put("height", JSONObject.NULL).put("display", "none").put("flex", 0), 2.625f)
    effective = host.styles[root]!!
    check(CraftNativeLength.from(effective.opt("height"), 2.625f)?.resolve(1900) == 1900)
    check(effective.opt("display") == "none" && effective.opt("flex") == 0)
    val replacement = View()
    host.setViewportChild(replacement)
    host.setChildStyle(root, JSONObject(), 2.625f)
    check(!host.styles[root]!!.has("height")) { "The old screen root retained viewport ownership" }
    host.setChildStyle(replacement, JSONObject(), 2.625f)
    check(host.styles[replacement]!!.opt("height") == "100%")
    host.setViewportChild(null)
    host.setChildStyle(replacement, JSONObject(), 2.625f)
    check(!host.styles[replacement]!!.has("height"))
    println("PASS native roots fill the viewport across style updates, replacements and height removal; explicit heights and ordinary children are preserved")
}
`)
}, 180_000)
