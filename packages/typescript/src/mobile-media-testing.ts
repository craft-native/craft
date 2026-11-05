/** Bun-only native filesystem fault tests. No application account or database is used. */
import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, rm } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { isAbsolute, join } from 'node:path'
import { requireAndroidEmulatorRoot } from './android-adb.js'

export interface MobileMediaCacheTestOptions {
  platform: 'ios' | 'android'
  /** An owned simulator UUID, or emulator serial. iOS creates a disposable simulator when omitted. */
  device?: string
  /** Unpublished Craft's packages directory; installed SDK templates are used by default. */
  sourceRoot?: string
  storageOnly?: boolean
  /** Installed Gradle CLI (8.11.1 or compatible). */
  gradle?: string
  /** Allow Gradle to resolve build dependencies. Defaults to offline. */
  online?: boolean
  log?: (line: string) => void
}

/** Keep the probe on the complete shipped downloader, including its durable worker. */
export function androidMediaProbeSource(shell: string): string {
  return ['internal object CraftNativeMedia', 'internal class CraftResumableDownload', 'internal class CraftNativeMediaWorker'].map(declaration => {
    const source = shell.match(new RegExp(`${declaration}\\b[\\s\\S]*?\\n\\}`))?.[0]
    if (!source) throw new Error(`Android media implementation missing: ${declaration}`)
    return source
  }).join('\n\n')
}

/** Real ENOSPC, cache cleanup, retry, coalescing and offline video decode on an isolated native probe. */
export async function verifyMobileMediaCache(options: MobileMediaCacheTestOptions): Promise<{ platform: string, requests: Record<string, number> }> {
  if (options.platform !== 'ios' && options.platform !== 'android') throw new Error('Choose ios or android')
  if (options.platform === 'android' && !/^emulator-\d+$/.test(options.device || '')) throw new Error('An explicit disposable Android emulator serial is required')
  if (options.platform === 'ios' && options.device && !/^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(options.device)) throw new Error('An explicit iOS simulator UUID is required')
  if (options.sourceRoot && !isAbsolute(options.sourceRoot)) throw new Error('sourceRoot must be an absolute local path')
  const root = options.sourceRoot || import.meta.dir
  const packagedFixtures = join(import.meta.dir, 'testing/media-cache')
  const fixtures = existsSync(packagedFixtures) ? packagedFixtures : join(import.meta.dir, '../fixtures/media-cache')
  const print = options.log || console.log
  const storageOnly = options.storageOnly === true
  const scratch = await mkdtemp(join(tmpdir(), 'craft-media-probe-'))
  const bytes = new Uint8Array(await Bun.file(join(fixtures, 'demo.mp4')).arrayBuffer())
  const counts = new Map<string, number>()
  const resumed = new Set<string>()
  let lockedReleased = false
  let finishLocked: (() => void) | undefined
  let finishObsolete: (() => void) | undefined
  const timers = new Set<ReturnType<typeof setTimeout>>()
  const server = Bun.listen<{ request: string, answered: boolean }>({
    hostname: '0.0.0.0', port: 0,
    socket: {
      open(socket) { socket.data = { request: '', answered: false } },
      data(socket, input) {
        socket.data.request += new TextDecoder().decode(input)
        if (socket.data.answered || !socket.data.request.includes('\r\n\r\n')) return
        socket.data.answered = true
        const path = socket.data.request.split(' ')[1]!
        const n = (counts.get(path) || 0) + 1
        counts.set(path, n)
        if (path === '/android/inflight/slow.mp4' && n === 1) {
          finishObsolete = () => socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
          return
        }
        if (path === '/android/inflight/status') {
          socket.end(`HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n${finishObsolete ? '1' : '0'}`)
          return
        }
        if (path === '/android/inflight/release') {
          finishObsolete?.()
          finishObsolete = undefined
          socket.end('HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
          return
        }
        if (path === '/android/locked/release') {
          lockedReleased = true
          finishLocked?.()
          finishLocked = undefined
          socket.end('HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
          return
        }
        // Android resumes the download its process died in (CraftResumableDownload): the rest, from where its part stopped.
        const from = Number(/^range:\s*bytes=(\d+)-\s*$/im.exec(socket.data.request)?.[1] ?? Number.NaN)
        if (path === '/android/restart.mp4' && n > 1 && from > 0 && from < bytes.length) {
          resumed.add(path)
          socket.write(`HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes ${from}-${bytes.length - 1}/${bytes.length}\r\nContent-Length: ${bytes.length - from}\r\nConnection: close\r\n\r\n`)
          socket.write(bytes.subarray(from))
          socket.end()
          return
        }
        const empty = path.endsWith('/empty.mp4')
        const partial = path.endsWith('/partial.mp4')
        const cut = (path.endsWith('/broken.mp4') || path.endsWith('/retry.mp4') || path.endsWith('/restart.mp4')) && n === 1
        const slow = path.endsWith('/slow.mp4') || (path.endsWith('/restart.mp4') && n === 1)
        socket.write(`HTTP/1.1 ${partial ? '206 Partial Content' : '200 OK'}\r\nContent-Type: video/mp4\r\nContent-Length: ${empty ? 0 : bytes.length}\r\nConnection: close\r\n\r\n`)
        if (empty) { socket.end();
        return }
        socket.write(bytes.subarray(0, Math.floor(bytes.length / 2)))
        if (cut && !slow) { socket.end();
        return }
        const finish = () => { if (!cut) socket.write(bytes.subarray(Math.floor(bytes.length / 2)));
        socket.end() }
        if (path === '/android/locked/slow.mp4') {
          if (lockedReleased) finish()
          else finishLocked = finish
          return
        }
        if (slow) {
          const timer = setTimeout(() => { timers.delete(timer);
          finish() }, cut ? 60000 : 700)
          timers.add(timer)
        }
        else finish()
      },
      error() {},
      drain() {},
    },
  })

  async function run(args: string[], cwd = scratch, allowedFailure = false): Promise<string> {
    const proc = Bun.spawn(args, { cwd, env: { ...process.env, ANDROID_HOME: process.env.ANDROID_HOME || join(homedir(), 'Library/Android/sdk') }, stdout: 'pipe', stderr: 'pipe', timeout: 180000 })
    const [output, errors, status] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited])
    if (status && !allowedFailure) throw new Error(`${args[0]} failed (${status}):\n${output}\n${errors}`)
    return output + errors
  }

  let simulator = ''
  let ownsSimulator = false
  const packageName = 'dev.craft.mediaprobe'
  const sdk = process.env.ANDROID_HOME || join(homedir(), 'Library/Android/sdk')
  const adb = join(sdk, 'platform-tools/adb')
  let serial = ''
  let mountedVolume = ''
  let mountedAndroidCache = ''
  try {
    if (options.platform === 'ios') {
      const files = await Bun.file(join(root, 'ios/templates/CraftNativeFiles.swift')).text()
      const ownership = await Bun.file(join(root, 'ios/templates/CraftNativeMediaOwnership.swift')).text()
      const media = files.slice(files.indexOf('enum CraftNativeMedia {'))
      if (!media.startsWith('enum CraftNativeMedia')) throw new Error('iOS media implementation missing')
      const source = join(scratch, 'main.swift')
      // A CLI process has no app sandbox. Give only its cache root a private test
      // directory; all download/commit/prune logic is the production source.
      const isolated = media.replace(/static var root: URL \{[\s\S]*?\n    \}/, 'static var root: URL { CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hq-download-probe-media") }')
      await Bun.write(source, `import Foundation\nimport CryptoKit\nimport Network\nstruct CraftNativeActionError: Error { let code: String;
  let message: String }\n${ownership}\n${isolated}\n${await Bun.file(join(fixtures, 'media-cache.swift.fixture')).text()}`)
      const iosSDK = (await run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])).trim()
      const executable = join(scratch, 'CraftMediaProbe')
      const architecture = process.arch === 'arm64' ? 'arm64' : 'x86_64'
      await run(['xcrun', 'swiftc', '-sdk', iosSDK, '-target', `${architecture}-apple-ios17.0-simulator`, source, '-o', executable])
      await run(['codesign', '--force', '--sign', '-', executable])
      simulator = options.device || ''
      if (!simulator) {
        const runtimes = JSON.parse(await run(['xcrun', 'simctl', 'list', 'runtimes', '-j'])).runtimes
        const runtime = runtimes.filter((r: any) => r.isAvailable && /^com\.apple\.CoreSimulator\.SimRuntime\.iOS-/.test(r.identifier)).sort((a: any, b: any) => b.version.localeCompare(a.version, undefined, { numeric: true }))[0]
        if (!runtime) throw new Error('Install an available iOS simulator runtime')
        simulator = (await run(['xcrun', 'simctl', 'create', 'Craft Media Cache QA', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16', runtime.identifier])).trim()
        ownsSimulator = true
        await run(['xcrun', 'simctl', 'boot', simulator])
        await run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'])
      }
      const base = `http://127.0.0.1:${server.port}/ios`
      const mediaRoot = join(scratch, 'media')
      const image = join(scratch, 'cache-pressure.sparseimage')
      const volume = join(scratch, 'cache-volume')
      await mkdir(volume)
      await run(['hdiutil', 'create', '-size', '16m', '-fs', 'HFS+', '-volname', 'HQCachePressure', '-type', 'SPARSE', image])
      await run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', volume, image])
      mountedVolume = volume
      print(await run(['xcrun', 'simctl', 'spawn', simulator, executable, base, 'storage', join(volume, 'craft-media')]))
      await run(['hdiutil', 'detach', mountedVolume])
      mountedVolume = ''
      print('PASS: iOS native ENOSPC, cache cleanup, progress preservation and video redownload')
      if (!storageOnly) {
        print(await run(['xcrun', 'simctl', 'spawn', simulator, executable, base, 'normal', mediaRoot]))
        for (const phase of ['retire', 'retired-recover']) print(await run(['xcrun', 'simctl', 'spawn', simulator, executable, base, phase, mediaRoot]))
        const interrupted = await run(['xcrun', 'simctl', 'spawn', simulator, executable, base, 'interrupt', mediaRoot], scratch, true)
        print(interrupted)
        if (!interrupted.includes('KILLING')) throw new Error('iOS probe did not reach process-death checkpoint')
        if (counts.get('/ios/restart.mp4') !== 1) throw new Error('iOS process did not start interrupted download')
        print(await run(['xcrun', 'simctl', 'spawn', simulator, executable, base, 'recover', mediaRoot]))
        if (counts.get('/ios/slow.mp4') !== 1) throw new Error('iOS duplicate fetch: keep did not coalesce')
        if (counts.get('/ios/account/slow.mp4') !== 2) throw new Error('iOS account switch did not start a fresh transfer')
        print('PASS: iOS simulator interruption, restart, retry, prune and cached video decode')
      }
    }
    if (options.platform === 'android') {
      serial = options.device || ''
      if (!/^emulator-\d+$/.test(serial)) throw new Error('Select a disposable Android emulator with ANDROID_SERIAL')
      const shell = await Bun.file(join(root, 'android/templates/CraftNativeShell.kt.template')).text()
      const media = androidMediaProbeSource(shell)
      const android = join(scratch, 'android')
      const app = join(android, 'app')
      const sources = join(app, 'src/main/java/dev/craft/mediaprobe')
      await mkdir(sources, { recursive: true })
      await Bun.write(join(android, 'settings.gradle.kts'), 'pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositories { google(); mavenCentral() } }\nrootProject.name = "HQDownloadProbe"\ninclude(":app")')
      await Bun.write(join(android, 'build.gradle.kts'), 'plugins { id("com.android.application") version "8.9.1" apply false; id("org.jetbrains.kotlin.android") version "2.0.21" apply false }')
      await Bun.write(join(android, 'local.properties'), `sdk.dir=${sdk}\n`)
      await Bun.write(join(android, 'gradle.properties'), 'android.useAndroidX=true\norg.gradle.jvmargs=-Xmx768m\norg.gradle.workers.max=2\n')
      await Bun.write(join(app, 'build.gradle.kts'), `plugins { id("com.android.application");
  id("org.jetbrains.kotlin.android") }\nandroid { namespace = "${packageName}";
  compileSdk = 36;
  defaultConfig { applicationId = "${packageName}";
  minSdk = 26;
  targetSdk = 35 };
  compileOptions { sourceCompatibility = JavaVersion.VERSION_17;
  targetCompatibility = JavaVersion.VERSION_17 };
  kotlinOptions { jvmTarget = "17" } }
dependencies { implementation("androidx.work:work-runtime-ktx:2.9.1") }`)
      await Bun.write(join(app, 'src/main/AndroidManifest.xml'), `<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.INTERNET"/><uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/><application android:usesCleartextTraffic="true" android:label="HQ Download Probe"/><instrumentation android:name=".DownloadProbe" android:targetPackage="${packageName}"/></manifest>`)
      await Bun.write(join(sources, 'DownloadProbe.kt'), `package ${packageName}\nimport android.content.Context\nimport android.content.SharedPreferences\nimport android.net.Uri\nimport android.os.Handler\nimport android.os.Looper\nimport org.json.JSONObject\nimport java.io.File\nimport java.util.concurrent.Executors\nimport java.util.concurrent.ConcurrentHashMap\ninternal data class CraftNativeCapabilityResult(val data: Any? = null, val code: String? = null, val message: String? = null)\n${media}\n${await Bun.file(join(fixtures, 'media-cache.kt')).text()}`)
      await run([options.gradle || process.env.GRADLE_EXECUTABLE || 'gradle', ...(options.online ? [] : ['--offline']), '--no-daemon', ':app:assembleDebug'], android)
      print(await run([adb, '-s', serial, 'install', '-r', join(app, 'build/outputs/apk/debug/app-debug.apk')]))
      const base = `http://10.0.2.2:${server.port}/android`
      const probe = async (phase: string, interrupted = false) => {
        const result = await run([adb, '-s', serial, 'shell', 'am', 'instrument', '-w', '-e', 'base', base, '-e', 'phase', phase, `${packageName}/.DownloadProbe`], scratch, interrupted)
        if (!interrupted && (!result.includes('PASS:') || result.includes('FAIL:'))) throw new Error(result)
        print(result)
      }
      await requireAndroidEmulatorRoot(adb, serial)
      await run([adb, '-s', serial, 'shell', 'run-as', packageName, 'mkdir', '-p', 'files/craft-media'])
      const cache = `/data/user/0/${packageName}/files/craft-media`
      const owner = (await run([adb, '-s', serial, 'shell', 'stat', '-c', '%u:%g', cache])).trim()
      const label = (await run([adb, '-s', serial, 'shell', 'ls', '-Zd', cache])).trim().split(/\s+/)[0]!
      if (!/^\d+:\d+$/.test(owner) || !/^u:object_r:app_data_file:s0(?::c\d+(?:,c\d+)*)?$/.test(label)) throw new Error('Unexpected probe cache ownership or SELinux label')
      const [uid, gid] = owner.split(':')
      // Bound only this probe's cache, preserving the stock app UID and SELinux label.
      await run([adb, '-s', serial, 'shell', 'mount', '-t', 'tmpfs', '-o', `size=16m,mode=700,uid=${uid},gid=${gid}`, 'tmpfs', cache])
      mountedAndroidCache = cache
      await run([adb, '-s', serial, 'shell', 'chcon', label, cache])
      await probe('storage')
      await run([adb, '-s', serial, 'shell', 'am', 'force-stop', packageName])
      await run([adb, '-s', serial, 'shell', 'umount', mountedAndroidCache])
      mountedAndroidCache = ''
      print('PASS: Android native ENOSPC, cache cleanup, progress preservation and video redownload')
      if (!storageOnly) {
        await probe('normal')
        await probe('retire')
        await run([adb, '-s', serial, 'shell', 'am', 'force-stop', packageName])
        await probe('retired-recover')
        await probe('interrupt', true)
        if (counts.get('/android/restart.mp4') !== 1) throw new Error('Android process did not start interrupted download')
        await probe('recover')
        if (counts.get('/android/retry.mp4') !== 2) throw new Error('Android explicit retry did not fetch once more immediately')
        if (counts.get('/android/settled.mp4') !== 1) throw new Error('Android explicit keep did not replace the settled running attempt exactly once')
        if (!resumed.has('/android/restart.mp4')) throw new Error('Android did not resume the interrupted download from its part file')
        if (counts.get('/android/slow.mp4') !== 1) throw new Error('Android duplicate fetch: keep did not coalesce')
        if (counts.get('/android/queued.mp4') !== 1) throw new Error('Android queued work was replaced instead of joined')
        if (counts.get('/android/locked/slow.mp4') !== 1) throw new Error('Android waiting writer fetched an already completed video')
        if (counts.get('/android/stale/slow.mp4') !== 1) throw new Error('Android obsolete worker fetched across a cache generation')
        if (counts.get('/android/inflight/slow.mp4') !== 2) throw new Error('Android in-flight generations did not retain exactly their own transfers')
        if (counts.get('/android/late-queued.mp4') !== 1) throw new Error('Android kept obsolete queued work across a cache generation')
        if (counts.get('/android/account/slow.mp4') !== 2) throw new Error('Android account switch did not start a fresh transfer')
        print('PASS: Android emulator interruption, resumed restart, retry, prune and cached video decode')
      }
    }
  }
  finally {
    print(JSON.stringify({ requests: Object.fromEntries(counts) }))
    if (mountedVolume) await run(['hdiutil', 'detach', mountedVolume])
    if (mountedAndroidCache) {
      await run([adb, '-s', serial, 'shell', 'am', 'force-stop', packageName], scratch, true)
      await run([adb, '-s', serial, 'shell', 'umount', mountedAndroidCache])
    }
    if (simulator && ownsSimulator) { await run(['xcrun', 'simctl', 'shutdown', simulator], scratch, true);
    await run(['xcrun', 'simctl', 'delete', simulator], scratch, true) }
    if (serial) await run([adb, '-s', serial, 'uninstall', packageName], scratch, true)
    for (const timer of timers) clearTimeout(timer)
    server.stop(true)
    await rm(scratch, { recursive: true, force: true })
  }
  return { platform: options.platform, requests: Object.fromEntries(counts) }
}
