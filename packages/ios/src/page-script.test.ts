import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'

// The script CraftApp.swift injects into every page, run here against a fake
// native side. The E2E suite runs it on a simulator too, but with one config
// per run, so a path that needs a capability both on and off is checked here.

const template = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')

/** The page script, as the string Swift evaluates, with every flag off. */
function pageScript(): string {
  const opening = 'let script = """\n            window.craft = {'
  const start = template.indexOf(opening)
  if (start === -1) throw new Error('CraftApp.swift no longer injects `window.craft = {` from `let script`')
  const end = template.indexOf('\n            """', start)
  return template
    .slice(template.indexOf('\n', start) + 1, end)
    // `\(config.enableHaptics)` and the like. Each is a Bool in the template.
    .replace(/\\\((?:[^()]|\([^()]*\))*\)/g, 'false')
    .replace(/\\\\/g, '\\')
}

interface Post { action: string, callbackId?: string, [key: string]: unknown }

function loadPage() {
  const posts: Post[] = []
  const listeners: Record<string, ((event: { type: string, detail: unknown }) => void)[]> = {}
  const page: Record<string, any> = {
    webkit: { messageHandlers: { craft: { postMessage: (message: Post) => posts.push(message) } } },
    addEventListener: (type: string, listener: (event: { type: string, detail: unknown }) => void) => {
      (listeners[type] ||= []).push(listener)
    },
    removeEventListener: () => {},
    dispatchEvent: (event: { type: string, detail: unknown }) => {
      for (const listener of listeners[event.type] || []) listener(event)
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
  // eslint-disable-next-line no-new-func
  new Function('window', 'document', 'navigator', 'CustomEvent', 'console', pageScript())(
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
    // What Swift's resolveCallback and rejectCallback evaluate.
    answer: (action: string, value: unknown) => craft._resolveCallback(last(action).callbackId, value),
    refuse: (action: string, message: string, code: string) => craft._rejectCallback(last(action).callbackId, message, code),
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
    ['clearWatch', craft => craft.geolocation.clearWatch()],
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

  it('hands a refusal to the caller of the raw call', async () => {
    const page = loadPage()
    const haptic = page.craft.haptic('light')
    page.refuse('haptic', 'Haptics is disabled', 'CAPABILITY_DISABLED')

    await expect(haptic).rejects.toMatchObject({ code: 'CAPABILITY_DISABLED' })
  })

  it('sends the v1 location clearWatch with an id once the last watch leaves', async () => {
    const page = loadPage()
    const first = page.craft.location.watchPosition(() => {})
    const second = page.craft.location.watchPosition(() => {})
    page.answer('watchPosition', true)

    page.craft.location.clearWatch(first)
    expect(() => page.last('clearWatch')).toThrow()
    page.craft.location.clearWatch(second)
    expect(page.last('clearWatch').callbackId).toMatch(/^cb_\d+$/)
    page.answer('clearWatch', true)
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
})
