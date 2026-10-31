import { afterAll, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { assertZigJsEngine, systemEngineUse } from './engine'

const scratch = mkdtempSync(join(tmpdir(), 'craft-engine-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

test('names whatever would run on the system JavaScriptCore, and nothing else', () => {
  expect(systemEngineUse(
    ['_JSEvaluateScript', '_kJSClassDefinitionEmpty', '_OBJC_CLASS_$_JSContext', '_OBJC_CLASS_$_JSONSerialization', '_JSON_parse', '_objc_msgSend'],
    ['/usr/lib/libSystem.B.dylib', '/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit', '/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore'],
  )).toEqual(['/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore', '_JSEvaluateScript', '_kJSClassDefinitionEmpty', '_OBJC_CLASS_$_JSContext'])
  expect(systemEngineUse(['_objc_msgSend'], ['/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit'])).toEqual([])
})

async function link(name: string, source: string, frameworks: string[]): Promise<string> {
  const file = join(scratch, `${name}.c`)
  const executable = join(scratch, name)
  writeFileSync(file, source)
  const child = Bun.spawn(['xcrun', 'clang', file, ...frameworks.flatMap(framework => ['-framework', framework]), '-o', executable], { stderr: 'inherit' })
  expect(await child.exited).toBe(0)
  return executable
}

test.skipIf(process.platform !== 'darwin')('reads a real linked host: WebKit alone passes, borrowing JavaScriptCore fails', async () => {
  const own = await link('own', 'typedef const struct OpaqueJSContext *JSContextRef;\nJSContextRef JSGlobalContextCreate(void *c) { return 0; }\nint main(void) { return JSGlobalContextCreate(0) != 0; }\n', ['WebKit'])
  await assertZigJsEngine(own)
  const borrowed = await link('borrowed', '#include <JavaScriptCore/JavaScriptCore.h>\nint main(void) { return JSGlobalContextCreate(0) == 0; }\n', ['WebKit', 'JavaScriptCore'])
  await expect(assertZigJsEngine(borrowed)).rejects.toThrow(/_JSGlobalContextCreate/)
}, 60_000)
