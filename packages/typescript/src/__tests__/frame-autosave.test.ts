/**
 * `frameAutosave` — windows that remember where they were (craft-native/craft#52).
 *
 * There was no `setFrameAutosaveName:` anywhere in the tree, so every Craft
 * window forgot its geometry on every launch. An app that wanted the standard
 * behaviour had to wire `onResize`/`onMove` to its own storage and restore on
 * next start, reimplementing badly what AppKit does in one call.
 */

import type { AppConfig } from '../types'
import { describe, expect, it } from 'bun:test'

async function argsFor(config: AppConfig): Promise<string[]> {
  const { CraftApp } = await import('../index')
  const app = new (CraftApp as unknown as { new (c: AppConfig): { buildArgs: () => string[] } })(config)
  return (app as unknown as { buildArgs: () => string[] }).buildArgs()
}

function valueOf(args: string[], flag: string): string | undefined {
  const index = args.indexOf(flag)
  return index === -1 ? undefined : args[index + 1]
}

describe('frameAutosave', () => {
  it('passes the autosave name through to the binary', async () => {
    const args = await argsFor({ window: { frameAutosave: 'main' } })
    expect(valueOf(args, '--frame-autosave')).toBe('main')
  })

  it('is absent when not configured, so nothing is remembered', async () => {
    // The default has to stay "forgets its geometry": silently starting to
    // persist frames would move existing apps' windows on upgrade.
    const args = await argsFor({ window: { width: 900, height: 700 } })
    expect(args).not.toContain('--frame-autosave')
  })

  it('coexists with explicit geometry rather than replacing it', async () => {
    // The two are not alternatives. `width`/`height`/`x`/`y` are what the
    // window opens at the first time, before there is any saved frame to
    // restore — so both must reach the binary.
    const args = await argsFor({
      window: { frameAutosave: 'main', width: 900, height: 700, x: 40, y: 60 },
    })
    expect(valueOf(args, '--frame-autosave')).toBe('main')
    expect(valueOf(args, '--width')).toBe('900')
    expect(valueOf(args, '--height')).toBe('700')
    expect(valueOf(args, '--x')).toBe('40')
    expect(valueOf(args, '--y')).toBe('60')
  })

  it('survives a name containing spaces as a single argument', async () => {
    const args = await argsFor({ window: { frameAutosave: 'Main Window' } })
    expect(valueOf(args, '--frame-autosave')).toBe('Main Window')
    expect(args.filter(a => a === 'Main Window')).toHaveLength(1)
  })
})
