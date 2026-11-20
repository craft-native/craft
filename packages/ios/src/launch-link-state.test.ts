import { expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Exercise the shipped capability dispatch in both real consumer orders.
// UIKit lifecycle delivery remains covered by the native acceptance journey.
test.skipIf(process.platform !== 'darwin')('the headless app and visible navigator each receive the cold link once', async () => {
  const actions = readFileSync(join(import.meta.dir, '../templates/CraftNativeActions.swift'), 'utf8')
  const begin = actions.indexOf('        case ("DeepLinks", "getInitialURL"):')
  const end = actions.indexOf('        case ("Database", _):', begin)
  expect(begin).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(begin)
  const method = (name: string) => {
    const start = actions.indexOf(`    ${name}`)
    expect(start).toBeGreaterThan(0)
    return actions.slice(start, actions.indexOf('\n    }', start) + '\n    }'.length)
  }
  const directory = mkdtempSync(join(tmpdir(), 'craft-launch-consumers-'))
  try {
    const source = join(directory, 'main.swift'), binary = join(directory, 'probe')
    writeFileSync(source, `import Foundation
struct ActionError: Error {}
struct Config { let enableDeepLinks = true }
class CraftHybrid {
    static let shared = CraftHybrid()
    func nativeRedirect(forInitialLink url: URL) -> String? {
        if url.path == "/m/workouts/library" {
            return "/m/login?next=%2Fm%2Fworkouts%2Flibrary%3Fdate%3D2026-11-21%23library"
        }
        return nil
    }
}
class DeepLinkManager {
    static let shared = DeepLinkManager()
    func resolveInitialURL(_ completion: (URL?) -> Void) { completion(URL(string: CommandLine.arguments[2])) }
}
enum Actions {
    static let cancellationLock = NSLock()
    static var initialDeepLinkClaimed = false
    static var appInitialDeepLinkClaimed = false
    static func complete(_ token: String, _ result: Result<Any, ActionError>, _ callback: (Result<Any, ActionError>) -> Void) { callback(result) }
    static func failure(_ code: String, _ message: String) -> Result<Any, ActionError> { .failure(ActionError()) }
${method('private static func claimInitialDeepLink(')}
${method('static func deepLinkData(')}
    static func perform(isAppScript: Bool, completion: (Result<Any, ActionError>) -> Void) {
        let config = Config(), requestToken = "fixture"
        let sync: Result<Any, ActionError>?
        switch ("DeepLinks", "getInitialURL") {
${actions.slice(begin, end)}
        default: sync = failure("UNKNOWN_ACTION", "Unsupported method")
        }
        if let sync { complete(requestToken, sync, completion) }
    }
}
func request(app: Bool) -> [String: Any]? {
    var payload: [String: Any]?
    Actions.perform(isAppScript: app) { result in
        if case .success(let value) = result { payload = value as? [String: Any] }
    }
    return payload?.filter { $0.key == "url" || $0.key == "nativeRedirect" }
}
let firstIsApp = CommandLine.arguments[1] == "app-first"
let answers = [request(app: firstIsApp), request(app: !firstIsApp), request(app: false), request(app: true)]
print(String(data: try! JSONSerialization.data(withJSONObject: answers.map { $0 as Any? ?? NSNull() }), encoding: .utf8)!)
`)
    const compiler = Bun.spawnSync(['swiftc', source, '-o', binary], { stdout: 'pipe', stderr: 'pipe', timeout: 120_000 })
    expect(compiler.exitCode, compiler.stderr.toString()).toBe(0)
    const links = [
      { url: 'lastsoulultra:///m/coaching/last-soul-ultra/plans' },
      {
        url: 'lastsoulultra:///m/workouts/library?date=2026-11-21#library',
        nativeRedirect: '/m/login?next=%2Fm%2Fworkouts%2Flibrary%3Fdate%3D2026-11-21%23library',
      },
    ]
    for (const order of ['screen-first', 'app-first']) {
      for (const link of links) {
        const result = Bun.spawnSync([binary, order, link.url], { stdout: 'pipe', stderr: 'pipe', timeout: 15_000 })
        expect(result.exitCode, result.stderr.toString()).toBe(0)
        expect(JSON.parse(result.stdout.toString()), order).toEqual([link, link, null, null])
      }
    }
  }
  finally { rmSync(directory, { recursive: true, force: true }) }
}, 150_000)

test.skipIf(process.platform !== 'darwin')('the Swift launch state waits for intent and never promotes a warm link to the initial URL', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')
  const state = template.slice(template.indexOf('final class CraftInitialLinkState {'), template.indexOf('\nclass DeepLinkManager {'))
  const root = mkdtempSync(join(tmpdir(), 'craft-launch-link-state-'))
  try {
    const source = join(root, 'main.swift')
    writeFileSync(source, `import Foundation\n${state}\n
let cold = CraftInitialLinkState()
var coldAnswers: [URL?] = []
cold.resolve { coldAnswers.append($0) }
cold.resolve { coldAnswers.append($0) }
assert(coldAnswers.isEmpty, "reading before UIKit's launch intent must wait")
let first = URL(string: "https://hq.training/diego-ruiz")!
cold.receive(first)
assert(coldAnswers == [first, first])
cold.receive(URL(string: "https://hq.training/pawel")!)
cold.settle()
assert(cold.url == first && coldAnswers.count == 2)
cold.resolve { assert($0 == first) }
let ordinary = CraftInitialLinkState()
var noURLAnswers: [URL?] = []
ordinary.resolve { noURLAnswers.append($0) }
ordinary.settle()
ordinary.receive(first)
ordinary.resolve { noURLAnswers.append($0) }
assert(ordinary.url == nil && noURLAnswers.count == 2 && noURLAnswers.allSatisfy { $0 == nil })
print("launch-link-state OK")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [status, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    expect(status, stderr).toBe(0)
    expect(stdout).toContain('launch-link-state OK')
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 30_000)

test.skipIf(process.platform !== 'darwin')('queued Swift links wait for a visible native screen and replay once in order', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')
  const manager = template.slice(template.indexOf('final class CraftInitialLinkState {'), template.indexOf('// MARK: - App State'))
  const root = mkdtempSync(join(tmpdir(), 'craft-native-link-replay-'))
  try {
    const source = join(root, 'main.swift')
    writeFileSync(source, `import Foundation
class UIApplication {
    enum State { case active, background, inactive }
    static let shared = UIApplication()
    static let didBecomeActiveNotification = Notification.Name("active")
    static let didEnterBackgroundNotification = Notification.Name("background")
    var applicationState = State.inactive
    var connectedScenes: [Int] = [1]
}
class WKWebView {
    func evaluateJavaScript(_ script: String, completionHandler: ((Any?, Error?) -> Void)?) {}
}
class CraftHybrid {
    static let shared = CraftHybrid()
    var isEnabled = true
    var hasWeb = false
    var prepared: [URL] = []
    var handled: [(url: URL, initial: Bool)] = []
    func prepareInitialDeepLink(_ url: URL) { prepared.append(url) }
    func handleDeepLink(_ url: URL, initial: Bool) -> Bool {
        handled.append((url, initial))
        return false
    }
}
${manager}
let links = DeepLinkManager.shared
let first = URL(string: "https://hq.training/diego-ruiz")!
let second = URL(string: "https://hq.training/pawel")!
var visible = false
var delivered: [URL] = []
var initialFlags: [Bool] = []
// UIKit's scene connection knows the URL before activation; SwiftUI may
// deliver onOpenURL only after the JavaScript bridge already became ready.
links.captureLaunchURL(first)
NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
links.setReady()
links.resolveInitialURL {
    assert($0 == first, "activation must preserve the scene's captured launch intent")
    assert(CraftHybrid.shared.prepared == [first], "the shell must prepare the captured URL before readers receive it")
}
links.handleURL(first)
let hidden = links.addNativeListener(canReceive: { visible }) { url, initial in
    if visible { delivered.append(url); initialFlags.append(initial) }
}
links.handleURL(second)
assert(delivered.isEmpty, "prewarming must not deliver to an invisible screen")
links.removeNativeListener(hidden)
visible = true
let active = links.addNativeListener(canReceive: { visible }) { url, initial in
    delivered.append(url)
    initialFlags.append(initial)
}
assert(delivered == [first, second], "an inactive listener must not discard queued links")
assert(initialFlags == [true, false], "the cold URL stays initial while waiting for a screen")
let third = URL(string: "https://hq.training/gyms/trifit")!
visible = false
links.handleURL(third)
links.replayNativeLinks()
assert(delivered == [first, second], "a hidden tab must retain a warm link")
visible = true
links.replayNativeLinks()
links.replayNativeLinks()
assert(delivered == [first, second, third] && initialFlags == [true, false, false])
links.removeNativeListener(active)
let fourth = URL(string: "https://hq.training/rappid")!
links.handleURL(first)
let reentrant = links.addNativeListener { url, initial in
    delivered.append(url)
    if url == first { links.handleURL(fourth); links.replayNativeLinks() }
}
assert(delivered == [first, second, third, first, fourth], "reentrant delivery must stay ordered without duplication")
links.removeNativeListener(reentrant)
_ = links.addNativeListener { url, initial in delivered.append(url) }
assert(delivered == [first, second, third, first, fourth], "consumed links must not replay again")
assert(CraftHybrid.shared.prepared == [first], "warm links must not be prepared as launch routes")
assert(CraftHybrid.shared.handled.map { $0.url } == delivered, "the shell must receive each original URL in order")
assert(CraftHybrid.shared.handled.map { $0.initial } == [true, false, false, false, false], "opening the same URL again is a warm link")
print("native-link-replay OK")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [status, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    expect(status, stderr).toBe(0)
    expect(stdout).toContain('native-link-replay OK')
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 30_000)
