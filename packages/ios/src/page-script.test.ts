import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'

// The script CraftApp.swift injects into every page, run here against a fake
// native side. The E2E suite runs it on a simulator too, but with one config
// per run, so a path that needs a capability both on and off is checked here.

const template = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')

/**
 * Where Swift seeds the page's callback counter, standing in for a process
 * that has already handed out this many ids (#226).
 */
const SEEDED_AT = 4200

/** The page script, as the string Swift evaluates, with every flag off. */
function pageScript(seed = SEEDED_AT): string {
  const opening = 'let script = """\n            window.craft = {'
  const start = template.indexOf(opening)
  if (start === -1) throw new Error('CraftApp.swift no longer injects `window.craft = {` from `let script`')
  const end = template.indexOf('\n            """', start)
  return template
    .slice(template.indexOf('\n', start) + 1, end)
    // The one interpolation that is a number rather than a Bool: the id the
    // page counts up from, which Swift carries across loads.
    .replace('\\(highestCallbackId)', String(seed))
    // `\(config.enableHaptics)` and the like. Each is a Bool in the template.
    .replace(/\\\((?:[^()]|\([^()]*\))*\)/g, 'false')
    .replace(/\\\\/g, '\\')
}

interface Post { action: string, callbackId?: string, [key: string]: unknown }

type Listener = (event: { type: string, detail: unknown }) => void

/**
 * `beforeInject` runs first, the way a page's own script runs before WebKit's
 * didFinish injects the bridge. `seed` is what Swift interpolates as the id
 * to count up from — its own high-water mark across loads (#226).
 */
function loadPage(beforeInject?: (page: Record<string, any>) => void, seed = SEEDED_AT) {
  const posts: Post[] = []
  const listeners: Record<string, Listener[]> = {}
  const page: Record<string, any> = {
    webkit: { messageHandlers: { craft: { postMessage: (message: Post) => posts.push(message) } } },
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
    location: { href: 'craft://app/' },
  }
  class CustomEvent {
    type: string
    detail: unknown
    constructor(type: string, options?: { detail?: unknown }) {
      this.type = type
      this.detail = options?.detail
    }
  }
  const quiet = { log() {}, warn() {}, error() {} }
  beforeInject?.(page)
  // eslint-disable-next-line no-new-func
  new Function('window', 'document', 'navigator', 'CustomEvent', 'console', pageScript(seed))(
    page,
    { addEventListener() {}, readyState: 'complete' },
    {},
    CustomEvent,
    quiet,
  )

  const craft = page.craft
  /** The last message the page posted for `action`. */
  const last = (action: string): Post => {
    const post = posts.findLast(message => message.action === action)
    if (!post) throw new Error(`the page never posted ${action}`)
    return post
  }
  return {
    craft,
    last,
    count: (action: string) => posts.filter(message => message.action === action).length,
    // What Swift's resolveCallback and rejectCallback evaluate.
    answer: (action: string, value: unknown) => craft._resolveCallback(last(action).callbackId, value),
    refuse: (action: string, message: string, code: string) => craft._rejectCallback(last(action).callbackId, message, code),
    // What DeepLinkManager.dispatchDeepLink evaluates, once the script has run.
    link: (url: string, initial: boolean) =>
      page.dispatchEvent(new CustomEvent('craftDeepLink', { detail: { url, initial } })),
    // What CraftEventManager.handleNotificationResponse evaluates.
    tap: (detail: unknown) =>
      page.dispatchEvent(new CustomEvent('craftNotificationResponse', { detail })),
    receive: (detail: unknown) =>
      page.dispatchEvent(new CustomEvent('craftNotificationReceived', { detail })),
    position: (detail: unknown) =>
      page.dispatchEvent(new CustomEvent('craftLocationUpdate', { detail })),
  }
}

describe('the injected iOS page script', () => {
  // #207: each of these posted no callbackId, so Swift's reply helpers, which
  // return early on a nil id, dropped the answer and the page got undefined.
  const calls: [string, (craft: any) => unknown][] = [
    ['haptic', craft => craft.haptic('light')],
    ['vibrate', craft => craft.vibrate([100, 50, 100])],
    ['startListening', craft => craft.startListening()],
    ['stopListening', craft => craft.stopListening()],
    ['watchPosition', craft => craft.geolocation.watchPosition(() => {})],
  ]

  for (const [action, call] of calls) {
    it(`hands ${action} the answer native sends`, async () => {
      const page = loadPage()
      const returned = call(page.craft)

      expect(page.last(action).callbackId).toMatch(/^cb_\d+$/)
      expect(returned).toBeInstanceOf(Promise)
      page.answer(action, true)
      expect(await returned).toBe(true)
    })
  }

  it('settles a legacy clear with no active watch without posting a redundant stop', async () => {
    const page = loadPage()
    expect(await page.craft.geolocation.clearWatch()).toBe(true)
    expect(page.count('clearWatch')).toBe(0)
  })

  // #226: the counter restarted at 0 on every injection, so the seventh call
  // of a reloaded page drew `cb_7` again — and an answer still owed to the
  // previous page's `cb_7` settled it, with that call's result or its TIMEOUT.
  it('counts up from where Swift says the last load left off', async () => {
    const page = loadPage()
    void page.craft.haptic('light')

    expect(page.last('haptic').callbackId).toBe(`cb_${SEEDED_AT + 1}`)
  })

  it('never redraws an id the process has already handed out', () => {
    // Two loads, the second seeded from what the first drew — which is what
    // `highestCallbackId` does in Swift: every call passes through the
    // message handler, so the seed covers the whole range a load used.
    const first = loadPage()
    const drawn: string[] = []
    for (let i = 0; i < 3; i++) {
      void first.craft.haptic('light')
      drawn.push(first.last('haptic').callbackId!)
    }

    const highest = Math.max(...drawn.map(id => Number(id.slice(3))))
    const second = loadPage(undefined, highest)
    void second.craft.haptic('light')
    void second.craft.vibrate([10])

    expect(new Set(drawn).size).toBe(3)
    for (const action of ['haptic', 'vibrate']) {
      expect(drawn).not.toContain(second.last(action).callbackId)
    }
    // And it carried on from there rather than restarting.
    expect(second.last('haptic').callbackId).toBe(`cb_${highest + 1}`)
  })

  it('hands a refusal to the caller of the raw call', async () => {
    const page = loadPage()
    const haptic = page.craft.haptic('light')
    page.refuse('haptic', 'Haptics is disabled', 'CAPABILITY_DISABLED')

    await expect(haptic).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })

  it('makes the flat location pair use numeric v1 handles and one native stream', async () => {
    const page = loadPage()
    const first = page.craft.watchPosition(() => {})
    const second = page.craft.location.watchPosition(() => {})
    expect(typeof first).toBe('number')
    expect(typeof second).toBe('number')
    expect(second).not.toBe(first)
    expect(page.count('watchPosition')).toBe(1)
    page.answer('watchPosition', true)

    page.craft.clearWatch(first)
    expect(() => page.last('clearWatch')).toThrow()
    page.craft.location.clearWatch(second)
    expect(page.count('clearWatch')).toBe(1)
    page.answer('clearWatch', true)
  })

  it('keeps no-argument clearWatch compatible by clearing every active handle once', () => {
    const page = loadPage()
    let calls = 0
    page.craft.watchPosition(() => calls++)
    page.craft.location.watchPosition(() => calls++)
    page.answer('watchPosition', true)

    page.craft.clearWatch()
    expect(page.count('clearWatch')).toBe(1)
    page.position({ latitude: 1 })
    expect(calls).toBe(0)

    page.craft.clearWatch()
    expect(page.count('clearWatch')).toBe(1)
  })

  it('drops a refused v1 start so the next subscriber asks native again', async () => {
    const page = loadPage()
    let calls = 0
    page.craft.watchPosition(() => calls++)
    page.refuse('watchPosition', 'Location is disabled', 'CAPABILITY_DISABLED')
    await Promise.resolve()

    page.position({ latitude: 1 })
    expect(calls).toBe(0)
    page.craft.watchPosition(() => calls++)
    expect(page.count('watchPosition')).toBe(2)
    page.refuse('watchPosition', 'Location is disabled', 'CAPABILITY_DISABLED')
    await Promise.resolve()
  })

  it('removes a refused legacy listener instead of leaving a dead watch behind', async () => {
    const page = loadPage()
    let calls = 0
    const started = page.craft.geolocation.watchPosition(() => calls++)
    page.refuse('watchPosition', 'Location is disabled', 'CAPABILITY_DISABLED')

    await expect(started).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
    page.position({ latitude: 1 })
    expect(calls).toBe(0)
  })

  it('does not let a legacy clear stop v1 subscribers sharing the native stream', async () => {
    const page = loadPage()
    let v1Calls = 0
    let legacyCalls = 0
    const id = page.craft.location.watchPosition(() => v1Calls++)
    page.answer('watchPosition', true)
    await Promise.resolve()

    const legacyStarted = page.craft.geolocation.watchPosition(() => legacyCalls++)
    expect(page.count('watchPosition')).toBe(1)
    expect(await legacyStarted).toBe(true)
    expect(await page.craft.geolocation.clearWatch()).toBe(true)
    expect(page.count('clearWatch')).toBe(0)

    page.position({ latitude: 1 })
    expect(v1Calls).toBe(1)
    expect(legacyCalls).toBe(0)
    page.craft.location.clearWatch(id)
    expect(page.count('clearWatch')).toBe(1)
  })

  // Haptics are feedback. An app that left enableHaptics off must not have
  // `await haptics.selection()` stop the flow it sits in, which is how the
  // SDK documents it and how Android and the web fallback behave.
  const feedback: [string, string, (craft: any) => Promise<unknown>][] = [
    ['impact', 'haptic', craft => craft.haptics.impact('heavy')],
    ['notification', 'haptic', craft => craft.haptics.notification('error')],
    ['selection', 'haptic', craft => craft.haptics.selection()],
    ['vibrate', 'vibrate', craft => craft.haptics.vibrate([100])],
  ]

  for (const [name, action, call] of feedback) {
    it(`settles haptics.${name} with nothing played when haptics are off`, async () => {
      const page = loadPage()
      const settled = call(page.craft)
      page.refuse(action, 'Haptics is disabled', 'CAPABILITY_DISABLED')

      expect(await settled).toBeUndefined()
    })

    it(`still rejects haptics.${name} when the native call fails`, async () => {
      const page = loadPage()
      const settled = call(page.craft)
      page.refuse(action, 'Native API call failed', 'NATIVE_CALL_FAILED')

      await expect(settled).rejects.toMatchObject({ code: 'NATIVE_CALL_FAILED' })
    })
  }

  // A notification tap on a cold launch is flushed the moment the bridge is
  // ready, and a page that wires its listener after its router hydrates was
  // not listening yet: "Try it" opened the home screen instead. Held the way
  // deep links are (#198), and handed to the first subscriber.
  it('hands a tap that arrived before anyone subscribed to the first subscriber', async () => {
    const page = loadPage()
    page.tap({ screen: 'plant-id' })

    const seen: unknown[] = []
    page.craft.notifications.onTap((detail: unknown) => seen.push(detail))
    await tick()

    expect(seen).toEqual([{ screen: 'plant-id' }])
  })

  it('keeps onTap on the notifications object the page ends up with', () => {
    // installCraftMobileContract replaces craft.notifications after the
    // replay attaches onTap, and onTap survives only because it copies own
    // properties across. Reorder those two blocks and it would vanish with
    // nothing else failing, so this reads the final object.
    const page = loadPage()
    expect(typeof page.craft.notifications.onTap).toBe('function')
    expect(typeof page.craft.notifications.onTap(() => {})).toBe('function')
    // And the contract's own additions are still there beside it.
    expect(typeof page.craft.notifications.show).toBe('function')
  })

  it('delivers a tap once, live, to a page already subscribed', async () => {
    const page = loadPage()
    const seen: unknown[] = []
    page.craft.notifications.onTap((detail: unknown) => seen.push(detail))
    await tick()

    page.tap({ screen: 'recap' })
    expect(seen).toEqual([{ screen: 'recap' }])
  })

  it('drops held taps for a subscriber that unsubscribed in the same tick', async () => {
    const page = loadPage()
    page.tap({ screen: 'plant-id' })

    const seen: unknown[] = []
    const unsubscribe = page.craft.notifications.onTap((detail: unknown) => seen.push(detail))
    unsubscribe()
    await tick()

    expect(seen).toEqual([])
  })

  // #256: a notification that arrives while the page is open reaches it,
  // live, on the notifications object the page ends up with.
  it('hands a notification that arrived while the page was open to onReceive', () => {
    const page = loadPage()
    expect(typeof page.craft.notifications.onReceive).toBe('function')

    const seen: unknown[] = []
    const unsubscribe = page.craft.notifications.onReceive((detail: unknown) => seen.push(detail))
    page.receive({ screen: 'recap' })
    expect(seen).toEqual([{ screen: 'recap' }])

    unsubscribe()
    page.receive({ screen: 'plant-id' })
    expect(seen).toEqual([{ screen: 'recap' }])
  })

  it('keeps arrivals and taps apart', async () => {
    const page = loadPage()
    const taps: unknown[] = []
    const arrivals: unknown[] = []
    page.craft.notifications.onTap((detail: unknown) => taps.push(detail))
    page.craft.notifications.onReceive((detail: unknown) => arrivals.push(detail))
    await tick()

    page.receive({ screen: 'recap' })
    page.tap({ screen: 'plant-id' })
    expect(arrivals).toEqual([{ screen: 'recap' }])
    expect(taps).toEqual([{ screen: 'plant-id' }])
  })

  // Held taps are for a launch the page was not there for. An arrival is
  // news only to a page that is running, so nothing is held for later.
  it('does not hold an arrival for a page that subscribes afterwards', async () => {
    const page = loadPage()
    page.receive({ screen: 'recap' })

    const seen: unknown[] = []
    page.craft.notifications.onReceive((detail: unknown) => seen.push(detail))
    await tick()
    expect(seen).toEqual([])
  })

  // #198 and #215. The Android page script runs the same block; its own test
  // covers the rest of the contract.
  const tick = () => new Promise(resolve => setTimeout(resolve, 5))

  it('hands the launch link to a page that subscribes after it arrived', async () => {
    const page = loadPage()
    page.link('app://launch', true)

    const seen: unknown[] = []
    page.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
    await tick()

    expect(seen).toEqual([{ url: 'app://launch', initial: true }])
  })

  it('delivers the launch link once to a craftReady handler that asks for it both ways', async () => {
    // The handler runs inside the script, before native has dispatched the
    // link at all, so there is nothing held yet for getInitialURL to claim.
    const seen: unknown[] = []
    const page = loadPage((window) => {
      window.addEventListener('craftReady', () => {
        void window.craft.deepLinks.getInitialURL()
        window.craft.deepLinks.onLink((detail: unknown) => seen.push(detail))
      })
    })
    page.link('app://launch', true)
    await tick()

    expect(seen).toEqual([])
    expect(page.last('getInitialURL').callbackId).toMatch(/^cb_\d+$/)
  })
})
