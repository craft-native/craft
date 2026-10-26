import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('refreshes a compiled screen by its committed root identity after a trait change', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const refresh = template.match(/    private fun refreshScreenTheme\(screen: Screen\) \{[\s\S]*?\n    \}/)?.[0]
  if (!refresh) throw new Error('Native screen theme refresh is missing')
  await runKotlinFixture(`
class JSONObject(val id: String)
class MutationDocument {
    val root = JSONObject("compiled-root")
    fun node(id: String): JSONObject? = root.takeIf { it.id == id }
    fun document(): JSONObject = root
}
class CraftNativeFlatList { fun refreshThemeDefaults() {} }
class CraftNativeRefreshableFlatList { val list = CraftNativeFlatList() }
class Screen {
    val mutations = MutationDocument()
    val controls = mutableMapOf<String, Any>()
    var committed: String? = null
}
fun applyScreenBackground(screen: Screen) {}
fun renderCommitted(screen: Screen, document: JSONObject) { screen.committed = document.id }
fun updateSafeAreaInsets(screen: Screen) {}
fun updateSafeAreaViews() {}
${refresh}
fun main() {
    val screen = Screen()
    refreshScreenTheme(screen)
    check(screen.committed == "compiled-root") { "A compiled root was skipped during the window trait refresh" }
    println("PASS committed protocol root refresh")
}
`)
}, 180_000)
