import { expect, test } from 'bun:test'
import { runKotlinFixture } from './testing'

test('announcement validation forwards text once and rejects malformed requests', async () => {
  const source = await Bun.file(new URL('../templates/MainActivityNative.kt.template', import.meta.url)).text()
  const implementation = source.match(/private fun craftNativeAnnounce\([\s\S]*?\n\}/)?.[0]
  if (!implementation) throw new Error('Missing native announcement implementation')
  await runKotlinFixture(`
class JSONArray(vararg val values: Any?) { fun opt(index: Int): Any? = values.getOrNull(index) }
class JSONObject(private val values: Map<String, Any?> = emptyMap()) {
    companion object { val NULL = Any() }
    fun opt(name: String): Any? = values[name]
}
data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)
${implementation}
fun main() {
    val said = mutableListOf<String>()
    for (args in listOf(JSONArray("Gespeichert"), JSONArray("Saved", JSONObject(mapOf("polite" to true))),
        JSONArray("Failed", JSONObject(mapOf("polite" to false))), JSONArray("Ready", JSONObject.NULL))) {
        check(craftNativeAnnounce(args) { said.add(it) }.data == true)
    }
    check(said == listOf("Gespeichert", "Saved", "Failed", "Ready"))
    for (args in listOf(JSONArray(), JSONArray(42), JSONArray(" "), JSONArray("Saved", false),
        JSONArray("Saved", JSONObject(mapOf("polite" to "yes"))), JSONArray("Saved", JSONObject(mapOf("polite" to 1))),
        JSONArray("Saved", JSONObject(mapOf("polite" to JSONObject.NULL))))) {
        check(craftNativeAnnounce(args) { error("Invalid input was announced") }.code == "INVALID_ARGUMENT")
    }
}
`)
}, 60_000)

test('native announcement and dialog promises preserve correlation, deadlines and listener cleanup', async () => {
  const source = await Bun.file(new URL('../templates/CraftNativeShell.kt.template', import.meta.url)).text()
  const start = source.indexOf('var nextCapabilityRequest = 0;')
  const end = source.indexOf('installNativeDialog();', start) + 'installNativeDialog();'.length
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  const listeners = new Set<(message: string) => void>()
  const requests: { id: string, payload: { module: string, method: string, args: unknown[], untimed: boolean } }[] = []
  let failPost = false
  const bridge = {
    capabilities: ['dialog', 'accessibility'], capabilityProtocolVersion: 1,
    addMessageListener(callback: (message: string) => void) { listeners.add(callback); return () => listeners.delete(callback) },
    postMessage(message: string) {
      if (failPost) throw new Error('Bridge closed')
      requests.push(JSON.parse(message))
    },
  }
  const scope = {} as { craft: { accessibility: { announce(text: unknown, options?: unknown): Promise<void> }, dialog: { confirm(options: unknown): Promise<boolean> } } }
  new Function('globalThis', '__stxNativeBridge', source.slice(start, end))(scope, bridge)
  const announcement = scope.craft.accessibility.announce('Saved', { polite: false })
  const dialog = scope.craft.dialog.confirm({ message: 'Continue?' })
  expect(requests.map(request => request.payload)).toEqual([
    { version: 1, module: 'Accessibility', method: 'announce', args: ['Saved', { polite: false }], untimed: false },
    { version: 1, module: 'Dialog', method: 'confirm', args: [{ message: 'Continue?' }], untimed: true },
  ])
  function reply(id: string, type: string, extra: Record<string, unknown> = {}) {
    for (const listener of [...listeners]) listener(JSON.stringify({ type, payload: { requestId: id, ...extra } }))
  }
  reply(requests[0]!.id, 'EVENT')
  expect(listeners.size).toBe(2)
  reply(requests[1]!.id, 'API_RESPONSE', { data: true })
  await expect(dialog).resolves.toBe(true)
  expect(listeners.size).toBe(1)
  reply(requests[0]!.id, 'API_RESPONSE', { data: true })
  await expect(announcement).resolves.toBeUndefined()
  expect(listeners.size).toBe(0)
  const invalid = scope.craft.accessibility.announce('')
  reply(requests[2]!.id, 'API_ERROR', { code: 'INVALID_ARGUMENT', message: 'Nonempty text required' })
  await expect(invalid).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
  expect(listeners.size).toBe(0)
  failPost = true
  await expect(scope.craft.accessibility.announce('Saved')).rejects.toThrow('Bridge closed')
  expect(listeners.size).toBe(0)
})
