import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('applies changed StatusBar props to the visible window without resetting unrelated updates', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const render = template.match(/"StatusBar" -> [^\n]+\.apply \{([\s\S]*?)\n            \}/)?.[1]
  const update = template.match(/    private fun updateStatusBarProps\(screen: Screen, props: JSONObject\) \{[\s\S]*?\n    \}/)?.[0] ?? ''
  if (!render) throw new Error('The shipped native StatusBar renderer is missing')
  await runKotlinFixture(`
class JSONObject(private val values: Map<String, Any?> = emptyMap()) {
    fun opt(name: String): Any? = values[name]
    fun has(name: String): Boolean = values.containsKey(name)
    fun isNull(name: String): Boolean = values[name] == null
}
class Screen {
    var statusBarStyle: String? = null
    var statusBarHidden: Boolean? = null
}
object View { const val GONE = 8 }
var visibility = 0
var visibleScreen: Screen? = null
val applied = mutableListOf<Pair<String?, Boolean?>>()
fun craftNativeOptionalString(value: Any?): String? = value as? String
fun craftNativeBoolean(value: Any?): Boolean = value == true
fun applyStatusBar(screen: Screen) {
    check(screen === visibleScreen)
    applied += screen.statusBarStyle to screen.statusBarHidden
}
${update}
fun renderStatusBar(screen: Screen, props: JSONObject) { ${render} }
fun main() {
    val screen = Screen()
    visibleScreen = screen
    // A full initial commit already applied the authored light-page style.
    screen.statusBarStyle = "dark-content"
    applyStatusBar(screen)
    renderStatusBar(screen, JSONObject(mapOf("barStyle" to "light-content")))
    check(applied.last() == ("light-content" to null)) { "Live dark appearance kept the previous icon contrast" }
    val count = applied.size
    renderStatusBar(screen, JSONObject(mapOf("barStyle" to "light-content")))
    check(applied.size == count) { "Unchanged props reset an imperative window appearance" }
    renderStatusBar(screen, JSONObject())
    check(applied.last() == (null to null)) { "Removing an authored override did not restore the default" }
    renderStatusBar(screen, JSONObject(mapOf("hidden" to true)))
    check(applied.last() == (null to true))
    renderStatusBar(screen, JSONObject(mapOf("hidden" to false)))
    check(applied.last() == (null to false))
    val beforeRetained = applied.size
    val retained = Screen()
    renderStatusBar(retained, JSONObject(mapOf("barStyle" to "dark-content", "hidden" to true)))
    check(retained.statusBarStyle == "dark-content" && retained.statusBarHidden == true)
    check(applied.size == beforeRetained) { "A retained screen changed the visible system bars" }
    println("PASS live StatusBar props, unchanged updates, override removal, visibility and retained isolation")
}
`)
}, 180_000)
