/**
 * `headless` and the DevTools flag (craft-native/craft#48).
 *
 * The issue is that there is no way to drive a craft window from outside the
 * process, and that measurement loops had to spawn *visible* windows over and
 * over — which the issue rightly calls hostile to photosensitive users.
 */

import type { AppConfig } from '../types'
import { describe, expect, it } from 'bun:test'

async function argsFor(config: AppConfig): Promise<string[]> {
  const { CraftApp } = await import('../index')
  const app = new (CraftApp as unknown as { new (c: AppConfig): { buildArgs: () => string[] } })(config)
  return (app as unknown as { buildArgs: () => string[] }).buildArgs()
}

describe('headless', () => {
  it('passes the flag through', async () => {
    expect(await argsFor({ window: { headless: true } })).toContain('--headless')
  })

  it('is absent unless asked for', async () => {
    expect(await argsFor({ window: { width: 900 } })).not.toContain('--headless')
  })

  it('does not change what the window is, only whether it is shown', async () => {
    // A headless run has to build the same window a visible one would, or a
    // measurement taken from it says nothing about the visible case.
    const args = await argsFor({ window: { headless: true, width: 900, height: 700, title: 'T' } })
    expect(args).toContain('--headless')
    expect(args[args.indexOf('--width') + 1]).toBe('900')
    expect(args[args.indexOf('--height') + 1]).toBe('700')
    expect(args[args.indexOf('--title') + 1]).toBe('T')
  })
})

describe('devTools', () => {
  it('is pushed in both directions', async () => {
    // The regression: the binary defaults DevTools off and had no flag that
    // turned them on, so the SDK pushing only the negative meant `devTools:
    // true` — what dev mode sets — silently did nothing.
    expect(await argsFor({ window: { devTools: true } })).toContain('--dev-tools')
    expect(await argsFor({ window: { devTools: false } })).toContain('--no-devtools')
  })

  it('always has an opinion, because the SDK fills one in', async () => {
    // `window: {}` does not mean "unset": the SDK defaults `devTools` to
    // `detectDevMode()`, so exactly one of the two flags is always sent. That
    // is what makes the positive flag necessary — without it, dev mode asked
    // for DevTools and got silence.
    const args = await argsFor({ window: {} })
    const sent = args.filter(a => a === '--dev-tools' || a === '--no-devtools')
    expect(sent).toHaveLength(1)
  })
})
