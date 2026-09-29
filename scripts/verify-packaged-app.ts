/** Install a package containing the real Craft binary, then launch it via the SDK. */
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { createApp, resolveCraftBinary } from '../packages/typescript/src/index'
import { packageApp, type PackageResult } from '../packages/typescript/src/package'
import { verifyNativeStartup } from './verify-native-startup'

const [binaryArgument, version] = Bun.argv.slice(2)
if (!binaryArgument || !version)
  throw new Error('Usage: bun scripts/verify-packaged-app.ts <craft-binary> <version>')

const binary = resolve(binaryArgument)
const platform = process.platform === 'darwin' ? 'macos' : process.platform === 'win32' ? 'windows' : 'linux'
const receipt = 'dev.craft.packaged-smoke'
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
  const page = `<!doctype html><title>Craft packaged smoke</title><script>
    if (!window.craft) {
      fetch('/failed', { method: 'POST', body: 'Craft bridge missing from installed app' })
    } else {
      fetch('/ready', { method: 'POST' })
    }
  </script>`
  const server = createServer((request, response) => {
    if (request.url === '/ready' && request.method === 'POST') acceptReady()
    if (request.url === '/failed' && request.method === 'POST') {
      let body = ''
      request.on('data', chunk => body += chunk.toString())
      request.on('end', () => rejectReady(new Error(body)))
    }
    response.writeHead(200, { 'Content-Type': 'text/html' })
    response.end(page)
  })
  let app: ReturnType<typeof createApp> | undefined
  try {
    if (resolveCraftBinary() !== 'craft')
      throw new Error('SDK did not select the PATH-based craft binary')
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
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
    }
    finally {
      if (timer) clearTimeout(timer)
      app.close()
      await shown.catch(() => {})
    }
  }
  finally {
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
      macos: { dmg: false, pkg: true },
      linux: { deb: true, rpm: false, appImage: false, debDependencies: [] },
      windows: { msi: true, zip: true, additionalFiles: platform === 'windows' ? [loader] : [] },
    })
    installer = artifact(results, platform === 'macos' ? 'pkg' : platform === 'windows' ? 'msi' : 'deb')

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
