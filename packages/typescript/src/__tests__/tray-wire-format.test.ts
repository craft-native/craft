import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { SystemTray } from '../api/tray'

/**
 * What SystemTray actually sends to the native runtime.
 *
 * The macOS dispatcher (macos.zig, handleBridgeMessage) requires `t` and `a`
 * and drops any message without them - silently outside debug builds. The SDK
 * posted `{ type, action, data }`, so every SystemTray call was a no-op: found
 * building Uplink's menubar app, which had to drive `window.craft.tray`
 * directly. The expected shapes here are the injected bridge's (craft-bridge.js).
 */

let posted: Array<Record<string, unknown>> = []
let saved: unknown

beforeEach(() => {
  posted = []
  const g = globalThis as any
  g.window = g.window || {}
  saved = g.window.webkit
  g.window.webkit = { messageHandlers: { craft: { postMessage: (message: Record<string, unknown>) => posted.push(message) } } }
  g.window.addEventListener ??= () => {}
  g.window.removeEventListener ??= () => {}
})

afterEach(() => {
  ;(globalThis as any).window.webkit = saved
})

describe('SystemTray on macOS', () => {
  it('posts the t/a/d messages native handles', async () => {
    const tray = new SystemTray('wire')
    await tray.setTitle('Uplink')
    await tray.setTooltip('Listening')
    expect(posted).toEqual([
      { t: 'tray', a: 'setTitle', d: 'Uplink' },
      { t: 'tray', a: 'setTooltip', d: 'Listening' },
    ])
  })

  it('sends setIcon as the { icon } JSON native parses', async () => {
    await new SystemTray('icon').setIcon('antenna.radiowaves.left.and.right')
    expect(posted[0]).toEqual({ t: 'tray', a: 'setIcon', d: JSON.stringify({ icon: 'antenna.radiowaves.left.and.right' }) })
  })

  it('gives every menu item an action, which is what a click comes back as', async () => {
    const tray = new SystemTray('menu')
    await tray.setMenu([{ id: 'pause', label: 'Pause' }, { type: 'separator' }, { label: 'Quit', action: 'quit' }])
    const items = JSON.parse(String(posted[0]!.d)) as Array<Record<string, unknown>>
    expect(posted[0]!.a).toBe('setMenu')
    expect(items[0]).toMatchObject({ id: 'pause', action: 'pause' })
    expect(items[1]).not.toHaveProperty('action')
    expect(items[2]).toMatchObject({ label: 'Quit', action: 'quit' })
  })
})
