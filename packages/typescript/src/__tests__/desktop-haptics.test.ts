import { afterEach, describe, expect, it } from 'bun:test'
import { haptics } from '../api/mobile'

/**
 * Haptics in a desktop window, driven through the real
 * `packages/zig/src/js/craft-bridge.js`.
 *
 * The SDK's `haptics.*` reach native through `window.craft.haptics`, which the
 * mobile bridges inject and the desktop bridge now injects too, posting to the
 * `haptics` namespace `bridge_haptics.zig` serves on macOS. These tests pin the
 * page half of that: what goes over the wire, what settles, and that a host
 * with nothing to play (Linux, Windows) does not fail the flow that asked.
 */

const BRIDGE_SRC = await Bun.file(
  new URL('../../../zig/src/js/craft-bridge.js', import.meta.url),
).text()

interface Envelope { t: string, a: string, d?: string, i?: number }

interface Harness {
  craft: any
  sent: Envelope[]
  win: any
  reply: (action: string, payload: unknown, id: number | null) => void
  fail: (err: { action?: string, code?: string, message?: string, id?: number }) => void
}

/** Run craft-bridge.js in a synthetic window, as `bridge-request-id.test.ts` does. */
function loadBridge(platform: 'webkit' | 'webview2' = 'webkit'): Harness {
  const sent: Envelope[] = []
  const win: any = {
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => true,
  }
  if (platform === 'webkit')
    win.webkit = { messageHandlers: { craft: { postMessage: (m: Envelope) => { sent.push(m) } } } }
  else
    win.chrome = { webview: { postMessage: (m: Envelope) => { sent.push(m) } } }
  const doc: any = { readyState: 'complete', addEventListener: () => {} }
  const console_: any = { ...console, error: () => {}, warn: () => {} }

  // eslint-disable-next-line no-new-func
  const run = new Function('window', 'document', 'console', 'setTimeout', 'clearTimeout', 'setInterval', BRIDGE_SRC)
  run(win, doc, console_, setTimeout, clearTimeout, () => 0)

  return {
    craft: win.craft,
    sent,
    win,
    reply: (action, payload, id) => win.__craftBridgeResult(action, payload, id),
    fail: err => win.__craftBridgeError(err),
  }
}

/** Answer the most recent call the way `sendResultToJS` does on macOS. */
function acceptLast(h: Harness): void {
  const last = h.sent.at(-1)!
  h.reply(last.a, true, last.i!)
}

/** Refuse the most recent call the way Linux and Windows do. */
function refuseLast(h: Harness, code = 'PLATFORM_NOT_SUPPORTED'): void {
  const last = h.sent.at(-1)!
  h.fail({ action: last.a, code, message: 'refused', id: last.i })
}

describe('desktop haptics bridge', () => {
  it('posts the raw haptic to the haptics namespace and resolves true', async () => {
    const h = loadBridge()
    const answer = h.craft.haptic('heavy')
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'haptic', d: '{"style":"heavy"}' })
    expect(typeof h.sent.at(-1)!.i).toBe('number')
    acceptLast(h)
    expect(await answer).toBe(true)
  })

  it('defaults a missing style to medium, as the mobile bridges do', async () => {
    const h = loadBridge()
    const answer = h.craft.haptic()
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'haptic', d: '{"style":"medium"}' })
    acceptLast(h)
    await answer
  })

  it('sends each helper as the style native folds onto a trackpad pattern', async () => {
    const h = loadBridge()
    const cases: Array<[() => Promise<void>, string]> = [
      [() => h.craft.haptics.selection(), '{"style":"selection"}'],
      [() => h.craft.haptics.impact(), '{"style":"medium"}'],
      [() => h.craft.haptics.impact('light'), '{"style":"light"}'],
      [() => h.craft.haptics.impact('heavy'), '{"style":"heavy"}'],
      [() => h.craft.haptics.notification(), '{"style":"success"}'],
      [() => h.craft.haptics.notification('warning'), '{"style":"warning"}'],
      [() => h.craft.haptics.notification('error'), '{"style":"error"}'],
    ]
    for (const [call, payload] of cases) {
      const done = call()
      expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'haptic', d: payload })
      acceptLast(h)
      // Feedback helpers resolve with nothing, matching the mobile shims.
      expect(await done).toBeUndefined()
    }
  })

  it('posts vibrate with the pattern, and an empty one when none is given', async () => {
    const h = loadBridge()
    const patterned = h.craft.haptics.vibrate([100, 50, 100])
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'vibrate', d: '{"pattern":[100,50,100]}' })
    acceptLast(h)
    await patterned

    const bare = h.craft.haptics.vibrate()
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'vibrate', d: '{"pattern":[]}' })
    acceptLast(h)
    await bare
  })

  it('settles the helpers on a host with nothing to play, and rejects the raw call', async () => {
    // WebView2 is the Windows host, which answers PLATFORM_NOT_SUPPORTED for
    // every namespace it does not serve.
    const h = loadBridge('webview2')

    const helper = h.craft.haptics.selection()
    refuseLast(h)
    expect(await helper).toBeUndefined()

    const raw = h.craft.haptic('selection').then(() => 'resolved', (e: any) => e)
    refuseLast(h)
    expect(await raw).toMatchObject({ code: 'PLATFORM_NOT_SUPPORTED' })
  })

  it('still rejects a helper when native fails for any other reason', async () => {
    const h = loadBridge()
    const helper = h.craft.haptics.impact('heavy').then(() => 'resolved', (e: any) => e)
    refuseLast(h, 'NATIVE_CALL_FAILED')
    expect(await helper).toMatchObject({ code: 'NATIVE_CALL_FAILED' })
  })
})

describe('craft-native haptics on desktop', () => {
  const globals = globalThis as any
  const hadWindow = 'window' in globals
  const previous = globals.window

  afterEach(() => {
    if (hadWindow)
      globals.window = previous
    else
      delete globals.window
  })

  it('reaches the desktop bridge through the same helper the phones use', async () => {
    const h = loadBridge()
    globals.window = h.win

    const selection = haptics.selection()
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'haptic', d: '{"style":"selection"}' })
    acceptLast(h)
    await selection

    const impact = haptics.impact('heavy')
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'haptic', d: '{"style":"heavy"}' })
    acceptLast(h)
    await impact

    const notification = haptics.notification('error')
    expect(h.sent.at(-1)).toMatchObject({ t: 'haptics', a: 'haptic', d: '{"style":"error"}' })
    acceptLast(h)
    await notification
  })
})
