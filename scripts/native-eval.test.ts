import { afterAll, expect, test } from 'bun:test'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

const binary = process.env.CRAFT_NATIVE_TEST_BIN
if (!binary) throw new Error('CRAFT_NATIVE_TEST_BIN must name the freshly built native CLI')
const unavailable = process.env.CRAFT_NATIVE_TEST_UNAVAILABLE === '1'
afterAll(removeAllTempDirs)

function run(args: string[]) {
  const result = Bun.spawnSync([binary!, ...args], { stdout: 'pipe', stderr: 'pipe', timeout: 5000 })
  expect(result.signalCode ?? null).toBeNull()
  expect(result.stdout.toString()).toBe('')
  return { exit: result.exitCode, error: result.stderr.toString() }
}

if (unavailable) {
  test('a runtime-disabled native CLI reports unavailable, not a script error', () => {
    const result = run(['--eval', 'throw new Error("not executed")'])
    expect(result.exit).toBe(1)
    expect(result.error).toContain('built without the JavaScript runtime')
    expect(result.error).not.toContain('not executed')
  })
}
else {
  for (const [source, detail] of [
    ['throw new Error("distinct failure")', 'Error: distinct failure'],
    ['throw new TypeError("caf\u00e9")', 'TypeError: caf\u00e9'],
    ['throw "primitive failure"', 'primitive failure'],
    ['throw 42', '42'],
    ['throw true', 'true'],
    ['throw null', 'null'],
    ['throw undefined', 'undefined'],
    ['throw {toString(){while(true){}},get message(){while(true){}}}', '[thrown object]'],
    ['var e=new Error("hidden"); Object.defineProperty(e,"message",{get(){while(true){}}}); throw e', 'Error: [accessor message omitted]'],
    ['var e=new Error("safe"); Object.defineProperty(e,"name",{get(){while(true){}}}); e.toString=function(){while(true){}}; throw e', 'Error: safe'],
    ['throw new Proxy(new Error("hidden"),{get(){while(true){}},getOwnPropertyDescriptor(){while(true){}}})', '[thrown proxy]'],
    ['var p=Proxy.revocable({},{}); p.revoke(); throw p.proxy', '[thrown proxy]'],
    ['throw "x".repeat(100000)', '[string exceeds diagnostic limit]'],
  ]) {
    test(`native eval safely reports ${detail}`, () => {
      const result = run(['--eval', source!])
      expect(result.exit).toBe(1)
      expect(result.error).toBe(`uncaught error: ${detail}\n`)
    }, 10_000)
  }

  test('eval-file reports the throw without dumping the input bundle', () => {
    const file = join(createTempDir('craft-eval-test-'), 'failure.js')
    writeFileSync(file, 'var secret = "PRIVATE_BUNDLE_CONTENT"; throw new Error("file failure")')
    const result = run(['--eval-file', file])
    expect(result.exit).toBe(1)
    expect(result.error).toBe('uncaught error: Error: file failure\n')
    expect(result.error).not.toContain('PRIVATE_BUNDLE_CONTENT')
  })

  test('native eval retains success and syntax-error classifications', () => {
    expect(run(['--eval', '40 + 2'])).toEqual({ exit: 0, error: '42\n' })
    expect(run(['--eval', 'function ('])).toEqual({ exit: 1, error: 'syntax error\n' })
  })
}
