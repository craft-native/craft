import { expect, test } from 'bun:test'
import { readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { runKotlinFixture } from './testing'

/**
 * Kotlin admits exactly the paths UIKit does, from one `publicPaths` list.
 *
 * The auth gate decides whether a signed-out launch may stay where it is
 * (#499). The two hosts resolve it independently, so a disagreement between
 * them is an app that is gated on one platform and not the other — the exact
 * shape of the defect the gate exists to fix, moved one level down.
 *
 * The rule is extracted from the template rather than retyped, and run through
 * Kotlin's own `startsWith`, `dropLast` and `endsWith`. A TypeScript
 * reimplementation would only prove that two things I wrote agree. The sibling
 * `packages/ios/src/native-gate.test.ts` runs the Swift version against this
 * same table of cases.
 */
const shell = readFileSync(join(import.meta.dir, '../templates/CraftNativeShell.kt.template'), 'utf8')

/** path, publicPaths, whether a signed-out launch may stay there. */
const cases: [string, string[], boolean][] = [
  ['/m', ['/m/login'], false],
  ['/m/login', ['/m/login'], true],
  ['/m/login/reset', ['/m/login'], true],
  ['/m/loginish', ['/m/login'], false],
  ['/m/store/42', ['/m/store'], true],
  ['/m/storefront', ['/m/store'], false],
  ['/m/store/42', ['/m/store/'], true],
  ['/m', [], false],
  ['/m', [''], false],
  ['/m/today', ['/'], false],
  ['/', ['/'], true],
  ['/m/signup', ['/m/login', '/m/signup'], true],
]

test('Kotlin admits exactly the paths UIKit does', async () => {
  const from = shell.indexOf('    fun gateAdmits(path: String, allowed: List<String>): Boolean = allowed.any { entry ->')
  expect(from, 'the shell must declare the allowlist rule').toBeGreaterThan(0)
  const to = shell.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  // Extracted, not retyped, and dedented out of its enclosing object.
  const rule = shell.slice(from, to + '\n    }'.length).replace(/^ {4}/gm, '')
  expect(rule).toContain('listed == "/" -> false')

  await runKotlinFixture(`
// Extracted from CraftNativeShell.kt.template, not retyped.
${rule}

fun main() {
    val cases = listOf(${cases.map(([path, allowed, expected]) =>
    `Triple(${JSON.stringify(path)}, listOf(${allowed.map(value => JSON.stringify(value)).join(', ')}), ${expected})`).join(',\n        ')})
    val wrong = cases.filter { (path, allowed, expected) -> gateAdmits(path, allowed) != expected }
    if (wrong.isNotEmpty()) throw AssertionError("Kotlin disagreed on " + wrong.joinToString { it.first })
    println("Kotlin and UIKit agree on all " + cases.size + " gate cases")
}
`)
}, 300_000)

test('a gate whose redirect nothing draws is refused at generation', async () => {
  const { init } = await import('./index')
  const screens = { '/m': 'Today', '/m/login': 'Login' }
  const base = {
    renderer: 'native' as const,
    nativeScreens: screens,
    devServerURL: 'https://example.com/m',
    appName: 'Gate',
    packageName: 'dev.craft.gate',
  }
  const generate = async (nativeGate: Record<string, unknown>) => {
    const output = join(tmpdir(), `craft-gate-${Math.random().toString(36).slice(2)}`)
    try {
      await init({ name: 'Gate', packageName: 'dev.craft.gate', output, config: { ...base, nativeGate } as never })
      return null
    }
    catch (error) { return (error as Error).message }
    finally { rmSync(output, { recursive: true, force: true }) }
  }

  // Trading a private screen for a blank one is not a fix.
  expect(await generate({ publicPaths: ['/m/login'], redirect: '/m/nowhere' })).toContain('is not a nativeScreens path')
  // A redirect the gate would itself redirect away from is a loop.
  expect(await generate({ publicPaths: ['/m/store'], redirect: '/m/login' })).toContain('must also be listed in nativeGate.publicPaths')
  expect(await generate({ publicPaths: ['/m/login'], redirect: 'm/login' })).toContain('must be an absolute path')
  expect(await generate({ publicPaths: ['m/login'], redirect: '/m/login' })).toContain('nativeGate.publicPaths')
}, 120_000)
