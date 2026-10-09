import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'bun:test'
import { build, hybridConfigProblems, init, isHybrid, matchNativePath, normalizeNativePath } from './index'

// Hybrid apps: web plus native screens (CraftHybrid.swift). The shell, the
// page script it injects and the typescript API each decide which paths are
// native, so all three are held to the same cases here.

const swift = readFileSync(join(import.meta.dir, '../templates/CraftHybrid.swift'), 'utf8')

const TABLE: Record<string, string> = {
  '/m': 'Today',
  '/m/calendar': 'Calendar',
  '/m/workout/new': 'NewWorkout',
  '/m/workout/:id': 'Workout',
  '/m/library/*': 'Library',
}

/** Path → [screen, params] or null. */
const CASES: Array<[string, [string, Record<string, string>] | null]> = [
  ['/m', ['Today', {}]],
  ['/m/', ['Today', {}]],
  ['/m?tab=1', ['Today', { tab: '1' }]],
  ['//m', ['Today', {}]],
  ['/m#top', ['Today', {}]],
  ['/m/calendar', ['Calendar', {}]],
  ['/m/calendar?date=2026-10-09&x=a%20b', ['Calendar', { date: '2026-10-09', x: 'a b' }]],
  ['/m/workout/new', ['NewWorkout', {}]],
  ['/m/workout/42', ['Workout', { id: '42' }]],
  ['/m/workout/42?id=7', ['Workout', { id: '42' }]],
  ['/m/workout/a%2Fb', ['Workout', { id: 'a/b' }]],
  ['/m/workout', null],
  ['/m/workout/42/edit', null],
  ['/m/library', ['Library', { '*': '' }]],
  ['/m/library/a/b', ['Library', { '*': 'a/b' }]],
  ['/m/settings', null],
  ['/', null],
  ['/mm', null],
  ['m', null],
  ['', null],
]

// ---------------------------------------------------------------------------
// The page script, run against a fake page
// ---------------------------------------------------------------------------

function pageScriptSource(routes: Record<string, string>, share: string[] = []): string {
  const open = 'static let pageScriptTemplate = #"""\n'
  const start = swift.indexOf(open)
  if (start === -1) throw new Error('CraftHybrid.swift no longer declares pageScriptTemplate')
  const end = swift.indexOf('\n    """#', start)
  // Swift strips the closing delimiter's four spaces from every line.
  const body = swift.slice(start + open.length, end).split('\n').map(line => line.replace(/^ {4}/, '')).join('\n')
  return body
    .replace('__CRAFT_HYBRID_ROUTES__', JSON.stringify(Object.entries(routes).map(([pattern, screen]) => ({ pattern, screen }))))
    .replace('__CRAFT_HYBRID_SHARE__', JSON.stringify(share))
}

type Listener = (event: any) => void

interface FakeEntry { url: string, depth: number, active: boolean }

class FakeStorage {
  map = new Map<string, string>()
  getItem(key: string) { return this.map.has(key) ? this.map.get(key)! : null }
  setItem(key: string, value: string) { this.map.set(key, String(value)) }
  removeItem(key: string) { this.map.delete(key) }
  clear() { this.map.clear() }
}

function loadPage(options: { routes?: Record<string, string>, share?: string[], protocol?: string, readyState?: string, presetStorage?: Record<string, string>, routerFirst?: boolean } = {}) {
  const posts: any[] = []
  const listeners: Record<string, Array<{ fn: Listener, capture: boolean }>> = {}
  const docListeners: Record<string, Listener[]> = {}
  const protocol = options.protocol ?? 'http:'
  const location = {
    protocol,
    origin: `${protocol}//localhost:3100`,
    pathname: '/m',
    search: '',
    get href() { return `${this.origin}${this.pathname}${this.search}` },
    assigned: [] as string[],
    assign(path: string) { this.assigned.push(path) },
  }
  const stack: FakeEntry[] = [{ url: '/m', depth: 0, active: true }]
  const routerCalls: any[] = []
  const fire = (type: string, event: any) => {
    for (const { fn } of listeners[type] || []) fn(event)
  }
  const historyCalls: string[] = []
  const history = {
    back() { historyCalls.push('back') },
    go(n: number) { historyCalls.push(`go(${n})`) },
  }
  const router = {
    navigate(url: string, pushState?: unknown) {
      routerCalls.push(['navigate', url, pushState])
      const u = new URL(url, location.href)
      if (u.origin !== location.origin) return Promise.resolve(false)
      for (const e of stack) e.active = false
      stack.push({ url: u.pathname, depth: stack.length, active: true })
      location.pathname = u.pathname
      location.search = u.search
      // As the stx router does: the event during the swap, then the answer.
      fire('stx:navigate', { detail: { url: u.pathname + u.search, direction: 'push' } })
      return Promise.resolve(true)
    },
    back() { routerCalls.push(['back']); return history.back() },
    selectTab(href: string) { routerCalls.push(['selectTab', href]) },
    screens() { return stack.map(e => ({ ...e, tab: '/m', live: true })) },
  }
  class StorageProto extends FakeStorage {}
  const localStorage = new StorageProto()
  const sessionStorage = new StorageProto()
  for (const [k, v] of Object.entries(options.presetStorage ?? {})) localStorage.map.set(k, v)
  const window: Record<string, any> = {
    history,
    webkit: { messageHandlers: { craftHybrid: { postMessage: (m: any) => posts.push(JSON.parse(JSON.stringify(m))) } } },
    addEventListener(type: string, fn: Listener, opts?: boolean | { capture?: boolean }) {
      (listeners[type] ||= []).push({ fn, capture: typeof opts === 'boolean' ? opts : !!opts?.capture })
    },
    localStorage,
    sessionStorage,
    Storage: StorageProto,
  }
  if (options.routerFirst) window.stxRouter = router
  const document = {
    readyState: options.readyState ?? 'complete',
    addEventListener(type: string, fn: Listener) { (docListeners[type] ||= []).push(fn) },
  }
  // eslint-disable-next-line no-new-func
  new Function('window', 'document', 'location', 'history', 'URL', 'Promise', pageScriptSource(options.routes ?? TABLE, options.share))(
    window,
    document,
    location,
    history,
    URL,
    Promise,
  )
  // The router's own script runs after the document-start one.
  if (!options.routerFirst) window.stxRouter = router
  const settle = () => new Promise(resolve => setTimeout(resolve, 5))
  return { window, posts, routerCalls, historyCalls, stack, location, fire, docListeners, router, settle, localStorage, sessionStorage }
}

describe('hybrid page script', () => {
  it('matches paths by the shared cases', () => {
    const page = loadPage()
    // As URLs: `//m` is another host to a page, so it is not compared here.
    for (const [path, expected] of CASES.filter(([path]) => !path.startsWith('//'))) {
      const got = page.window.__craftHybrid.match(path || 'x:')
      if (!expected || !path.startsWith('/')) {
        // A bare `m` or '' resolves against the page and is the page's path,
        // so only absolute paths are compared for non-matches.
        if (path.startsWith('/')) expect(got).toBeNull()
        continue
      }
      expect(got && { screen: got.screen, params: got.params }).toEqual({ screen: expected[0], params: expected[1] })
    }
  })

  it('reports the page it loaded on', () => {
    const page = loadPage()
    expect(page.posts[0]).toEqual({ type: 'navigated', path: '/m', direction: 'load', depth: 0 })
  })

  it('reports the load once the document has parsed', () => {
    const page = loadPage({ readyState: 'loading' })
    expect(page.posts.filter(m => m.type === 'navigated')).toHaveLength(0)
    page.docListeners.DOMContentLoaded!.forEach(fn => fn({}))
    expect(page.posts.at(-1).direction).toBe('load')
  })

  it('reports nothing from the offline page', () => {
    const page = loadPage({ protocol: 'craft:' })
    expect(page.posts.filter(m => m.type === 'navigated')).toHaveLength(0)
  })

  it('hands router navigation to a native path to the shell and draws nothing', async () => {
    const page = loadPage()
    const answer = await page.window.stxRouter.navigate('/m/calendar?date=2026-10-09')
    expect(answer).toBe(false)
    expect(page.routerCalls).toHaveLength(0)
    expect(page.posts.at(-1)).toEqual({ type: 'navigateNative', path: '/m/calendar?date=2026-10-09', replace: false })
    await page.window.stxRouter.navigate('/m/workout/9', 'replace')
    expect(page.posts.filter(m => m.type === 'navigateNative').at(-1)).toEqual({ type: 'navigateNative', path: '/m/workout/9', replace: true })
    // A redirect also moves the page there, behind the native screen, so it
    // is not left on the page it redirected away from (sign-in).
    expect(page.routerCalls).toHaveLength(1)
  })

  it('wraps a router that existed before the script', async () => {
    const page = loadPage({ routerFirst: true })
    await page.window.stxRouter.navigate('/m/calendar')
    expect(page.posts.at(-1).type).toBe('navigateNative')
  })

  it('leaves web paths, Back and tab switches to the router', async () => {
    const page = loadPage()
    await page.window.stxRouter.navigate('/m/settings')
    await page.window.stxRouter.navigate('/m', false)
    await page.window.stxRouter.navigate('/m/calendar', 'tab')
    await page.window.stxRouter.navigate('https://example.com/m')
    expect(page.routerCalls.map(c => c[1])).toEqual(['/m/settings', '/m', '/m/calendar', 'https://example.com/m'])
    expect(page.posts.filter(m => m.type === 'navigateNative')).toHaveLength(0)
  })

  it('navigates for the shell without handing it back, and tags the report', async () => {
    const page = loadPage()
    const answer = await page.window.__craftHybrid.navigate('/m/workout/42')
    expect(page.routerCalls[0]).toEqual(['navigate', '/m/workout/42', { instant: true }])
    expect(answer).toEqual({ path: '/m/workout/42', depth: 1 })
    expect(page.posts.at(-1)).toEqual({ type: 'navigated', path: '/m/workout/42', direction: 'push', depth: 1, byHost: true })
    // The page's own navigation afterwards is its own again.
    await page.settle()
    await page.window.stxRouter.navigate('/m/x')
    expect(page.posts.at(-1)).toEqual({ type: 'navigated', path: '/m/x', direction: 'push', depth: 2 })
    // And a native path is the shell's again.
    await page.window.stxRouter.navigate('/m')
    expect(page.posts.at(-1).type).toBe('navigateNative')
  })

  it('answers the shell once the page has drawn the path, or when it went nowhere', async () => {
    const page = loadPage()
    let drawn = false
    const pending = page.window.__craftHybrid.navigate('/m/workout/7').then((answer: any) => { drawn = true; return answer })
    expect(drawn).toBe(false)
    expect(await pending).toEqual({ path: '/m/workout/7', depth: 1 })
    // Off-origin: the router declines (answers false) and reports nothing.
    expect(await page.window.__craftHybrid.navigate('https://elsewhere.test/x')).toEqual({ path: '/m/workout/7', depth: 1 })
  })

  it('navigates a page without a router by loading the path', async () => {
    const page = loadPage()
    page.window.stxRouter = undefined
    const answer = await page.window.__craftHybrid.navigate('/m/workout/1')
    expect(page.location.assigned).toEqual(['/m/workout/1'])
    expect(answer).toEqual({ path: '/m/workout/1', depth: 0 })
  })

  it('catches a click on a link to a native path before the router', () => {
    const page = loadPage()
    const link = (attrs: Record<string, string>, href: string) => ({
      href,
      target: attrs.target ?? '',
      hasAttribute: (name: string) => name in attrs,
      getAttribute: (name: string) => attrs[name] ?? null,
    })
    const click = (a: any) => {
      const event = { defaultPrevented: false, button: 0, target: { closest: () => a }, prevented: false, stopped: false, preventDefault() { this.prevented = true }, stopPropagation() { this.stopped = true } }
      page.fire('click', event)
      return event
    }
    const native = click(link({}, 'http://localhost:3100/m/calendar'))
    expect(native.prevented && native.stopped).toBe(true)
    expect(page.posts.at(-1)).toEqual({ type: 'navigateNative', path: '/m/calendar', replace: false })
    for (const [attrs, href] of [
      [{}, 'http://localhost:3100/m/settings'],
      [{ 'data-native-tab': 'Today' }, 'http://localhost:3100/m'],
      [{ 'data-stx-nav': 'tab' }, 'http://localhost:3100/m'],
      [{ target: '_blank' }, 'http://localhost:3100/m'],
      [{ 'data-craft-web': '' }, 'http://localhost:3100/m'],
      [{}, 'https://elsewhere.test/m'],
    ] as Array<[Record<string, string>, string]>) {
      expect(click(link(attrs, href)).prevented).toBe(false)
    }
  })

  it('sends Back at the entry a native screen opened to the shell', async () => {
    const page = loadPage()
    await page.window.__craftHybrid.navigate('/m/workout/42')
    page.window.__craftHybrid.setBase(1)
    page.window.history.back()
    page.window.stxRouter.back()
    expect(page.posts.filter(m => m.type === 'back')).toHaveLength(2)
    expect(page.historyCalls).toEqual([])
    // Deeper than that entry, Back is the page's.
    await page.router.navigate('/m/workout/42/exercise/1')
    page.window.history.back()
    expect(page.historyCalls).toEqual(['back'])
    // On a tab's own web root there is no native screen to go back to.
    page.window.__craftHybrid.setBase(null)
    page.stack.splice(1)
    page.stack[0]!.active = true
    page.window.history.back()
    expect(page.historyCalls).toEqual(['back', 'back'])
  })

  it('takes the bar\'s Back link at that entry as Back, not as a tap on its fallback path', async () => {
    const page = loadPage()
    const back = { href: 'http://localhost:3100/m/calendar', target: '', hasAttribute: (name: string) => name === 'data-native-back', getAttribute: () => null }
    const click = () => {
      const event = { defaultPrevented: false, button: 0, target: { closest: () => back }, prevented: false, stopped: false, preventDefault() { this.prevented = true }, stopPropagation() { this.stopped = true } }
      page.fire('click', event)
      return event
    }
    // A tab's own web root: the page handles its Back.
    expect(click().prevented).toBe(false)
    expect(page.posts.filter(m => m.type === 'navigateNative')).toHaveLength(0)
    await page.window.__craftHybrid.navigate('/m/workout/42')
    page.window.__craftHybrid.setBase(1)
    expect(click().prevented).toBe(true)
    expect(page.posts.at(-1)).toEqual({ type: 'back' })
    expect(page.posts.filter(m => m.type === 'navigateNative')).toHaveLength(0)
  })

  it('keeps the router from taking the edge swipe at that entry', async () => {
    const page = loadPage()
    const touch = (x: number) => {
      const event = { touches: [{ clientX: x }], stopped: false, stopPropagation() { this.stopped = true } }
      page.fire('touchstart', event)
      return event.stopped
    }
    expect(touch(10)).toBe(false)
    await page.window.__craftHybrid.navigate('/m/workout/42')
    page.window.__craftHybrid.setBase(1)
    expect(touch(10)).toBe(true)
    expect(touch(120)).toBe(false)
    await page.router.navigate('/m/workout/42/more')
    expect(touch(10)).toBe(false)
  })

  it('goes back to a depth for the shell and tags the pop', async () => {
    const page = loadPage()
    await page.router.navigate('/m/a')
    await page.router.navigate('/m/b')
    expect(page.window.__craftHybrid.backTo(0)).toBe(2)
    expect(page.historyCalls).toEqual(['go(-2)'])
    page.fire('stx:navigate', { detail: { url: '/m', direction: 'pop' } })
    expect(page.posts.at(-1).byHost).toBe(true)
    expect(page.window.__craftHybrid.backTo(5)).toBe(0)
  })

  it('mirrors the shared web-storage keys to the shell', () => {
    const page = loadPage({ share: ['auth_token'], presetStorage: { auth_token: 'old' } })
    const shares = () => page.posts.filter(m => m.type === 'shareStorage')
    expect(shares()).toEqual([{ type: 'shareStorage', key: 'auth_token', value: 'old' }])
    page.localStorage.setItem('auth_token', 'new')
    page.localStorage.setItem('other', 'x')
    page.localStorage.setItem('auth_token', 'new')
    expect(shares().map(m => m.value)).toEqual(['old', 'new'])
    // A session-only sign-in is read first, as the page reads it.
    page.sessionStorage.setItem('auth_token', 'session')
    page.sessionStorage.removeItem('auth_token')
    page.localStorage.removeItem('auth_token')
    expect(shares().map(m => m.value)).toEqual(['old', 'new', 'session', 'new', null])
  })

  it('stays out of a page without the channel', () => {
    const window: Record<string, any> = { webkit: { messageHandlers: {} } }
    // eslint-disable-next-line no-new-func
    new Function('window', 'document', 'location', 'history', pageScriptSource(TABLE))(window, {}, { protocol: 'http:' }, { back() {}, go() {} })
    expect(window.__craftHybrid).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// The typescript API's matcher and the generator
// ---------------------------------------------------------------------------

describe('hybrid paths in typescript', () => {
  it('matches paths by the shared cases', () => {
    for (const [path, expected] of CASES) {
      const got = matchNativePath(TABLE, path)
      expect(got && [got.screen, got.params]).toEqual(expected)
    }
  })

  it('normalizes paths', () => {
    expect(normalizeNativePath('/m/')).toBe('/m')
    expect(normalizeNativePath('/')).toBe('/')
    expect(normalizeNativePath('//a///b/?q')).toBe('/a/b')
    expect(normalizeNativePath('m')).toBeNull()
  })

  it('says what is wrong with a hybrid config', () => {
    expect(hybridConfigProblems({ nativeScreens: TABLE, tabs: [{ id: '/m', title: 'Today' }] })).toEqual([])
    expect(hybridConfigProblems({ renderer: 'native', nativeScreens: { '/m': 'Today' } })[0]).toContain('renderer: "web"')
    expect(hybridConfigProblems({ nativeScreens: { 'm': 'Today' } })[0]).toContain('absolute path')
    expect(hybridConfigProblems({ nativeScreens: { '/m/': 'Today' } })[0]).toContain('trailing slash')
    expect(hybridConfigProblems({ nativeScreens: { '/m?x=1': 'Today' } })[0]).toContain('query')
    expect(hybridConfigProblems({ nativeScreens: { '/m/*/x': 'Today' } })[0]).toContain('only end in *')
    expect(hybridConfigProblems({ nativeScreens: { '/m': '1 bad' } })[0]).toContain('screen name')
    expect(hybridConfigProblems({ tabs: [{ id: '/m', title: '' }] })[0]).toContain('needs an id')
    expect(hybridConfigProblems({ tabs: [{ id: '/m', title: 'A' }, { id: '/m', title: 'B' }] })[0]).toContain('twice')
    expect(hybridConfigProblems({ shareStorage: { auth_token: '' } })[0]).toContain('Keychain key')
    expect(isHybrid({ nativeScreens: TABLE })).toBe(true)
    expect(isHybrid({ renderer: 'web', nativeScreens: {} })).toBe(false)
    expect(isHybrid({ renderer: 'native', nativeScreens: TABLE })).toBe(false)
  })
})

describe('hybrid project generation', () => {
  const workspace = mkdtempSync(join(tmpdir(), 'craft-hybrid-'))
  afterAll(() => rmSync(workspace, { recursive: true, force: true }))
  const bundle = join(workspace, 'screens.js')
  writeFileSync(bundle, '// screens v1\n')

  it('writes the hybrid config, the shell and the native bundle', async () => {
    const output = join(workspace, 'App')
    await init({
      name: 'Hybrid Probe',
      bundleId: 'dev.craft.hybrid.probe',
      output,
      runtimeDir: null,
      config: {
        devServerURL: 'http://localhost:3100/m',
        nativeScreens: { '/m': 'Today' },
        nativeBundle: bundle,
        tabs: [{ id: '/m', title: 'Today', symbol: 'sun.max' }, { id: '/m/calendar', title: 'Calendar', symbol: 'calendar' }],
        shareStorage: { auth_token: 'auth.token' },
      },
    })
    const config = JSON.parse(readFileSync(join(output, 'craft.config.json'), 'utf8'))
    expect(config.nativeScreens).toEqual({ '/m': 'Today' })
    expect(config.tabs[1]).toEqual({ id: '/m/calendar', title: 'Calendar', symbol: 'calendar' })
    expect(config.shareStorage).toEqual({ auth_token: 'auth.token' })
    expect(config.enableSecureStorage).toBe(true)
    expect(existsSync(join(output, 'Sources', 'CraftHybrid.swift'))).toBe(true)
    expect(readFileSync(join(output, 'dist', 'native-screen.js'), 'utf8')).toBe('// screens v1\n')
    // CraftApp.swift is renamed for the product; the shell it refers to is not.
    expect(readFileSync(join(output, 'Sources', 'HybridProbeApp.swift'), 'utf8')).toContain('CraftHybrid.shared.isEnabled')

    // A build refreshes the bundle, after any web assets replace dist/.
    writeFileSync(bundle, '// screens v2\n')
    const site = join(workspace, 'site')
    mkdirSync(site, { recursive: true })
    writeFileSync(join(site, 'index.html'), '<!doctype html>')
    await build({ output, htmlPath: site, generateProject: false, runtimeDir: null })
    expect(readFileSync(join(output, 'dist', 'native-screen.js'), 'utf8')).toBe('// screens v2\n')
    const other = join(workspace, 'other.js')
    writeFileSync(other, '// other\n')
    await build({ output, nativeBundlePath: other, generateProject: false, runtimeDir: null })
    expect(readFileSync(join(output, 'dist', 'native-screen.js'), 'utf8')).toBe('// other\n')
  })

  it('refuses a broken hybrid config', async () => {
    await expect(init({
      name: 'Broken',
      output: join(workspace, 'Broken'),
      runtimeDir: null,
      config: { nativeScreens: { 'm': 'Today' } },
    })).rejects.toThrow('absolute path')
  })

  it('keeps --native-bundle to native and hybrid apps', async () => {
    const output = join(workspace, 'Web')
    await init({ name: 'Web', bundleId: 'dev.craft.hybrid.web', output, runtimeDir: null })
    await expect(build({ output, nativeBundlePath: bundle, generateProject: false, runtimeDir: null })).rejects.toThrow('nativeScreens')
  })
})

// ---------------------------------------------------------------------------
// The shell's own Swift, compiled and run on its own
// ---------------------------------------------------------------------------

/** A Foundation-only declaration lifted out of the template by its braces. */
function declaration(opening: string): string {
  const start = swift.indexOf(opening)
  if (start === -1) throw new Error(`CraftHybrid.swift no longer declares ${opening}`)
  let depth = 0
  for (let i = start; i < swift.length; i++) {
    if (swift[i] === '{') depth++
    else if (swift[i] === '}' && --depth === 0) return swift.slice(start, i + 1)
  }
  throw new Error(`unbalanced ${opening}`)
}

const swiftc = process.platform === 'darwin' && Bun.which('swiftc')

describe.skipIf(!swiftc)('hybrid shell in Swift', () => {
  const dir = mkdtempSync(join(tmpdir(), 'craft-hybrid-swift-'))
  afterAll(() => rmSync(dir, { recursive: true, force: true }))

  const main = `import Foundation

${declaration('struct CraftHybridRoutes {')}

${declaration('enum CraftHybridMessage: Equatable {')}

let input = try! JSONSerialization.jsonObject(with: Data(CommandLine.arguments[1].utf8)) as! [String: Any]
var out: [String: Any] = [:]

let routes = CraftHybridRoutes(input["table"] as! [String: String])
out["matches"] = (input["paths"] as! [String]).map { path -> Any in
    guard let match = routes.match(path) else { return NSNull() }
    return [match.screen, match.params]
}
out["appPaths"] = (input["urls"] as! [String]).map { CraftHybridRoutes.appPath(of: URL(string: $0)!) }
out["tabs"] = (input["tabPaths"] as! [String]).map { CraftHybridRoutes.tab(owning: $0, among: input["tabIds"] as! [String]).map { $0 as Any } ?? NSNull() }

func describe(_ message: CraftHybridMessage?) -> String { message.map { "\\($0)" } ?? "nil" }
out["messages"] = (input["messages"] as! [[String: Any]]).map { describe(CraftHybridMessage.parse($0)) }

print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
`
  const mainPath = join(dir, 'main.swift')
  writeFileSync(mainPath, main)
  const binary = join(dir, 'hybrid')
  const compiled = Bun.spawnSync(['swiftc', '-o', binary, mainPath], { stderr: 'pipe' })
  if (compiled.exitCode !== 0) throw new Error(`swiftc failed:\n${compiled.stderr.toString()}`)

  const messages = [
    { type: 'navigateNative', path: '/m/calendar' },
    { type: 'navigateNative', path: '/m', replace: true },
    { type: 'navigateNative', path: 'm' },
    { type: 'navigated', path: '/m/workout/4', direction: 'pop', depth: 2, byHost: true },
    { type: 'navigated', path: '/m', depth: -3 },
    { type: 'back' },
    { type: 'open', path: '/m/workout/4' },
    { type: 'open' },
    { type: 'snapshotSet', name: 'today', json: '{}' },
    { type: 'snapshotSet', name: 'today' },
    { type: 'snapshotRemove', name: 'today' },
    { type: 'snapshotClear' },
    { type: 'shareStorage', key: 'auth_token', value: 'abc' },
    { type: 'shareStorage', key: 'auth_token', value: null },
    { type: 'whatever' },
  ]
  const run = Bun.spawnSync([binary, JSON.stringify({
    table: TABLE,
    paths: CASES.map(([path]) => path),
    urls: ['hqtraining://m', 'hqtraining://m/calendar?date=1', 'hqtraining:///m/x', 'https://hq.training/m/workout/4', 'https://hq.training', 'http://localhost:3100/m'],
    tabPaths: ['/m', '/m/workout/4', '/m/calendar', '/m/calendar/day', '/me', '/x'],
    tabIds: ['/m', '/m/calendar', '/me'],
    messages,
  })], { stderr: 'pipe' })
  if (run.exitCode !== 0) throw new Error(`the Swift probe failed:\n${run.stderr.toString()}`)
  const result = JSON.parse(run.stdout.toString())

  it('matches paths by the shared cases', () => {
    CASES.forEach(([path, expected], index) => {
      expect([path, result.matches[index]]).toEqual([path, expected])
    })
  })

  it('turns links into app paths', () => {
    expect(result.appPaths).toEqual(['/m', '/m/calendar?date=1', '/m/x', '/m/workout/4', '/', '/m'])
  })

  it('finds the tab a path belongs to', () => {
    expect(result.tabs).toEqual(['/m', '/m', '/m/calendar', '/m/calendar', '/me', null])
  })

  it('reads the page\'s messages', () => {
    expect(result.messages).toEqual([
      'navigateNative(path: "/m/calendar", replace: false)',
      'navigateNative(path: "/m", replace: true)',
      'nil',
      'navigated(path: "/m/workout/4", direction: "pop", depth: 2, byHost: true)',
      'navigated(path: "/m", direction: "push", depth: 0, byHost: false)',
      'back',
      'open(path: "/m/workout/4")',
      'nil',
      'snapshotSet(name: "today", json: "{}")',
      'nil',
      'snapshotRemove(name: "today")',
      'snapshotClear',
      'shareStorage(key: "auth_token", value: Optional("abc"))',
      'shareStorage(key: "auth_token", value: nil)',
      'nil',
    ])
  })
})
