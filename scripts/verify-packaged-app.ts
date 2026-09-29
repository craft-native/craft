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
  const testDeepLink = testSystemClipboard && platform === 'macos'
  const testMacNotificationPermission = testSystemClipboard && platform === 'macos'
  const testLinuxNotification = testSystemClipboard && platform === 'linux'
  const testWindowsNotification = testSystemClipboard && platform === 'windows'
  const clipboardMarker = `Craft "quoted" \\ path ${randomUUID()}`
  const deepLinkUrl = `${deepLinkScheme}://open/${randomUUID()}`
  const notificationMarker = `Craft installed notification ${randomUUID()}`
  const notificationId = `craft-installed-${randomUUID()}`
  let macPermissionDenied = false
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
      if (${testLinuxNotification}) {
        if (!window.craft.notifications || !window.craft.notifications.requestPermission || !window.craft.notifications.show)
          throw new Error('installed app has no notification bridge')
        if (!await window.craft.notifications.requestPermission())
          throw new Error('installed Linux app denied notification permission')
        await window.craft.notifications.show({ title: ${JSON.stringify(notificationMarker)}, body: 'Installed-app integration smoke' })
      }
      if (${testMacNotificationPermission}) {
        const permission = await Promise.race([
          window.craft.notifications.requestPermission(),
          new Promise((_, reject) => setTimeout(() => reject(new Error('macOS notification permission did not answer within 15 seconds')), 15000)),
        ])
        if (typeof permission !== 'boolean') throw new Error('macOS notification permission reply was not boolean')
        if (permission) {
          await window.craft.notifications.show({ id: ${JSON.stringify(notificationId)}, title: ${JSON.stringify(notificationMarker)}, body: 'Installed-app integration smoke' })
          let delivered = false
          for (let attempt = 0; attempt < 50; attempt++) {
            delivered = await window.craft.notifications.hasDelivered(${JSON.stringify(notificationId)})
            if (delivered) break
            await new Promise(resolve => setTimeout(resolve, 100))
          }
          if (!delivered) throw new Error('macOS Notification Center did not report the installed app notification')
        }
        else await fetch('/notification-denied', { method: 'POST' })
      }
      if (${testWindowsNotification}) {
        if (!await window.craft.notifications.requestPermission())
          throw new Error('installed Windows app denied notification permission')
        await window.craft.notifications.show({ title: ${JSON.stringify(notificationMarker)}, body: 'Installed-app integration smoke' })
      }
      await fetch('/ready', { method: 'POST' })
    })().catch((error) => {
      const target = new URL('/failed', location.origin)
      target.searchParams.set('reason', String(error?.stack || error))
      return fetch(target, { method: 'POST' })
    })
  </script>`
  const server = createServer((request, response) => {
    if (request.url === '/ready' && request.method === 'POST') acceptReady()
    if (request.url?.startsWith('/deep-link?') && request.method === 'POST') {
      const received = new URL(request.url, 'http://127.0.0.1').searchParams.get('url')
      acceptDeepLink(received)
    }
    if (request.url?.startsWith('/failed?') && request.method === 'POST') {
      const reason = new URL(request.url, 'http://127.0.0.1').searchParams.get('reason')
      rejectReady(new Error(reason || 'Installed app reported a failure without details'))
    }
    if (request.url === '/notification-denied' && request.method === 'POST') macPermissionDenied = true
    response.writeHead(200, { 'Content-Type': 'text/html' })
    response.end(page)
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
      quiet: true,
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
          ? 'Installed macOS app notification permission was denied; delivery cannot be verified on this runner'
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
  try {
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
      macos: { dmg: false, pkg: true, urlSchemes: [deepLinkScheme] },
      linux: { deb: true, rpm: false, appImage: false, debDependencies: ['libnotify-bin'], urlSchemes: [deepLinkScheme] },
      windows: { msi: true, zip: true, additionalFiles: platform === 'windows' ? [loader] : [], urlSchemes: [deepLinkScheme] },
    })
    installer = artifact(results, platform === 'macos' ? 'pkg' : platform === 'windows' ? 'msi' : 'deb')
    if (platform === 'linux') {
      const dependencies = await command('inspect Linux DEB dependencies', ['dpkg-deb', '--field', installer, 'Depends'])
      if (!dependencies.split(',').map(item => item.trim()).includes('libnotify-bin'))
        throw new Error('Installed-app DEB did not declare the notify-send provider')
      const inspected = join(work, 'deb-inspect')
      await command('extract Linux DEB for protocol inspection', ['dpkg-deb', '--extract', installer, inspected])
      const desktop = readFileSync(join(inspected, 'usr', 'share', 'applications', 'craft.desktop'), 'utf8')
      if (!desktop.includes(`MimeType=x-scheme-handler/${deepLinkScheme};`) || !desktop.includes('Exec=/usr/bin/craft %u'))
        throw new Error('Linux DEB did not register its declared URL scheme')
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
    }
    await launchViaSdk()
  }
  finally {
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
