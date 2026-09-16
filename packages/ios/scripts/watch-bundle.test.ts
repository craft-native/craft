import { afterEach, describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { watchCompanionProblems } from './watch-bundle'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

/** A built app's directory shape, with plists served from memory. */
function bundle(parts: { watch?: boolean, extension?: boolean }) {
  const root = mkdtempSync(join(tmpdir(), 'craft-watch-bundle-'))
  roots.push(root)
  const app = join(root, 'Probe.app')
  mkdirSync(app, { recursive: true })
  if (parts.watch) mkdirSync(join(app, 'Watch', 'ProbeWatch.app'), { recursive: true })
  if (parts.extension) mkdirSync(join(app, 'Watch', 'ProbeWatch.app', 'PlugIns', 'ProbeWatchExtension.appex'), { recursive: true })
  return app
}

const complete = (path: string): Record<string, unknown> | null =>
  path.includes('.appex')
    ? { NSExtension: { NSExtensionPointIdentifier: 'com.apple.watchkit' } }
    : { WKWatchKitApp: true, WKCompanionAppBundleIdentifier: 'dev.craft.probe' }

describe('watchCompanionProblems', () => {
  it('passes the WatchKit 2 companion the generator now emits', () => {
    expect(watchCompanionProblems(bundle({ watch: true, extension: true }), 'Probe', complete)).toEqual([])
  })

  it('names #194: a Watch app with no WatchKit marker', () => {
    const noMarker = (path: string) => (path.includes('.appex') ? complete(path) : { WKCompanionAppBundleIdentifier: 'dev.craft.probe' })
    expect(watchCompanionProblems(bundle({ watch: true, extension: true }), 'Probe', noMarker)).toEqual([
      'Watch/ProbeWatch.app sets neither WKWatchKitApp nor WKApplication to true, so iOS will not install it (#194)',
    ])
  })

  it('accepts WKApplication, the single-target marker, in place of WKWatchKitApp', () => {
    const modern = (path: string) => (path.includes('.appex') ? complete(path) : { WKApplication: true })
    expect(watchCompanionProblems(bundle({ watch: true, extension: true }), 'Probe', modern)).toEqual([])
  })

  it('names #195: a Watch app with no extension inside it', () => {
    expect(watchCompanionProblems(bundle({ watch: true }), 'Probe', complete)).toEqual([
      'Watch/ProbeWatch.app has no PlugIns/ProbeWatchExtension.appex, so it is not a WatchKit 2 app (#195)',
    ])
  })

  it('says when there is no Watch app to check at all', () => {
    expect(watchCompanionProblems(bundle({}), 'Probe', complete)).toEqual(['Probe.app embeds no Watch/ProbeWatch.app'])
  })

  it('checks the extension is a WatchKit extension, not merely present', () => {
    const wrongPoint = (path: string) => (path.includes('.appex') ? { NSExtension: { NSExtensionPointIdentifier: 'com.apple.widgetkit-extension' } } : complete(path))
    expect(watchCompanionProblems(bundle({ watch: true, extension: true }), 'Probe', wrongPoint)).toEqual([
      'ProbeWatchExtension.appex declares extension point "com.apple.widgetkit-extension", not com.apple.watchkit',
    ])
  })
})
