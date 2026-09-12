import { afterEach, beforeEach, describe, expect, it, mock } from 'bun:test'
import { Window, windowManager } from '../api/window'

describe('typed window-handle routing', () => {
  const previousWindow = globalThis.window
  const call = mock(async (...args: [string, Record<string, unknown> | undefined, string]) => {
    void args
  })
  const open = mock(async (options: { id: string }) => ({ name: options.id }))
  const listeners = new Map<string, Set<EventListener>>()

  beforeEach(() => {
    call.mockClear()
    open.mockClear()
    listeners.clear()
    Object.defineProperty(globalThis, 'window', {
      configurable: true,
      value: {
        addEventListener: (name: string, listener: EventListener) => {
          const bucket = listeners.get(name) ?? new Set<EventListener>()
          bucket.add(listener)
          listeners.set(name, bucket)
        },
        removeEventListener: (name: string, listener: EventListener) => {
          listeners.get(name)?.delete(listener)
        },
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

  it('keeps every common mutation on the retained handle', async () => {
    const settings = new Window('settings')

    await settings.blur()
    await settings.unmaximize()
    await settings.restore()
    await settings.setMinimumSize(320, 240)
    await settings.setMaximumSize(1600, 1200)
    await settings.setBounds({ x: 40, width: 900 })
    await settings.setWindowLevel(3)

    expect(call.mock.calls.map(args => [args[0], args[2]])).toEqual([
      ['blur', 'settings'],
      ['unmaximize', 'settings'],
      ['restore', 'settings'],
      ['setMinimumSize', 'settings'],
      ['setMaximumSize', 'settings'],
      ['setBounds', 'settings'],
      ['setWindowLevel', 'settings'],
    ])
  })

  it('loads content in the retained handle instead of the calling page', async () => {
    const settings = new Window('settings')

    await settings.loadHTML('<h1>Preferences</h1>')
    await settings.loadURL('https://example.test/preferences')

    expect(call.mock.calls.map(args => [args[0], args[1], args[2]])).toEqual([
      ['loadHTML', { html: '<h1>Preferences</h1>' }, 'settings'],
      ['loadURL', { url: 'https://example.test/preferences' }, 'settings'],
    ])
  })

  it('creates through the injected bridge instead of the incompatible generic envelope', async () => {
    const id = `settings-${Date.now()}`
    const created = await windowManager.create({ id, html: '<h1>Settings</h1>' })

    expect(open).toHaveBeenCalledWith({ id, html: '<h1>Settings</h1>' })
    expect(created.id).toBe(id)
  })

  it('delivers direct native event data only to the matching local handle', () => {
    const current = new Window('main')
    const settings = new Window('settings')
    const currentResize = mock(() => {})
    const settingsResize = mock(() => {})
    current.on('resize', currentResize)
    settings.on('resize', settingsResize)

    const event = { detail: { windowId: 'main', width: 800, height: 600 } } as CustomEvent
    for (const listener of listeners.get('craft:window:resize') ?? []) listener(event)

    expect(currentResize).toHaveBeenCalledWith({ windowId: 'main', width: 800, height: 600 })
    expect(settingsResize).not.toHaveBeenCalled()
  })
})
