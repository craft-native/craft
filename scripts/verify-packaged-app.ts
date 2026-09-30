/** Install a package containing the real Craft binary, then launch it via the SDK. */
import { createHash, randomUUID } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { createApp, resolveCraftBinary } from '../packages/typescript/src/index'
import { packageApp, type PackageResult, WINDOWS_NOTIFICATION_ID_FILE, windowsNotificationAppId } from '../packages/typescript/src/package'
import { verifyNativeStartup } from './verify-native-startup'

const [binaryArgument, version] = Bun.argv.slice(2)
if (!binaryArgument || !version)
  throw new Error('Usage: bun scripts/verify-packaged-app.ts <craft-binary> <version>')

const binary = resolve(binaryArgument)
const platform = process.platform === 'darwin' ? 'macos' : process.platform === 'win32' ? 'windows' : 'linux'
const receipt = 'dev.craft.packaged-smoke'
const deepLinkScheme = 'craftpackagedsmoke'
const installPath = platform === 'macos'
  ? '/Applications/craft.app/Contents/MacOS/craft'
  : platform === 'windows'
    ? join(process.env.ProgramFiles || 'C:\\Program Files', 'craft', 'craft.exe')
    : '/usr/bin/craft'

async function command(label: string, argv: string[]): Promise<string> {
  const child = Bun.spawn(argv, { stdout: 'pipe', stderr: 'pipe' })
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  const output = `${stdout}${stderr}`.trim()
  if (code !== 0) throw new Error(`${label} failed (${code}): ${output}`)
  console.log(`${label}: ${output || 'ok'}`)
  return output
}

async function dispatchLinuxUri(label: string, url: string, observed: Promise<void>): Promise<void> {
  // GIO reads the installed x-scheme-handler desktop entry directly. The
  // xdg-open wrapper on headless CI delegates to a broken document portal.
  // Success means the installed page reported the URL, not just a zero exit.
  const child = Bun.spawn(['gio', 'open', url], { stdout: 'ignore', stderr: 'pipe' })
  const stderr = new Response(child.stderr).text()
  const failed = child.exited.then(async (code) => {
    if (code !== 0) throw new Error(`${label} failed (${code}): ${await stderr}`)
    return new Promise<never>(() => {})
  })
  await Promise.race([observed, failed])
  console.log(`${label}: installed page observed ${url}`)
}

async function startColdDeepLinkObserver(testWarm: boolean): Promise<{
  launchUrl: string
  waitFor: (expected: string) => Promise<void>
  waitForWarm: (expected: string) => Promise<void>
  close: () => Promise<void>
}> {
  let acceptCold!: (url: string | null) => void
  let acceptWarm!: (url: string | null) => void
  let coldReceived = false
  const receivedCold = new Promise<string | null>(resolve => { acceptCold = resolve })
  const receivedWarm = new Promise<string | null>(resolve => { acceptWarm = resolve })
  const page = `<!doctype html><title>Craft cold deep-link smoke</title><script>
    (async () => {
      if (!window.craft?.deepLink?.getInitialUrl) throw new Error('installed app has no deep-link bridge')
      if (${testWarm}) window.craft.deepLink.onUrl(detail => {
        const report = new URL('/warm', location.origin)
        report.searchParams.set('url', detail.url)
        fetch(report, { method: 'POST' }).then(() => window.craft.window.close())
      })
      const url = window.craft.deepLink.getInitialUrl()
      const report = new URL('/received', location.origin)
      if (url) report.searchParams.set('url', url)
      await fetch(report, { method: 'POST' })
      if (!${testWarm}) window.craft.window.close()
    })().catch(error => {
      const report = new URL('/failed', location.origin)
      report.searchParams.set('reason', String(error))
      return fetch(report, { method: 'POST' })
    })
  </script>`
  const server = createServer((request, response) => {
    if (request.url?.startsWith('/received?') && request.method === 'POST') {
      const url = new URL(request.url, 'http://127.0.0.1').searchParams.get('url')
      if (coldReceived) acceptWarm(`unexpected second app instance: ${url}`)
      else { coldReceived = true; acceptCold(url) }
    }
    if (request.url?.startsWith('/warm?') && request.method === 'POST')
      acceptWarm(new URL(request.url, 'http://127.0.0.1').searchParams.get('url'))
    if (request.url?.startsWith('/failed?') && request.method === 'POST') {
      const reason = `error: ${new URL(request.url, 'http://127.0.0.1').searchParams.get('reason')}`
      if (coldReceived) acceptWarm(reason)
      else acceptCold(reason)
    }
    response.writeHead(200, { 'Content-Type': 'text/html', Connection: 'close' })
    response.end(page)
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const address = server.address() as AddressInfo
  return {
    launchUrl: `http://127.0.0.1:${address.port}/`,
    async waitFor(expected: string) {
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        const actual = await Promise.race([
          receivedCold,
          new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('Installed app did not report its cold deep link within 20 seconds')), 20_000) }),
        ])
        if (actual !== expected) throw new Error(`Installed app cold deep link differed: ${JSON.stringify(actual)}`)
      }
      finally { if (timer) clearTimeout(timer) }
    },
    async waitForWarm(expected: string) {
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        const actual = await Promise.race([
          receivedWarm,
          new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('Running app did not report its warm deep link within 20 seconds')), 20_000) }),
        ])
        if (actual !== expected) throw new Error(`Running app warm deep link differed: ${JSON.stringify(actual)}`)
      }
      finally { if (timer) clearTimeout(timer) }
    },
    close: () => new Promise<void>(resolve => server.close(() => resolve())),
  }
}

function artifact(results: PackageResult[], format: string): string {
  const result = results.find(item => item.format === format)
  if (!result?.success || !result.outputPath || !existsSync(result.outputPath))
    throw new Error(`${format} packaging failed: ${result?.error || 'missing artifact'}`)
  return result.outputPath
}

function sha256(path: string): string {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

async function startLinuxNotificationObserver(marker: string): Promise<{ observe: () => Promise<boolean>, stop: () => Promise<void> }> {
  // A private D-Bus session (created by CI) and Dunst let the host verify the
  // exact banner that the installed app sent, not just that _send() posted JS.
  const daemon = Bun.spawn(['dunst', '--config', '-'], {
    stdin: 'ignore', stdout: 'ignore', stderr: 'ignore',
  })
  const stop = async () => {
    daemon.kill()
    await daemon.exited
  }
  try {
    for (let attempt = 0; attempt < 30; attempt++) {
      // NameHasOwner does not activate org.freedesktop.Notifications. Calling
      // dunstctl before our daemon owns the name can instead auto-start a
      // *second* Dunst, making this one exit before observing anything.
      const probe = Bun.spawnSync([
        'dbus-send', '--session', '--print-reply', '--dest=org.freedesktop.DBus',
        '/org/freedesktop/DBus', 'org.freedesktop.DBus.NameHasOwner',
        'string:org.freedesktop.Notifications',
      ], { stdout: 'pipe', stderr: 'pipe' })
      if (probe.exitCode === 0 && probe.stdout.toString().includes('boolean true')) {
        await command('clear private notification history', ['dunstctl', 'history-clear'])
        const observe = async () => {
          for (let poll = 0; poll < 100; poll++) {
            const count = Bun.spawnSync(['dunstctl', 'count', 'displayed'], { stdout: 'pipe', stderr: 'pipe' })
            if (count.exitCode === 0 && Number(count.stdout.toString().trim()) > 0)
              await command('close displayed notification into history', ['dunstctl', 'close-all'])
            const history = Bun.spawnSync(['dunstctl', 'history'], { stdout: 'pipe', stderr: 'pipe' })
            if (history.exitCode === 0 && history.stdout.toString().includes(marker)) return true
            await new Promise(resolve => setTimeout(resolve, 100))
          }
          return false
        }
        return { observe, stop }
      }
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    throw new Error('Dunst did not become ready in the private D-Bus session')
  }
  catch (error) {
    await stop()
    throw error
  }
}

async function launchViaSdk(): Promise<void> {
  const oldPath = process.env.PATH
  const oldCraftBin = process.env.CRAFT_BIN
  process.env.PATH = `${dirname(installPath)}${process.platform === 'win32' ? ';' : ':'}${oldPath || ''}`
  delete process.env.CRAFT_BIN

  let acceptReady!: () => void
  let rejectReady!: (error: Error) => void
  const ready = new Promise<void>((resolve, reject) => {
    acceptReady = resolve
    rejectReady = reject
  })
  // Hosted runners have disposable clipboards. Do not replace a developer's
  // clipboard when this installer verifier is run manually.
  const testSystemClipboard = process.env.GITHUB_ACTIONS === 'true'
  const testMultiWindow = testSystemClipboard
  const testMacWindowAdoption = testMultiWindow && platform === 'macos'
  const testDeepLink = testSystemClipboard && platform === 'macos'
  const testMacNotificationPermission = testSystemClipboard && platform === 'macos'
  const testLinuxNotification = testSystemClipboard && platform === 'linux'
  const testWindowsNotification = testSystemClipboard && platform === 'windows'
  const clipboardMarker = `Craft "quoted" \\ path ${randomUUID()}`
  const deepLinkUrl = `${deepLinkScheme}://open/${randomUUID()}`
  const notificationMarker = `Craft installed notification ${randomUUID()}`
  const notificationId = `craft-installed-${randomUUID()}`
  let macPermissionDenied = false
  let macPermissionStatus = 'unknown'
  let installedChildReady = false
  let installedChildResizeArmed = false
  let installedChildResized = false
  let installedGrandchildReady = false
  let installedGrandchildResized = false
  let acceptDeepLink!: (url: string | null) => void
  const receivedDeepLink = new Promise<string | null>((resolve) => {
    acceptDeepLink = resolve
  })
  const page = `<!doctype html><title>Craft packaged smoke</title><script>
    (async function () {
      if (!window.craft) throw new Error('Craft bridge missing from installed app')
      if (${testDeepLink}) {
        if (!window.craft.deepLink || !window.craft.deepLink.onUrl)
          throw new Error('installed app has no deep-link bridge')
        const reportLink = detail => {
          const target = new URL('/deep-link', location.origin)
          target.searchParams.set('url', detail.url)
          return fetch(target, { method: 'POST' })
        }
        window.craft.deepLink.onUrl(reportLink)
        const initial = window.craft.deepLink.getInitialUrl()
        if (initial) reportLink({ url: initial })
      }
      if (${testSystemClipboard}) {
        const expected = ${JSON.stringify(clipboardMarker)}
        if (!window.craft.clipboard || !window.craft.clipboard.writeText || !window.craft.clipboard.readText)
          throw new Error('installed app has no clipboard bridge')
        await window.craft.clipboard.writeText(expected)
        let actual = ''
        for (let attempt = 0; attempt < 30; attempt++) {
          actual = await window.craft.clipboard.readText()
          if (actual === expected) break
          await new Promise(resolve => setTimeout(resolve, 100))
        }
        if (actual !== expected)
          throw new Error(JSON.stringify({ message: 'clipboard bridge round trip differed', actual }))
      }
      if (${testMultiWindow}) {
        if (!window.craft.window?.open || !window.craft.window?._call)
          throw new Error('installed app has no multi-window bridge')
        const child = await window.craft.window.open({
          name: 'installed-child', title: 'Craft installed child',
          url: new URL('/installed-child', location.href).href,
        })
        if (child?.name !== 'installed-child') throw new Error('installed child returned the wrong handle')
        let loaded = false
        for (let attempt = 0; attempt < 100; attempt++) {
          loaded = (await (await fetch('/installed-child-status')).json()).ready
          if (loaded) break
          await new Promise(resolve => setTimeout(resolve, 100))
        }
        if (!loaded) throw new Error('installed child page did not load within 10 seconds')
        const title = await window.craft.window._call('getTitle', {}, child.name)
        if (title !== 'Craft installed child') throw new Error('installed child title reached the wrong window')
        const mainSize = await window.craft.window._call('getSize', {}, 'main')
        await fetch('/installed-child-arm', { method: 'POST' })
        await new Promise((resolve, reject) => {
          let lastResize = null
          const listener = event => {
            if (event.detail.windowId !== child.name) return
            lastResize = event.detail
            if (!Number.isFinite(event.detail.width) || !Number.isFinite(event.detail.height)) return
            if (Math.abs(event.detail.width - 720) > 60 || Math.abs(event.detail.height - 510) > 60) return
            clearTimeout(timeout)
            window.removeEventListener('craft:window:resize', listener)
            resolve()
          }
          const timeout = setTimeout(() => {
            window.removeEventListener('craft:window:resize', listener)
            reject(new Error(['creator did not receive installed child resize event:', JSON.stringify(lastResize)].join(' ')))
          }, 10000)
          window.addEventListener('craft:window:resize', listener)
          window.craft.window._call('setSize', { width: 720, height: 510 }, child.name).catch(error => {
            clearTimeout(timeout)
            window.removeEventListener('craft:window:resize', listener)
            reject(error)
          })
        })
        let childResized = false
        for (let attempt = 0; attempt < 100; attempt++) {
          childResized = (await (await fetch('/installed-child-status')).json()).resized
          if (childResized) break
          await new Promise(resolve => setTimeout(resolve, 100))
        }
        if (!childResized) throw new Error('installed child page did not receive its local resize event')
        const childSize = await window.craft.window._call('getSize', {}, child.name)
        if (Math.abs(childSize.width - 720) > 60 || Math.abs(childSize.height - 510) > 60)
          throw new Error('installed child did not reach the requested size')
        const mainAfter = await window.craft.window._call('getSize', {}, 'main')
        if (Math.abs(mainAfter.width - mainSize.width) > 40 || Math.abs(mainAfter.height - mainSize.height) > 40)
          throw new Error('installed child resize changed the main window size')
        if (${testMacWindowAdoption}) {
          let grandchildLoaded = false
          for (let attempt = 0; attempt < 100; attempt++) {
            grandchildLoaded = (await (await fetch('/installed-grandchild-status')).json()).ready
            if (grandchildLoaded) break
            await new Promise(resolve => setTimeout(resolve, 100))
          }
          if (!grandchildLoaded) throw new Error('installed grandchild page did not load within 10 seconds')
          let stolen = false
          try {
            await window.craft.window.open({
              name: 'installed-grandchild', title: 'Wrong owner',
              url: new URL('/installed-grandchild', location.href).href,
            })
          }
          catch (_) { stolen = true }
          if (!stolen) throw new Error('installed grandchild handle was stolen from its live creator')
        }
        await new Promise((resolve, reject) => {
          const listener = event => {
            if (event.detail.windowId !== child.name) return
            clearTimeout(timeout)
            window.removeEventListener('craft:window:close', listener)
            resolve()
          }
          const timeout = setTimeout(() => {
            window.removeEventListener('craft:window:close', listener)
            reject(new Error('creator did not receive installed child close event'))
          }, 10000)
          window.addEventListener('craft:window:close', listener)
          window.craft.window._call('close', {}, child.name).catch(error => {
            clearTimeout(timeout)
            window.removeEventListener('craft:window:close', listener)
            reject(error)
          })
        })
        if (${testMacWindowAdoption}) {
          // macOS close retains the creator's webview and event ownership.
          // Permanent destroy is what must release the grandchild's owner.
          await window.craft.window._call('destroy', {}, child.name)
          const title = await window.craft.window._call('getTitle', {}, 'installed-grandchild')
          if (title !== 'Craft installed grandchild')
            throw new Error('unparented installed grandchild did not survive creator destroy')
          const adopted = await window.craft.window.open({
            name: 'installed-grandchild', title: 'Craft installed grandchild',
            url: new URL('/installed-grandchild', location.href).href,
          })
          if (adopted.name !== 'installed-grandchild')
            throw new Error('installed grandchild could not be adopted')
          await window.craft.window._call('executeJavaScript', { code: 'window.__expectAdoptedResize = true' }, adopted.name)
          const adoptedResize = new Promise((resolve, reject) => {
            const listener = event => {
              if (event.detail.windowId !== adopted.name) return
              clearTimeout(timeout)
              window.removeEventListener('craft:window:resize', listener)
              resolve()
            }
            const timeout = setTimeout(() => {
              window.removeEventListener('craft:window:resize', listener)
              reject(new Error('installed grandchild resize did not reach its new creator'))
            }, 10000)
            window.addEventListener('craft:window:resize', listener)
          })
          await window.craft.window._call('setSize', { width: 680, height: 470 }, adopted.name)
          await adoptedResize
          let grandchildResized = false
          for (let attempt = 0; attempt < 100; attempt++) {
            grandchildResized = (await (await fetch('/installed-grandchild-status')).json()).resized
            if (grandchildResized) break
            await new Promise(resolve => setTimeout(resolve, 100))
          }
          if (!grandchildResized) throw new Error('installed grandchild did not receive its local resize event')
          await window.craft.window._call('destroy', {}, adopted.name)
        }
      }
      if (${testLinuxNotification}) {
        if (!window.craft.notifications || !window.craft.notifications.requestPermission || !window.craft.notifications.show)
          throw new Error('installed app has no notification bridge')
        if (!await window.craft.notifications.requestPermission())
          throw new Error('installed Linux app denied notification permission')
        await window.craft.notifications.show({ title: ${JSON.stringify(notificationMarker)}, body: 'Installed-app integration smoke' })
      }
      if (${testMacNotificationPermission}) {
        let permission = null
        let requestError = null
        try {
          permission = await Promise.race([
            window.craft.notifications.requestPermission({ provisional: true }),
            new Promise((_, reject) => setTimeout(() => reject(new Error('macOS notification permission did not answer within 15 seconds')), 15000)),
          ])
        }
        catch (error) {
          // An NSError is not a normal denial. Ask Notification Center for
          // its actual state before classifying a runner that cannot prompt.
          if (error?.code !== 'NATIVE_CALL_FAILED') throw error
          requestError = error
        }
        const status = await window.craft.notifications.getPermissionStatus()
        if (typeof status !== 'string') throw new Error('macOS notification authorization status was not a string')
        if (status === 'notDetermined' || status === 'unknown')
          throw new Error(JSON.stringify({ message: 'macOS notification authorization did not reach a determined state', status, requestError }))
        if (requestError && status !== 'denied')
          throw new Error(JSON.stringify({ message: 'macOS notification request failed despite a non-denied status', status, requestError }))
        if (!requestError && typeof permission !== 'boolean') throw new Error('macOS notification permission reply was not boolean')
        if (permission || status === 'authorized' || status === 'provisional' || status === 'ephemeral') {
          await window.craft.notifications.show({ id: ${JSON.stringify(notificationId)}, title: ${JSON.stringify(notificationMarker)}, body: 'Installed-app integration smoke' })
          let delivered = false
          for (let attempt = 0; attempt < 50; attempt++) {
            delivered = await window.craft.notifications.hasDelivered(${JSON.stringify(notificationId)})
            if (delivered) break
            await new Promise(resolve => setTimeout(resolve, 100))
          }
          if (!delivered) throw new Error('macOS Notification Center did not report the installed app notification')
        }
        else {
          const report = new URL('/notification-denied', location.origin)
          report.searchParams.set('status', status)
          await fetch(report, { method: 'POST' })
        }
      }
      if (${testWindowsNotification}) {
        if (!await window.craft.notifications.requestPermission())
          throw new Error('installed Windows app denied notification permission')
        await window.craft.notifications.show({ title: ${JSON.stringify(notificationMarker)}, body: 'Installed-app integration smoke' })
      }
      await fetch('/ready', { method: 'POST' })
    })().catch((error) => {
      const target = new URL('/failed', location.origin)
      target.searchParams.set('reason', [String(error?.message || error), error?.stack].filter(Boolean).join(' | '))
      return fetch(target, { method: 'POST' })
    })
  </script>`
  const childPage = `<!doctype html><title>Craft installed child</title><script>
    (async function () {
      if (!window.craft?.window?._call) throw new Error('installed child has no window bridge')
      const title = await window.craft.window._call('getTitle', {}, 'main')
      if (title !== 'Craft installed child') throw new Error('installed child page addressed another window')
      window.addEventListener('craft:window:resize', event => {
        if (event.detail.windowId !== 'main') return
        if (!Number.isFinite(event.detail.width) || !Number.isFinite(event.detail.height)) return
        if (Math.abs(event.detail.width - 720) > 60 || Math.abs(event.detail.height - 510) > 60) return
        fetch('/installed-child-resized', { method: 'POST' })
      })
      if (${testMacWindowAdoption}) {
        const grandchild = await window.craft.window.open({
          name: 'installed-grandchild', title: 'Craft installed grandchild',
          url: new URL('/installed-grandchild', location.href).href,
        })
        if (grandchild.name !== 'installed-grandchild')
          throw new Error('installed child opened the wrong grandchild')
      }
      await fetch('/installed-child-ready', { method: 'POST' })
    })().catch(error => {
      const target = new URL('/failed', location.origin)
      target.searchParams.set('reason', [String(error?.message || error), error?.stack].filter(Boolean).join(' | '))
      return fetch(target, { method: 'POST' })
    })
  </script>`
  const grandchildPage = `<!doctype html><title>Craft installed grandchild</title><script>
    (async function () {
      const title = await window.craft.window._call('getTitle', {}, 'main')
      if (title !== 'Craft installed grandchild')
        throw new Error('installed grandchild page addressed another window')
      window.addEventListener('craft:window:resize', event => {
        if (event.detail.windowId !== 'main' || !window.__expectAdoptedResize) return
        if (Math.abs(event.detail.width - 680) > 60 || Math.abs(event.detail.height - 470) > 60) return
        fetch('/installed-grandchild-resized', { method: 'POST' })
      })
      await fetch('/installed-grandchild-ready', { method: 'POST' })
    })().catch(error => {
      const target = new URL('/failed', location.origin)
      target.searchParams.set('reason', [String(error?.message || error), error?.stack].filter(Boolean).join(' | '))
      return fetch(target, { method: 'POST' })
    })
  </script>`
  const server = createServer((request, response) => {
    if (request.url === '/installed-child-ready' && request.method === 'POST') {
      installedChildReady = true
      response.writeHead(200).end('ok')
      return
    }
    if (request.url === '/installed-child-arm' && request.method === 'POST') {
      installedChildResizeArmed = true
      installedChildResized = false
      response.writeHead(200).end('ok')
      return
    }
    if (request.url === '/installed-child-resized' && request.method === 'POST') {
      if (installedChildResizeArmed) installedChildResized = true
      response.writeHead(200).end('ok')
      return
    }
    if (request.url === '/installed-child-status' && request.method === 'GET') {
      response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ ready: installedChildReady, resized: installedChildResized }))
      return
    }
    if (request.url === '/installed-grandchild-ready' && request.method === 'POST') {
      installedGrandchildReady = true
      response.writeHead(200).end('ok')
      return
    }
    if (request.url === '/installed-grandchild-resized' && request.method === 'POST') {
      installedGrandchildResized = true
      response.writeHead(200).end('ok')
      return
    }
    if (request.url === '/installed-grandchild-status' && request.method === 'GET') {
      response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ ready: installedGrandchildReady, resized: installedGrandchildResized }))
      return
    }
    if (request.url === '/ready' && request.method === 'POST') acceptReady()
    if (request.url?.startsWith('/deep-link?') && request.method === 'POST') {
      const received = new URL(request.url, 'http://127.0.0.1').searchParams.get('url')
      acceptDeepLink(received)
    }
    if (request.url?.startsWith('/failed?') && request.method === 'POST') {
      const reason = new URL(request.url, 'http://127.0.0.1').searchParams.get('reason')
      rejectReady(new Error(reason || 'Installed app reported a failure without details'))
    }
    if (request.url?.startsWith('/notification-denied?') && request.method === 'POST') {
      macPermissionDenied = true
      macPermissionStatus = new URL(request.url, 'http://127.0.0.1').searchParams.get('status') || 'unknown'
    }
    response.writeHead(200, { 'Content-Type': 'text/html' })
    response.end(request.url?.startsWith('/installed-grandchild') ? grandchildPage : request.url?.startsWith('/installed-child') ? childPage : page)
  })
  let app: ReturnType<typeof createApp> | undefined
  let notificationObserver: Awaited<ReturnType<typeof startLinuxNotificationObserver>> | undefined
  try {
    if (resolveCraftBinary() !== 'craft')
      throw new Error('SDK did not select the PATH-based craft binary')
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    if (testLinuxNotification)
      notificationObserver = await startLinuxNotificationObserver(notificationMarker)
    const address = server.address() as AddressInfo
    app = createApp({
      url: `http://127.0.0.1:${address.port}/`,
      // Native NSError diagnostics must be visible when a CI host cannot
      // authorize notifications; quiet mode keeps stderr only on app failure.
      quiet: platform !== 'macos',
      window: { title: 'Craft packaged smoke', devTools: false, hotReload: false },
    })
    const shown = app.show()
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      await Promise.race([
        ready,
        shown.then(() => { throw new Error('Installed Craft exited before loading the sample app') }),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('Installed Craft did not load the sample app within 45 seconds')), 45_000)
        }),
      ])
      console.log('SDK launched installed Craft from PATH and its WebView loaded the bridge')
      if (testMultiWindow)
        console.log('Installed app opened, resized, and closed a child window with creator-scoped events')
      if (testMacWindowAdoption)
        console.log('Installed macOS grandchild survived creator destroy and re-routed events after adoption')
      if (testSystemClipboard) {
        const readCommand = platform === 'macos'
          ? ['pbpaste']
          : platform === 'windows'
            ? ['powershell', '-NoProfile', '-NonInteractive', '-Command', 'Get-Clipboard -Raw']
            : ['xclip', '-selection', 'clipboard', '-o']
        const osValue = await command('read system clipboard', readCommand)
        if (osValue !== clipboardMarker)
          throw new Error(`Installed app clipboard write did not reach the OS: ${JSON.stringify(osValue)}`)
        console.log('Installed app clipboard bridge and OS clipboard agree')
      }
      if (notificationObserver) {
        if (!await notificationObserver.observe())
          throw new Error('Dunst history did not contain the installed app notification within 10 seconds')
        console.log('Installed Linux app notification reached the desktop daemon')
      }
      if (testMacNotificationPermission)
        console.log(macPermissionDenied
          ? `Installed macOS app notification authorization is ${macPermissionStatus}; delivery cannot be verified on this runner`
          : 'Installed macOS app notification reached Notification Center')
      if (testWindowsNotification) {
        const appId = windowsNotificationAppId('craft', 'Craft Packaged Smoke')
        let delivered = false
        for (let attempt = 0; attempt < 50; attempt++) {
          const xml = await command('inspect Windows notification history', [
            'powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            `$ErrorActionPreference='Stop'; [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null; [Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory('${appId}') | ForEach-Object { $_.Content.GetXml() }`,
          ])
          if (xml.includes(notificationMarker)) { delivered = true; break }
          await new Promise(resolve => setTimeout(resolve, 100))
        }
        if (!delivered) throw new Error('Windows notification history did not contain the installed app toast')
        console.log('Installed Windows app notification reached Action Center')
      }
      if (testDeepLink) {
        await command('dispatch installed app URL scheme', ['open', deepLinkUrl])
        let linkTimer: ReturnType<typeof setTimeout> | undefined
        try {
          const received = await Promise.race([
            receivedDeepLink,
            new Promise<never>((_, reject) => {
              linkTimer = setTimeout(() => reject(new Error('Installed app did not receive its URL scheme within 15 seconds')), 15_000)
            }),
          ])
          if (received !== deepLinkUrl)
            throw new Error(`Installed app received the wrong deep link: ${JSON.stringify(received)}`)
          console.log('Installed macOS app received its registered deep link')
        }
        finally {
          if (linkTimer) clearTimeout(linkTimer)
        }
      }
    }
    finally {
      if (timer) clearTimeout(timer)
      app.close()
      await shown.catch(() => {})
    }
  }
  finally {
    if (notificationObserver) await notificationObserver.stop()
    server.close()
    if (oldPath === undefined) delete process.env.PATH
    else process.env.PATH = oldPath
    if (oldCraftBin === undefined) delete process.env.CRAFT_BIN
    else process.env.CRAFT_BIN = oldCraftBin
  }
}

async function main(): Promise<void> {
  if (!existsSync(binary)) throw new Error(`Built Craft binary missing: ${binary}`)
  const installRoot = platform === 'linux' ? installPath : platform === 'macos' ? '/Applications/craft.app' : dirname(installPath)
  if (existsSync(installRoot)) throw new Error(`Refusing to replace existing installation: ${installRoot}`)
  if (platform === 'linux') {
    const installedPackage = Bun.spawnSync(['dpkg-query', '-W', '-f=${Status}', 'craft'], { stdout: 'pipe', stderr: 'pipe' })
    if (installedPackage.exitCode === 0)
      throw new Error('Refusing to replace an existing Debian craft package')
  }
  if (platform === 'macos') {
    const installedReceipt = Bun.spawnSync(['pkgutil', '--pkg-info', receipt], { stdout: 'pipe', stderr: 'pipe' })
    if (installedReceipt.exitCode === 0)
      throw new Error(`Refusing to reuse existing package receipt: ${receipt}`)
  }
  const work = mkdtempSync(join(tmpdir(), 'craft-packaged-smoke-'))
  let installed = false
  let installer = ''
  let coldObserver: Awaited<ReturnType<typeof startColdDeepLinkObserver>> | undefined
  try {
    if (process.env.GITHUB_ACTIONS === 'true' && platform !== 'macos')
      coldObserver = await startColdDeepLinkObserver(true)
    const loader = join(dirname(binary), 'WebView2Loader.dll')
    if (platform === 'windows' && !existsSync(loader))
      throw new Error(`Windows WebView2 loader missing beside binary: ${loader}`)
    const results = await packageApp({
      name: 'craft',
      version,
      description: 'Craft packaged application smoke test',
      author: 'Craft Packaged Smoke',
      binaryPath: binary,
      outDir: work,
      bundleId: receipt,
      platforms: [platform],
      // The hosted runner rejected authorization from the unsigned bundle.
      // Ad-hoc signing tests whether an installed code identity is sufficient
      // without requiring a release certificate on the hosted runner.
      macos: { dmg: false, pkg: true, signIdentity: '-', urlSchemes: [deepLinkScheme] },
      linux: { deb: true, rpm: false, appImage: false, debDependencies: ['libnotify-bin'], urlSchemes: [deepLinkScheme], launchUrl: coldObserver?.launchUrl },
      windows: { msi: true, zip: true, additionalFiles: platform === 'windows' ? [loader] : [], urlSchemes: [deepLinkScheme], launchUrl: coldObserver?.launchUrl },
    })
    installer = artifact(results, platform === 'macos' ? 'pkg' : platform === 'windows' ? 'msi' : 'deb')
    if (platform === 'linux') {
      const dependencies = await command('inspect Linux DEB dependencies', ['dpkg-deb', '--field', installer, 'Depends'])
      if (!dependencies.split(',').map(item => item.trim()).includes('libnotify-bin'))
        throw new Error('Installed-app DEB did not declare the notify-send provider')
      const inspected = join(work, 'deb-inspect')
      await command('extract Linux DEB for protocol inspection', ['dpkg-deb', '--extract', installer, inspected])
      const desktop = readFileSync(join(inspected, 'usr', 'share', 'applications', 'craft.desktop'), 'utf8')
      if (!desktop.includes(`MimeType=x-scheme-handler/${deepLinkScheme};`) || !desktop.includes('Exec=/usr/bin/craft') || !desktop.includes('--deep-link %u'))
        throw new Error('Linux DEB did not register its declared URL scheme')
      if (coldObserver && !desktop.includes(`--url "${coldObserver.launchUrl}"`))
        throw new Error('Linux DEB protocol handler did not load its packaged app page')
    }

    if (platform === 'windows') {
      const zip = artifact(results, 'zip')
      const expanded = join(work, 'expanded')
      const quotedZip = zip.replaceAll("'", "''")
      const quotedExpanded = expanded.replaceAll("'", "''")
      await command('extract Windows ZIP', ['pwsh', '-NoProfile', '-Command', `Expand-Archive -LiteralPath '${quotedZip}' -DestinationPath '${quotedExpanded}'`])
      verifyNativeStartup(join(expanded, 'craft.exe'), version)
      if (sha256(join(expanded, 'WebView2Loader.dll')) !== sha256(loader))
        throw new Error('Windows ZIP did not preserve the WebView2 loader')
      console.log('Windows ZIP executable and loader verified')
      await command('install Windows MSI', ['msiexec.exe', '/i', installer, '/qn', '/norestart'])
    }
    else if (platform === 'macos') await command('install macOS PKG', ['sudo', 'installer', '-pkg', installer, '-target', '/'])
    else await command('install Linux DEB', ['sudo', 'dpkg', '-i', installer])
    installed = true

    if (!existsSync(installPath)) throw new Error(`Installer did not create ${installPath}`)
    if (platform === 'macos')
      await command('verify installed macOS app signature', ['codesign', '--verify', '--deep', '--strict', '/Applications/craft.app'])
    verifyNativeStartup(installPath, version)
    if (platform === 'windows' && sha256(join(dirname(installPath), 'WebView2Loader.dll')) !== sha256(loader))
      throw new Error('Windows MSI did not install the WebView2 loader beside craft.exe')
    if (platform === 'windows') {
      const appId = windowsNotificationAppId('craft', 'Craft Packaged Smoke')
      if (readFileSync(join(dirname(installPath), WINDOWS_NOTIFICATION_ID_FILE), 'utf8') !== appId)
        throw new Error('Windows MSI notification identity did not match its package metadata')
      const shortcut = join(process.env.ProgramData || 'C:\\ProgramData', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'craft.lnk')
      if (!existsSync(shortcut)) throw new Error(`Windows MSI did not install its Start-menu shortcut: ${shortcut}`)
      console.log('Windows MSI installed matching notification identity and Start-menu shortcut')
      const protocol = await command('inspect Windows installed URL protocol', ['reg.exe', 'query', `HKCR\\${deepLinkScheme}`, '/v', 'URL Protocol'])
      if (!protocol.includes('URL Protocol')) throw new Error('Windows MSI did not register its declared URL scheme')
      const launch = await command('inspect Windows URL launch command', ['reg.exe', 'query', `HKCR\\${deepLinkScheme}\\shell\\open\\command`, '/ve'])
      if (!launch.includes('--deep-link') || !launch.includes('"%1"'))
        throw new Error('Windows MSI URL handler did not pass a separate deep-link argument')
      if (coldObserver && !launch.includes(coldObserver.launchUrl))
        throw new Error('Windows MSI URL handler did not load its packaged app page')
    }
    if (coldObserver) {
      const coldUrl = `${deepLinkScheme}://cold/${randomUUID()}`
      if (platform === 'linux') {
        await command('select installed Linux URI handler', ['xdg-mime', 'default', 'craft.desktop', `x-scheme-handler/${deepLinkScheme}`])
        const selected = await command('inspect Linux URI handler', ['xdg-mime', 'query', 'default', `x-scheme-handler/${deepLinkScheme}`])
        if (selected !== 'craft.desktop') throw new Error(`Linux selected the wrong URI handler: ${selected}`)
        await dispatchLinuxUri('dispatch cold Linux URI', coldUrl, coldObserver.waitFor(coldUrl))
      }
      else {
        await command('dispatch cold Windows URI', ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', `Start-Process -FilePath '${coldUrl}'`])
      }
      if (platform !== 'linux') await coldObserver.waitFor(coldUrl)
      console.log(`Installed ${platform} app received its cold-launch deep link`)
      const warmUrl = `${deepLinkScheme}://warm/${randomUUID()}`
      if (platform === 'linux') {
        await dispatchLinuxUri('dispatch warm Linux URI', warmUrl, coldObserver.waitForWarm(warmUrl))
      }
      else await command('dispatch warm Windows URI', ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', `Start-Process -FilePath '${warmUrl}'`])
      if (platform !== 'linux') await coldObserver.waitForWarm(warmUrl)
      console.log(`Running ${platform} app received its warm deep link in the existing page`)
      // The page posts before asking Craft to close; let that native close
      // finish before another app instance starts or MSI uninstall begins.
      await new Promise(resolve => setTimeout(resolve, 500))
    }
    await launchViaSdk()
  }
  finally {
    if (coldObserver) await coldObserver.close()
    if (installed) {
      if (platform === 'windows') await command('uninstall Windows MSI', ['msiexec.exe', '/x', installer, '/qn', '/norestart'])
      else if (platform === 'macos') {
        await command('remove smoke app', ['sudo', 'rm', '-rf', '/Applications/craft.app'])
        await command('forget smoke receipt', ['sudo', 'pkgutil', '--forget', receipt])
      }
      else await command('uninstall Linux DEB', ['sudo', 'dpkg', '--remove', 'craft'])
      if (existsSync(installPath)) throw new Error(`Uninstall left ${installPath} behind`)
    }
    rmSync(work, { recursive: true, force: true })
  }
}

if (import.meta.main) await main()
