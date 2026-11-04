import { expect, test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('anchored menus reject disabled, duplicate and stale choices after updates or teardown', async () => {
  const source = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  // The shared compiler emits this event and lowercased binding for .stx screens.
  expect(source).toContain('craftNativeEventName(events, "onContextMenuAction").ifBlank { longPressHandler }')
  expect(source).toContain('props.optJSONArray("contextMenu") ?: props.optJSONArray("contextmenu")')
  const start = source.indexOf('internal data class CraftNativeMenuItem')
  const end = source.indexOf('private fun craftNativeAnnounce(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  const implementation = source.slice(start, end).replaceAll('android.widget.PopupMenu', 'PopupMenu').replaceAll('android.view.MenuItem', 'MenuItem')
  await runKotlinFixture(`
object Build { object VERSION { const val SDK_INT = 35 } }
class View { val context = Any(); var isEnabled = true }
class MenuItem(val itemId: Int, val title: String) { var isEnabled = true }
class Menu {
    val items = mutableListOf<MenuItem>()
    fun add(group: Int, id: Int, order: Int, title: String): MenuItem = MenuItem(id, title).also { items.add(it) }
}
class PopupMenu(val context: Any, val anchor: View) {
    companion object { var last: PopupMenu? = null }
    val menu = Menu()
    var click: (MenuItem) -> Boolean = { false }
    var dismissed = false
    var onDismiss: (PopupMenu) -> Unit = {}
    fun setOnMenuItemClickListener(callback: (MenuItem) -> Boolean) { click = callback }
    fun setOnDismissListener(callback: (PopupMenu) -> Unit) { onDismiss = callback }
    var forceIcons = false
    fun setForceShowIcon(value: Boolean) { forceIcons = value }
    fun dismiss() { dismissed = true; onDismiss(this) }
    fun show() { last = this }
}
${implementation}
fun main() {
    val anchor = View()
    val host = CraftNativeContextMenu(anchor)
    val selected = mutableListOf<String>()
    host.update(listOf(CraftNativeMenuItem("copy", "Copy"), CraftNativeMenuItem("delete", "Delete", destructive = true),
        CraftNativeMenuItem("blocked", "Blocked", disabled = true), CraftNativeMenuItem("copy", "Duplicate"), CraftNativeMenuItem("", "Bad"))) { selected.add(it) }
    check(host.show { _, _ -> })
    val old = requireNotNull(PopupMenu.last)
    check(old.anchor === anchor && old.menu.items.size == 3 && old.forceIcons)
    check(old.click(old.menu.items[0]))
    check(!old.menu.items[2].isEnabled && !old.click(old.menu.items[2]))
    host.update(listOf(CraftNativeMenuItem("delete", "New delete"))) { selected.add("new:" + it) }
    check(old.dismissed && !old.click(old.menu.items[1]))
    check(host.show { _, _ -> })
    val current = requireNotNull(PopupMenu.last)
    check(current.click(current.menu.items[0]))
    anchor.isEnabled = false
    check(!current.click(current.menu.items[0]) && !host.show { _, _ -> })
    host.clear()
    anchor.isEnabled = true
    check(current.dismissed && !current.click(current.menu.items[0]))
    check(!host.show { _, _ -> })
    check(selected == listOf("copy", "new:delete"))
    val stable = CraftNativeContextMenu(anchor)
    val stableItems = listOf(CraftNativeMenuItem("copy", "Copy"))
    var count = 0
    stable.update(stableItems, "same") { count++ }
    check(stable.show { _, _ -> })
    val held = requireNotNull(PopupMenu.last)
    stable.update(stableItems, "same") { count += 2 }
    check(!held.dismissed && held.click(held.menu.items[0]) && count == 2)
    stable.update(stableItems, "changed") { count += 4 }
    check(held.dismissed && !held.click(held.menu.items[0]) && count == 2)

}
`)
}, 60_000)
