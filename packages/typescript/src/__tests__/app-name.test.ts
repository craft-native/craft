/**
 * `appName` — the name macOS shows in the menu bar (craft-native/craft#50).
 *
 * The App menu title and the About/Hide/Quit items come from
 * `NSProcessInfo.processName`, which for a bare binary is the executable — so
 * every app launched through the shared `craft` binary called itself "craft".
 * The workaround downstream was to symlink the binary under the app's name and
 * spawn through the symlink.
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

describe('appName', () => {
  it('passes the name through to the binary', async () => {
    const args = await argsFor({ appName: 'Harness', html: '<h1>hi</h1>' })
    expect(valueOf(args, '--app-name')).toBe('Harness')
  })

  it('is absent when not configured, so the binary keeps its own default', async () => {
    const args = await argsFor({ html: '<h1>hi</h1>' })
    expect(args).not.toContain('--app-name')
  })

  it('is independent of the window title', async () => {
    // A note-taking app is "Notes" in the menu bar whatever the open document
    // has put in the title bar. Conflating the two is the reason `--title`
    // could not be used for this.
    const args = await argsFor({
      appName: 'Notes',
      window: { title: 'Untitled — edited' },
    })
    expect(valueOf(args, '--app-name')).toBe('Notes')
    expect(valueOf(args, '--title')).toBe('Untitled — edited')
  })

  it('survives a name containing spaces as a single argument', async () => {
    // argv, not a shell string: the name must arrive whole rather than as
    // three arguments the parser would read as a URL.
    const args = await argsFor({ appName: 'My Great App' })
    expect(valueOf(args, '--app-name')).toBe('My Great App')
    expect(args.filter(a => a === 'My Great App')).toHaveLength(1)
  })

  it('is emitted even in menubar-only mode', async () => {
    // A menubar app has no window at all, and the App menu is the only place
    // its name is ever shown — so this is the mode that needs it most.
    const args = await argsFor({ appName: 'Hush', window: { menubarOnly: true } })
    expect(valueOf(args, '--app-name')).toBe('Hush')
    expect(args).toContain('--menubar-only')
  })
})
