import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from 'bun:test'
import { randomUUID } from 'node:crypto'
import { Window, windowManager } from '../api/window'

describe('typed window-handle routing', () => {
  const previousWindow = globalThis.window
  let callResult: unknown
  const call = mock(async (...args: [string, Record<string, unknown> | undefined, string]) => {
    void args
    return callResult
  })
  const open = mock(async (options: { id: string }) => ({ name: options.id }))
  const listeners = new Map<string, Set<EventListener>>()
  // The manager retains stable handles across fixtures and Bun reruns. Wall
  // clock milliseconds can collide while each test installs a fresh fake DOM.
  let clock: ReturnType<typeof spyOn>
  const fixtureId = (label: string) => `${label}-${randomUUID()}`

  beforeEach(() => {
    // Keep time fixed so reintroducing Date.now() IDs fails deterministically.
    clock = spyOn(Date, 'now').mockReturnValue(0)
    call.mockClear()
    callResult = undefined
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
    clock.mockRestore()
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
    await settings.setMinSize(320, 240)
    await settings.setMaxSize(1600, 1200)
    await settings.setBounds({ x: 40, width: 900 })
    await settings.setWindowLevel(3)

    expect(call.mock.calls.map(args => [args[0], args[2]])).toEqual([
      ['blur', 'settings'],
      ['unmaximize', 'settings'],
      ['restore', 'settings'],
      ['setMinimumSize', 'settings'],
      ['setMaximumSize', 'settings'],
      ['setMinSize', 'settings'],
      ['setMaxSize', 'settings'],
      ['setBounds', 'settings'],
      ['setWindowLevel', 'settings'],
    ])
  })

  it('routes portable controls and their readbacks to the retained child', async () => {
    const settings = new Window('settings')

    await settings.setBounds({ x: -20, width: 700 })
    await settings.center()
    await settings.setResizable(false)
    callResult = false
    expect(await settings.isResizable()).toBe(false)
    await settings.setFullscreen(true)
    await settings.toggleFullscreen()

    expect(call.mock.calls.map(args => [args[0], args[2]])).toEqual([
      ['setBounds', 'settings'],
      ['center', 'settings'],
      ['setResizable', 'settings'],
      ['isResizable', 'settings'],
      ['setFullscreen', 'settings'],
      ['toggleFullscreen', 'settings'],
    ])
    expect(call.mock.calls[0]?.[1]).toEqual({ x: -20, width: 700, animate: undefined })
    expect(call.mock.calls[2]?.[1]).toEqual({ resizable: false })
    expect(call.mock.calls[4]?.[1]).toEqual({ fullscreen: true })
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

  it('awaits JavaScript results from the retained child', async () => {
    const settings = new Window('settings')
    callResult = 'Preferences'

    await expect(settings.executeJavaScript('document.title')).resolves.toBe('Preferences')
    expect(call).toHaveBeenCalledWith(
      'executeJavaScript',
      { code: 'document.title' },
      'settings',
    )
  })

  it('keeps local evaluations on the current page and propagates native errors', async () => {
    const current = windowManager.current
    callResult = { nested: [true, 'current'] }
    await expect(current.executeJavaScript('({ nested: [true, "current"] })'))
      .resolves.toEqual({ nested: [true, 'current'] })
    expect(call).toHaveBeenCalledWith(
      'executeJavaScript',
      { code: '({ nested: [true, "current"] })' },
      'main',
    )

    const nativeError = Object.assign(new Error('evaluation failed'), { code: 'NATIVE_CALL_FAILED' })
    callResult = Promise.reject(nativeError)
    await expect(new Window('settings').executeJavaScript('throw new Error("evaluation failed")'))
      .rejects.toBe(nativeError)
    expect(call).toHaveBeenCalledWith(
      'executeJavaScript',
      { code: 'throw new Error("evaluation failed")' },
      'settings',
    )
  })

  it('destroys the retained child rather than the calling page', async () => {
    const settings = new Window('settings')

    await settings.destroy()

    expect(call).toHaveBeenCalledWith('destroy', undefined, 'settings')
    expect(settings.isClosed).toBe(true)
    expect(listeners.get('craft:window:resize')?.size ?? 0).toBe(0)
  })

  it('revives the stable SDK handle around a fresh native window after destroy', async () => {
    const id = fixtureId('destroyed')
    const first = await windowManager.create({ id, html: '<h1>First</h1>' })
    await first.destroy()

    const reopened = await windowManager.create({ id, html: '<h1>Fresh</h1>' })

    expect(reopened).toBe(first)
    expect(reopened.isClosed).toBe(false)
    expect(open).toHaveBeenCalledTimes(2)
  })

  it('creates through the injected bridge instead of the incompatible generic envelope', async () => {
    const id = fixtureId('settings')
    const created = await windowManager.create({ id, html: '<h1>Settings</h1>' })

    expect(open).toHaveBeenCalledWith({ id, html: '<h1>Settings</h1>' })
    expect(created.id).toBe(id)
  })

  it('uses the injected window envelope in WebView2 as well as WebKit', async () => {
    const host = globalThis.window as unknown as {
      webkit?: unknown
      chrome?: { webview: { postMessage: () => void } }
    }
    Reflect.deleteProperty(host, 'webkit')
    host.chrome = { webview: { postMessage: () => {} } }
    const id = fixtureId('webview2')
    const created = await windowManager.create({ id, html: '<h1>Windows</h1>' })
    await created.setTitle('Windows')
    callResult = id

    expect(open).toHaveBeenCalledWith({ id, html: '<h1>Windows</h1>' })
    expect(call).toHaveBeenCalledWith('setTitle', { title: 'Windows' }, id)
    expect(await windowManager.getFocused()).toBe(created)
    expect(call).toHaveBeenCalledWith('getFocused', undefined, 'main')
  })

  it('refuses the local main alias before opening a child window', async () => {
    await expect(windowManager.create({ id: 'main', html: '<h1>Orphan</h1>' }))
      .rejects.toThrow('reserved for the current window')
    expect(open).not.toHaveBeenCalled()
  })

  it('resolves the focused retained handle through the injected bridge', async () => {
    const id = fixtureId('focused')
    const settings = await windowManager.create({ id, html: '<h1>Settings</h1>' })
    callResult = id

    expect(await windowManager.getFocused()).toBe(settings)
    expect(call).toHaveBeenCalledWith('getFocused', undefined, 'main')
  })

  it('revives the same handle and its listeners when a named window is reopened', async () => {
    const id = fixtureId('reopened')
    const settings = await windowManager.create({ id, html: '<h1>Settings</h1>' })
    const onResize = mock(() => {})
    settings.on('resize', onResize)

    await settings.close()
    expect(settings.isClosed).toBe(true)
    expect(listeners.get('craft:window:resize')?.size).toBe(1)

    const reopened = await windowManager.create({ id, html: '<h1>Settings</h1>' })
    expect(reopened).toBe(settings)
    expect(reopened.isClosed).toBe(false)
    expect(listeners.get('craft:window:resize')?.size).toBe(1)

    const event = { detail: { windowId: id, width: 700, height: 500 } } as CustomEvent
    for (const listener of listeners.get('craft:window:resize') ?? []) listener(event)
    expect(onResize).toHaveBeenCalledWith({ windowId: id, width: 700, height: 500 })
  })

  it('keeps the current handle subscribed across a native reopen', async () => {
    const current = new Window('main')
    const onFocus = mock(() => {})
    current.on('focus', onFocus)

    await current.close()
    expect(current.isClosed).toBe(true)
    expect(listeners.get('craft:window:focus')?.size).toBe(1)

    const event = { detail: { windowId: 'main' } } as CustomEvent
    for (const listener of listeners.get('craft:window:focus') ?? []) listener(event)

    expect(current.isClosed).toBe(false)
    expect(onFocus).toHaveBeenCalledWith({ windowId: 'main' })
  })

  it('tracks native close and focus events on the local handle', () => {
    const current = new Window('main')
    const closeEvent = { detail: { windowId: 'main' } } as CustomEvent
    for (const listener of listeners.get('craft:window:close') ?? []) listener(closeEvent)
    expect(current.isClosed).toBe(true)

    const focusEvent = { detail: { windowId: 'main' } } as CustomEvent
    for (const listener of listeners.get('craft:window:focus') ?? []) listener(focusEvent)
    expect(current.isClosed).toBe(false)
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

  it('delivers a child event to its typed handle in the creator page', () => {
    const current = new Window('main')
    const settings = new Window('settings')
    const currentFocus = mock(() => {})
    const settingsFocus = mock(() => {})
    current.on('focus', currentFocus)
    settings.on('focus', settingsFocus)

    const event = { detail: { windowId: 'settings' } } as CustomEvent
    for (const listener of listeners.get('craft:window:focus') ?? []) listener(event)

    expect(settingsFocus).toHaveBeenCalledWith({ windowId: 'settings' })
    expect(currentFocus).not.toHaveBeenCalled()
  })
})
