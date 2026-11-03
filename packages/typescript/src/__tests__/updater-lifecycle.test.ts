import { afterEach, describe, expect, it } from 'bun:test'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AutoUpdater } from '../updater'

const running: AutoUpdater[] = []
afterEach(() => { for (const updater of running.splice(0)) updater.stopAutoCheck() })
const waitFor = async (condition: () => boolean) => {
  for (let i = 0; i < 200; i++) {
    if (condition()) return
    await Bun.sleep(5)
  }
  throw new Error('Updater did not settle')
}
function fixture() {
  const updater = new AutoUpdater({ updateUrl: 'https://example.com/update.json', currentVersion: '1.0.0', appPath: '/Applications/Fixture.app', checkInterval: 80, autoDownload: false })
  running.push(updater)
  let checks = 0
  let downloads = 0
  let installs = 0
  const update = { version: '1.0.1', releaseDate: '2026-01-01', platforms: {} }
  updater.checkForUpdates = async () => { checks++; return update }
  updater.downloadUpdate = async () => { downloads++; return '/verified/update.zip' }
  updater.installUpdate = async () => { installs++ }
  return { updater, checks: () => checks, downloads: () => downloads, installs: () => installs }
}

describe('automatic update lifecycle', () => {
  it('delays the first check, honors changing native preferences and stops cleanly', async () => {
    const f = fixture()
    let enabled = false
    f.updater.startAutoCheck({ initialDelay: 30, policyInterval: 10, enabled: async () => enabled, autoDownload: true })
    await Bun.sleep(50)
    expect(f.checks()).toBe(0)
    enabled = true
    await waitFor(() => f.downloads() === 1)
    expect(f.checks()).toBe(1)
    expect(f.installs()).toBe(0)
    enabled = false
    await Bun.sleep(100)
    expect(f.checks()).toBe(1)
    enabled = true
    await waitFor(() => f.checks() === 2)
    f.updater.stopAutoCheck()
    await Bun.sleep(100)
    expect(f.checks()).toBe(2)
  })
  it('is idempotent and invalidates an awaited policy on stop', async () => {
    const f = fixture()
    let resolve!: (enabled: boolean) => void
    f.updater.startAutoCheck({ enabled: () => new Promise<boolean>(done => { resolve = done }) })
    f.updater.startAutoCheck()
    await waitFor(() => !!resolve)
    f.updater.stopAutoCheck()
    resolve(true)
    await Bun.sleep(30)
    expect(f.checks()).toBe(0)
    f.updater.startAutoCheck({ autoDownload: false })
    await waitFor(() => f.checks() === 1)
    expect(f.downloads()).toBe(0)
  })
  it('rechecks the preference before downloading and reports policy failures', async () => {
    const f = fixture()
    let reads = 0
    f.updater.startAutoCheck({ enabled: () => ++reads === 1, autoDownload: true })
    await waitFor(() => f.checks() === 1)
    expect(f.downloads()).toBe(0)
    f.updater.stopAutoCheck()
    let error: Error | undefined
    f.updater.on('error', value => { error = value })
    f.updater.startAutoCheck({ enabled: () => { throw new Error('Preference unavailable') } })
    await waitFor(() => !!error)
    expect(error!.message).toBe('Preference unavailable')
    expect(f.downloads()).toBe(0)
  })
  it('shares real concurrent manifest checks', async () => {
    const originalFetch = globalThis.fetch
    let requests = 0
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    const updater = new AutoUpdater({ updateUrl: 'https://example.com/update.json', currentVersion: '1.0.0', appPath: '/Applications/Fixture.app', autoDownload: false })
    globalThis.fetch = (async () => { requests++; await gate; return Response.json({ version: '1.0.1', platforms: {}, releaseDate: '2026-01-01' }) }) as unknown as typeof fetch
    try {
      const first = updater.checkForUpdates()
      expect(updater.checkForUpdates()).toBe(first)
      release()
      expect((await first)!.version).toBe('1.0.1')
      expect(requests).toBe(1)
    }
    finally { globalThis.fetch = originalFetch }
  })
  it('shares a download until verification, retries failures, and preserves a ready archive', async () => {
    const originalFetch = globalThis.fetch
    const directory = mkdtempSync(join(tmpdir(), 'craft-update-lifecycle-'))
    const payload = 'verified archive fixture'
    let downloads = 0
    let fail = true
    const updater = new AutoUpdater({ updateUrl: 'https://example.com/update.json', currentVersion: '1.0.0', appPath: '/Applications/Fixture.app', downloadDir: directory, autoDownload: false, checkInterval: 10 })
    running.push(updater)
    updater.on('error', () => {})
    const platform = { url: 'https://example.com/update.zip', size: payload.length, sha256: createHash('sha256').update(payload).digest('hex') }
    globalThis.fetch = (async (url: string | URL | Request) => {
      if (String(url).includes('update.json')) return Response.json({ version: '1.0.1', platforms: { [process.platform]: platform }, releaseDate: '2026-01-01' })
      downloads++
      await Bun.sleep(15)
      return new Response(fail ? 'corrupt' : payload)
    }) as unknown as typeof fetch
    try {
      await updater.checkForUpdates()
      const failed = updater.downloadUpdate()
      expect(updater.downloadUpdate()).toBe(failed)
      expect(await failed).toBeNull()
      fail = false
      const pending = updater.downloadUpdate()
      expect(updater.downloadUpdate()).toBe(pending)
      const path = await pending
      expect(readFileSync(path!, 'utf8')).toBe(payload)
      expect(await updater.downloadUpdate()).toBe(path)
      expect(downloads).toBe(2)
      updater.startAutoCheck({ policyInterval: 5, autoDownload: true })
      await Bun.sleep(40)
      expect(downloads).toBe(2)
    }
    finally { updater.stopAutoCheck(); globalThis.fetch = originalFetch; rmSync(directory, { recursive: true, force: true }) }
  })
  it('rejects invalid timing policies', () => {
    const f = fixture()
    for (const policy of [{ initialDelay: -1 }, { initialDelay: Infinity }, { policyInterval: 0 }, { policyInterval: NaN }])
      expect(() => f.updater.startAutoCheck(policy)).toThrow('intervals')
  })
})
