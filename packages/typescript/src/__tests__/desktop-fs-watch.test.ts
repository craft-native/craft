import { afterEach, describe, expect, it } from 'bun:test'
import { watch } from '../api/fs'

/**
 * `craft.fs.watch` in a desktop window, driven through the real
 * `packages/zig/src/js/craft-bridge.js`.
 *
 * It used to post `{path, callbackId}` with no `id`, which `bridge_fs.zig`'s
 * watch rejects with MISSING_DATA — and as a fire-and-forget `_send`, the
 * rejection reached nobody. These pin the contract both halves now share: the
 * page names the watch, native registers it under that `id` and answers
 * `{id}`, a `craft:fs:change` event carries the id back, and `unwatch` sends
 * the same id.
 */

const BRIDGE_SRC = await Bun.file(
  new URL('../../../zig/src/js/craft-bridge.js', import.meta.url),
).text()

interface Envelope { t: string, a: string, d?: string, i?: number }

interface Harness {
  craft: any
  sent: Envelope[]
  win: any
  /** Dispatch `craft:fs:change` the way native would, with `detail`. */
  change: (detail: Record<string, unknown>) => void
}

/**
 * Run craft-bridge.js in a synthetic window, as `desktop-haptics.test.ts`
 * does — but with a real event target, since watch delivery is events.
 */
function loadBridge(): Harness {
  const sent: Envelope[] = []
  const events = new EventTarget()
  const win: any = {
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    dispatchEvent: events.dispatchEvent.bind(events),
    webkit: { messageHandlers: { craft: { postMessage: (m: Envelope) => { sent.push(m) } } } },
  }
  const doc: any = { readyState: 'complete', addEventListener: () => {} }
  const console_: any = { ...console, error: () => {}, warn: () => {} }

  // eslint-disable-next-line no-new-func
  const run = new Function('window', 'document', 'console', 'setTimeout', 'clearTimeout', 'setInterval', BRIDGE_SRC)
  run(win, doc, console_, setTimeout, clearTimeout, () => 0)

  return {
    craft: win.craft,
    sent,
    win,
    change: detail => win.dispatchEvent(new CustomEvent('craft:fs:change', { detail })),
  }
}

/** The fs messages posted so far for `action`, payloads parsed. */
function posted(h: Harness, action: string): Array<{ i?: number, d: any }> {
  return h.sent
    .filter(m => m.t === 'fs' && m.a === action)
    .map(m => ({ i: m.i, d: JSON.parse(m.d || '{}') }))
}

/** Answer the last `watch` the way `bridge_fs.zig` does: `{id}`, stamped. */
function acceptWatch(h: Harness): string {
  const last = posted(h, 'watch').at(-1)!
  h.win.__craftBridgeResult('watch', { id: last.d.id }, last.i)
  return last.d.id
}

describe('desktop fs.watch bridge', () => {
  it('names the watch and posts the id, path and recursive flag native reads', async () => {
    const h = loadBridge()
    const pending = h.craft.fs.watch('/tmp/project', () => {}, { recursive: true })

    const [msg] = posted(h, 'watch')
    expect(typeof msg.i).toBe('number')
    expect(typeof msg.d.id).toBe('string')
    expect(msg.d.id.length).toBeGreaterThan(0)
    expect(msg.d).toEqual({ id: msg.d.id, path: '/tmp/project', recursive: true })

    acceptWatch(h)
    const handle = await pending
    expect(handle.id).toBe(msg.d.id)
    expect(typeof handle.unwatch).toBe('function')
  })

  it('defaults recursive to false, as native does', async () => {
    const h = loadBridge()
    const pending = h.craft.fs.watch('/tmp/a')
    expect(posted(h, 'watch')[0].d.recursive).toBe(false)
    acceptWatch(h)
    await pending
  })

  it('gives every watch its own id', async () => {
    const h = loadBridge()
    const first = h.craft.fs.watch('/tmp/a', () => {})
    acceptWatch(h)
    const second = h.craft.fs.watch('/tmp/a', () => {})
    acceptWatch(h)
    expect((await first).id).not.toBe((await second).id)
  })

  it('delivers a change only to the watch whose id it carries', async () => {
    const h = loadBridge()
    const heardA: any[] = []
    const heardB: any[] = []
    const a = h.craft.fs.watch('/tmp/a', (e: any) => heardA.push(e))
    acceptWatch(h)
    const b = h.craft.fs.watch('/tmp/b', (e: any) => heardB.push(e))
    acceptWatch(h)
    const [ha, hb] = [await a, await b]

    h.change({ id: ha.id, type: 'modify', path: '/tmp/a/x.txt' })
    h.change({ id: hb.id, type: 'create', path: '/tmp/b/y.txt' })
    h.change({ id: 'someone-else', type: 'delete', path: '/tmp/c' })

    expect(heardA).toEqual([{ id: ha.id, type: 'modify', path: '/tmp/a/x.txt' }])
    expect(heardB).toEqual([{ id: hb.id, type: 'create', path: '/tmp/b/y.txt' }])
  })

  it('unwatches by the same id, stops delivering, and does so once', async () => {
    const h = loadBridge()
    const heard: any[] = []
    const pending = h.craft.fs.watch('/tmp/a', (e: any) => heard.push(e))
    const id = acceptWatch(h)
    const handle = await pending

    await handle.unwatch()
    expect(posted(h, 'unwatch').map(m => m.d)).toEqual([{ id }])

    h.change({ id, type: 'modify', path: '/tmp/a' })
    expect(heard).toEqual([])

    // A second stop, by the handle or by id, posts nothing more.
    await handle.unwatch()
    await h.craft.fs.unwatch(id)
    expect(posted(h, 'unwatch')).toHaveLength(1)
  })

  it('craft.fs.unwatch(id) stops a watch the same way the handle does', async () => {
    const h = loadBridge()
    const heard: any[] = []
    const pending = h.craft.fs.watch('/tmp/a', (e: any) => heard.push(e))
    const id = acceptWatch(h)
    await pending

    await h.craft.fs.unwatch(id)
    expect(posted(h, 'unwatch').map(m => m.d)).toEqual([{ id }])
    h.change({ id, type: 'modify', path: '/tmp/a' })
    expect(heard).toEqual([])
  })

  it('rejects when native refuses, and leaves no listener behind', async () => {
    // Linux and Windows do not route the fs namespace.
    const h = loadBridge()
    const heard: any[] = []
    const pending = h.craft.fs.watch('/tmp/a', (e: any) => heard.push(e)).then(() => 'resolved', (e: any) => e)
    const last = posted(h, 'watch').at(-1)!
    h.win.__craftBridgeError({ action: 'watch', code: 'PLATFORM_NOT_SUPPORTED', message: 'refused', id: last.i })
    expect(await pending).toMatchObject({ code: 'PLATFORM_NOT_SUPPORTED' })

    h.change({ id: last.d.id, type: 'modify', path: '/tmp/a' })
    expect(heard).toEqual([])
    // Nothing registered, so nothing to unwatch.
    await h.craft.fs.unwatch(last.d.id)
    expect(posted(h, 'unwatch')).toHaveLength(0)
  })
})

describe('craft-native watch on desktop', () => {
  const globals = globalThis as any
  const hadWindow = 'window' in globals
  const previous = globals.window

  afterEach(() => {
    if (hadWindow)
      globals.window = previous
    else
      delete globals.window
  })

  it('goes through window.craft.fs.watch and unwatches by the same id', async () => {
    const h = loadBridge()
    globals.window = h.win

    const heard: Array<[string, string]> = []
    const pending = watch('/tmp/project', (event, filename) => heard.push([event, filename]))
    const [msg] = posted(h, 'watch')
    // The SDK's default is recursive, and it is passed through.
    expect(msg.d).toMatchObject({ path: '/tmp/project', recursive: true })
    const id = acceptWatch(h)
    const stop = await pending

    h.change({ id, type: 'modify', path: '/tmp/project/a.ts' })
    expect(heard).toEqual([['modify', '/tmp/project/a.ts']])

    stop()
    expect(posted(h, 'unwatch').map(m => m.d)).toEqual([{ id }])
  })
})
