import { afterEach, describe, expect, it } from 'bun:test'

/**
 * The reply-correlation contract, exercised against the real
 * `packages/zig/src/js/craft-bridge.js` — the file that ships inside the
 * binary — rather than a reimplementation of it.
 *
 * This is behavioural, not a source scan. Every test here drives the actual
 * promise machinery: call a facade, watch what goes out over
 * `webkit.messageHandlers.craft`, answer it the way native would, and check
 * which promise settles with what. A source scan cannot tell whether the
 * right caller was resolved, and that is the entire bug.
 */

const BRIDGE_SRC = await Bun.file(
  new URL('../../../zig/src/js/craft-bridge.js', import.meta.url),
).text()

interface Envelope { t: string, a: string, d?: string, i?: number }

interface Harness {
  craft: any
  /** Every message the page posted to native, in order. */
  sent: Envelope[]
  /** Native answering a call, the way `sendResultToJS` does. */
  reply: (action: string, payload: unknown, id: number | null) => void
  /** Native failing a call, the way `sendErrorToJS` does. */
  fail: (err: { action?: string, code?: string, message?: string, id?: number }) => void
  win: any
  errors: unknown[][]
}

/**
 * Run craft-bridge.js in a synthetic window.
 *
 * The script is an IIFE that reads bare `window`, `document` and `console`, so
 * they can simply be passed in as parameters — no DOM, no jsdom, and nothing
 * shared between tests.
 */
/**
 * The bridge's timers. A test that sends without answering (an id check, a
 * fire-and-forget) leaves its call's timeout running; left alone it rejects
 * during whatever test runs then, as an unhandled error that fails that one.
 * Each test's bridge stops when the test does.
 */
const timers = new Set<ReturnType<typeof setTimeout>>()
const bridgeSetTimeout = (run: (...args: unknown[]) => void, ms?: number, ...args: unknown[]) => {
  const timer = setTimeout(() => { timers.delete(timer); run(...args) }, ms)
  timers.add(timer)
  return timer
}
const bridgeClearTimeout = (timer: ReturnType<typeof setTimeout>) => {
  timers.delete(timer)
  clearTimeout(timer)
}
afterEach(() => {
  for (const timer of timers) clearTimeout(timer)
  timers.clear()
})

function loadBridge(platform: 'webkit' | 'webview2' = 'webkit'): Harness {
  const sent: Envelope[] = []
  const errors: unknown[][] = []
  const win: any = {
    addEventListener: () => {},
    removeEventListener: () => {},
    // The script fires `craft:ready` on load.
    dispatchEvent: () => true,
  }
  if (platform === 'webkit') {
    win.webkit = { messageHandlers: { craft: { postMessage: (m: Envelope) => { sent.push(m) } } } }
  }
  else {
    win.chrome = { webview: { postMessage: (m: Envelope) => { sent.push(m) } } }
  }
  const doc: any = { readyState: 'complete', addEventListener: () => {} }
  const console_: any = { ...console, error: (...a: unknown[]) => { errors.push(a) }, warn: () => {} }

  // eslint-disable-next-line no-new-func
  const run = new Function('window', 'document', 'console', 'setTimeout', 'clearTimeout', 'setInterval', BRIDGE_SRC)
  run(win, doc, console_, bridgeSetTimeout, bridgeClearTimeout, () => 0)

  return {
    craft: win.craft,
    sent,
    win,
    errors,
    reply: (action, payload, id) => {
      // Mirrors formatResultJS: three arguments, `null` when there is no id.
      win.__craftBridgeResult(action, payload, id)
    },
    fail: err => win.__craftBridgeError(err),
  }
}

/** Let queued promise callbacks run. */
const settle = () => new Promise(r => setTimeout(r, 0))

/**
 * Capture a promise's outcome now, so several promises can reject on the same
 * tick without any of them being momentarily unhandled. Resolves to the
 * rejection reason, or to `'resolved'` if it settled the other way.
 */
function settled(p: Promise<unknown>): Promise<unknown> {
  return p.then(() => 'resolved', (e: unknown) => e)
}

describe('bridge reply correlation', () => {
  it('selects native menu bar visibility explicitly and never silently downgrades an unknown backend', async () => {
    const h = loadBridge()
    await h.craft.menubar.init({ backend: 'nativeVisibility' })
    expect(h.sent.at(-1)).toMatchObject({ t: 'menubarCollapse', a: 'init', d: '{"backend":"nativeVisibility","preserveSystemItems":true}' })
    await h.craft.menubar.init({ backend: 'nativeVisibility', preserveSystemItems: false })
    expect(h.sent.at(-1)).toMatchObject({ t: 'menubarCollapse', a: 'init', d: '{"backend":"nativeVisibility","preserveSystemItems":false}' })
    await h.craft.menubar.destroy()
    expect(h.sent.at(-1)).toMatchObject({ t: 'menubarCollapse', a: 'destroy' })
    const count = h.sent.length
    await expect(h.craft.menubar.init({ backend: 'unknown' })).rejects.toThrow('Unknown menu bar backend')
    await expect(h.craft.menubar.init({ backend: '' })).rejects.toThrow('Unknown menu bar backend')
    await expect(h.craft.menubar.init({ backend: 'nativeVisibility', preserveSystemItems: 'false' })).rejects.toThrow('preserveSystemItems must be a boolean')
    expect(h.sent).toHaveLength(count)
  })

  it('posts notification show with zero delay', async () => {
    const h = loadBridge()
    await h.craft.notifications.show({ title: 'Now' })
    expect(h.sent.at(-1)).toMatchObject({ t: 'notification', a: 'schedule', d: '{"title":"Now","delay":0}' })
    await h.craft.notifications.show({ title: 'Later', delay: 30 })
    expect(h.sent.at(-1)).toMatchObject({ t: 'notification', a: 'schedule', d: '{"title":"Later","delay":30}' })
  })

  it('queries a delivered notification by ID and interprets native booleans', async () => {
    const h = loadBridge()
    const found = h.craft.notifications.hasDelivered('sample-1')
    expect(h.sent.at(-1)).toMatchObject({ t: 'notification', a: 'hasDelivered', d: '{"id":"sample-1"}' })
    h.reply('hasDelivered', true, h.sent.at(-1)!.i!)
    expect(await found).toBe(true)
    const absent = h.craft.notifications.hasDelivered('missing')
    h.reply('hasDelivered', false, h.sent.at(-1)!.i!)
    expect(await absent).toBe(false)
  })

  it('accepts both native notification permission reply shapes', async () => {
    const h = loadBridge()
    const mac = h.craft.notifications.requestPermission()
    h.reply('requestPermission', 'granted', h.sent.at(-1)!.i!)
    expect(await mac).toBe(true)

    const linux = h.craft.notifications.requestPermission()
    h.reply('requestPermission', { granted: true }, h.sent.at(-1)!.i!)
    expect(await linux).toBe(true)
  })

  it('passes a provisional notification request to the native bridge', async () => {
    const h = loadBridge()
    const request = h.craft.notifications.requestPermission({ provisional: true })
    expect(h.sent.at(-1)).toMatchObject({ t: 'notification', a: 'requestPermission', d: '{"provisional":true}' })
    h.reply('requestPermission', 'granted', h.sent.at(-1)!.i!)
    expect(await request).toBe(true)
  })

  it('reports the native notification authorization status separately from permission requests', async () => {
    const h = loadBridge()
    const status = h.craft.notifications.getPermissionStatus()
    expect(h.sent.at(-1)).toMatchObject({ t: 'notification', a: 'getPermissionStatus' })
    h.reply('getPermissionStatus', 'denied', h.sent.at(-1)!.i!)
    expect(await status).toBe('denied')
  })

  it('reports a denied macOS notification permission separately from delivery', async () => {
    const h = loadBridge()
    const denied = h.craft.notifications.requestPermission()
    h.reply('requestPermission', 'denied', h.sent.at(-1)!.i!)
    expect(await denied).toBe(false)
    expect(h.sent.map(message => message.a)).toEqual(['requestPermission'])
  })

  it('keeps an authorization failure distinct from the separately queried status', async () => {
    const h = loadBridge()
    const request = h.craft.notifications.requestPermission({ provisional: true })
    h.fail({ action: 'requestPermission', code: 'NATIVE_CALL_FAILED', message: 'Notifications are not allowed for this application', id: h.sent.at(-1)!.i! })
    await expect(request).rejects.toMatchObject({ code: 'NATIVE_CALL_FAILED' })

    const status = h.craft.notifications.getPermissionStatus()
    h.reply('getPermissionStatus', 'denied', h.sent.at(-1)!.i!)
    expect(await status).toBe('denied')
  })

  it('uses WebView2 when WebKit is absent and preserves the reply id', async () => {
    const h = loadBridge('webview2')
    const pending = h.craft.tags.get('/windows')
    expect(h.sent).toHaveLength(1)
    expect(h.sent[0]).toMatchObject({ t: 'tags', a: 'get' })
    expect(h.sent[0].i).toBeGreaterThan(0)
    h.reply('get', { tags: ['native'] }, h.sent[0].i!)
    expect(await pending).toEqual(['native'])

    // A page may expose a partial `webkit` object without Craft's handler.
    // It must still use the authenticated WebView2 transport.
    h.win.webkit = { messageHandlers: {} }
    const next = h.craft.tags.get('/windows-next')
    expect(h.sent).toHaveLength(2)
    h.reply('get', { tags: ['again'] }, h.sent[1].i!)
    expect(await next).toEqual(['again'])
  })

  it('preserves JSON null for local and named script results on both desktop transports', async () => {
    for (const platform of ['webkit', 'webview2'] as const) {
      const h = loadBridge(platform)
      const local = h.craft.window._call('executeJavaScript', { code: 'undefined' }, 'main')
      h.reply('executeJavaScript', null, h.sent.at(-1)!.i!)
      expect(await local).toBeNull()

      const named = h.craft.window._call('executeJavaScript', { code: 'null' }, 'settings')
      h.reply('executeJavaScript', null, h.sent.at(-1)!.i!)
      expect(await named).toBeNull()

      // Keep the legacy empty-response behavior for unrelated actions.
      const title = h.craft.window._call('getTitle', {}, 'settings')
      h.reply('getTitle', null, h.sent.at(-1)!.i!)
      expect(await title).toEqual({})
    }
  })

  it('gives each caller its own answer when two bridges share an action name', async () => {
    // `get` is served by both keychain and tags. Before request ids, both
    // callers queued under the string "get" and were matched by arrival order,
    // so answering out of order swapped the payloads.
    const h = loadBridge()

    const keychain = h.craft.keychain.get('svc', 'acct')
    const tags = h.craft.tags.get('/some/file')

    expect(h.sent).toHaveLength(2)
    const [keychainMsg, tagsMsg] = h.sent
    expect(keychainMsg.t).toBe('keychain')
    expect(tagsMsg.t).toBe('tags')
    expect(keychainMsg.i).toBeDefined()
    expect(tagsMsg.i).not.toBe(keychainMsg.i)

    // Native answers the second call first — the case that used to swap.
    h.reply('get', { tags: ['red'] }, tagsMsg.i!)
    h.reply('get', { value: 'hunter2' }, keychainMsg.i!)

    expect(await keychain).toBe('hunter2')
    expect(await tags).toEqual(['red'])
  })

  it('would have swapped those payloads without the ids', async () => {
    // The control. Same two calls, answered in the same order, but as a
    // pre-id binary would answer them: no id, so the action-name queue picks
    // the head. keychain asked first, so keychain is handed the tags payload
    // and reads `undefined` off it. This is the bug, reproduced.
    const h = loadBridge()

    const keychain = h.craft.keychain.get('svc', 'acct')
    const tags = h.craft.tags.get('/some/file')

    h.reply('get', { tags: ['red'] }, null)
    h.reply('get', { value: 'hunter2' }, null)

    expect(await keychain).toBeUndefined()
    expect(await tags).toEqual([])
  })

  it('resolves the right caller among several calls to one action on one bridge', async () => {
    const h = loadBridge()
    const a = h.craft.tags.get('/a')
    const b = h.craft.tags.get('/b')
    const c = h.craft.tags.get('/c')

    const ids = h.sent.map(m => m.i!)
    expect(new Set(ids).size).toBe(3)

    // Answer middle, last, first.
    h.reply('get', { tags: ['B'] }, ids[1])
    h.reply('get', { tags: ['C'] }, ids[2])
    h.reply('get', { tags: ['A'] }, ids[0])

    expect(await a).toEqual(['A'])
    expect(await b).toEqual(['B'])
    expect(await c).toEqual(['C'])
  })

  it('rejects only the call that failed, not everything sharing its name', async () => {
    // `isEnabled` is served by autoLaunch, bluetooth and crashReporter.
    // Draining by action name rejected callers of all three.
    const h = loadBridge()

    const autoLaunch = h.craft.autoLaunch.isEnabled()
    const bluetooth = h.craft.bluetooth.isEnabled()
    const bluetoothId = h.sent[1].i!

    h.fail({ action: 'isEnabled', code: 'NATIVE_CALL_FAILED', message: 'no bluetooth', id: bluetoothId })

    await expect(bluetooth).rejects.toMatchObject({ message: 'no bluetooth' })

    // autoLaunch never heard about it and still answers normally.
    h.reply('isEnabled', { value: true }, h.sent[0].i!)
    expect(await autoLaunch).toBe(true)
  })

  it('would have rejected the innocent caller without the id', async () => {
    // The control for the test above.
    const h = loadBridge()
    // Outcomes are captured synchronously: both reject on the same tick, and
    // awaiting them one after the other would leave the second unhandled.
    const autoLaunch = settled(h.craft.autoLaunch.isEnabled())
    const bluetooth = settled(h.craft.bluetooth.isEnabled())

    h.fail({ action: 'isEnabled', code: 'NATIVE_CALL_FAILED', message: 'no bluetooth' })

    expect(await bluetooth).toMatchObject({ message: 'no bluetooth' })
    expect(await autoLaunch).toMatchObject({ message: 'no bluetooth' })
  })

  it('drops a reply for an id it does not know instead of giving it to someone else', async () => {
    const h = loadBridge()
    const pending = h.craft.tags.get('/a')
    const id = h.sent[0].i!

    // A late or duplicated reply for a call that already settled. The old code
    // had no way to tell, and would have handed this to the waiting caller.
    h.reply('get', { tags: ['GHOST'] }, id + 999)
    await settle()

    h.reply('get', { tags: ['MINE'] }, id)
    expect(await pending).toEqual(['MINE'])
  })

  it('answers a call once — a duplicate reply changes nothing', async () => {
    const h = loadBridge()
    const p = h.craft.tags.get('/a')
    const id = h.sent[0].i!

    h.reply('get', { tags: ['first'] }, id)
    h.reply('get', { tags: ['second'] }, id)

    expect(await p).toEqual(['first'])
  })

  it('still resolves a reply that arrives without an id', async () => {
    // Not version skew — this file is embedded in the binary, so the two
    // always match. It is for replies raised outside any dispatch, where
    // native has no request to name.
    const h = loadBridge()
    const p = h.craft.tags.get('/a')
    h.reply('get', { tags: ['ok'] }, null)
    expect(await p).toEqual(['ok'])
  })

  it('puts a distinct id on every message, fire-and-forget included', async () => {
    const h = loadBridge()
    const tags = h.craft.tags.get('/a')
    h.craft.permissions.openSettings('camera') // _send, no reply expected
    h.craft.window.show?.()
    const autoLaunch = h.craft.autoLaunch.isEnabled()

    const ids = h.sent.map(m => m.i)
    expect(ids.every(i => typeof i === 'number' && i > 0)).toBe(true)
    expect(new Set(ids).size).toBe(ids.length)
    h.reply('get', { tags: [] }, h.sent[0].i!)
    h.reply('isEnabled', { value: true }, h.sent.at(-1)!.i!)
    await Promise.all([tags, autoLaunch])
  })

  it('reports a fire-and-forget failure rather than rejecting a live call', async () => {
    const h = loadBridge()
    const live = h.craft.tags.get('/a')
    const liveId = h.sent[0].i!

    h.craft.permissions.openSettings('camera')
    const sendId = h.sent[1].i!
    expect(sendId).not.toBe(liveId)

    // `_send` registered no pending entry, so there is nobody to reject.
    h.fail({ action: 'openSettings', code: 'NATIVE_CALL_FAILED', message: 'settings unavailable', id: sendId })
    expect(h.errors).toHaveLength(1)

    h.reply('get', { tags: ['fine'] }, liveId)
    expect(await live).toEqual(['fine'])
  })

  it('keeps native dialogs pending until selection or cancellation while machine requests still expire', async () => {
    const h = loadBridge()
    h.win.__craftBridgeRequestTimeoutMs = 1
    const selected = h.craft.dialog.showOpenDialog({ properties: ['openDirectory'] })
    const selectedId = h.sent.at(-1)!.i!
    const cancelled = h.craft.dialog.showOpenDialog({ properties: ['openDirectory'] })
    const cancelledId = h.sent.at(-1)!.i!
    const failed = h.craft.dialog.showSaveDialog({})
    const failedId = h.sent.at(-1)!.i!
    // User-controlled dialogs must not schedule a machine timeout at all.
    expect(timers.size).toBe(0)
    await expect(h.craft.tags.get('/a')).rejects.toThrow(/timed out/)
    expect(h.win.__craftBridgeById[selectedId]).toBeDefined()
    expect(h.win.__craftBridgeById[cancelledId]).toBeDefined()
    h.reply('openFolder', { canceled: true, filePaths: [] }, cancelledId)
    h.reply('openFolder', { canceled: false, filePaths: ['/selected'] }, selectedId)
    h.fail({ action: 'saveFile', code: 'NATIVE_CALL_FAILED', message: 'native panel failed', id: failedId })
    await expect(failed).rejects.toThrow('native panel failed')
    expect(await cancelled).toMatchObject({ canceled: true, filePaths: [] })
    expect(await selected).toMatchObject({ canceled: false, filePaths: ['/selected'] })
    expect(Object.keys(h.win.__craftBridgeById)).toHaveLength(0)
    expect(h.win.__craftBridgePending.openFolder).toBeUndefined()
  })

  it('forgets a timed-out call in both tables, and drops its late reply', async () => {
    const h = loadBridge()
    h.win.__craftBridgeRequestTimeoutMs = 1
    const p = h.craft.tags.get('/a')
    const id = h.sent[0].i!

    await expect(p).rejects.toThrow(/timed out/)

    expect(h.win.__craftBridgeById[id]).toBeUndefined()
    expect(h.win.__craftBridgePending.get).toBeUndefined()

    // The late reply lands on an empty table and goes nowhere. Nothing to
    // assert but the absence of a throw — and that the next call is unaffected.
    h.reply('get', { tags: ['late'] }, id)

    h.win.__craftBridgeRequestTimeoutMs = 30000
    const next = h.craft.tags.get('/b')
    h.reply('get', { tags: ['next'] }, h.sent[1].i!)
    expect(await next).toEqual(['next'])
  })

  it('leaves no entry behind after a call settles', async () => {
    const h = loadBridge()
    const p = h.craft.tags.get('/a')
    h.reply('get', { tags: [] }, h.sent[0].i!)
    await p

    expect(Object.keys(h.win.__craftBridgeById)).toHaveLength(0)
    expect(Object.keys(h.win.__craftBridgePending)).toHaveLength(0)
  })

  it('still drops every pending call when native reports an unattributable failure', async () => {
    // An error with neither id nor action means the bridge itself is in
    // trouble; nobody should be left hanging.
    const h = loadBridge()
    const a = settled(h.craft.tags.get('/a'))
    const b = settled(h.craft.autoLaunch.isEnabled())

    h.fail({ code: 'NATIVE_CALL_FAILED', message: 'bridge down' })

    expect(await a).toMatchObject({ message: 'bridge down' })
    expect(await b).toMatchObject({ message: 'bridge down' })
    expect(Object.keys(h.win.__craftBridgeById)).toHaveLength(0)
  })
})

describe('native background deadlines', () => {
  it('correlates concurrent deadlines in completion order without DOM timeouts', async () => {
    const h = loadBridge()
    h.win.__craftBridgeRequestTimeoutMs = 1
    const order: string[] = []
    const slow = h.craft.timers.sleep(65000).then(() => { order.push('slow') })
    const fast = h.craft.timers.sleep(5).then(() => { order.push('fast') })
    const requests = h.sent.filter(m => m.t === 'timers' && m.a === 'sleep')
    expect(requests).toHaveLength(2)
    expect(JSON.parse(requests[0]!.d!).delayMs).toBe(65000)
    await new Promise(resolve => setTimeout(resolve, 10))
    expect(order).toEqual([])
    h.reply('sleep', { fired: true }, requests[1]!.i!)
    await fast
    h.reply('sleep', { fired: true }, requests[0]!.i!)
    await slow
    expect(order).toEqual(['fast', 'slow'])
  })

  it('confirms native cancellation before rejecting and releases both requests', async () => {
    const h = loadBridge()
    const controller = new AbortController()
    const waiting = h.craft.timers.sleep(60000, { signal: controller.signal })
    let rejected = false
    void waiting.catch(() => { rejected = true })
    controller.abort()
    await settle()
    expect(rejected).toBe(false)
    const sleep = h.sent.find(m => m.a === 'sleep')!
    const cancel = h.sent.find(m => m.a === 'cancel')!
    expect(JSON.parse(cancel.d!).timerId).toBe(JSON.parse(sleep.d!).timerId)
    // WebKit can deliver the acknowledgements in either order.
    h.reply('cancel', { cancelled: true }, cancel.i!)
    await settle()
    expect(rejected).toBe(false)
    h.reply('sleep', { fired: false }, sleep.i!)
    await expect(waiting).rejects.toHaveProperty('name', 'AbortError')
    expect(Object.keys(h.win.__craftBridgeById)).toHaveLength(0)
  })

  it('does not post invalid or already aborted deadlines', async () => {
    const h = loadBridge()
    const controller = new AbortController()
    controller.abort()
    await expect(h.craft.timers.sleep(1, { signal: controller.signal })).rejects.toHaveProperty('name', 'AbortError')
    for (const ms of [-1, NaN, 0.5, 86400001]) await expect(h.craft.timers.sleep(ms)).rejects.toBeInstanceOf(RangeError)
    expect(h.sent.filter(m => m.t === 'timers')).toHaveLength(0)
  })
})


it('awaits native Keychain writes and deletes and propagates storage failures', async () => {
  const h = loadBridge()
  let saved = false
  const write = h.craft.keychain.set('svc', 'acct', 'pw').then(() => { saved = true })
  await Promise.resolve()
  expect(saved).toBe(false)
  h.reply('set', { ok: true }, h.sent[0].i!)
  await write
  expect(saved).toBe(true)
  const remove = h.craft.keychain.delete('svc', 'acct')
  h.fail({ action: 'delete', code: 'PERMISSION_DENIED', message: 'keychain locked', id: h.sent[1].i! })
  await expect(remove).rejects.toThrow('keychain locked')
  const denied = h.craft.keychain.set('svc', 'acct', 'pw')
  h.fail({ action: 'set', code: 'PERMISSION_DENIED', message: 'access denied', id: h.sent[2].i! })
  await expect(denied).rejects.toThrow('access denied')
})


it('keeps Keychain authentication pending until macOS answers without timing out the user', async () => {
  const h = loadBridge()
  h.win.__craftBridgeRequestTimeoutMs = 1
  const read = h.craft.keychain.get('svc', 'acct')
  const readId = h.sent.at(-1)!.i!
  const write = h.craft.keychain.set('svc', 'acct', 'pw')
  const writeId = h.sent.at(-1)!.i!
  expect(timers.size).toBe(0)
  await expect(h.craft.tags.get('/a')).rejects.toThrow(/timed out/)
  expect(h.win.__craftBridgeById[readId]).toBeDefined()
  h.reply('get', { value: 'saved' }, readId)
  h.fail({ action: 'set', code: 'CANCELLED', message: 'user cancelled authentication', id: writeId })
  expect(await read).toBe('saved')
  await expect(write).rejects.toThrow('user cancelled authentication')
  expect(Object.keys(h.win.__craftBridgeById)).toHaveLength(0)
})
