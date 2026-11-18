import { test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { liftKotlinMember, runKotlinFixture } from './testing'

// Run the shipped capability dispatch and Activity claim, rather than a
// TypeScript copy. Full Activity lifecycle delivery is a mobile E2E concern.
test('headless and visible Android consumers each claim the cold link once, including restoration', async () => {
  const activity = readFileSync(join(import.meta.dir, '../templates/MainActivityNative.kt.template'), 'utf8')
  const capabilities = readFileSync(join(import.meta.dir, '../templates/CraftNativeCapabilities.kt.template'), 'utf8')
  const dispatch = capabilities.split('\n').find(line => line.includes('"DeepLinks" -> complete('))
  if (!dispatch) throw new Error('DeepLinks capability dispatch is missing')
  const restore = activity.split('\n').filter(line => /(?:initialDeepLinkClaimed|appInitialDeepLinkClaimed) = savedInstanceState/.test(line)).join('\n')
  const save = activity.split('\n').filter(line => /outState.putBoolean\("craft\.(?:initialDeepLinkClaimed|appInitialDeepLinkClaimed)"/.test(line)).join('\n')
  await runKotlinFixture(`
import org.json.JSONObject
typealias Uri = String
class Bundle {
    private val values = mutableMapOf<String, Boolean>()
    fun putBoolean(key: String, value: Boolean) { values[key] = value }
    fun getBoolean(key: String, fallback: Boolean) = values[key] ?: fallback
}
class Host(savedInstanceState: Bundle? = null) {
    private var initialDeepLink: Uri? = "lastsoulultra:///m/coaching/last-soul-ultra/plans"
    private var initialDeepLinkClaimed = false
    private var appInitialDeepLinkClaimed = false
    init {
${restore}
    }
    fun save(outState: Bundle) {
${save}
    }
${liftKotlinMember(activity, 'consumeInitialDeepLink')}
    fun deepLinkData(url: Uri) = url
}
data class CraftNativeCapabilityResult(val data: Any?)
class Capabilities(private val activity: Host?) {
    private val config = JSONObject().put("enableDeepLinks", true)
    private fun success(value: Any?) = CraftNativeCapabilityResult(value)
    private fun failure(code: String, message: String): CraftNativeCapabilityResult = error(code + message)
    private fun complete(token: String, result: CraftNativeCapabilityResult, completion: (CraftNativeCapabilityResult) -> Unit) { completion(result) }
${liftKotlinMember(capabilities, 'deepLinks')}
    fun request(isAppScript: Boolean): Any? {
        var answer: Any? = null
        val requestToken = "fixture"
        val method = "getInitialURL"
        val completion: (CraftNativeCapabilityResult) -> Unit = { answer = it.data }
        when ("DeepLinks") {
${dispatch}
        }
        return answer
    }
}
fun main() {
    val url = "lastsoulultra:///m/coaching/last-soul-ultra/plans"
    for (firstIsApp in listOf(false, true)) {
        val host = Host()
        val bridge = Capabilities(host)
        check(bridge.request(firstIsApp) == url)
        val saved = Bundle()
        host.save(saved)
        val restored = Capabilities(Host(saved))
        check(restored.request(!firstIsApp) == url) { "One consumer must not starve the other, including after restoration" }
        check(restored.request(firstIsApp) === JSONObject.NULL)
        check(restored.request(!firstIsApp) === JSONObject.NULL)
    }
    println("PASS independent one-shot cold links and Activity restoration")
}
`, ['org.json:json:20240303'])
}, 300_000)
