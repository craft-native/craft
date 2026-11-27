import { expect, it } from 'bun:test'

/**
 * #587's drag-region measuring runs from timers. On 204deb8d0 it read
 * `document.querySelectorAll` in a harness whose loaded `document` had no
 * DOM, and the throw surfaced in later, unrelated tests (WebSocketClient,
 * simulator recordings). Where there is no DOM it now measures nothing, and
 * nothing it does escapes the timer.
 */

const BRIDGE_SRC = await Bun.file(new URL('../../../zig/src/js/craft-bridge.js', import.meta.url)).text()

function load(doc: Record<string, unknown>): { sent: Array<{ a: string }>, warned: unknown[][], timers: ReturnType<typeof setTimeout>[] } {
  const sent: Array<{ a: string }> = []
  const warned: unknown[][] = []
  const timers: ReturnType<typeof setTimeout>[] = []
  const win: any = {
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => true,
    webkit: { messageHandlers: { craft: { postMessage: (m: { a: string }) => { sent.push(m) } } } },
  }
  const console_ = { ...console, error: () => {}, warn: (...a: unknown[]) => { warned.push(a) } }
  // Real timers, so the 100 ms fallback actually fires inside this test.
  const timeout = (fn: () => void, ms?: number) => {
    const timer = setTimeout(fn, ms)
    timers.push(timer)
    return timer
  }
  // eslint-disable-next-line no-new-func
  const run = new Function('window', 'document', 'console', 'setTimeout', 'clearTimeout', 'setInterval', BRIDGE_SRC)
  run(win, doc, console_, timeout, clearTimeout, () => 0)
  return { sent, warned, timers }
}

it('a loaded document with no DOM measures nothing and throws nothing later (#587)', async () => {
  const { sent, warned, timers } = load({ readyState: 'complete', addEventListener: () => {} })
  await new Promise(resolve => setTimeout(resolve, 250))
  expect(sent.filter(message => message.a === 'setDragRegions')).toEqual([])
  expect(warned).toEqual([])
  for (const timer of timers) clearTimeout(timer)
})

it('a measuring error is caught and reported, not thrown into the next task', async () => {
  const { warned, timers } = load({
    readyState: 'complete',
    addEventListener: () => {},
    querySelectorAll: () => { throw new Error('torn down') },
  })
  await new Promise(resolve => setTimeout(resolve, 250))
  expect(String(warned[0]?.[0])).toContain('could not measure drag regions')
  for (const timer of timers) clearTimeout(timer)
})
