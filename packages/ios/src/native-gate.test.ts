import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'
import { hybridConfigProblems } from './index'

/**
 * The allowlist rule the shipped shell uses, run through Swift itself.
 *
 * A signed-out launch paints a signed-in screen because the app script that
 * would stop it cannot run until the first frame has been committed (#499).
 * The gate moves the decision to whoever resolves the start path, so this
 * predicate is what stands between a signed-out launch and the previous
 * session's data.
 *
 * The function is extracted from the template rather than restated here, and
 * compiled, because a TypeScript reimplementation would only prove that two
 * things I wrote agree. `String.hasPrefix` and Swift's trailing-slash
 * trimming are the actual behaviour, and this runs them.
 */
const template = readFileSync(join(import.meta.dir, '../templates/CraftHybrid.swift'), 'utf8')

function gateRule(): string {
  const from = template.indexOf('    static func gateAdmits(')
  expect(from, 'the shell must declare the allowlist rule').toBeGreaterThan(0)
  const to = template.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  const rule = template.slice(from, to + '\n    }'.length)
  // It must be Foundation-only, or this probe would need the whole shell.
  expect(rule).not.toContain('UIKit')
  return rule
}

/** path, public list, whether a signed-out launch may stay there. */
const cases: [string, string[], boolean][] = [
  ['/m', ['/m/login'], false],
  ['/m/login', ['/m/login'], true],
  ['/m/login/reset', ['/m/login'], true],
  // The separator is what stops a sibling borrowing a listed path's letters.
  ['/m/loginish', ['/m/login'], false],
  ['/m/store/42', ['/m/store'], true],
  ['/m/storefront', ['/m/store'], false],
  ['/m/store/42', ['/m/store/'], true],
  ['/m', [], false],
  ['/m', [''], false],
  // "/" is the root path, not a prefix of everything.
  ['/m/today', ['/'], false],
  ['/', ['/'], true],
  ['/m/signup', ['/m/login', '/m/signup'], true],
]

test.skipIf(process.platform !== 'darwin')('the shipped allowlist rule admits exactly the paths it should', () => {
  const dir = createTempDir('craft-native-gate-')
  try {
    const probe = join(dir, 'main.swift'), binary = join(dir, 'gate')
    writeFileSync(probe, `import Foundation

enum Gate {
${gateRule()}
}

for line in (try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)).split(separator: "\\n") {
    let parts = line.split(separator: "\\t", omittingEmptySubsequences: false)
    let allowed = parts[1].isEmpty ? [] : parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    print(Gate.gateAdmits(String(parts[0]), public: allowed) ? "true" : "false")
}
`)
    const build = Bun.spawnSync(['swiftc', probe, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(build.exitCode, build.stderr.toString()).toBe(0)

    const input = join(dir, 'cases.tsv')
    writeFileSync(input, cases.map(([path, allowed]) => `${path}\t${allowed.join(',')}`).join('\n'))
    const run = Bun.spawnSync([binary, input], { stdout: 'pipe', stderr: 'pipe', timeout: 60_000 })
    expect(run.exitCode, run.stderr.toString()).toBe(0)

    const answers = run.stdout.toString().trim().split('\n')
    expect(answers.length, 'every case must get an answer').toBe(cases.length)
    const wrong = cases
      .map(([path, allowed, expected], index) => ({ path, allowed, expected, actual: answers[index] === 'true' }))
      .filter(row => row.actual !== row.expected)
    expect(wrong, 'Swift disagreed with the allowlist these paths should get').toEqual([])
  }
  finally { removeTempDir(dir) }
}, 180_000)

test('a gate whose redirect nothing draws is refused at generation', () => {
  const screens = { '/m': 'Today', '/m/login': 'Login' }
  const base = { renderer: 'native' as const, nativeScreens: screens, devServerURL: 'https://example.com/m', tabs: [] }

  expect(hybridConfigProblems({ ...base, nativeGate: { publicPaths: ['/m/login'], redirect: '/m/login' } })).toEqual([])
  // Trading a private screen for a blank one is not a fix.
  expect(hybridConfigProblems({ ...base, nativeGate: { publicPaths: ['/m/login'], redirect: '/m/nowhere' } })[0])
    .toContain('is not a nativeScreens path')
  // A redirect the gate would itself redirect away from is a loop.
  expect(hybridConfigProblems({ ...base, nativeGate: { publicPaths: ['/m/store'], redirect: '/m/login' } })[0])
    .toContain('must also be listed in nativeGate.publicPaths')
  expect(hybridConfigProblems({ ...base, nativeGate: { publicPaths: ['/m/login'], redirect: 'm/login' } })[0])
    .toContain('must be an absolute path')
  expect(hybridConfigProblems({ ...base, nativeGate: { publicPaths: ['m/login'], redirect: '/m/login' } }).join('\n'))
    .toContain('nativeGate.publicPaths')
})

test('the gate is resolved before anything is built, and the app script still is not', () => {
  const screen = readFileSync(join(import.meta.dir, '../templates/CraftNativeScreen.swift'), 'utf8')
  const from = template.indexOf('    func configure(_ config: CraftConfig) {')
  expect(from).toBeGreaterThan(0)
  const configure = template.slice(from, template.indexOf('\n    }', from))

  // Order inside configure is the entire fix, so it is read as order rather
  // than as presence. The gate has to decide before `startsNative` is derived
  // from the start path and before the chrome is told what to draw.
  const gate = configure.indexOf('applyGate(config)')
  const decided = configure.indexOf('startsNative = isEnabled')
  const chrome = configure.indexOf('CraftChrome.shared.configure(')
  expect(gate, 'configure must apply the gate').toBeGreaterThan(0)
  expect(gate, 'the gate must decide before the start path is treated as final').toBeLessThan(decided)
  expect(gate, 'the gate must decide before the chrome is configured').toBeLessThan(chrome)

  // And the thing that could not do this job keeps its own ordering: the app
  // script is still started after the first frame so it never delays one.
  // If that ever changes, the gate is no longer the only thing standing
  // between a signed-out launch and a private screen.
  expect(template).toContain('CATransaction.setCompletionBlock { [weak self] in self?.startAppScript() }')

  // The mitigation: a path replacement from the app script reaches the shell
  // instead of being dropped by a guard written for pushes.
  const navigate = screen.indexOf('case "NAVIGATE", "NAVIGATE_REPLACE":')
  expect(navigate).toBeGreaterThan(0)
  const handler = screen.slice(navigate, navigate + 1400).replace(/^\s*\/\/[^\n]*$/gm, '')
  expect(handler).toContain('guard isAppScript || navigationController?.topViewController === self else { return }')
  // The push path still refuses it: the app script has no stack to push onto.
  expect(handler).toContain('guard !isAppScript, navigationController?.topViewController === self,')
})
