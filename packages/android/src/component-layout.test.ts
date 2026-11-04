/** Component scopes must retain their root's layout without owning a second flex item. */
import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('forwards single-root component layout through nested scopes without mutating the document', async () => {
  const source = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const helper = source.match(/internal fun craftNativeComponentLayoutStyle\(node: JSONObject\): JSONObject \{[\s\S]*?\n\}/)?.[0]
  if (!helper) throw new Error('Native component layout forwarding is missing')
  await runKotlinFixture(`
import org.json.JSONObject
${helper}
fun main() {
    fun scope(child: JSONObject, style: JSONObject = JSONObject()): JSONObject = JSONObject()
        .put("type", "View").put("props", JSONObject().put("data-stx-component-wrapper", ""))
        .put("style", style).put("children", org.json.JSONArray().put(child))
    val pill = JSONObject().put("type", "Pressable").put("style", JSONObject()
        .put("position", "absolute").put("right", 16).put("bottom", 20)
        .put("maxWidth", 300).put("padding", 12).put("backgroundColor", "blue"))
    val nested = scope(scope(pill))
    val style = craftNativeComponentLayoutStyle(nested)
    check(style.getString("position") == "absolute") { "An overlay participated in screen flex flow" }
    check(style.getInt("right") == 16 && style.getInt("bottom") == 20 && style.getInt("maxWidth") == 300)
    check(!style.has("padding") && !style.has("backgroundColor")) { "The scope duplicated its root's decoration" }
    check(nested.getJSONObject("style").length() == 0) { "Layout forwarding changed the protocol document" }
    val explicit = craftNativeComponentLayoutStyle(scope(pill, JSONObject().put("right", 8)))
    check(explicit.getInt("right") == 8 && explicit.getInt("bottom") == 20)
    pill.getJSONObject("style").put("bottom", 40)
    check(craftNativeComponentLayoutStyle(nested).getInt("bottom") == 40) { "A reactive anchor stayed stale" }
    val flow = scope(JSONObject().put("type", "ScrollView").put("style", JSONObject().put("flex", 1).put("height", "100%")))
    check(craftNativeComponentLayoutStyle(flow).getInt("flex") == 1)
    check(craftNativeComponentLayoutStyle(flow).getString("height") == "100%")
    val siblings = scope(pill)
    siblings.getJSONArray("children").put(JSONObject().put("type", "Text"))
    check(!craftNativeComponentLayoutStyle(siblings).has("position")) { "A multi-root component borrowed only one root" }
    val modal = scope(JSONObject().put("type", "Modal").put("style", JSONObject().put("height", 400)))
    check(!craftNativeComponentLayoutStyle(modal).has("height")) { "A modal changed normal flow" }
    val ordinary = JSONObject().put("type", "View").put("children", org.json.JSONArray().put(pill))
    check(!craftNativeComponentLayoutStyle(ordinary).has("position"))
    println("PASS component roots preserve overlay anchors and flex, reactive changes and explicit wrapper constraints without duplicating decoration or changing multi-root/modal layout")
}
`, ['org.json:json:20250517'])
}, 180_000)
