import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { Window, windowManager } from '../api/window'

describe('typed window-handle routing', () => {
  const previousWindow = globalThis.window
  const call = mock(async () => undefined)
  const open = mock(async (options: { id: string }) => ({ name: options.id }))

  beforeEach(() => {
    call.mockClear()
    open.mockClear()
    Object.defineProperty(globalThis, 'window', {
      configurable: true,
      value: {
        addEventListener: () => {},
        removeEventListener: () => {},
        webkit: { messageHandlers: { craft: { postMessage: () => {} } } },
        craft: { window: { _call: call, open } },
      },
    })
  })

  afterEach(() => {
    if (previousWindow === undefined) {
      Reflect.deleteProperty(globalThis, 'window')
    }
    else {
      Object.defineProperty(globalThis, 'window', {
        configurable: true,
        value: previousWindow,
      })
    }
  })

  it('passes the retained child id to the injected bridge', async () => {
    const settings = new Window('settings')
    await settings.setTitle('Preferences')

    expect(call).toHaveBeenCalledWith(
      'setTitle',
      { title: 'Preferences' },
      'settings',
    )
  })

  it('creates through the injected bridge instead of the incompatible generic envelope', async () => {
    const id = `settings-${Date.now()}`
    const created = await windowManager.create({ id, html: '<h1>Settings</h1>' })

    expect(open).toHaveBeenCalledWith({ id, html: '<h1>Settings</h1>' })
    expect(created.id).toBe(id)
  })
})
