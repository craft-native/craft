import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('reapplies the received window insets when safe-area edges change', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const names = ['setPadding', 'setSafeAreaEdges', 'setWindowSafeInsets', 'applySafeAreaPadding']
  const methods = names.map(name => template.match(new RegExp(`    (?:override |private )?fun ${name}\\([^\\n]*\\) \\{[\\s\\S]*?\\n    \\}`))?.[0])
  if (methods.some(method => !method)) throw new Error('Native safe-area padding implementation is missing')
  const fields = template.match(/    private var authoredPadding = [\s\S]*?    private var safeAreaEdges = [^\n]+/)?.[0]
  if (!fields) throw new Error('Native safe-area state is missing')
  await runKotlinFixture(`
open class View {
    var padding = intArrayOf(0, 0, 0, 0)
    open fun setPadding(left: Int, top: Int, right: Int, bottom: Int) { padding = intArrayOf(left, top, right, bottom) }
}
class JSONArray(private val values: List<String>) {
    fun length(): Int = values.size
    fun optString(index: Int): String = values[index]
}
class Layout : View() {
${fields}
    fun invalidateMeasurements() {}
${methods.join('\n')}
}
fun main() {
    val view = Layout()
    view.setPadding(16, 16, 16, 16)
    view.setWindowSafeInsets(2, 48, 2, 24)
    check(view.padding.contentEquals(intArrayOf(18, 64, 18, 40)))
    view.setSafeAreaEdges(JSONArray(listOf("bottom")))
    check(view.padding.contentEquals(intArrayOf(16, 16, 16, 40))) { "Removing an edge retained its old window inset" }
    view.setSafeAreaEdges(JSONArray(emptyList()))
    check(view.padding.contentEquals(intArrayOf(16, 16, 16, 16)))
    view.setSafeAreaEdges(null)
    check(view.padding.contentEquals(intArrayOf(18, 64, 18, 40))) { "Restoring an edge lost its previously received inset" }
    repeat(3) { view.setPadding(16, 16, 16, 16) }
    check(view.padding.contentEquals(intArrayOf(18, 64, 18, 40))) { "Reconciliation accumulated safe-area padding" }
    view.setWindowSafeInsets(0, 0, 0, 0)
    check(view.padding.contentEquals(intArrayOf(16, 16, 16, 16)))
    view.setSafeAreaEdges(JSONArray(listOf("top")))
    view.setWindowSafeInsets(0, 32, 0, 20)
    check(view.padding.contentEquals(intArrayOf(16, 48, 16, 16)))
    println("PASS live edge removal, restoration, authored padding, repeated reconciliation and changed insets")
}
`)
}, 180_000)
