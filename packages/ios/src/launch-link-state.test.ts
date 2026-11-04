import { expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

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
    func handleDeepLink(_ url: URL) -> Bool { false }
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
links.resolveInitialURL { assert($0 == first, "activation must preserve the scene's captured launch intent") }
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
print("native-link-replay OK")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [status, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    expect(status, stderr).toBe(0)
    expect(stdout).toContain('native-link-replay OK')
  }
  finally { rmSync(root, { recursive: true, force: true }) }
}, 30_000)
