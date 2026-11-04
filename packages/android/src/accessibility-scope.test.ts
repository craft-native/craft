import { expect, test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('modal containment restores authored roles across nested, removed and non-modal overlays', async () => {
  const source = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const start = source.indexOf('private fun craftNativeModalAccessibility(')
  const end = source.indexOf('private fun craftNativeSpokenText(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  await runKotlinFixture(`
import java.util.Locale
open class View(var importantForAccessibility: Int = 1) {
    companion object { const val IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS = 4 }
}
class ViewGroup(val children: MutableList<View>) : View() {
    val childCount: Int get() = children.size
    fun getChildAt(index: Int) = children[index]
}
${source.slice(start, end)}
fun main() {
    val page = View(2) // authored role:none must survive dismissal
    val outer = View()
    val inner = View()
    val popup = View()
    val root = ViewGroup(mutableListOf(page, outer, inner, popup))
    val saved = mutableMapOf<View, Int>()
    craftNativeModalAccessibility(root, saved) { it === outer }
    check(page.importantForAccessibility == 4)
    check(outer.importantForAccessibility == 1 && popup.importantForAccessibility == 1)
    craftNativeModalAccessibility(root, saved) { it === outer || it === inner }
    check(page.importantForAccessibility == 4 && outer.importantForAccessibility == 4)
    check(inner.importantForAccessibility == 1 && popup.importantForAccessibility == 1)
    // A targeted mutation changes the background role while the inner is open.
    page.importantForAccessibility = 1
    craftNativeModalAccessibility(root, saved) { it === outer || it === inner }
    check(page.importantForAccessibility == 4)
    root.children.remove(inner)
    craftNativeModalAccessibility(root, saved) { it === outer }
    check(outer.importantForAccessibility == 1 && page.importantForAccessibility == 4)
    craftNativeModalAccessibility(root, saved) { false } // hidden or nonModal
    check(page.importantForAccessibility == 1 && saved.isEmpty())
    page.importantForAccessibility = 2
    craftNativeModalAccessibility(root, saved) { it === outer }
    root.children.clear() // tree teardown also restores detached references
    craftNativeModalAccessibility(root, saved) { false }
    check(page.importantForAccessibility == 2 && saved.isEmpty())
    check(craftNativeAccessibilityLanguage(" de-DE ")?.toLanguageTag() == "de-DE")
    check(craftNativeAccessibilityLanguage("en-GB")?.language == "en")
    for (value in listOf(null, "", "  ", 42)) check(craftNativeAccessibilityLanguage(value) == null)
}
`)
}, 60_000)
