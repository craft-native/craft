/** Exercise the shipped Kotlin predicate with the Android builder's compiler. */
import { test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('native Kotlin constraints reject malformed rules and match complete decoded values', async () => {
  const template = await Bun.file(new URL('../templates/CraftNativeShell.kt.template', import.meta.url)).text()
  const start = template.indexOf('    private fun parametersAllowed(')
  const end = template.indexOf('\n    private fun bind(', start)
  if (start < 0 || end < 0) throw new Error('The native route constraint predicate is missing')
  await runKotlinFixture(`
class JSONArray(vararg items: Any?) {
    private val values = items.toList()
    fun length() = values.size
    fun opt(index: Int): Any? = values.getOrNull(index)
}
class JSONObject(vararg items: Pair<String, Any?>) {
    private val values = mapOf(*items)
    fun keys() = values.keys.iterator()
    fun opt(name: String): Any? = values[name]
    fun has(name: String) = values.containsKey(name)
    fun optJSONObject(name: String) = values[name] as? JSONObject
    fun optJSONArray(name: String) = values[name] as? JSONArray
    fun optBoolean(name: String, fallback: Boolean) = values[name] as? Boolean ?: fallback
}
class Matcher {
    fun accepts(value: String, rule: Any?) = parametersAllowed(JSONObject("username" to value), JSONObject("username" to rule))
${template.slice(start, end)}
}
fun main() {
    val matcher = Matcher()
    val rule = JSONObject("pattern" to "[a-z0-9]+(?:-[a-z0-9]+)*", "exclude" to JSONArray("terms", "privacy", "health-safety"), "ignoreCase" to true)
    for (value in listOf("terms", "TERMS", "privacy", "health-safety", "-invalid", "ava/smith", "ava\\n", "ava_smith")) check(!matcher.accepts(value, rule))
    for (value in listOf("ava-smith", "AVA")) check(matcher.accepts(value, rule))
    for (invalid in listOf(JSONObject("pattern" to "["), JSONObject("pattern" to 1), JSONObject("exclude" to JSONArray(1)), JSONObject("ignoreCase" to "yes"), JSONObject("unknown" to true), JSONArray())) check(!matcher.accepts("ava", invalid))
    check(matcher.accepts("ava", JSONObject()))
    // Java's equals(ignoreCase) merges dotless i and final sigma with other
    // letters, unlike the complete-string lowercase comparison used by JS/iOS.
    val exclusions = JSONObject("exclude" to JSONArray("i", "σ"), "ignoreCase" to true)
    for (value in listOf("i", "I", "σ", "Σ")) check(!matcher.accepts(value, exclusions))
    for (value in listOf("ı", "İ", "ς")) check(matcher.accepts(value, exclusions)) { "Unicode exclusion drift: $value" }
    java.util.Locale.setDefault(java.util.Locale.forLanguageTag("tr-TR"))
    check(!matcher.accepts("I", exclusions)) { "Exclusions must not depend on the device locale" }
    println("PASS full-value Kotlin regex, exclusions, case folding and malformed-rule rejection")
}
`)
}, 180_000)
