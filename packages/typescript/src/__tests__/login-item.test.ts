import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { app } from '../api/app'

/**
 * #588: `app.setLoginItemSettings` and `getLoginItemSettings` were sent as
 * `app` actions. Native's app bridge serves neither and, outside debug builds,
 * says nothing about an unknown action, so in a WebKit host the promise never
 * settled. Login items are served by `autoLaunch` (SMAppService), which these
 * now call.
 */

let posted: Array<Record<string, unknown>> = []
let saved: unknown

beforeEach(() => {
  posted = []
  const g = globalThis as any
  g.window = g.window || {}
  saved = g.window.webkit
  g.window.webkit = { messageHandlers: { craft: { postMessage: (message: Record<string, unknown>) => posted.push(message) } } }
})

afterEach(() => {
  ;(globalThis as any).window.webkit = saved
})

/** Answer the oldest pending request in `bucket`, as native's reply does. */
function reply(bucket: string, payload: unknown): void {
  expect((globalThis as any).window.__craftBridgeResolve(bucket, payload)).toBe(true)
}

describe('login items', () => {
  it('turns open-at-login on and off through autoLaunch', async () => {
    const on = app.setLoginItemSettings({ openAtLogin: true })
    reply('autoLaunch.enable', { ok: true })
    await on
    const off = app.setLoginItemSettings({ openAtLogin: false })
    reply('autoLaunch.disable', { ok: true })
    await off
    expect(posted.map(message => message.type ?? message.t)).toEqual(['autoLaunch', 'autoLaunch'])
    expect(JSON.stringify(posted)).not.toContain('setLoginItemSettings')
  })

  it('rejects when macOS declines, instead of pretending it worked', async () => {
    const attempt = app.setLoginItemSettings({ openAtLogin: true })
    reply('autoLaunch.enable', { ok: false, reason: 'SMAppService unavailable (macOS < 13)' })
    await expect(attempt).rejects.toThrow('macOS did not register the login item: SMAppService unavailable (macOS < 13)')
  })

  it('refuses options SMAppService cannot honour', async () => {
    await expect(app.setLoginItemSettings({ openAtLogin: true, openAsHidden: true })).rejects.toThrow('supports only openAtLogin')
    await expect(app.setLoginItemSettings({ openAtLogin: true, args: ['--background'] })).rejects.toThrow('supports only openAtLogin')
    expect(posted).toEqual([])
  })

  it('reads the setting from autoLaunch.isEnabled', async () => {
    const read = app.getLoginItemSettings()
    reply('autoLaunch.isEnabled', { value: true, status: 1 })
    expect(await read).toEqual({ openAtLogin: true, openAsHidden: false, wasOpenedAtLogin: false, wasOpenedAsHidden: false })
  })

  it('the injected app module routes the same way', () => {
    const source = readFileSync(join(import.meta.dir, '../../../zig/src/js/craft-app.js'), 'utf8')
    expect(source).not.toContain("_send('setLoginItemSettings'")
    expect(source).not.toContain("_send('getLoginItemSettings'")
    expect(source).toContain('window.craft.autoLaunch.enable()')
    expect(source).toContain('window.craft.autoLaunch.isEnabled()')
  })
})
