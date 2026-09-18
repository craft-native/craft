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
    // Whether the device itself can do speech, which `capabilities` ands with
    // the build flag. It follows `enabled` so that turning speech on in a
    // test describes a device that can serve it.
    .replace('${SpeechRecognizer.isRecognitionAvailable(activity)}', String(enabled))
    // The rest of the Kotlin string templates, `${isBiometricAvailable()}` and
    // the like. Each is a Boolean in the capabilities object.
    .replace(/\$\{(?:[^{}]|\{[^{}]*\})*\}/g, 'false')
  if (/\{\{|\$/.test(script)) throw new Error('the page script still holds a template placeholder')
  return script
}

type Listener = (event: { type: string, detail: unknown }) => void

/**
 * `beforeInject` runs first, the way a page's own script runs before Android
 * injects the bridge. `enabled` sets every `{{ENABLE_*}}` flag, and `answers`
 * says what a named CraftAndroid method returns, the way Kotlin answers it.
 */
function loadPage(
  beforeInject?: (page: Record<string, any>) => void,
  enabled = true,
  answers: Record<string, unknown> = {},
) {
  const calls: string[] = []
  const args: unknown[][] = []
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
  // Every method the page calls is recorded by name, and answers whatever
  // `answers` says Kotlin would. Undefined by default, which is also what a
  // WebView reports for a @JavascriptInterface method that threw.
  const CraftAndroid = new Proxy({}, {
    get: (_, name: string) => (...called: unknown[]) => {
      calls.push(name)
      args.push(called)
      const answer = answers[name]
      if (answer instanceof Error) throw answer
      return answer
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
    args,
    /** The arguments of the last call to `name`. */
    argsOf: (name: string) => args[calls.lastIndexOf(name)],
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
    // What is left answering nothing after #219: flashlight, keepAwake and
    // the flat watch API (#220). There is no promise to reject, so the call
    // no-ops, and native must not be asked to do it either.
    const page = loadPage(undefined, false)

    expect(page.craft.setKeepAwake(true)).toBeUndefined()
    expect(page.craft.toggleFlashlight()).toBeUndefined()
    expect(page.calls).toEqual([])
  })

  it('serves the same calls when the app was built with them', async () => {
    const page = loadPage()

    expect(page.craft.capabilities.share).toBe(true)
    void page.craft.share('hello')
    void page.craft.secureStore.set('k', 'v')
    // A tick, because haptic reaches native from inside a promise, so that a
    // native failure rejects rather than throwing at the caller.
    void page.craft.haptic('light')
    await tick()

    expect(page.calls).toEqual(['share', 'secureSet', 'haptic'])
  })

  // #219: all four used to return undefined, so a page that awaited one got
  // `undefined`, which reads as success, and a page written for iOS behaved
  // differently here. @JavascriptInterface answers synchronously, so the
  // answer is the Kotlin method's own return value.
  const answering: [string, string, (craft: any) => unknown][] = [
    ['haptic', 'haptic', craft => craft.haptic('light')],
    ['vibrate', 'vibrate', craft => craft.vibrate([100, 50, 100])],
    ['startListening', 'startListening', craft => craft.startListening()],
    ['stopListening', 'stopListening', craft => craft.stopListening()],
  ]

  for (const [name, method, call] of answering) {
    it(`hands ${name} the answer Kotlin returned`, async () => {
      const page = loadPage(undefined, true, { [method]: true })
      const returned = call(page.craft)

      expect(returned).toBeInstanceOf(Promise)
      expect(await returned).toBe(true)
      expect(page.calls).toContain(method)
    })

    it(`answers ${name} false when the device did not take it`, async () => {
      // Kotlin returns false, and a Kotlin method that throws reaches the
      // page as undefined. Neither is `true`, and neither may be a hang.
      const page = loadPage(undefined, true, { [method]: undefined })
      expect(await call(page.craft)).toBe(false)
    })
  }

  it('rejects, rather than throwing at the caller, when native fails', async () => {
    // An Error in `answers` is thrown, the way a @JavascriptInterface method
    // that throws reaches the page. The caller gets a rejected promise, not
    // an exception at the call site, which is why the call sits in `.then`.
    const page = loadPage(undefined, true, { haptic: new Error('Vibrator died') })

    let returned: Promise<unknown> | undefined
    expect(() => { returned = page.craft.haptic('light') }).not.toThrow()
    await expect(returned).rejects.toThrow('Vibrator died')
  })

  it('lets a real native failure through haptics.impact, unlike a refusal', async () => {
    const page = loadPage(undefined, true, { haptic: new Error('Vibrator died') })
    await expect(page.craft.haptics.impact('heavy')).rejects.toThrow('Vibrator died')
  })

  it('sends vibrate the pattern as JSON, the shape Kotlin parses', async () => {
    const page = loadPage(undefined, true, { vibrate: true })
    await page.craft.vibrate([100, 50])

    expect(page.argsOf('vibrate')).toEqual(['[100,50]'])
  })

  it('refuses the three that a capability gates, now that they can carry it', async () => {
    // Before #219 these warned and returned undefined, because there was no
    // promise to reject. #209 left that note in the gate; this collects it.
    const page = loadPage(undefined, false)

    await expect(page.craft.haptic('light')).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    await expect(page.craft.vibrate([100])).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    await expect(page.craft.startListening()).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    expect(page.calls).toEqual([])
  }, 5000)

  it('leaves stopListening ungated, as iOS does', async () => {
    // Tearing a screen down must not depend on which build it runs on.
    const page = loadPage(undefined, false, { stopListening: true })

    expect(await page.craft.stopListening()).toBe(true)
    expect(page.calls).toEqual(['stopListening'])
  }, 5000)

  // The other half of #207's split, which Android could not have until
  // craft.haptic() had an answer: the raw call reports the refusal, and the
  // feedback helpers treat a capability left off as nothing to play.
  const feedback: [string, (craft: any) => Promise<unknown>][] = [
    ['impact', craft => craft.haptics.impact('heavy')],
    ['notification', craft => craft.haptics.notification('error')],
    ['selection', craft => craft.haptics.selection()],
    ['vibrate', craft => craft.haptics.vibrate([100])],
  ]

  for (const [name, call] of feedback) {
    it(`settles haptics.${name} with nothing played when haptics are off`, async () => {
      const page = loadPage(undefined, false)
      expect(await call(page.craft)).toBeUndefined()
      expect(page.calls).toEqual([])
    }, 5000)

    it(`plays haptics.${name} when the app was built with haptics`, async () => {
      const page = loadPage(undefined, true, { haptic: true, vibrate: true })
      expect(await call(page.craft)).toBeUndefined()
      expect(page.calls.length).toBe(1)
    })
  }

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
