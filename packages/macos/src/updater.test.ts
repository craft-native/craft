import type { KeyObject } from 'node:crypto'
import { afterAll, expect, test } from 'bun:test'
import { createHash, generateKeyPairSync, sign } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import process from 'node:process'
import { buildMacOSNative } from './index'

/*
 * The release side of updates, as the tooling that signs them does it (Stacks'
 * desktop package, `updater.ts` and `update-signing.ts`): the canonical payload
 * is `JSON.stringify` of these ten fields in this order, signed with Ed25519,
 * and the public key travels as `ed25519-public:<base64url SPKI DER>`. The
 * Swift updater has to agree with every byte of it.
 */
interface Manifest {
  version: string
  url: string
  sha256: string
  size: number
  sourceRevision: string
  platform: string
  architecture: string
  signingKeyId: string
  signature: string
  publishedAt?: string
  notes?: string
}

function payload(manifest: Manifest): Buffer {
  return Buffer.from(JSON.stringify({
    version: manifest.version,
    url: manifest.url,
    sha256: manifest.sha256.toLowerCase(),
    size: manifest.size,
    sourceRevision: manifest.sourceRevision,
    platform: manifest.platform,
    architecture: manifest.architecture,
    signingKeyId: manifest.signingKeyId,
    publishedAt: manifest.publishedAt || null,
    notes: manifest.notes || null,
  }), 'utf8')
}

function keypair(): { privateKey: KeyObject, publicKey: string } {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519')
  return { privateKey, publicKey: `ed25519-public:${publicKey.export({ format: 'der', type: 'spki' }).toString('base64url')}` }
}

function signed(unsigned: Omit<Manifest, 'signature' | 'signingKeyId'>, privateKey: KeyObject, keyId = 'main'): Manifest {
  const manifest = { ...unsigned, signingKeyId: keyId, signature: '' }
  manifest.signature = sign(null, payload(manifest), privateKey).toString('base64url')
  return manifest
}

function parseVersion(version: string): [number, number, number] {
  const match = version.match(/^v?(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?$/)
  if (!match) throw new Error(`Invalid semantic version: ${version}`)
  return [Number(match[1]), Number(match[2]), Number(match[3])]
}

function compareVersions(left: string, right: string): number {
  const a = parseVersion(left)
  const b = parseVersion(right)
  for (let index = 0; index < 3; index++) {
    if (a[index] !== b[index]) return Math.sign(a[index]! - b[index]!)
  }
  return 0
}

function updateFeedUrl(feedUrl: string, target: { platform: string, architecture: string }, query: { channel?: string, currentVersion?: string } = {}): string {
  const url = new URL(`${feedUrl.replace(/\/+$/, '')}/${target.platform}/${target.architecture}`)
  if (query.channel && query.channel !== 'stable') url.searchParams.set('channel', query.channel)
  if (query.currentVersion) url.searchParams.set('current', query.currentVersion)
  return url.toString()
}

const root = resolve(import.meta.dir, '../../..')
const architecture = process.arch === 'arm64' ? 'arm64' : 'x64'
const scratch = mkdtempSync(join(tmpdir(), 'craft-macos-updater-'))
const fixtureIdentifier = 'dev.craft.updater-fixture'
afterAll(() => {
  // Anything the swap test left running was started from this folder.
  Bun.spawnSync(['pkill', '-f', scratch])
  Bun.spawnSync(['hdiutil', 'detach', '-quiet', '-force', join(scratch, 'volume')])
  rmSync(scratch, { recursive: true, force: true })
  rmSync(join(homedir(), 'Library/Caches', fixtureIdentifier), { recursive: true, force: true })
// Detaching a disk image can wait on the system; the inherited 5 s is not a budget for it.
}, 60_000)

async function run(args: string[], cwd = root): Promise<string> {
  const child = Bun.spawn(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
  const [code, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
  expect({ code, error: code === 0 ? '' : err }).toEqual({ code: 0, error: '' })
  return out
}

const revision = 'a'.repeat(40)
const unsigned = { version: '1.0.1', url: 'https://updates.example.com/files/stable/darwin-arm64/1.0.1/update.zip', sha256: 'c'.repeat(64), size: 1234, sourceRevision: revision, platform: 'darwin', architecture }

test.skipIf(process.platform !== 'darwin')('agrees with the release tooling on what a signed manifest is, and refuses everything else', async () => {
  const main = keypair()
  const other = keypair()
  const keys = { main: main.publicKey }
  const good = signed({ ...unsigned, publishedAt: '2026-11-14T10:00:00.000Z', notes: 'Faster search.' }, main.privateKey)
  const awkward = 'Quotes " and \\ and a tab\t, a line\nbreak, a bell \u0007, a DEL \u007F, a separator \u2028, a slash /, an umlaut ü, and a rocket 🚀 <b>&amp;</b>'
  const manifests: Array<{ name: string, manifest: unknown, keys?: Record<string, string>, currentVersion?: string, architecture?: string, expect: string, error?: RegExp }> = [
    { name: 'a newer build signed by a trusted key', manifest: good, expect: 'available' },
    { name: 'notes full of characters JSON escapes', manifest: signed({ ...unsigned, notes: awkward }, main.privateKey), expect: 'available' },
    { name: 'notes that open with a byte order mark', manifest: signed({ ...unsigned, notes: '\uFEFFFrom a file an editor saved with a mark.' }, main.privateKey), expect: 'available' },
    { name: 'no date and no notes sign as null', manifest: signed(unsigned, main.privateKey), expect: 'available' },
    { name: 'an empty date signs as null too', manifest: signed({ ...unsigned, publishedAt: '', notes: '' }, main.privateKey), expect: 'available' },
    { name: 'an upper-case checksum signs in lower case', manifest: signed({ ...unsigned, sha256: 'AB'.repeat(32) }, main.privateKey), expect: 'available' },
    { name: 'a pre-release tag takes no part in the order', manifest: signed({ ...unsigned, version: 'v2.0.0-beta.1' }, main.privateKey), expect: 'available' },
    { name: 'a loopback http download, for development', manifest: signed({ ...unsigned, url: 'http://127.0.0.1:4010/update.zip' }, main.privateKey), expect: 'available' },
    { name: 'the same version', manifest: good, currentVersion: '1.0.1', expect: 'current' },
    { name: 'an older version', manifest: good, currentVersion: '1.2.0', expect: 'current' },
    { name: 'a download address changed after signing', manifest: { ...good, url: 'https://evil.example.com/update.zip' }, expect: 'error', error: /signature verification failed/ },
    { name: 'a checksum changed after signing', manifest: { ...good, sha256: 'd'.repeat(64) }, expect: 'error', error: /signature verification failed/ },
    { name: 'a size changed after signing', manifest: { ...good, size: 1235 }, expect: 'error', error: /signature verification failed/ },
    { name: 'a version raised after signing', manifest: { ...good, version: '9.0.0' }, expect: 'error', error: /signature verification failed/ },
    { name: 'notes changed after signing', manifest: { ...good, notes: 'Faster search!' }, expect: 'error', error: /signature verification failed/ },
    { name: 'signed by a key the app does not hold', manifest: signed(unsigned, other.privateKey), expect: 'error', error: /signature verification failed/ },
    { name: 'a key id the app does not trust', manifest: signed(unsigned, other.privateKey, 'other'), expect: 'error', error: /not trusted: other/ },
    { name: 'a trusted key in the wrong encoding', manifest: good, keys: { main: main.publicKey.replace('ed25519-public:', '') }, expect: 'error', error: /invalid encoding/ },
    { name: 'a trusted key that is not an Ed25519 public key', manifest: good, keys: { main: `ed25519-public:${Buffer.from('not a key').toString('base64url')}` }, expect: 'error', error: /signature verification failed/ },
    { name: 'a build for another architecture', manifest: signed({ ...unsigned, architecture: architecture === 'arm64' ? 'x64' : 'arm64' }, main.privateKey), expect: 'error', error: /not this app's darwin-/ },
    { name: 'a build for another platform', manifest: signed({ ...unsigned, platform: 'linux' }, main.privateKey), expect: 'error', error: /built for linux-/ },
    { name: 'a plain http download', manifest: signed({ ...unsigned, url: 'http://updates.example.com/update.zip' }, main.privateKey), expect: 'error', error: /require HTTPS/ },
    { name: 'a download that is not http at all', manifest: signed({ ...unsigned, url: 'file:///Applications/Other.app' }, main.privateKey), expect: 'error', error: /require HTTPS/ },
    { name: 'a fractional size', manifest: signed({ ...unsigned, size: 12.5 }, main.privateKey), expect: 'error', error: /integer size/ },
    { name: 'a short source revision', manifest: signed({ ...unsigned, sourceRevision: 'abc123' }, main.privateKey), expect: 'error', error: /source revision/ },
    { name: 'no signature', manifest: { ...good, signature: undefined }, expect: 'error', error: /Ed25519 signature/ },
    { name: 'not a version', manifest: signed({ ...unsigned, version: '1.0' }, main.privateKey), expect: 'error', error: /Invalid semantic version/ },
    { name: 'not an object', manifest: [good], expect: 'error', error: /must be an object/ },
  ]
  const versions = [['1.0.1', '1.0.0'], ['1.0.0', '1.0.1'], ['1.10.0', '1.9.9'], ['v2.0.0', '2.0.0'], ['2.0.0-beta.1', '2.0.0'], ['1.0.0', '1.0.0-rc.1'], ['10.0.0', '9.99.99'], ['0.0.504', '0.0.503']]
  const strings = [awkward, '', 'plain', '\u0000\u0001\u001F', '"', '\\', '\b\f\n\r\t', 'é\u0301 ﬁ Ω', '\uFEFFbom']
  const feeds = [
    { feed: 'https://example.com/api/updates', architecture, channel: 'stable', currentVersion: '1.0.0' },
    { feed: 'https://example.com/api/updates///', architecture, channel: 'beta', currentVersion: '1.0.0-beta.1' },
    { feed: 'http://127.0.0.1:3000/api/updates/', architecture, channel: '', currentVersion: '' },
    { feed: 'https://example.com/api/updates', architecture, channel: 'nightly', currentVersion: '2.0.0+build' },
  ]
  const urls: Array<[string, boolean]> = [
    ['https://example.com/update.zip', true], ['HTTPS://EXAMPLE.COM/update.zip', true], ['http://localhost:8080/update.zip', true], ['http://127.0.0.1/update.zip', true], ['http://[::1]:8080/update.zip', true],
    ['http://example.com/update.zip', false], ['http://127.0.0.1@example.com/update.zip', false], ['http://localhost.example.com/update.zip', false], ['http://127.0.0.2/update.zip', false],
    ['ftp://example.com/update.zip', false], ['file:///tmp/update.zip', false], ['update.zip', false], ['', false],
  ]

  // Three installed apps and what would replace each: by exchange, by moving aside, and by nothing at all.
  const folder = (name: string, marker?: string): string => {
    const path = join(scratch, 'swaps', name)
    if (marker) {
      mkdirSync(path, { recursive: true })
      writeFileSync(join(path, 'version'), marker)
    }
    return path
  }
  const swaps = [
    { bundle: folder('a/App.app', 'old'), next: folder('a/.update/App.app', 'new'), exchange: 'yes' },
    { bundle: folder('b/App.app', 'old'), next: folder('b/.update/App.app', 'new'), exchange: 'no' },
    { bundle: folder('c/App.app', 'old'), next: folder('c/.update/Missing.app'), exchange: 'no' },
  ]

  const cases = join(scratch, 'cases.json')
  writeFileSync(cases, JSON.stringify({
    swaps,
    manifests: manifests.map(item => ({ name: item.name, manifest: item.manifest, keys: item.keys ?? keys, currentVersion: item.currentVersion ?? '1.0.0', architecture })),
    versions,
    strings,
    feeds,
    urls: urls.map(([url]) => url),
  }))
  const executable = join(scratch, 'updater-checks')
  await run(['swiftc', '-swift-version', '5', 'packages/macos/templates/CraftMacUpdater.swift', 'packages/macos/fixtures/UpdaterChecks.swift', '-o', executable])
  const answers = JSON.parse(await run([executable, cases])) as {
    architecture: string
    manifests: Array<{ name: string, outcome: string, error?: string, payload?: string, version?: string }>
    versions: Array<number | string>
    strings: string[]
    feeds: string[]
    urls: boolean[]
    swaps: string[]
  }

  expect(answers.architecture).toBe(architecture)
  for (const [index, item] of manifests.entries()) {
    const answer = answers.manifests[index]!
    expect({ name: answer.name, outcome: answer.outcome }).toEqual({ name: item.name, outcome: item.expect })
    if (item.error) expect(answer.error).toMatch(item.error)
    // Whatever parses is put into the same bytes the release tooling signs.
    if (answer.payload) expect(Buffer.from(answer.payload, 'base64').toString('utf8')).toBe(payload(item.manifest as Manifest).toString('utf8'))
  }
  expect(answers.manifests.filter(answer => answer.payload).length).toBeGreaterThan(20)
  expect(answers.versions).toEqual(versions.map(([left, right]) => compareVersions(left!, right!)))
  expect(answers.strings).toEqual(strings.map(text => JSON.stringify(text)))
  expect(answers.feeds).toEqual(feeds.map(feed => updateFeedUrl(feed.feed, { platform: 'darwin', architecture }, { channel: feed.channel, currentVersion: feed.currentVersion })))
  expect(answers.urls).toEqual(urls.map(([, secure]) => secure))
  // Swapped either way; and when the new bundle cannot take its place, the old one is back and nothing is left beside it.
  expect(answers.swaps[0]).toBe('swapped')
  expect(answers.swaps[1]).toBe('swapped')
  expect(answers.swaps[2]).toMatch(/^error: The update could not take the app's place/)
  expect(swaps.map(swap => readFileSync(join(swap.bundle, 'version'), 'utf8'))).toEqual(['new', 'new', 'old'])
  expect(readFileSync(join(swaps[0]!.next, 'version'), 'utf8')).toBe('old')
  expect(readdirSync(join(scratch, 'swaps/b'))).toEqual(['.update', 'App.app'])
  expect(readdirSync(join(scratch, 'swaps/c'))).toEqual(['App.app'])
}, 180_000)

/*
 * The screen of the fixture app: plain JavaScript on the host's own globals, no
 * stx. It drives `craft.updater` when a desktop command asks, and draws what
 * the updater told it into a Text the test driver's snapshot can read.
 */
const screen = `
var log = { initial: craft.updater.status(), events: [], results: {} };
function post(type, payload, id) { __stxNativeBridge.postMessage(JSON.stringify({ id: id || String(Math.random()), type: type, payload: payload })); }
function draw() {
  post('RENDER', { document: { id: 'root', type: 'View', style: { flexGrow: 1 }, props: {}, children: [
    { id: 'status', type: 'Text', style: {}, props: { testID: 'status', text: JSON.stringify(log) }, children: [] }
  ] } });
}
var stop = craft.updater.onChange(function (status) { log.events.push(status.state); log.last = status; draw(); });
__stxNativeBridge.onMessage(function (text) {
  var message = JSON.parse(text);
  if (message.type === 'API_RESPONSE' && message.payload.requestId === 'capability') { log.capability = message.payload.data; draw(); return; }
  if (message.type !== 'CRAFT_EVENT') return;
  if (message.payload.event === 'craftUpdaterChange') { log.hostEvents = (log.hostEvents || 0) + 1; return; }
  if (message.payload.event !== 'craftDesktopCommand') return;
  var id = message.payload.detail.id, run = id.split(':')[0];
  if (run === 'check' || run === 'install') craft.updater[run]().then(function (status) { log.results[id] = status; draw(); });
  if (run === 'relaunch') craft.updater.relaunch().then(function () { log.results[id] = 'relaunching'; draw(); }, function (error) { log.results[id] = String(error.message); draw(); });
  if (run === 'capability') post('API_REQUEST', { version: 1, module: 'Updater', method: 'status', args: [] }, 'capability');
  if (run === 'stop') { stop(); log.results[id] = true; draw(); }
});
log.capabilities = __stxNativeBridge.capabilities;
draw();
`

interface Status { currentVersion: string, state: string, selfUpdating: boolean, reason?: string, version?: string, notes?: string, publishedAt?: string, progress?: number, error?: string, lastCheckedAt?: string }
interface ScreenLog { initial: Status, events: string[], results: Record<string, Status | string | boolean>, last?: Status, capability?: Status, capabilities: string[], hostEvents?: number }

function infoPlist(version: string, identifier: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${identifier}</string>
<key>CFBundleName</key><string>Fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
`
}

test.skipIf(process.platform !== 'darwin')('installs a signed update over the running app, and leaves the app alone when anything about the update is wrong', async () => {
  // The real host, with the updater compiled in.
  const built = join(scratch, 'host')
  const bundleSource = join(scratch, 'native-screen.js')
  writeFileSync(bundleSource, screen)
  const host = await buildMacOSNative({ outdir: built, nativeBundle: bundleSource, updater: true })

  const main = keypair()
  let manifest: Manifest | null = null
  let archive: Uint8Array = new Uint8Array()
  let feedRequests = 0
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch(request) {
      const url = new URL(request.url)
      if (url.pathname === `/api/updates/darwin/${architecture}`) {
        feedRequests++
        const current = url.searchParams.get('current')
        if (!manifest) return new Response(JSON.stringify({ error: 'No update has been published for this platform.' }), { status: 404 })
        if (current && compareVersions(manifest.version, current) <= 0) return new Response(null, { status: 204 })
        return Response.json(manifest)
      }
      if (url.pathname === '/files/update.zip') return new Response(archive, { headers: { 'content-type': 'application/zip' } })
      return new Response('Not found', { status: 404 })
    },
  })
  const origin = `http://127.0.0.1:${server.port}`

  // A signed, zipped app bundle of the fixture at `version`.
  async function makeApp(directory: string, version: string, options: { identifier?: string, spoil?: boolean, receipt?: boolean } = {}): Promise<string> {
    const app = join(directory, 'Fixture.app')
    mkdirSync(join(app, 'Contents/MacOS'), { recursive: true })
    mkdirSync(join(app, 'Contents/Resources'), { recursive: true })
    cpSync(host.executable, join(app, 'Contents/MacOS/Fixture'))
    writeFileSync(join(app, 'Contents/Info.plist'), infoPlist(version, options.identifier ?? fixtureIdentifier))
    writeFileSync(join(app, 'Contents/Resources/native-screen.js'), screen)
    writeFileSync(join(app, 'Contents/Resources/craft-app.json'), JSON.stringify({
      apiUrl: origin,
      title: 'Fixture',
      route: 'Main',
      session: false,
      // Every two seconds, so the test sees the timer as well as the check on launch.
      updates: { feedUrl: `${origin}/api/updates`, publicKeys: { main: main.publicKey }, channel: 'stable', checkEveryHours: 2 / 3600 },
    }))
    // What the App Store leaves in a copy it installed.
    if (options.receipt) {
      mkdirSync(join(app, 'Contents/_MASReceipt'))
      writeFileSync(join(app, 'Contents/_MASReceipt/receipt'), 'receipt')
    }
    await run(['codesign', '--force', '--sign', '-', app])
    // Changed after it was signed: the seal over its resources no longer holds.
    if (options.spoil) writeFileSync(join(app, 'Contents/Resources/native-screen.js'), `${screen}\n// changed after signing\n`)
    return app
  }
  async function publish(name: string, version: string, options: { identifier?: string, spoil?: boolean, tamper?: boolean } = {}): Promise<void> {
    const directory = join(scratch, name)
    const app = await makeApp(directory, version, options)
    const zip = join(directory, 'update.zip')
    await run(['ditto', '-c', '-k', '--keepParent', app, zip])
    const bytes = new Uint8Array(readFileSync(zip))
    manifest = signed({
      version,
      url: `${origin}/files/update.zip`,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      size: bytes.byteLength,
      sourceRevision: revision,
      platform: 'darwin',
      architecture,
      publishedAt: '2026-11-14T10:00:00.000Z',
      notes: 'Faster "search".',
    }, main.privateKey)
    // The same length, one byte different: what a meddler on the way would serve.
    if (options.tamper) bytes[bytes.byteLength >> 1]! ^= 0xFF
    archive = bytes
  }

  const installed = join(scratch, 'installed')
  const app = await makeApp(installed, '1.0.0')
  const executable = join(app, 'Contents/MacOS/Fixture')
  const versionOnDisk = (): string => /<key>CFBundleShortVersionString<\/key><string>([^<]+)</.exec(readFileSync(join(app, 'Contents/Info.plist'), 'utf8'))![1]!
  const leftovers = (): string[] => readdirSync(installed).filter(name => name !== 'Fixture.app')
  const sealed = async (): Promise<void> => { await run(['codesign', '--verify', '--deep', '--strict', app]) }

  // The test driver: actions in, results and a snapshot of the app out.
  const driver = join(scratch, 'driver')
  mkdirSync(driver)
  let actions = 0
  const snapshot = (): { updater: Status, windows: Array<{ nodes: Array<{ id: string, value?: string }>, errors: string[] }> } | null => {
    try { return JSON.parse(readFileSync(join(driver, 'state.json'), 'utf8')) }
    catch { return null }
  }
  const screenLog = (): ScreenLog | null => {
    const text = snapshot()?.windows[0]?.nodes.find(node => node.id === 'status')?.value
    return text ? JSON.parse(text) as ScreenLog : null
  }
  async function until<T>(what: string, read: () => T | null | undefined | false, timeout = 30_000): Promise<T> {
    const deadline = Date.now() + timeout
    while (Date.now() < deadline) {
      const value = read()
      if (value) return value
      await Bun.sleep(50)
    }
    throw new Error(`Timed out waiting for ${what}. Updater: ${JSON.stringify(snapshot()?.updater)}; screen: ${JSON.stringify(screenLog())}; errors: ${JSON.stringify(snapshot()?.windows[0]?.errors)}`)
  }
  async function command(id: string): Promise<void> {
    const number = ++actions
    writeFileSync(join(driver, `action-${number}.json`), JSON.stringify({ action: 'command', id, window: 'main' }))
    await until(`the result of ${id}`, () => existsSync(join(driver, `result-${number}.json`)))
  }
  async function answer(id: string): Promise<Status> {
    await command(id)
    return await until(`the screen's answer to ${id}`, () => screenLog()?.results[id]) as Status
  }

  // Another copy of the app, started and watched until its updater says what `ready` waits for.
  async function watch(name: string, binary: string, ready: (status: Status) => boolean): Promise<Status> {
    const directory = join(scratch, name)
    mkdirSync(directory)
    const other = Bun.spawn([binary, '--test-dir', directory], { stdout: 'ignore', stderr: 'ignore' })
    try {
      const deadline = Date.now() + 30_000
      let status: Status | undefined
      while (Date.now() < deadline) {
        try { status = JSON.parse(readFileSync(join(directory, 'state.json'), 'utf8')).updater as Status }
        catch { status = undefined }
        if (status && ready(status)) return status
        await Bun.sleep(50)
      }
      throw new Error(`Timed out waiting for ${name}: ${JSON.stringify(status)}`)
    }
    finally {
      other.kill()
      await other.exited
    }
  }

  // 1.0.1 is published before the app starts, and what the server hands out for it was changed on the way.
  await publish('tampered', '1.0.1', { tamper: true })

  // A copy from the App Store has an update feed in its settings by mistake: it never asks it.
  const store = await makeApp(join(scratch, 'store-copy'), '1.0.0', { receipt: true })
  const fromStore = await watch('store-copy-driver', join(store, 'Contents/MacOS/Fixture'), status => status.state === 'unavailable')
  expect(fromStore).toMatchObject({ currentVersion: '1.0.0', state: 'unavailable', selfUpdating: false })
  expect(fromStore.reason).toMatch(/App Store/)
  await Bun.sleep(1500)
  expect(feedRequests).toBe(0)

  // A copy opened from a disk image learns of the update, and says why it cannot install it.
  const image = join(scratch, 'fixture.dmg')
  const volume = join(scratch, 'volume')
  await makeApp(join(scratch, 'image-copy'), '1.0.0')
  await run(['hdiutil', 'create', '-quiet', '-srcfolder', join(scratch, 'image-copy'), '-format', 'UDRO', image])
  await run(['hdiutil', 'attach', '-quiet', '-nobrowse', '-readonly', '-mountpoint', volume, image])
  try {
    const onImage = await watch('image-copy-driver', join(volume, 'Fixture.app/Contents/MacOS/Fixture'), status => status.state === 'available')
    expect(onImage).toMatchObject({ currentVersion: '1.0.0', state: 'available', version: '1.0.1', selfUpdating: false })
    expect(onImage.reason).toMatch(/read-only volume/)
  }
  finally {
    await run(['hdiutil', 'detach', '-quiet', '-force', volume])
  }
  expect(feedRequests).toBeGreaterThan(0)
  const child = Bun.spawn([executable, '--test-dir', driver], { stdout: 'ignore', stderr: 'ignore' })
  try {
    // Nobody asked: the check on launch found it.
    await until('the check on launch', () => snapshot()?.updater.state === 'available')
    const first = await until('the screen', () => screenLog())
    expect(first.initial.currentVersion).toBe('1.0.0')
    expect(first.initial.selfUpdating).toBe(true)
    expect(first.capabilities).toContain('updater')
    const found = snapshot()!.updater
    expect(found).toMatchObject({ currentVersion: '1.0.0', state: 'available', selfUpdating: true, version: '1.0.1', notes: 'Faster "search".', publishedAt: '2026-11-14T10:00:00.000Z' })
    expect(found.lastCheckedAt).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/)
    expect(found.reason).toBeUndefined()
    // And the timer keeps asking.
    const asked = feedRequests
    await until('a check from the timer', () => feedRequests >= asked + 2)

    // A download that is not the file the manifest was signed for.
    const tampered = await answer('install:tampered')
    expect(tampered).toMatchObject({ state: 'error', error: 'Update checksum mismatch', currentVersion: '1.0.0' })
    expect(versionOnDisk()).toBe('1.0.0')
    expect(leftovers()).toEqual([])
    await sealed()

    // An honest download of an app whose code signature is broken.
    await publish('spoiled', '1.0.1', { spoil: true })
    expect((await answer('check:spoiled')).state).toBe('available')
    const spoiled = await answer('install:spoiled')
    expect(spoiled.state).toBe('error')
    expect(spoiled.error).toMatch(/signature is not valid/)
    expect(versionOnDisk()).toBe('1.0.0')
    expect(leftovers()).toEqual([])

    // A properly signed app that is not this app.
    await publish('stranger', '1.0.1', { identifier: 'dev.craft.someone-else' })
    expect((await answer('check:stranger')).state).toBe('available')
    const stranger = await answer('install:stranger')
    expect(stranger.state).toBe('error')
    expect(stranger.error).toMatch(/different app \(dev\.craft\.someone-else\), not dev\.craft\.updater-fixture/)
    expect(versionOnDisk()).toBe('1.0.0')
    expect(leftovers()).toEqual([])
    await sealed()

    // Nothing is installed, so there is nothing to relaunch into.
    expect(await answer('relaunch:early') as unknown).toBe('No update is installed.')

    // The same status through the capability protocol, for a runtime that wraps it itself.
    await command('capability')
    expect(await until('the capability answer', () => screenLog()?.capability)).toMatchObject({ currentVersion: '1.0.0', selfUpdating: true })

    // The real 1.0.1.
    await publish('good', '1.0.1')
    expect((await answer('check:good')).state).toBe('available')
    const before = screenLog()!.events.length
    const done = await answer('install:good')
    expect(done).toMatchObject({ state: 'installed', version: '1.0.1', currentVersion: '1.0.0' })
    expect(done.error).toBeUndefined()
    expect(versionOnDisk()).toBe('1.0.1')
    expect(leftovers()).toEqual([])
    await sealed()
    // Every step reached the screen, in order, through onChange.
    const steps = screenLog()!.events.slice(before).filter((state, index, all) => state !== all[index - 1])
    expect(steps).toEqual(['downloading', 'installing', 'installed'])
    expect(screenLog()!.hostEvents).toBeGreaterThan(3)
    // Installed is where it stays: another check or install changes nothing.
    expect((await answer('check:after')).state).toBe('installed')
    expect((await answer('install:after')).state).toBe('installed')

    // Relaunch: this process quits, and the bundle now at its path starts with the same arguments.
    rmSync(join(driver, 'state.json'), { force: true })
    await command('relaunch:now')
    expect(await child.exited).toBe(0)
    rmSync(join(driver, 'state.json'), { force: true })
    const relaunched = await until('the relaunched app', () => snapshot()?.updater.currentVersion === '1.0.1' && snapshot()!.updater)
    expect(relaunched.selfUpdating).toBe(true)
    // The feed has nothing newer than 1.0.1 for it.
    await until('the relaunched app to be current', () => snapshot()?.updater.state === 'current')
    expect(screenLog()!.initial.currentVersion).toBe('1.0.1')
    // An action the first launch answered is not run again by the second.
    expect(screenLog()!.results).toEqual({})
  }
  finally {
    const number = ++actions
    writeFileSync(join(driver, `action-${number}.json`), JSON.stringify({ action: 'quit' }))
    await Bun.sleep(500)
    child.kill()
    Bun.spawnSync(['pkill', '-f', scratch])
    server.stop(true)
  }
}, 600_000)

test.skipIf(process.platform !== 'darwin')('a host built without the updater holds none of it and answers that it cannot update itself', async () => {
  // What a Mac App Store build compiles: no `updater`, so no CRAFT_UPDATER.
  const built = join(scratch, 'store-host')
  const bundleSource = join(scratch, 'store-screen.js')
  writeFileSync(bundleSource, screen)
  const host = await buildMacOSNative({ outdir: built, nativeBundle: bundleSource })
  const binary = readFileSync(host.executable).toString('latin1')
  for (const mark of ['/usr/bin/ditto', 'ed25519-public:', 'CraftMacUpdater']) expect(binary.includes(mark)).toBe(false)

  const driver = join(scratch, 'store-driver')
  mkdirSync(driver)
  const child = Bun.spawn([host.executable, '--api-url', 'http://127.0.0.1:9', '--no-session', '--native-bundle', host.bundle, '--title', 'Store', '--test-dir', driver], { stdout: 'ignore', stderr: 'ignore' })
  try {
    const read = (): { updater: Status, windows: Array<{ nodes: Array<{ id: string, value?: string }> }> } | null => {
      try { return JSON.parse(readFileSync(join(driver, 'state.json'), 'utf8')) }
      catch { return null }
    }
    const log = (): ScreenLog | null => {
      const text = read()?.windows[0]?.nodes.find(node => node.id === 'status')?.value
      return text ? JSON.parse(text) as ScreenLog : null
    }
    const deadline = Date.now() + 30_000
    while (!log() && Date.now() < deadline) await Bun.sleep(50)
    const unavailable = { state: 'unavailable', selfUpdating: false, reason: 'This build of the app does not update itself.' }
    expect(read()!.updater).toMatchObject(unavailable)
    expect(log()!.initial).toMatchObject(unavailable)
    expect(log()!.capabilities).not.toContain('updater')
    // Asking changes nothing, and nothing is asked of any feed.
    for (const [number, id] of ['check', 'install'].entries()) {
      writeFileSync(join(driver, `action-${number + 1}.json`), JSON.stringify({ action: 'command', id, window: 'main' }))
      while (!log()?.results[id] && Date.now() < deadline) await Bun.sleep(50)
      expect(log()!.results[id]).toMatchObject(unavailable)
    }
    expect(log()!.events).toEqual([])
  }
  finally {
    child.kill()
    await child.exited
  }
}, 600_000)
