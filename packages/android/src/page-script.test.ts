import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'
import { renderAndroidPromiseRuntime } from './promise-runtime'

// The script CraftBridge injects into every page, run here against a fake
// CraftAndroid. Nothing else runs it off a device, and a syntax error in it
// compiles fine in Kotlin and leaves window.craft undefined on the emulator.

const template = readFileSync(join(import.meta.dir, '../templates/CraftBridge.kt.template'), 'utf8')

/** The page script, as Kotlin evaluates it, with every capability on or off. */
function pageScript(enabled = true): string {
  const opening = '        val script = """\n'
  const start = template.indexOf(opening)
  if (start === -1) throw new Error('CraftBridge.kt.template no longer builds `val script = """`')
  const end = template.indexOf('\n        """.trimIndent()', start)
  const script = template
    .slice(start + opening.length, end)
    .replace(/\{\{PROMISE_RUNTIME\}\}/g, () => renderAndroidPromiseRuntime('            '))
    .replace(/\{\{ENABLE_[A-Z_]+\}\}/g, String(enabled))
    // Kotlin string templates, `${isBiometricAvailable()}` and the like. Each
    // is a Boolean in the capabilities object.
    .replace(/\$\{(?:[^{}]|\{[^{}]*\})*\}/g, 'false')
  if (/\{\{|\$/.test(script)) throw new Error('the page script still holds a template placeholder')
  return script
}

type Listener = (event: { type: string, detail: unknown }) => void

/** `beforeInject` runs first, the way a page's own script runs before Android injects the bridge. */
function loadPage(beforeInject?: (page: Record<string, any>) => void, enabled = true) {
  const calls: string[] = []
  const listeners: Record<string, Listener[]> = {}
  const page: Record<string, any> = {
    addEventListener: (type: string, listener: Listener) => {
      (listeners[type] ||= []).push(listener)
    },
    removeEventListener: (type: string, listener: Listener) => {
      listeners[type] = (listeners[type] || []).filter(existing => existing !== listener)
    },
    dispatchEvent: (event: { type: string, detail: unknown }) => {
      for (const listener of [...(listeners[event.type] || [])]) listener(event)
      return true
    },
    location: { href: 'https://appassets.androidplatform.net/index.html' },
  }
  page.window = page
  class CustomEvent {
    type: string
    detail: unknown
    constructor(type: string, options?: { detail?: unknown }) {
      this.type = type
      this.detail = options?.detail
    }
  }
  // Every method the page calls answers undefined and is recorded by name.
  const CraftAndroid = new Proxy({}, {
    get: (_, name: string) => (..._args: unknown[]) => {
      calls.push(name)
      return undefined
    },
  })
  const quiet = { log() {}, warn() {}, error() {}, info() {}, debug() {} }
  const document = { addEventListener() {}, removeEventListener() {}, visibilityState: 'visible', readyState: 'complete' }

  const inject = () => {
    // eslint-disable-next-line no-new-func
    new Function('window', 'document', 'CraftAndroid', 'CustomEvent', 'console', pageScript(enabled))(
      page,
      document,
      CraftAndroid,
      CustomEvent,
      quiet,
    )
  }
  beforeInject?.(page)
  inject()

  return {
    page,
    calls,
    inject,
    get craft() { return page.craft },
    // What CraftBridge.dispatchDeepLink evaluates, once the script has run.
    link: (url: string, initial: boolean) =>
      page.dispatchEvent(new CustomEvent('craftDeepLink', { detail: { url, initial } })),
  }
}

const tick = () => new Promise(resolve => setTimeout(resolve, 5))

describe('the injected Android page script', () => {
  // #215: every one of these received nothing before, because a link was
  // dispatched once, to whoever had subscribed by then, which was nobody.
  it('hands the launch link to a page that subscribes after it arrived', async () => {
    const page = loadPage()
    page.link('app://launch', true)

    const seen: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
    await tick()

    expect(seen).toEqual([{ url: 'app://launch', initial: true }])
  })

  it('returns an unsubscribe from onLink and onDeepLink', () => {
    const page = loadPage()
    expect(typeof page.craft.deepLinks.onLink(() => {})).toBe('function')
    expect(typeof page.craft.onDeepLink(() => {})).toBe('function')
  })

  it('leaves the launch link to getInitialURL when the page asks for it first', async () => {
    const page = loadPage()
    page.link('app://launch', true)

    const initial = page.craft.deepLinks.getInitialURL()
    const seen: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
    await tick()

    expect(seen).toEqual([])
    expect(page.calls).toContain('getInitialURL')
    page.page._craftDeepLinkResolve({ url: 'app://launch' })
    expect(await initial).toEqual({ url: 'app://launch' })
  })

  it('leaves the launch link to getInitialURL when the page asks for it second', async () => {
    const page = loadPage()
    page.link('app://launch', true)

    const seen: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
    void page.craft.deepLinks.getInitialURL()
    await tick()

    expect(seen).toEqual([])
  })

  it('delivers the launch link once to a craftReady handler that asks for it both ways', async () => {
    // The handler runs inside the script, before native has dispatched the
    // link at all, so there is nothing held yet for getInitialURL to claim.
    const seen: unknown[] = []
    let subscribed = false
    const page = loadPage((window) => {
      window.addEventListener('craftReady', () => {
        void window.craft.deepLinks.getInitialURL()
        subscribed = typeof window.craft.deepLinks.onLink((detail: unknown) => seen.push(detail)) === 'function'
      })
    })
    page.link('app://launch', true)
    await tick()

    expect(subscribed).toBe(true)
    expect(page.calls).toContain('getInitialURL')
    expect(seen).toEqual([])

    // And the subscription is live: only the launch link was held back.
    page.link('app://warm', false)
    expect(seen).toEqual([{ url: 'app://warm', initial: false }])
  })

  it('shares one replay between onDeepLink and deepLinks.onLink', async () => {
    const page = loadPage()
    page.link('app://launch', true)

    const legacy: unknown[] = []
    const current: unknown[] = []
    page.craft.onDeepLink((detail: unknown) => legacy.push(detail))
    page.craft.deepLinks.onLink((detail: unknown) => current.push(detail))
    await tick()

    expect(legacy).toEqual([{ url: 'app://launch', initial: true }])
    expect(current).toEqual([])
  })

  it('drops held links for a subscriber that unsubscribed in the same tick', async () => {
    const page = loadPage()
    page.link('app://launch', true)

    const seen: unknown[] = []
    const unsubscribe = page.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
    unsubscribe()
    await tick()
    page.link('app://warm', false)

    expect(seen).toEqual([])
  })

  it('delivers a link that arrives after subscribing once, as it arrives', async () => {
    const page = loadPage()
    const seen: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
    await tick()
    page.link('app://warm', false)

    expect(seen).toEqual([{ url: 'app://warm', initial: false }])
  })

  // #209: the flags craft.capabilities reports are enforced, as on iOS.
  it('refuses a call whose capability the app was not built with', async () => {
    const page = loadPage(undefined, false)

    expect(page.craft.capabilities.share).toBe(false)
    await expect(page.craft.share('hello')).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    await expect(page.craft.deepLinks.getInitialURL()).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    await expect(page.craft.secureStore.set('k', 'v')).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    expect(page.calls).toEqual([])
  }, 5000)

  it('refuses through the v1 contract as well, since it wraps the same call', async () => {
    const page = loadPage(undefined, false)
    await expect(page.craft.share.share({ text: 'hello' })).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  }, 5000)

  it('does nothing, rather than refusing, for a call with no answer to give', async () => {
    // haptic and vibrate still return undefined (#219), so there is no
    // promise to reject; native must not be asked to buzz either.
    const page = loadPage(undefined, false)

    expect(page.craft.haptic('light')).toBeUndefined()
    expect(page.craft.vibrate([100])).toBeUndefined()
    expect(page.calls).toEqual([])
  })

  it('serves the same calls when the app was built with them', async () => {
    const page = loadPage()

    expect(page.craft.capabilities.share).toBe(true)
    void page.craft.share('hello')
    void page.craft.secureStore.set('k', 'v')
    page.craft.haptic('light')

    expect(page.calls).toEqual(['share', 'secureSet', 'haptic'])
  })

  it('does not hand a link to a second subscriber after the script runs again in the same page', async () => {
    const page = loadPage()
    const first: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => first.push(detail))
    await tick()

    page.inject()
    page.link('app://warm', false)
    const second: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => second.push(detail))
    await tick()

    // The first subscriber heard it live. A second copy of the script that
    // buffered it again would replay it to the next subscriber as well.
    expect(first).toEqual([{ url: 'app://warm', initial: false }])
    expect(second).toEqual([])
  })
})
