/**
 * macOS bundle mechanics.
 *
 * The swap is the part worth testing without a signing certificate: it is the
 * step that can destroy the user's installed app, and every one of its failure
 * modes is reachable with ordinary directories.
 */

import { execFileSync } from 'child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import { AutoUpdater, DeltaGenerator } from '../updater/index'
import {
  canReplaceBundle,
  extractBundleFromZip,
  readBundleIdentity,
  swapBundle,
  verifyBundleTrust,
} from '../updater/macos-bundle'

const darwin = process.platform === 'darwin'

let work: string

beforeEach(() => {
  work = mkdtempSync(join(tmpdir(), 'craft-bundle-test-'))
})

afterEach(() => {
  rmSync(work, { recursive: true, force: true })
})

/** A directory shaped enough like a bundle for the file operations to be real. */
function makeBundle(path: string, marker: string): string {
  mkdirSync(join(path, 'Contents/MacOS'), { recursive: true })
  writeFileSync(join(path, 'Contents/MacOS/App'), marker)
  return path
}

/**
 * A bundle `codesign` will actually sign.
 *
 * It needs an `Info.plist` naming a `CFBundleExecutable`, and that executable
 * has to be a real Mach-O — a text file gets "bundle format unrecognized".
 * Borrowing a system binary is cheaper than compiling one and makes the test
 * independent of a toolchain.
 */
function makeSignableBundle(path: string): string {
  mkdirSync(join(path, 'Contents/MacOS'), { recursive: true })
  copyFileSync('/bin/echo', join(path, 'Contents/MacOS/App'))
  writeFileSync(join(path, 'Contents/Info.plist'), [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0"><dict>',
    '<key>CFBundleExecutable</key><string>App</string>',
    '<key>CFBundleIdentifier</key><string>org.craft.test.bundle</string>',
    '<key>CFBundleName</key><string>App</string>',
    '<key>CFBundlePackageType</key><string>APPL</string>',
    '<key>CFBundleShortVersionString</key><string>1.0</string>',
    '</dict></plist>',
  ].join('\n'))
  return path
}

describe('swapBundle', () => {
  it('replaces the installed bundle and removes the old one', async () => {
    const installed = makeBundle(join(work, 'App.app'), 'old')
    const staged = makeBundle(join(work, 'staging', 'App.app'), 'new')

    const result = await swapBundle(staged, installed)

    expect(readFileSync(join(installed, 'Contents/MacOS/App'), 'utf8')).toBe('new')
    expect(result.previousPath).toBeNull()
  })

  it('leaves nothing behind in the install directory', async () => {
    const installed = makeBundle(join(work, 'App.app'), 'old')
    const staged = makeBundle(join(work, 'staging', 'App.app'), 'new')

    await swapBundle(staged, installed)

    // The retired and incoming copies are dotfiles in the same directory; a
    // swap that forgets to clean them up doubles disk use on every update.
    expect(readdirSync(work).filter(n => n !== 'staging')).toEqual(['App.app'])
  })

  it('installs into a path that has no bundle yet', async () => {
    const installed = join(work, 'App.app')
    const staged = makeBundle(join(work, 'staging', 'App.app'), 'fresh')

    const result = await swapBundle(staged, installed)

    expect(readFileSync(join(installed, 'Contents/MacOS/App'), 'utf8')).toBe('fresh')
    expect(result.previousPath).toBeNull()
  })

  it('refuses a staged path that does not exist, leaving the install intact', async () => {
    const installed = makeBundle(join(work, 'App.app'), 'old')

    await expect(swapBundle(join(work, 'missing.app'), installed)).rejects.toThrow(/missing/)
    expect(readFileSync(join(installed, 'Contents/MacOS/App'), 'utf8')).toBe('old')
  })

  it('crosses a filesystem boundary by copying rather than failing', async () => {
    // `rename` across devices fails with EXDEV. The staging directory being on
    // a different volume from /Applications is the normal case, not the edge
    // one, so the copy fallback is what runs in production.
    const installed = makeBundle(join(work, 'App.app'), 'old')
    const otherVolume = mkdtempSync(join(tmpdir(), 'craft-elsewhere-'))
    try {
      const staged = makeBundle(join(otherVolume, 'App.app'), 'new')
      await swapBundle(staged, installed)
      expect(readFileSync(join(installed, 'Contents/MacOS/App'), 'utf8')).toBe('new')
    }
    finally {
      rmSync(otherVolume, { recursive: true, force: true })
    }
  })
})

describe('canReplaceBundle', () => {
  it('is true for a writable parent directory', () => {
    expect(canReplaceBundle(join(work, 'App.app'))).toBe(true)
  })

  it('is false when the parent does not exist', () => {
    expect(canReplaceBundle(join(work, 'nowhere', 'App.app'))).toBe(false)
  })
})

describe('verifyBundleTrust', () => {
  it('reports a missing bundle rather than throwing', async () => {
    const result = await verifyBundleTrust(join(work, 'nope.app'))
    expect(result.ok).toBe(false)
    expect(result.reason).toBe('unreadable')
  })

  it.if(darwin)('rejects an unsigned directory', async () => {
    const bundle = makeSignableBundle(join(work, 'Unsigned.app'))
    const result = await verifyBundleTrust(bundle)
    expect(result.ok).toBe(false)
    expect(result.reason).toBe('codesign-invalid')
  })

  it.if(darwin)('reads nothing but nulls out of an unsigned bundle', async () => {
    const bundle = makeSignableBundle(join(work, 'Unsigned.app'))
    const identity = await readBundleIdentity(bundle)
    expect(identity.teamId).toBeNull()
  })

  it.if(darwin)('fails a team mismatch on an ad-hoc signed bundle', async () => {
    const bundle = makeSignableBundle(join(work, 'AdHoc.app'))
    // `-s -` is an ad-hoc signature: structurally valid, no team, no
    // notarization. It separates "the signature verifies" from "we trust who
    // made it", which is the distinction the policy exists to enforce.
    execFileSync('codesign', ['--force', '--sign', '-', bundle])

    const result = await verifyBundleTrust(bundle, { teamId: 'ABCDE12345', requireNotarized: false })
    expect(result.ok).toBe(false)
    expect(result.reason).toBe('team-mismatch')
  })

  it.if(darwin)('accepts an ad-hoc bundle when no team is pinned and Gatekeeper is not consulted', async () => {
    const bundle = makeSignableBundle(join(work, 'AdHoc2.app'))
    execFileSync('codesign', ['--force', '--sign', '-', bundle])

    const result = await verifyBundleTrust(bundle, { requireNotarized: false })
    expect(result.ok).toBe(true)
  })

  it.if(darwin)('rejects an ad-hoc bundle once Gatekeeper is consulted', async () => {
    // The default. An unnotarized build must not pass the policy an updater
    // runs with, or the trust check is decorative.
    const bundle = makeSignableBundle(join(work, 'AdHoc3.app'))
    execFileSync('codesign', ['--force', '--sign', '-', bundle])

    const result = await verifyBundleTrust(bundle)
    expect(result.ok).toBe(false)
    expect(result.reason).toBe('gatekeeper-rejected')
  })
})

describe('extractBundleFromZip', () => {
  it.if(darwin)('finds the bundle in an archive', async () => {
    const source = makeBundle(join(work, 'src', 'App.app'), 'payload')
    const archive = join(work, 'App.zip')
    execFileSync('ditto', ['-c', '-k', '--keepParent', source, archive])

    const staged = await extractBundleFromZip(archive, join(work, 'out'))

    expect(existsSync(staged.appPath)).toBe(true)
    expect(readFileSync(join(staged.appPath, 'Contents/MacOS/App'), 'utf8')).toBe('payload')
  })
})

describe('DeltaGenerator.isSupported', () => {
  it('answers without throwing on a machine with no diff tool', () => {
    expect(typeof DeltaGenerator.isSupported()).toBe('boolean')
  })
})

describe('AutoUpdater.getLastError', () => {
  /**
   * `checkForUpdates` returns null both when there is no newer version and
   * when it could not find out. Without a way to tell those apart, an app
   * shows "you are up to date" to a user whose network is down — the one
   * wrong answer an update check can give, because it is confident and it
   * stops them looking further.
   */
  function updaterForMissingManifest(): AutoUpdater {
    const updater = new AutoUpdater({
      updateUrl: 'file:///definitely/missing/update.json',
      currentVersion: '1.0.0',
      appPath: join(work, 'App.app'),
      autoDownload: false,
    })
    // An EventEmitter with no `error` listener throws on emit.
    updater.on('error', () => {})
    return updater
  }

  it('is null before anything has been attempted', () => {
    expect(updaterForMissingManifest().getLastError()).toBeNull()
  })

  it('records why a check could not complete', async () => {
    const updater = updaterForMissingManifest()
    const result = await updater.checkForUpdates()

    expect(result).toBeNull()
    expect(updater.getLastError()).not.toBeNull()
  })

  it('is cleared when a later check starts', async () => {
    const updater = updaterForMissingManifest()
    await updater.checkForUpdates()
    expect(updater.getLastError()).not.toBeNull()

    // A stale error outliving its attempt is the same bug in the other
    // direction: a successful check that still reports the previous failure.
    const pending = updater.checkForUpdates()
    expect(updater.getLastError()).toBeNull()
    await pending
  })
})
