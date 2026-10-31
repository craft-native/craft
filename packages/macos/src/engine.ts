/**
 * Screens run on zig-js, and only on zig-js. zig-js exports JavaScriptCore's C
 * API under the same names, and a host built with `webkit` sits one framework
 * away from Apple's JavaScriptCore. So a `JS*` function zig-js does not define,
 * or a Swift import that autolinks JavaScriptCore, would quietly bind part of
 * the screen's engine to the system one, and fail far from the cause (a value
 * from one engine handed to the other). The build checks the linked host.
 */

/** The C API (`JSValueRef`, `kJSClassDefinitionEmpty`) and its Objective-C wrappers. */
const SYSTEM_ENGINE_SYMBOL = /^_(?:kJS[A-Z]|JS(?:Value|Object|String|BigInt|Context|GlobalContext|Class|PropertyName|EvaluateScript|CheckScriptSyntax|GarbageCollect|Script|Weak|ReportExtraMemoryCost|Synchronous)|OBJC_CLASS_\$_JS(?:Context|Value|ManagedValue|VirtualMachine)$)/

/** What in a host's imports would run on the system's JavaScriptCore; empty when everything is zig-js. */
export function systemEngineUse(undefinedSymbols: string[], linkedLibraries: string[]): string[] {
  return [
    ...linkedLibraries.filter(library => library.includes('/JavaScriptCore.framework/')),
    ...undefinedSymbols.filter(symbol => SYSTEM_ENGINE_SYMBOL.test(symbol)),
  ]
}

async function lines(args: string[]): Promise<string[]> {
  const child = Bun.spawn(args, { stdout: 'pipe', stderr: 'inherit' })
  const text = await new Response(child.stdout).text()
  if (await child.exited !== 0) throw new Error(`Could not inspect the host: ${args.join(' ')}`)
  return text.split('\n').map(line => line.trim()).filter(Boolean)
}

/** Fails when the linked host would run any script on the system's JavaScriptCore. */
export async function assertZigJsEngine(executable: string): Promise<void> {
  const [undefinedSymbols, linked] = await Promise.all([
    lines(['xcrun', 'nm', '-u', '-j', executable]),
    lines(['xcrun', 'otool', '-L', executable]),
  ])
  const leaks = systemEngineUse(undefinedSymbols, linked.slice(1).map(line => line.split(' (')[0]!))
  if (leaks.length) {
    throw new Error(`The host would run scripts on the system's JavaScriptCore instead of zig-js:\n  ${leaks.join('\n  ')}\nDefine the missing functions in zig-js, or keep JavaScriptCore out of the Swift imports.`)
  }
}
