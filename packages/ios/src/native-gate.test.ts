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

function linkRule(): string {
  const from = template.indexOf('    static func gatedLinkDestination(')
  expect(from).toBeGreaterThan(0)
  const to = template.indexOf('\n    }', from)
  expect(to).toBeGreaterThan(from)
  return template.slice(from, to + '\n    }'.length)
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
${linkRule()}
}

let protectedPaths = ["/m/workouts/library", "/m/backyard"]
let raw = "/m/workouts/library?date=2026-11-19&filter=a%2Bb#start"
let redirect = "/m/login"
precondition(Gate.gatedLinkDestination(raw, path: "/m/workouts/library", protectedPaths: protectedPaths, redirect: redirect) { false } ==
    "/m/login?next=%2Fm%2Fworkouts%2Flibrary%3Fdate%3D2026-11-19%26filter%3Da%252Bb%23start")
precondition(Gate.gatedLinkDestination(raw, path: "/m/workouts/library", protectedPaths: protectedPaths, redirect: redirect) { true } == nil)
precondition(Gate.gatedLinkDestination("/m/backyard/rounds#clock", path: "/m/backyard/rounds", protectedPaths: protectedPaths, redirect: redirect) { false } != nil)
for publicPath in ["/m/start", "/m/backyard-notes", "/m/store/42"] {
    precondition(Gate.gatedLinkDestination(publicPath, path: publicPath, protectedPaths: protectedPaths, redirect: redirect) { fatalError("public link read the session") } == nil)
}
precondition(Gate.gatedLinkDestination("//elsewhere.invalid/m/backyard", path: "/m/backyard", protectedPaths: protectedPaths, redirect: redirect) { false } == redirect)

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
  const linkGate = { publicPaths: ['/m/login'], redirect: '/m/login', protectedLinks: ['/m/backyard'] }
  expect(hybridConfigProblems({ ...base, nativeGate: linkGate })).toEqual([])
  expect(hybridConfigProblems({ ...base, nativeGate: { ...linkGate, protectedLinks: ['//elsewhere.invalid'] } }).join('\n')).toContain('nativeGate.protectedLinks')
  expect(hybridConfigProblems({ ...base, nativeGate: { ...linkGate, linkRedirect: '/m/unknown' } }).join('\n')).toContain('nativeGate.linkRedirect')
  expect(hybridConfigProblems({ ...base, nativeGate: { ...linkGate, protectedLinks: ['/m/login'] } }).join('\n')).toContain('cannot itself be protected')
})

test('queued and live UIKit links share a gate before native navigation', () => {
  const from = template.indexOf('    func handleDeepLink(')
  const body = template.slice(from, template.indexOf('\n    }', from))
  expect(body).toContain('percentEncodedFragment')
  expect(body.indexOf('gatedLinkPath(')).toBeGreaterThan(0)
  expect(body.indexOf('gatedLinkPath(')).toBeLessThan(body.indexOf('controller.showNative('))
  expect(body).toContain('untilShell.append(show)')
  expect(body).toContain('show(controller)')
  expect(body).toContain('if initial, initialDeepLinkRedirect?.url == url { return true }')
})

test('a protected launch resolves to the Login root before URL subscribers run', () => {
  const app = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')
  const from = app.indexOf('    func captureLaunchURL(')
  const capture = app.slice(from, app.indexOf('\n    }', from))
  expect(capture.indexOf('prepareInitialDeepLink(url)')).toBeGreaterThan(0)
  expect(capture.indexOf('prepareInitialDeepLink(url)')).toBeLessThan(capture.indexOf('launch.receive(url)'))
  expect(template).toContain('startPath = redirect\n        startsNative = true\n        initialDeepLinkRedirect = (url, redirect)')
  expect(app).toContain('CraftHybrid.shared.handleDeepLink(url, initial: initial)')
})

test('UIKit does not prewarm protected tabs before or after scheduling while signed out', () => {
  const from = template.indexOf('    private func prepareAdjacentNativeTabs()')
  const body = template.slice(from, template.indexOf('\n    }', from))
  expect(body).toContain('hybrid.gatedLinkPath(tabs[$0]) == nil')
  expect(body.indexOf('self.hybrid.gatedLinkPath(id) == nil')).toBeGreaterThan(0)
  expect(body.indexOf('self.hybrid.gatedLinkPath(id) == nil')).toBeLessThan(body.indexOf('self.makeStack('))
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
