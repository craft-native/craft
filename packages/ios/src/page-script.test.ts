import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'bun:test'

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

/**
 * Every timer a loaded page started, cleared when its test ends.
 *
 * A call a test leaves unanswered (`void page.craft.haptics.prepare()`) keeps
 * the bridge's 30-second timeout running. When it fires the promise rejects
 * with nobody listening, and Bun charges that to whichever test is running
 * then, in another file if the suite has moved on: on a slow CI runner the
 * hybrid page script failed with "Craft bridge timed out: hapticPrepare".
 * The page's timers go through the global at call time, so a test that
 * swaps `globalThis.setTimeout` still sees them.
 */
const pageTimers = new Set<ReturnType<typeof setTimeout>>()
const pageSetTimeout = (handler: () => void, ms?: number) => {
  const timer = globalThis.setTimeout(handler, ms)
  pageTimers.add(timer)
  return timer
}
const pageClearTimeout = (timer: ReturnType<typeof setTimeout>) => {
  pageTimers.delete(timer)
  globalThis.clearTimeout(timer)
}
afterEach(() => {
  for (const timer of pageTimers) globalThis.clearTimeout(timer)
  pageTimers.clear()
})

type Listener = (event: { type: string, detail: unknown }) => void

/**
 * `beforeInject` runs first, the way a page's own script runs before WebKit's
 * didFinish injects the bridge. `seed` is what Swift interpolates as the id
 * to count up from — its own high-water mark across loads (#226).
 */
function loadPage(beforeInject?: (page: Record<string, any>) => void, seed = SEEDED_AT, document: Record<string, any> = { addEventListener() {}, readyState: 'complete' }) {
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
  new Function('window', 'document', 'navigator', 'CustomEvent', 'console', 'setTimeout', 'clearTimeout', pageScript(seed))(
    page,
    document,
    {},
    CustomEvent,
    quiet,
    pageSetTimeout,
    pageClearTimeout,
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
    // Any event native dispatches on window.
    emit: (type: string, detail: unknown) =>
      page.dispatchEvent(new CustomEvent(type, { detail })),
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

  // Each kind reaches the generator UIKit has for it. notification() and
  // selection() used to post impact weights ('heavy', 'soft'), so a success
  // felt like a thud and a picker detent like a tap.
  const kinds: [string, (craft: any) => Promise<unknown>, string][] = [
    ['impact(\'rigid\')', craft => craft.haptics.impact('rigid'), 'rigid'],
    ['impact(\'soft\')', craft => craft.haptics.impact('soft'), 'soft'],
    ['impact()', craft => craft.haptics.impact(), 'medium'],
    ['notification(\'error\')', craft => craft.haptics.notification('error'), 'error'],
    ['notification(\'warning\')', craft => craft.haptics.notification('warning'), 'warning'],
    ['notification()', craft => craft.haptics.notification(), 'success'],
    ['selection()', craft => craft.haptics.selection(), 'selection'],
  ]

  for (const [name, call, style] of kinds) {
    it(`plays haptics.${name} as the ${style} haptic`, async () => {
      const page = loadPage()
      const played = call(page.craft)
      expect(page.last('haptic').style).toBe(style)
      page.answer('haptic', true)
      expect(await played).toBeUndefined()
    })
  }

  it('warms a generator through haptics.prepare, quietly when haptics are off', async () => {
    const page = loadPage()
    const warmed = page.craft.haptics.prepare('selection')
    expect(page.last('hapticPrepare')).toMatchObject({ kind: 'selection' })
    page.refuse('hapticPrepare', 'Haptics is disabled', 'CAPABILITY_DISABLED')
    expect(await warmed).toBeUndefined()

    void page.craft.haptics.prepare()
    expect(page.last('hapticPrepare').kind).toBeNull()
  })

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

  it('keeps the legacy secureStorage.remove alias beside delete', async () => {
    const page = loadPage()
    const removed = page.craft.secureStorage.remove('session-token')

    expect(page.last('secureRemove')).toMatchObject({ key: 'session-token' })
    page.answer('secureRemove', true)
    await expect(removed).resolves.toBeUndefined()
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

describe('when the bridge announces itself', () => {
  // The bridge is a document-start user script now, so it runs before any of
  // the page's own code. craftReady still has to reach pages written for the
  // old after-load injection, which only listen for it.
  it('waits for the document to be parsed, then fires craftReady once and tells native', () => {
    const contentLoaded: Array<() => void> = []
    const document = {
      readyState: 'loading',
      addEventListener: (type: string, listener: () => void) => {
        if (type === 'DOMContentLoaded') contentLoaded.push(listener)
      },
    }
    let readyEvents = 0
    const page = loadPage((window) => {
      window.addEventListener('craftReady', () => { readyEvents++ })
    }, SEEDED_AT, document)

    // There at once, for a page that checks rather than listens.
    expect(page.craft.platform).toBe('ios')
    expect(page.craft.ready).toBeUndefined()
    expect(readyEvents).toBe(0)
    expect(page.count('__craftReady')).toBe(0)

    for (const listener of contentLoaded) listener()
    expect(readyEvents).toBe(1)
    expect(page.craft.ready).toBe(true)
    expect(page.count('__craftReady')).toBe(1)

    // A second DOMContentLoaded (or a late re-run of the hook) is not a second ready.
    for (const listener of contentLoaded) listener()
    expect(readyEvents).toBe(1)
    expect(page.count('__craftReady')).toBe(1)
  })

  it('announces at once when it is installed into a document already parsed', () => {
    let readyEvents = 0
    const page = loadPage((window) => {
      window.addEventListener('craftReady', () => { readyEvents++ })
    })
    expect(readyEvents).toBe(1)
    expect(page.count('__craftReady')).toBe(1)
  })
})

describe('the appearance the page should match', () => {
  const snapshot = { contentSizeCategory: 'extraExtraLarge', fontScale: 1.235, reduceMotion: true, reduceTransparency: false, colorScheme: 'dark' }

  it('announces the starting appearance with craftReady, and reads it back', () => {
    const seen: unknown[] = []
    const page = loadPage((window) => {
      window.__craftAppearance = snapshot
      window.addEventListener('craftAppearance', (event: { detail: unknown }) => seen.push(event.detail))
    })
    expect(seen).toEqual([snapshot])
    expect(page.craft.appearance).toEqual(snapshot)
  })

  it('hands later changes to onAppearanceChange until unsubscribed', () => {
    const page = loadPage()
    expect(page.craft.appearance).toBeNull()
    const seen: unknown[] = []
    const stop = page.craft.onAppearanceChange((detail: unknown) => seen.push(detail))
    // What CraftPageAppearance.script(_, announce: true) dispatches.
    page.emit('craftAppearance', { ...snapshot, fontScale: 1.412 })
    stop()
    page.emit('craftAppearance', snapshot)
    expect(seen).toEqual([{ ...snapshot, fontScale: 1.412 }])
  })
})

describe('craft.background', () => {
  it('answers a background event with its id, or everything pending without one', async () => {
    const page = loadPage()
    const seen: unknown[] = []
    page.craft.background.onSilentPush((detail: unknown) => seen.push(detail))
    page.emit('craftSilentPush', { id: 'push-1', payload: { sync: 'workouts' } })
    expect(seen).toEqual([{ id: 'push-1', payload: { sync: 'workouts' } }])

    const done = page.craft.background.complete(true, 'push-1')
    expect(page.last('backgroundComplete')).toMatchObject({ ok: true, id: 'push-1' })
    page.answer('backgroundComplete', true)
    expect(await done).toBe(true)

    void page.craft.background.complete(false)
    expect(page.last('backgroundComplete')).toMatchObject({ ok: false, id: null })
  })
})

describe('the bridge user script', () => {
  // The guard Swift wraps the bridge in, so it installs only where the
  // message handlers would answer it.
  const line = template.split('\n').find(text => text.includes("if ((location.protocol === 'craft:' && location.host === 'app')"))
  if (!line) throw new Error('CraftApp.swift no longer guards the bridge user script by origin')
  const condition = line.trim().replace(/^if \(/, '').replace(/\) \{$/, '')
  const installs = (protocol: string, host: string) =>
    // eslint-disable-next-line no-new-func
    new Function('location', `return ${condition.replace('\\(trusted)', JSON.stringify(['https://hq.training', 'http://localhost:3000']))}`)({ protocol, host })

  it('installs in the app\'s own origins and nowhere else', () => {
    expect(installs('craft:', 'app')).toBe(true)
    expect(installs('https:', 'hq.training')).toBe(true)
    expect(installs('http:', 'localhost:3000')).toBe(true)
    expect(installs('https:', 'evil.example')).toBe(false)
    expect(installs('https:', 'hq.training.evil.example')).toBe(false)
    expect(installs('about:', '')).toBe(false)
  })
})

describe('the native UI the page can drive', () => {
  it('confirms through the system alert and answers a boolean', async () => {
    const page = loadPage()
    const confirmed = page.craft.dialog.confirm({ title: 'Delete workout?', message: 'This cannot be undone.', confirmLabel: 'Delete', destructive: true })
    expect(page.last('dialogConfirm')).toMatchObject({ title: 'Delete workout?', confirmLabel: 'Delete', destructive: true })
    page.answer('dialogConfirm', true)
    expect(await confirmed).toBe(true)
  })

  it('settles every call with what nothing-happened means when native fails', async () => {
    const page = loadPage()
    const calls: [string, Promise<unknown>, unknown][] = [
      ['dialogConfirm', page.craft.dialog.confirm('Sure?'), false],
      ['dialogActionSheet', page.craft.dialog.actionSheet({ actions: [{ id: 'a', title: 'A' }] }), null],
      ['contextMenuShow', page.craft.contextMenu.show({ items: [{ id: 'a', title: 'A' }], anchor: { x: 1, y: 2, width: 3, height: 4 } }), null],
      ['browserOpen', page.craft.browser.open('https://example.com'), { cancelled: true }],
      ['symbolImage', page.craft.symbols.image('heart.fill'), null],
      ['statusBarSetStyle', page.craft.statusBar.setStyle('light'), false],
      ['chromeSetUnderPageColor', page.craft.chrome.setUnderPageColor('#000'), false],
      ['refreshEnable', page.craft.refresh.enable(), false],
    ]
    for (const [action] of calls) page.refuse(action, 'Native API call failed', 'NATIVE_CALL_FAILED')
    for (const [, call, fallback] of calls) expect(await call).toEqual(fallback)

    const alerted = page.craft.dialog.alert('Saved')
    expect(page.last('dialogAlert')).toMatchObject({ title: 'Saved' })
    page.refuse('dialogAlert', 'Native API call failed', 'NATIVE_CALL_FAILED')
    expect(await alerted).toBeUndefined()
  })

  it('does not time out a dialog, a menu or the browser a person is still reading', () => {
    const page = loadPage()
    const pending: number[] = []
    const realSetTimeout = globalThis.setTimeout
    globalThis.setTimeout = ((fn: () => void, ms?: number) => { if (ms === 30000) pending.push(ms); return realSetTimeout(() => {}, 0) }) as typeof setTimeout
    try {
      void page.craft.dialog.alert('Hi')
      void page.craft.dialog.confirm('Sure?')
      void page.craft.dialog.actionSheet({ actions: [] })
      void page.craft.contextMenu.show({ items: [] })
      void page.craft.browser.open('https://example.com', { mode: 'auth', callbackScheme: 'hqtraining' })
    }
    finally {
      globalThis.setTimeout = realSetTimeout
    }
    expect(pending).toEqual([])
    expect(page.last('browserOpen')).toMatchObject({ url: 'https://example.com', mode: 'auth', callbackScheme: 'hqtraining' })
  })

  it('reads an element anchor as its viewport rect and answers the chosen id', async () => {
    const page = loadPage()
    const element = { getBoundingClientRect: () => ({ left: 10, top: 20, width: 30, height: 40 }) }
    const chosen = page.craft.dialog.actionSheet({
      title: 'Workout',
      anchor: element,
      actions: [{ id: 'edit', title: 'Edit' }, { id: 'delete', title: 'Delete', style: 'destructive' }, { id: 'cancel', title: 'Cancel', style: 'cancel' }],
    })
    expect(page.last('dialogActionSheet').anchor).toEqual({ x: 10, y: 20, width: 30, height: 40 })
    expect(page.last('dialogActionSheet').actions).toEqual([
      { id: 'edit', title: 'Edit', style: 'default' },
      { id: 'delete', title: 'Delete', style: 'destructive' },
      { id: 'cancel', title: 'Cancel', style: 'cancel' },
    ])
    page.answer('dialogActionSheet', 'delete')
    expect(await chosen).toBe('delete')

    const menu = page.craft.contextMenu.show({ items: [{ id: 'dup', title: 'Duplicate', symbol: 'plus.square.on.square' }], anchor: element })
    expect(page.last('contextMenuShow').items).toEqual([{ id: 'dup', title: 'Duplicate', symbol: 'plus.square.on.square', destructive: false, disabled: false }])
    page.answer('contextMenuShow', null)
    expect(await menu).toBeNull()
  })

  it('draws a symbol once per size and colour', async () => {
    const page = loadPage()
    const first = page.craft.symbols.image('heart.fill', { pointSize: 22, weight: 'semibold', color: '#ff0000' })
    const again = page.craft.symbols.image('heart.fill', { pointSize: 22, weight: 'semibold', color: '#ff0000' })
    expect(page.count('symbolImage')).toBe(1)
    page.answer('symbolImage', 'data:image/png;base64,AAAA')
    expect(await first).toBe('data:image/png;base64,AAAA')
    expect(await again).toBe('data:image/png;base64,AAAA')
    void page.craft.symbols.image('heart.fill', { pointSize: 28 })
    expect(page.count('symbolImage')).toBe(2)
  })

  it('narrows the status bar style and the keyboard bar to what native takes', () => {
    const page = loadPage()
    void page.craft.statusBar.setStyle('purple')
    expect(page.last('statusBarSetStyle').style).toBe('default')
    void page.craft.statusBar.setStyle('light')
    expect(page.last('statusBarSetStyle').style).toBe('light')
    void page.craft.chrome.setKeyboardAccessory(false)
    expect(page.last('chromeSetKeyboardAccessory').visible).toBe(false)
    void page.craft.refresh.enable({ tintColor: '#22c55e' })
    expect(page.last('refreshEnable').tintColor).toBe('#22c55e')
  })
})

describe('the viewport pin', () => {
  // Swift's multi-line string, as the page receives it.
  const start = template.indexOf('static let viewportScript = """')
  const body = template.slice(template.indexOf('\n', start) + 1, template.indexOf('\n    """', start)).replace(/\\\\/g, '\\')
  const pin = (content: string | null) => {
    let meta: Record<string, any> | null = null
    if (content !== null) {
      const attributes: Record<string, string> = { name: 'viewport', content }
      meta = { getAttribute: (key: string) => attributes[key] ?? null, setAttribute: (key: string, value: string) => { attributes[key] = value } }
    }
    const appended: any[] = []
    const document = {
      readyState: 'interactive',
      querySelector: () => meta,
      createElement: () => {
        const attributes: Record<string, string> = {}
        return { getAttribute: (key: string) => attributes[key] ?? null, setAttribute: (key: string, value: string) => { attributes[key] = value } }
      },
      head: { appendChild: (node: any) => appended.push(node) },
      addEventListener() {},
    }
    // eslint-disable-next-line no-new-func
    new Function('document', body)(document)
    return (meta ?? appended[0]).getAttribute('content')
  }

  it('keeps the page\'s own width and pins its scale', () => {
    expect(pin('width=device-width, initial-scale=1, viewport-fit=cover')).toBe('width=device-width, initial-scale=1, viewport-fit=cover, minimum-scale=1, maximum-scale=1, user-scalable=no')
  })

  it('overrides a page that allowed zooming', () => {
    expect(pin('width=device-width, maximum-scale=5, user-scalable=yes')).toBe('width=device-width, minimum-scale=1, maximum-scale=1, user-scalable=no')
  })

  it('adds a viewport to a page without one', () => {
    expect(pin(null)).toBe('width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no')
  })
})

describe('craft.db', () => {
  // Native has handled dbExecute/dbQuery for a long time; the page had no way
  // to reach them, so localDatabase did nothing on iOS while Android worked.
  it('posts SQL with its parameters and resolves with what native answers', async () => {
    const { craft, last, answer } = loadPage()
    const executed = craft.db.execute('INSERT INTO t (at, text) VALUES (?, ?)', [1791136990820, 'hi'])
    expect(last('dbExecute')).toMatchObject({ sql: 'INSERT INTO t (at, text) VALUES (?, ?)', params: [1791136990820, 'hi'] })
    answer('dbExecute', { rowsAffected: 1, lastInsertId: 7 })
    expect(await executed).toEqual({ rowsAffected: 1, lastInsertId: 7 })

    const queried = craft.db.query('SELECT 1 AS one')
    expect(last('dbQuery')).toMatchObject({ sql: 'SELECT 1 AS one', params: [] })
    answer('dbQuery', [{ one: 1 }])
    expect(await queried).toEqual([{ one: 1 }])
  })
})

describe('native SQLite binding', () => {
  // Swift side, checked as source: text must be copied by SQLite
  // (SQLITE_TRANSIENT) and integers carried as 64-bit, or strings are read
  // from freed memory and millisecond timestamps wrap.
  it('binds text as transient and integers as 64-bit', () => {
    expect(template).toContain('sqlite3_bind_text(statement, idx, str, -1, sqliteTransient)')
    expect(template).not.toContain('sqlite3_bind_text(statement, idx, str, -1, nil)')
    expect(template).toContain('sqlite3_bind_int64(statement, idx, number.int64Value)')
    expect(template).toContain('sqlite3_column_int64(statement, i)')
    expect(template).not.toMatch(/sqlite3_column_int\(statement/)
  })
})

describe('craft.crashReporter', () => {
  // The page's error SDK hands its events to the app's crash reporter
  // (CraftCrashReporter.swift), so they share the offline outbox.
  it('offers the flag the reporter answers, which is off until it is configured', () => {
    const { craft } = loadPage()
    expect(craft.capabilities.crashReporter).toBe(false)
  })

  it('posts an event and settles with what native answers', async () => {
    const { craft, last, answer } = loadPage()
    const queued = craft.crashReporter.capture({ type: 'TypeError', message: 'boom' })
    expect(last('crashReporterCapture')).toMatchObject({ event: { type: 'TypeError', message: 'boom' } })
    expect(last('crashReporterCapture').callbackId).toMatch(/^cb_\d+$/)
    answer('crashReporterCapture', true)
    expect(await queued).toBe(true)
  })

  it('names the user by id only, as a string, and null on sign-out', async () => {
    const { craft, last, answer } = loadPage()
    const named = craft.crashReporter.setUser(967)
    expect(last('crashReporterSetUser')).toMatchObject({ id: '967' })
    answer('crashReporterSetUser', true)
    await named
    const cleared = craft.crashReporter.setUser(null)
    expect(last('crashReporterSetUser')).toMatchObject({ id: null })
    answer('crashReporterSetUser', true)
    await cleared
  })

  it('adds breadcrumbs, flushes and reads the context through their own actions', async () => {
    const { craft, last, answer } = loadPage()
    const crumb = craft.crashReporter.addBreadcrumb({ type: 'navigation', message: '/m/calendar' })
    expect(last('crashReporterAddBreadcrumb')).toMatchObject({ breadcrumb: { type: 'navigation', message: '/m/calendar' } })
    answer('crashReporterAddBreadcrumb', true)
    await crumb
    const flushed = craft.crashReporter.flush()
    answer('crashReporterFlush', true)
    expect(await flushed).toBe(true)
    const context = craft.crashReporter.context()
    answer('crashReporterContext', { enabled: true, release: '1.0.0+41' })
    expect(await context).toMatchObject({ release: '1.0.0+41' })
  })

  it('hands back the refusal native sends when reporting is not configured', async () => {
    const { craft, refuse } = loadPage()
    const queued = craft.crashReporter.capture({ message: 'x' })
    refuse('crashReporterCapture', 'Crash reporting is not configured', 'CAPABILITY_DISABLED')
    await expect(queued).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })
})

describe('craft.speech', () => {
  // Spoken workout cues. Native rather than the page's speechSynthesis, which
  // in a WKWebView stops the person's music and obeys the silent switch.
  it('is always offered, whatever the app was built with', () => {
    const { craft } = loadPage()
    expect(craft.capabilities.speech).toBe(true)
  })

  it('posts the text and its options and settles with what native answers when it ends', async () => {
    const { craft, last, answer } = loadPage()
    const spoken = craft.speech.speak('Rest, 15 seconds. Up next: Dead Bug', { rate: 1.2, language: 'en-GB', interrupt: false })

    expect(last('speak')).toMatchObject({
      text: 'Rest, 15 seconds. Up next: Dead Bug',
      rate: 1.2,
      language: 'en-GB',
      interrupt: false,
    })
    expect(last('speak').callbackId).toMatch(/^cb_\d+$/)
    answer('speak', true)
    expect(await spoken).toBe(true)
  })

  it('interrupts by default and leaves rate and language to native when not given', async () => {
    const { craft, last, answer } = loadPage()
    const spoken = craft.speech.speak('Go')

    expect(last('speak')).toMatchObject({ text: 'Go', rate: null, language: null, interrupt: true })
    // The cue that was cut off, which native settles false.
    answer('speak', false)
    expect(await spoken).toBe(false)
  })

  it('hands an empty text the refusal native sends', async () => {
    const { craft, refuse } = loadPage()
    const spoken = craft.speech.speak('')
    refuse('speak', 'speak needs some text to say', 'INVALID_ARGUMENT')
    await expect(spoken).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
  })

  it('stops through stopSpeaking and waits for native to confirm', async () => {
    const { craft, last, answer } = loadPage()
    const stopped = craft.speech.stop()
    expect(last('stopSpeaking').callbackId).toMatch(/^cb_\d+$/)
    answer('stopSpeaking', true)
    expect(await stopped).toBe(true)
  })

  it('settles every call from the synthesizer delegate, not when the call is taken', () => {
    // A cue's promise is what a player awaits before moving on, so it has to
    // mean "finished speaking".
    expect(template).toContain('extension CraftWebView.Coordinator: AVSpeechSynthesizerDelegate')
    expect(template).toContain('didFinish utterance: AVSpeechUtterance')
    expect(template).toContain('didCancel utterance: AVSpeechUtterance')
    expect(template).toContain('try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])')
    expect(template).toContain('setActive(false, options: .notifyOthersOnDeactivation)')
  })
})

describe('craft.music', () => {
  // The Music app's song and transport (CraftMusic.swift). Each call is one
  // posted action that native answers with the status or a snapshot.
  it('posts each call as the action native answers, and settles with its answer', async () => {
    const { craft, last, answer } = loadPage()
    const snapshot = { available: true, authorization: 'authorized', title: 'Intervals', isPlaying: true }

    const status = craft.music.getAuthorizationStatus()
    answer('musicGetAuthorization', 'notDetermined')
    expect(await status).toBe('notDetermined')

    const nowPlaying = craft.music.getNowPlaying()
    answer('musicGetNowPlaying', snapshot)
    expect(await nowPlaying).toEqual(snapshot)

    for (const command of ['play', 'pause', 'togglePlayPause', 'skipToNext'] as const) {
      const done = craft.music[command]()
      expect(last('musicControl')).toMatchObject({ command })
      answer('musicControl', snapshot)
      expect(await done).toEqual(snapshot)
    }

    const back = craft.music.skipToPrevious({ restartAfter: 0 })
    expect(last('musicControl')).toMatchObject({ command: 'skipToPrevious', restartAfter: 0 })
    answer('musicControl', snapshot)
    await back
    void craft.music.skipToPrevious()
    expect(last('musicControl')).toMatchObject({ command: 'skipToPrevious', restartAfter: null })
    answer('musicControl', snapshot)

    const observing = craft.music.observe()
    expect(last('musicObserve')).toMatchObject({ enabled: true })
    answer('musicObserve', true)
    expect(await observing).toBe(true)
    void craft.music.observe(false)
    expect(last('musicObserve')).toMatchObject({ enabled: false })
    answer('musicObserve', false)
  })

  it('waits on the media library prompt for as long as the person takes', async () => {
    const { craft, answer } = loadPage()
    const asked = craft.music.requestAuthorization()
    // No 30-second timeout: the person may read the prompt for longer.
    expect([...pageTimers].length).toBe(0)
    answer('musicRequestAuthorization', 'authorized')
    expect(await asked).toBe('authorized')
  })

  it('hands a build without the capability the refusal native sends', async () => {
    const { craft, refuse } = loadPage()
    const nowPlaying = craft.music.getNowPlaying()
    refuse('musicGetNowPlaying', 'Apple Music is disabled', 'CAPABILITY_DISABLED')
    await expect(nowPlaying).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })

  it('reads nothing before access, drives the system player, and pushes its changes', () => {
    const music = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftMusic.swift'), 'utf8')
    expect(template).toContain('music: \\(config.enableAppleMusic)')
    expect(template).toContain('self?.sendToWeb("craftMusicChange", data: snapshot)')
    expect(music).toContain('MPMusicPlayerController.systemMusicPlayer')
    expect(music).toContain('guard isAuthorized else { return result }')
    expect(music).toContain('MPMediaLibrary.requestAuthorization')
    expect(music).toContain('player.beginGeneratingPlaybackNotifications()')
    expect(music).toContain('.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange')
    // The stand-in never ships to a device.
    expect(music).toMatch(/#if targetEnvironment\(simulator\)\n\s+if UserDefaults\.standard\.bool\(forKey: "CraftFakeMusicPlayer"\)/)
  })
})

describe('craft.health heart rate as it arrives', () => {
  // An anchored HealthKit query (CraftHealth.swift) whose batches arrive as
  // craftHealthHeartRate events until it is stopped.
  it('starts from `since`, or lets native default it, and stops', async () => {
    const { craft, last, answer } = loadPage()
    const started = craft.health.startHeartRateUpdates({ since: 1700 })
    expect(last('startHealthHeartRateUpdates')).toMatchObject({ since: 1700 })
    answer('startHealthHeartRateUpdates', true)
    expect(await started).toBe(true)

    for (const options of [undefined, {}, { since: 'soon' }]) {
      void craft.health.startHeartRateUpdates(options)
      expect(last('startHealthHeartRateUpdates')).toMatchObject({ since: null })
      answer('startHealthHeartRateUpdates', true)
    }

    const stopped = craft.health.stopHeartRateUpdates()
    expect(last('stopHealthHeartRateUpdates').action).toBe('stopHealthHeartRateUpdates')
    answer('stopHealthHeartRateUpdates', true)
    expect(await stopped).toBe(true)
  })

  it('hands a build without HealthKit the refusal native sends', async () => {
    const { craft, refuse } = loadPage()
    const started = craft.health.startHeartRateUpdates()
    refuse('startHealthHeartRateUpdates', 'HealthKit is disabled', 'CAPABILITY_DISABLED')
    await expect(started).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })

  it('drives the live workout lifecycle through HealthKit', async () => {
    const { craft, last, answer } = loadPage()
    const started = craft.health.startWorkout({ type: 'running', location: 'outdoor' })
    expect(last('startHealthWorkout')).toMatchObject({ type: 'running', location: 'outdoor' })
    answer('startHealthWorkout', { id: 'live-1', type: 'running', startDate: 1000 })
    expect(await started).toMatchObject({ id: 'live-1' })
    const paused = craft.health.pauseWorkout()
    expect(last('pauseHealthWorkout').action).toBe('pauseHealthWorkout')
    answer('pauseHealthWorkout', true)
    expect(await paused).toBe(true)
    const resumed = craft.health.resumeWorkout()
    answer('resumeHealthWorkout', true)
    expect(await resumed).toBe(true)
    const ended = craft.health.endWorkout()
    answer('endHealthWorkout', { id: 'live-1', workoutId: 'hk-1', endDate: 9000, durationSeconds: 8 })
    expect(await ended).toMatchObject({ workoutId: 'hk-1' })
  })

  it('discards without taking the save path and preserves native refusals', async () => {
    const { craft, last, answer, refuse } = loadPage()
    const discarded = craft.health.discardWorkout()
    expect(last('discardHealthWorkout').action).toBe('discardHealthWorkout')
    answer('discardHealthWorkout', true)
    expect(await discarded).toBe(true)
    for (const code of ['NO_WORKOUT', 'WORKOUT_ENDING', 'CAPABILITY_DISABLED']) {
      const rejected = craft.health.discardWorkout()
      refuse('discardHealthWorkout', code, code)
      await expect(rejected).rejects.toMatchObject({ code })
    }
  })
})

describe('craft.heartRate', () => {
  // A Bluetooth heart-rate strap (CraftHeartRate.swift). Every method is one
  // `heartRate` action naming it, the way a native screen's HeartRate module
  // calls them; asking for Bluetooth is its own action, which waits.
  it('posts each call as the heartRate action with its method and options', async () => {
    const { craft, last, answer } = loadPage()
    const state = { available: true, connection: 'connected', bpm: 141 }

    const now = craft.heartRate.getState()
    expect(last('heartRate')).toMatchObject({ method: 'getState', options: {} })
    answer('heartRate', state)
    expect(await now).toEqual(state)

    void craft.heartRate.scan({ timeout: 8 })
    expect(last('heartRate')).toMatchObject({ method: 'scan', options: { timeout: 8 } })
    answer('heartRate', state)
    void craft.heartRate.scan()
    expect(last('heartRate')).toMatchObject({ method: 'scan', options: { timeout: null } })
    answer('heartRate', state)

    for (const id of ['A1B2', { id: 'A1B2' }]) {
      void craft.heartRate.connect(id)
      expect(last('heartRate')).toMatchObject({ method: 'connect', options: { id: 'A1B2' } })
      answer('heartRate', state)
    }
    void craft.heartRate.disconnect({ forget: true })
    expect(last('heartRate')).toMatchObject({ method: 'disconnect', options: { forget: true } })
    answer('heartRate', state)
    void craft.heartRate.readRecording({ since: 1700 })
    expect(last('heartRate')).toMatchObject({ method: 'readRecording', options: { since: 1700 } })
    answer('heartRate', [])

    for (const method of ['stopScan', 'getDevices', 'reconnect', 'startRecording', 'pauseRecording', 'resumeRecording', 'stopRecording', 'getRecordingState']) {
      const done = craft.heartRate[method]()
      expect(last('heartRate')).toMatchObject({ method })
      answer('heartRate', { method })
      expect(await done).toEqual({ method })
    }
  })

  it('waits on the Bluetooth prompt for as long as the person takes', async () => {
    const { craft, answer } = loadPage()
    const asked = craft.heartRate.requestAuthorization()
    expect([...pageTimers].length).toBe(0)
    answer('heartRateRequestAuthorization', 'authorized')
    expect(await asked).toBe('authorized')
  })

  it('hands a build without the capability the refusal native sends', async () => {
    const { craft, refuse } = loadPage()
    expect(craft.capabilities.heartRate).toBe(false)
    const scan = craft.heartRate.scan()
    refuse('heartRate', 'Heart rate is disabled', 'CAPABILITY_DISABLED')
    await expect(scan).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })

  it('reads the standard Heart Rate Service and pushes readings to the page and native screens', () => {
    const service = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftHeartRate.swift'), 'utf8')
    expect(template).toContain('heartRate: \\(config.enableHeartRate)')
    expect(template).toContain('self.sendToWeb("craftHeartRate", data: detail)')
    expect(template).toContain('"craftMusicChange", "craftHeartRate"]')
    expect(service).toContain('CBUUID(string: "180D")')
    expect(service).toContain('CBUUID(string: "2A37")')
    expect(service).toContain('peripheral.setNotifyValue(true, for: measurement)')
    // The flags byte decides the width of the rate and what follows it.
    expect(service).toContain('guard let bpm = flags & 0x01 != 0 ? uint16() : uint8() else { return nil }')
    expect(service).toContain('while let value = uint16() { intervals.append(Double(value) * 1000 / 1024) }')
    // A lost strap is asked for again until disconnect().
    expect(service).toMatch(/if wantsConnection \{\n\s+connection = "reconnecting"\n\s+central\.connect\(peripheral\)/)
    // Without it the native screens alone hear it.
    expect(service).toContain('if pageSink?(detail) != true { CraftWebServices.forward("craftHeartRate", data: detail) }')
    // The stand-in never ships to a device.
    expect(service).toMatch(/#if targetEnvironment\(simulator\)\n\s+return UserDefaults\.standard\.bool\(forKey: "CraftFakeHeartRateMonitor"\)/)
  })
})

describe('craft.scheduledWorkouts', () => {
  // Workouts on the paired Apple Watch (CraftScheduledWorkouts.swift,
  // WorkoutKit). Every method is one `scheduledWorkouts` action naming it, the
  // way a native screen's ScheduledWorkouts module calls them; asking to
  // schedule is its own action, which waits on the person.
  const plan = {
    id: '6f1c2b8e-5a7d-4c3e-9b1a-2d4e6f8a0b1c',
    date: '2026-10-20',
    hour: 6,
    minute: 30,
    workout: {
      activity: 'running',
      location: 'outdoor',
      displayName: '4 x 1 km',
      warmup: { goal: { type: 'time', seconds: 600 } },
      blocks: [{ iterations: 4, steps: [
        { purpose: 'work', step: { goal: { type: 'distance', meters: 1000 }, alert: { type: 'speed', min: 4.1, max: 4.4 } } },
        { purpose: 'recovery', step: { goal: { type: 'time', seconds: 120 } } },
      ] }],
    },
  }

  it('posts each call as the scheduledWorkouts action with its method and options', async () => {
    const { craft, last, answer } = loadPage()

    const supported = craft.scheduledWorkouts.isSupported()
    expect(last('scheduledWorkouts')).toMatchObject({ method: 'isSupported', options: {} })
    answer('scheduledWorkouts', true)
    expect(await supported).toBe(true)

    const scheduled = craft.scheduledWorkouts.schedule(plan)
    expect(last('scheduledWorkouts')).toMatchObject({ method: 'schedule', options: plan })
    answer('scheduledWorkouts', { id: plan.id })
    expect(await scheduled).toEqual({ id: plan.id })

    for (const id of [plan.id, { id: plan.id }]) {
      void craft.scheduledWorkouts.remove(id)
      expect(last('scheduledWorkouts')).toMatchObject({ method: 'remove', options: { id: plan.id } })
      answer('scheduledWorkouts', true)
    }

    for (const method of ['authorization', 'list', 'removeAll']) {
      const done = craft.scheduledWorkouts[method]()
      expect(last('scheduledWorkouts')).toMatchObject({ method, options: {} })
      answer('scheduledWorkouts', { method })
      expect(await done).toEqual({ method })
    }
  })

  it('waits on the scheduling prompt for as long as the person takes', async () => {
    const { craft, answer } = loadPage()
    const asked = craft.scheduledWorkouts.requestAuthorization()
    expect([...pageTimers].length).toBe(0)
    answer('scheduledWorkoutsRequestAuthorization', 'authorized')
    expect(await asked).toBe('authorized')
  })

  it('hands a build without the capability the refusal native sends', async () => {
    const { craft, refuse } = loadPage()
    expect(craft.capabilities.scheduledWorkouts).toBe(false)
    const list = craft.scheduledWorkouts.list()
    refuse('scheduledWorkouts', 'Scheduled workouts are disabled', 'CAPABILITY_DISABLED')
    await expect(list).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })

  it('builds WorkoutKit plans, refusing what WorkoutKit refuses and dropping a refused alert', () => {
    const service = readFileSync(join(import.meta.dir, '..', 'templates', 'CraftScheduledWorkouts.swift'), 'utf8')
    expect(template).toContain('scheduledWorkouts: \\(config.enableScheduledWorkouts)')
    expect(template).toContain('case "scheduledWorkouts", "scheduledWorkoutsRequestAuthorization":')
    // WorkoutKit is imported only behind the build condition.
    expect(service).toMatch(/#if CRAFT_SCHEDULED_WORKOUTS\nimport HealthKit\nimport WorkoutKit\n#endif/)
    expect(service).toContain('guard CustomWorkout.supportsActivity(activity) else {')
    expect(service).toContain('guard CustomWorkout.supportsGoal(parsedGoal.goal, activity: activity, location: location) else {')
    expect(service).toContain('if CustomWorkout.supportsAlert(parsed.alert, activity: activity, location: location) {')
    expect(service).toContain('return .success((.speed(range, unit: .metersPerSecond, metric: .current), type))')
    // The plan id is the WorkoutPlan's; list() answers it lowercase.
    expect(service).toContain('WorkoutPlan(.custom(custom), id: id)')
    expect(service).toContain('["id": id.uuidString.lowercased(), "complete": complete]')
    // schedule() says so when nothing kept the plan (no paired watch).
    expect(service).toContain('"NOT_SCHEDULED"')
    expect(service).toContain('WorkoutScheduler.maxAllowedScheduledWorkoutCount')
    // Step names are iOS 18's.
    expect(service).toContain('if #available(iOS 18.0, *), let name =')
    // The stand-in never ships to a device.
    expect(service).toMatch(/#if targetEnvironment\(simulator\)\n\s+if UserDefaults\.standard\.bool\(forKey: "CraftFakeWorkoutScheduler"\)/)
  })
})
