import { describe, expect, it } from 'bun:test'

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
function loadBridge(): Harness {
  const sent: Envelope[] = []
  const errors: unknown[][] = []
  const win: any = {
    webkit: {
      messageHandlers: {
        craft: { postMessage: (m: Envelope) => { sent.push(m) } },
      },
    },
    addEventListener: () => {},
    removeEventListener: () => {},
    // The script fires `craft:ready` on load.
    dispatchEvent: () => true,
  }
  const doc: any = { readyState: 'complete', addEventListener: () => {} }
  const console_: any = { ...console, error: (...a: unknown[]) => { errors.push(a) }, warn: () => {} }

  // eslint-disable-next-line no-new-func
  const run = new Function('window', 'document', 'console', 'setTimeout', 'clearTimeout', 'setInterval', BRIDGE_SRC)
  run(win, doc, console_, setTimeout, clearTimeout, () => 0)

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
    h.craft.tags.get('/a')
    h.craft.keychain.set('svc', 'acct', 'pw') // _send, no reply expected
    h.craft.window.show?.()
    h.craft.autoLaunch.isEnabled()

    const ids = h.sent.map(m => m.i)
    expect(ids.every(i => typeof i === 'number' && i > 0)).toBe(true)
    expect(new Set(ids).size).toBe(ids.length)
  })

  it('reports a fire-and-forget failure rather than rejecting a live call', async () => {
    const h = loadBridge()
    const live = h.craft.tags.get('/a')
    const liveId = h.sent[0].i!

    h.craft.keychain.set('svc', 'acct', 'pw')
    const sendId = h.sent[1].i!
    expect(sendId).not.toBe(liveId)

    // `_send` registered no pending entry, so there is nobody to reject.
    h.fail({ action: 'set', code: 'NATIVE_CALL_FAILED', message: 'keychain locked', id: sendId })
    expect(h.errors).toHaveLength(1)

    h.reply('get', { tags: ['fine'] }, liveId)
    expect(await live).toEqual(['fine'])
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
