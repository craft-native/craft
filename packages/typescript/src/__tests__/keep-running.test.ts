/**
 * `keepRunning` — whether the app outlives its last window (craft-native/craft#63).
 *
 * The flag is tri-state on purpose. Unset is not the same as `false`: unset
 * lets craft decide from the shape of the app (a tray or menubar-only app
 * stays, a windowed app quits), while `false` is an app saying it wants to go
 * away with its window even though it has a tray. Collapsing the two would
 * make the setting unable to express the case most likely to need it.
 */

import type { AppConfig } from '../types'
import { describe, expect, it } from 'bun:test'

async function argsFor(config: AppConfig): Promise<string[]> {
  const { CraftApp } = await import('../index')
  const app = new (CraftApp as unknown as { new (c: AppConfig): { buildArgs: () => string[] } })(config)
  return (app as unknown as { buildArgs: () => string[] }).buildArgs()
}

describe('keepRunning', () => {
  it('passes --keep-running when the app asks to stay', async () => {
    expect(await argsFor({ window: { keepRunning: true } })).toContain('--keep-running')
  })

  it('passes --quit-on-close when the app asks to go', async () => {
    const args = await argsFor({ window: { systemTray: true, keepRunning: false } })
    expect(args).toContain('--quit-on-close')
    expect(args).not.toContain('--keep-running')
  })

  it('passes neither when the app has not said', async () => {
    // Craft's own default then applies, which is the point of leaving it unset.
    const args = await argsFor({ window: { width: 900 } })
    expect(args).not.toContain('--keep-running')
    expect(args).not.toContain('--quit-on-close')
  })

  it('does not confuse an unset value with false', async () => {
    // `if (x)` would send nothing for false; `if (x !== undefined)` would send
    // --quit-on-close for unset. Both are wrong and both are easy to write.
    const unset = await argsFor({ window: { systemTray: true } })
    const explicitFalse = await argsFor({ window: { systemTray: true, keepRunning: false } })
    expect(unset).not.toContain('--quit-on-close')
    expect(explicitFalse).toContain('--quit-on-close')
  })

  it('leaves the rest of the window config alone', async () => {
    const args = await argsFor({ window: { keepRunning: true, title: 'T', width: 900 } })
    expect(args).toContain('--keep-running')
    expect(args).toContain('--title')
    expect(args).toContain('T')
  })
})
