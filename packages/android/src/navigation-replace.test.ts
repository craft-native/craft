/** Execute the shipped navigation method with a delayed native teardown barrier. */
import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('replaces a completed flow without navigating from its disposed isolate', async () => {
  const template = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const method = template.match(/    private fun navigateOpen\([\s\S]*?\n    \}/)?.[0]
  if (!method) throw new Error('Native path navigation is missing')
  await runKotlinFixture(`
class JSONObject(vararg pairs: Pair<String, Any>) {
    val values = mutableMapOf(*pairs)
    fun put(key: String, value: Any): JSONObject { values[key] = value; return this }
    fun length() = values.size
}
data class Screen(val name: String, var path: String? = null, val params: JSONObject = JSONObject(), val props: JSONObject = JSONObject())
data class Match(val screen: String, val params: JSONObject, val path: String)
data class Tab(val id: String)
class Routes {
    val tabs = listOf(Tab("/m"), Tab("/m/progress"))
    val match = Match("Claim", JSONObject("kind" to "club", "slug" to "rappid"), "/m/claim")
    fun appPath(target: String, schemes: Collection<String>): String? = target
    fun match(path: String): Match? = if (path.startsWith("/m/claim")) match else if (path == "/m/progress") Match("Progress", JSONObject(), path) else null
    fun tabFor(path: String): Tab? = tabs.find { it.id == path }
    fun tabOwning(path: String): Tab? = null
    fun siteURL(path: String): String? = null
}
class Navigation {
    val routes = Routes()
    val urlSchemes = emptyList<String>()
    var currentTab = 0
    var screens = mutableListOf(Screen("Today", "/m"), Screen("Login", "/m/login"))
    val pending = mutableListOf<() -> Unit>()
    val disposed = mutableListOf<Screen>()
    var shown: Screen? = null
    var received: JSONObject? = null
    fun selectTab(index: Int) { currentTab = index; screens = mutableListOf(Screen("Progress", "/m/progress")) }
    fun popToRoot() { while (screens.size > 1) screens.removeAt(screens.lastIndex) }
    fun openExternal(path: String) { error("This fixture does not target an external path") }
    fun closeScreen(screen: Screen, done: () -> Unit) { disposed.add(screen); pending.add(done) }
    fun closeScreens(screens: List<Screen>, done: () -> Unit) { disposed.addAll(screens); if (screens.isEmpty()) done() else pending.add(done) }
    fun show(screen: Screen) { shown = screen }
    fun send(screen: Screen, type: String, payload: JSONObject) { received = payload }
    fun openScreen(name: String, params: JSONObject, props: JSONObject = JSONObject()): Screen = Screen(name, params = params, props = props).also { screens.add(it) }
    // No cover is up in these flows: navigateOpen only asks whether one is.
    val cover: Any? = null
    fun closeCover(animated: Boolean = true, done: () -> Unit = {}) { done() }
    fun openCover(match: Match, props: JSONObject) { error("This fixture opens no cover") }
    fun replace(path: String, props: JSONObject = JSONObject()) = navigateOpen(path, replace = true, props = props)
    fun complete() { pending.toList().also { pending.clear() }.forEach { it() } }
${method}
}
fun main() {
    val path = "/m/claim?kind=club&slug=rappid"
    val props = JSONObject("membershipId" to "membership-42")
    val fresh = Navigation()
    fresh.replace(path, props)
    check(fresh.screens.map { it.name } == listOf("Today"))
    check(fresh.pending.size == 1 && fresh.disposed.single().name == "Login")
    fresh.complete()
    check(fresh.screens.map { it.name } == listOf("Today", "Claim"))
    check(fresh.screens.last().path == "/m/claim")
    check(fresh.screens.last().params.values["slug"] == "rappid")
    check(fresh.screens.last().props === props)

    val existing = Navigation()
    val claim = Screen("Claim", "/m/claim")
    existing.screens.add(1, claim)
    existing.replace(path, props)
    check(existing.shown == null && existing.pending.size == 1)
    existing.complete()
    check(existing.screens.map { it.name } == listOf("Today", "Claim"))
    check(existing.shown === claim)
    check((existing.received!!.values["params"] as JSONObject).values["slug"] == "rappid")
    check(existing.received!!.values["props"] === props)

    val interrupted = Navigation()
    interrupted.replace(path)
    interrupted.screens = mutableListOf(Screen("Me", "/m/me"))
    interrupted.complete()
    check(interrupted.screens.map { it.name } == listOf("Me"))

    val crossTab = Navigation()
    val originalStack = crossTab.screens
    crossTab.replace("/m/progress", props)
    check(crossTab.currentTab == 0 && originalStack.map { it.name } == listOf("Today"))
    crossTab.complete()
    check(crossTab.currentTab == 1 && originalStack.none { it.name == "Login" })
    check(crossTab.received!!.values["props"] === props)
    println("PASS atomic replacement waits for teardown, reuses canonical screens, preserves parameters and respects a changed stack")
}
`)
}, 180_000)
