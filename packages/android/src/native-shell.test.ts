import { readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import vm from 'node:vm'
import { afterAll, describe, expect, it } from 'bun:test'
import { build, healthConnectPermissions, init, renderAndroidPermissions } from './index'
import { createTempDir, removeAllTempDirs } from '../../typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const templates = join(import.meta.dir, '../templates')

/** The prelude every isolate runs (CraftNativeShell.kt's CraftNativePrelude), with its Kotlin holes filled. */
function prelude(stores: Record<string, Record<string, string>>, capabilities: string[] = [], fields = ''): string {
  const source = readFileSync(join(templates, 'CraftNativeShell.kt.template'), 'utf8')
  const start = source.indexOf('): String = """') + '): String = """'.length
  const end = source.indexOf('""".trimIndent()', start)
  return source.slice(start, end)
    .replace('$routePrelude', 'globalThis.__stxNativeRoute = "Today";')
    .replace('$STORES', JSON.stringify(stores))
    .replace('$bridgeFields', `platform: 'android', capabilityProtocolVersion: 1, capabilities: ${JSON.stringify(capabilities)}${fields}`)
    .replace('$post', 'globalThis.__posted.push(JSON.parse(value));')
    .replace('$receiveSetup', 'globalThis.__deliver = deliver;')
}

interface Isolate {
  posted: Array<{ type: string, payload: any }>
  heard: any[]
  context: Record<string, any>
  deliver: (message: unknown) => void
}

function isolate(stores: Record<string, Record<string, string>> = {}, capabilities: string[] = [], fields = ''): Isolate {
  const context: Record<string, any> = { __posted: [], console: { error() {}, log() {} } }
  vm.createContext(context)
  vm.runInContext(prelude({ storage: {}, secure: {}, snapshots: {}, ...stores }, capabilities, fields), context)
  const heard: any[] = []
  context.__stxNativeBridge.onMessage((raw: string) => heard.push(JSON.parse(raw)))
  return { posted: context.__posted, heard, context, deliver: message => context.__deliver(JSON.stringify(message)) }
}

describe('the native shell prelude (JavaScriptSandbox has no synchronous host calls)', () => {
  it('names browser URL globals that are intentionally unavailable on native screens', () => {
    const app = isolate()
    for (const expression of [
      'new URLSearchParams()',
      'new URL("/leaderboard")',
      'new TextEncoder()',
    ]) {
      expect(() => vm.runInContext(expression, app.context)).toThrow(/not available on a native screen/)
    }
    expect(() => vm.runInContext('new URLSearchParams()', app.context)).toThrow(/encodeURIComponent/)
  })

  it('reports every unsupported browser global with the same native-screen wording', () => {
    const app = isolate()
    for (const name of ['URL', 'URLSearchParams', 'TextEncoder']) {
      expect(() => vm.runInContext(`new ${name}()`, app.context)).toThrow(new RegExp(`${name} is not available on a native screen`))
    }
  })

  it('answers storage, snapshots and secure storage synchronously from the preloaded copies', () => {
    const app = isolate({
      storage: { units: '"metric"' },
      secure: { 'auth.token': 'token-1' },
      snapshots: { 'workout-42': '{"id":42}' },
    })
    expect(vm.runInContext('window === globalThis', app.context)).toBe(true)
    expect(app.context.craft.storage.getSync('units')).toBe('metric')
    expect(app.context.craft.secureStorage.getSync('auth.token')).toBe('token-1')
    expect(app.context.craft.secureStorage.getSync('missing')).toBeNull()
    expect(app.context.craft.snapshots.get('workout-42')).toEqual({ id: 42 })
  })

  it('keeps the synchronous getters when the runtime assigns its own namespace', () => {
    const app = isolate({ storage: { units: '"imperial"' } })
    const get = () => Promise.resolve('async')
    app.context.craft.storage = Object.assign({}, app.context.craft.storage, { get })
    expect(app.context.craft.storage.get).toBe(get)
    expect(app.context.craft.storage.getSync('units')).toBe('imperial')
  })

  it('writes through the host and resolves a snapshot once the host kept it', async () => {
    const app = isolate()
    const kept = app.context.craft.snapshots.set('today', { day: 'tue' })
    expect(app.context.craft.snapshots.get('today')).toEqual({ day: 'tue' })
    const write = app.posted.find(message => message.type === 'SYNC_WRITE')!
    expect(write.payload).toMatchObject({ store: 'snapshots', key: 'today', value: '{"day":"tue"}' })
    app.deliver({ type: 'SYNC_RESULT', payload: { id: write.payload.id, ok: true } })
    await kept
  })

  it('rejects a failed snapshot after restoring the confirmed value from the host', async () => {
    const app = isolate({ snapshots: { campaign: '{"tick":24}' } })
    const kept = app.context.craft.snapshots.set('campaign', { tick: 25 })
    const write = app.posted.find(message => message.type === 'SYNC_WRITE')!
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'snapshots', key: 'campaign', value: '{"tick":24}' } })
    app.deliver({ type: 'SYNC_RESULT', payload: { id: write.payload.id, ok: false } })
    await expect(kept).rejects.toThrow('craft.snapshots.set could not be written')
    expect(app.context.craft.snapshots.get('campaign')).toEqual({ tick: 24 })
  })

  it('rejects invalid checkpoint names and values before posting a write', async () => {
    const app = isolate()
    await expect(app.context.craft.snapshots.set('../escape', { tick: 1 })).rejects.toThrow(/Snapshot names are letters/)
    await expect(app.context.craft.snapshots.set('valid', undefined)).rejects.toThrow(/is not JSON/)
    expect(app.context.craft.snapshots.get('../escape')).toBeNull()
    expect(app.posted.filter(message => message.type === 'SYNC_WRITE')).toHaveLength(0)
  })

  it('follows another isolate\'s writes and tells the screen a snapshot changed', () => {
    const app = isolate({ snapshots: { header: '{"userId":1}' } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'snapshots', key: 'header', value: '{"userId":2}' } })
    expect(app.context.craft.snapshots.get('header')).toEqual({ userId: 2 })
    expect(app.heard).toContainEqual({ type: 'SNAPSHOT_CHANGED', payload: { name: 'header' } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'auth.token', value: null } })
    expect(app.context.craft.secureStorage.getSync('auth.token')).toBeNull()
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'snapshots', clear: true, keep: [] } })
    expect(app.context.craft.snapshots.get('header')).toBeNull()
  })

  it('reports each change of the sign-in token once, as SESSION_CHANGED and to craft.session', () => {
    const app = isolate({ secure: { 'auth.token': 'ava', 'other': 'x' } })
    const session = app.context.craft.session
    expect(session.key).toBe('auth.token')
    expect(session.token()).toBe('ava')
    const heard: unknown[] = []
    const stop = session.onChange((token: string | null, previous: string | null) => heard.push([token, previous, app.context.craft.secureStorage.getSync('auth.token')]))
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'other', value: 'y' } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'auth.token', value: 'ava' } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'auth.token', value: 'ben' } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', clear: true } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'auth.token', value: '' } })
    stop()
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'auth.token', value: 'cy' } })
    expect(heard).toEqual([['ben', 'ava', 'ben'], [null, 'ben', null]])
    expect(app.heard.filter(message => message.type === 'SESSION_CHANGED')).toEqual([
      { type: 'SESSION_CHANGED', payload: { key: 'auth.token', token: 'ben', previous: 'ava' } },
      { type: 'SESSION_CHANGED', payload: { key: 'auth.token', token: null, previous: 'ben' } },
      { type: 'SESSION_CHANGED', payload: { key: 'auth.token', token: 'cy', previous: null } },
    ])
  })

  it('follows the configured token key and keeps craft.session when the runtime assigns its own', () => {
    const app = isolate({ secure: { 'auth.token': 'ignored', 'hq.session': 'ava' } }, [], `, sessionTokenKey: 'hq.session'`)
    expect(app.context.craft.session.token()).toBe('ava')
    app.context.craft.session = { extra: true }
    expect(app.context.craft.session.extra).toBe(true)
    expect(app.context.craft.session.key).toBe('hq.session')
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'auth.token', value: 'other' } })
    app.deliver({ type: 'SYNC_UPDATE', payload: { store: 'secure', key: 'hq.session', value: 'ben' } })
    expect(app.heard.filter(message => message.type === 'SESSION_CHANGED').map(message => message.payload))
      .toEqual([{ key: 'hq.session', token: 'ben', previous: 'ava' }])
  })

  it('gives the isolate timers and frames from the host', () => {
    const app = isolate()
    const fired: string[] = []
    const once = app.context.setTimeout((word: string) => fired.push(word), 25, 'once')
    const cancelled = app.context.setTimeout(() => fired.push('never'), 10)
    app.context.clearTimeout(cancelled)
    expect(app.posted).toContainEqual({ type: 'TIMER', payload: { id: once, ms: 25 } })
    expect(app.posted).toContainEqual({ type: 'TIMER_CLEAR', payload: { id: cancelled } })
    app.deliver({ type: 'TIMER_FIRE', payload: { id: cancelled } })
    app.deliver({ type: 'TIMER_FIRE', payload: { id: once } })
    expect(fired).toEqual(['once'])

    const every = app.context.setInterval(() => fired.push('tick'), 100)
    app.deliver({ type: 'TIMER_FIRE', payload: { id: every } })
    expect(app.posted.filter(message => message.type === 'TIMER' && message.payload.id === every)).toHaveLength(2)

    const frames: number[] = []
    app.context.requestAnimationFrame((time: number) => frames.push(time))
    app.context.requestAnimationFrame((time: number) => frames.push(time + 1))
    expect(app.posted.filter(message => message.type === 'FRAME')).toHaveLength(1)
    app.deliver({ type: 'FRAME_FIRE', payload: { time: 16 } })
    expect(frames).toEqual([16, 17])
  })

  it('hands everything else to the runtime unchanged', () => {
    const app = isolate()
    app.deliver({ type: 'API_RESPONSE', payload: { requestId: '1', data: true } })
    expect(app.heard).toContainEqual({ type: 'API_RESPONSE', payload: { requestId: '1', data: true } })
  })

  it('routes legacy page-shaped dialogs through the native capability bridge', async () => {
    const app = isolate({}, ['dialog'])
    const sheet = app.context.craft.dialog.actionSheet({
      title: 'Remove photo?',
      actions: [{ id: 'remove', title: 'Remove', style: 'destructive' }],
    })
    const request = app.posted.find(message => message.type === 'API_REQUEST')!
    expect(request.payload).toMatchObject({
      module: 'Dialog',
      method: 'actionSheet',
      untimed: true,
      args: [{ title: 'Remove photo?', actions: [{ id: 'remove', title: 'Remove', style: 'destructive' }] }],
    })
    // The host's response id is the request's top-level id. Android's
    // prelude forwards the payload unchanged, so use that exact value.
    app.deliver({ type: 'API_RESPONSE', payload: { requestId: request.id, data: 'remove' } })
    expect(await sheet).toBe('remove')
  })
})

describe('the native app shell in a generated project', () => {
  it('declares one location permission when live health and Bluetooth both need it', () => {
    const permissions = renderAndroidPermissions({
      appName: 'Live health', packageName: 'dev.craft.livehealth', renderer: 'native',
      enableHealthServices: true, enableHeartRate: true,
    })
    expect(permissions.match(/android\.permission\.ACCESS_FINE_LOCATION/g)).toHaveLength(1)
    expect(permissions).toContain('<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />')
    expect(permissions).not.toContain('ACCESS_FINE_LOCATION" android:maxSdkVersion')
    const bluetooth = renderAndroidPermissions({
      appName: 'Bluetooth', packageName: 'dev.craft.bluetooth', renderer: 'native', enableHeartRate: true,
    })
    expect(bluetooth.match(/android\.permission\.ACCESS_FINE_LOCATION/g)).toHaveLength(1)
    expect(bluetooth).toContain('ACCESS_FINE_LOCATION" android:maxSdkVersion="30"')
  })

  it('declares only the Health Connect permissions the app reads and writes', () => {
    const permissions = healthConnectPermissions({ healthConnect: { read: ['sleep', 'workouts'], write: ['mindful'], background: true } })
    expect(permissions).toContain('android.permission.health.READ_SLEEP')
    expect(permissions).toContain('android.permission.health.READ_EXERCISE')
    expect(permissions).toContain('android.permission.health.WRITE_MINDFULNESS')
    expect(permissions).toContain('android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND')
    expect(permissions).not.toContain('android.permission.health.WRITE_EXERCISE')
    expect(permissions).not.toContain('android.permission.health.READ_STEPS')
    // Glucose is a read of its own; Health Connect has no insulin, so asking for it adds nothing.
    const diabetes = healthConnectPermissions({ healthConnect: { read: ['bloodGlucose', 'insulinDelivery', 'dietaryCarbohydrates'], write: [] } })
    expect(diabetes).toContain('android.permission.health.READ_BLOOD_GLUCOSE')
    expect(diabetes).toContain('android.permission.health.READ_NUTRITION')
    expect(diabetes.filter(p => p.includes('INSULIN'))).toEqual([])
    // Without a list, the original set.
    expect(healthConnectPermissions({})).toContain('android.permission.health.WRITE_EXERCISE')
    expect(() => healthConnectPermissions({ healthConnect: { read: ['oxygen' as never] } })).toThrow(/Unknown Health Connect type/)
    expect(renderAndroidPermissions({ appName: 'A', packageName: 'a.b', renderer: 'native', backgroundRefresh: { enabled: true } }))
      .toContain('android.permission.RECEIVE_BOOT_COMPLETED')
  })

  it('writes the shell, its services and Health Connect for a native app', async () => {
    const root = createTempDir('craft-android-shell-')
    try {
      const services = join(root, 'google-services.json')
      writeFileSync(services, JSON.stringify({ client: [{ client_info: { android_client_info: { package_name: 'dev.craft.shell' } } }] }))
      const output = join(root, 'app')
      await init({
        name: 'Shell',
        packageName: 'dev.craft.shell',
        output,
        runtimeDir: null,
        config: {
          renderer: 'native',
          enableHealthConnect: true,
          enableHealthServices: true,
          enablePushNotifications: true,
          googleServicesFile: services,
          healthConnect: { read: ['steps', 'mindful'], write: ['mindful'] },
          devServerURL: 'https://example.com/m',
          nativeScreens: { '/m': 'Today', '/m/workout/:id': 'Workout' },
          tabs: [{ id: '/m', title: 'Today', symbol: 'sun.max', selectedSymbol: 'sun.max.fill', selectedIconTint: '#ff3b30', selectedIconPulse: false }],
          nativeApp: '__app',
          backgroundRefresh: { enabled: true, minimumIntervalMinutes: 60 },
        },
      })
      const java = join(output, 'app/src/main/java/dev/craft/shell')
      for (const file of ['CraftNativeShell.kt', 'CraftSnapshotFile.kt', 'CraftNativeServices.kt', 'CraftNativeBackground.kt', 'CraftNativeHealth.kt', 'CraftNativeMessagingService.kt', 'CraftHealthServices.kt', 'CraftHealthServicesService.kt'])
        expect(existsSync(join(java, file))).toBe(true)
      expect(readFileSync(join(java, 'CraftNativeHealth.kt'), 'utf8')).toContain('HealthConnectClient')
      expect(readFileSync(join(java, 'CraftHealthServicesService.kt'), 'utf8')).toContain('HealthServices.getClient(this).exerciseClient')
      expect(readFileSync(join(java, 'CraftNativeServices.kt'), 'utf8')).toContain('FirebaseMessaging.getInstance().token')
      const shell = readFileSync(join(java, 'CraftNativeShell.kt'), 'utf8')
      expect(shell).toContain('override fun onInterceptTouchEvent(event: MotionEvent)')
      expect(shell).toContain('onTabSwipeStart?.invoke(dx, event.x, event.y)')
      expect(shell).toContain('tabSwipeEnabled = options.optBoolean("tabSwipeEnabled", true)')
      // Wi-Fi only: a kept video is not fetched on a metered connection, and says it is waiting.
      expect(readFileSync(join(java, 'CraftNativeServices.kt'), 'utf8')).toContain('optBoolean("cellular", true)')
      expect(shell).toContain('setRequiredNetworkType(if (wifiOnly) androidx.work.NetworkType.UNMETERED else androidx.work.NetworkType.CONNECTED)')
      expect(shell).toContain('wifiOnly && metered(app) -> "cellular"')
      expect(shell).toContain('.put("reason", reason).put("queued", true)')
      const manifest = readFileSync(join(output, 'app/src/main/AndroidManifest.xml'), 'utf8')
      expect(manifest).toContain('android.permission.health.WRITE_MINDFULNESS')
      expect(manifest).not.toContain('android.permission.health.WRITE_EXERCISE')
      expect(manifest).toContain('.CraftNativeMessagingService')
      expect(manifest).toContain('android:authorities="dev.craft.shell.craftfiles"')
      expect(manifest).toContain('android.permission.START_VIEW_PERMISSION_USAGE')
      const gradle = readFileSync(join(output, 'app/build.gradle.kts'), 'utf8')
      expect(gradle).toContain('androidx.browser:browser')
      expect(gradle).toContain('androidx.work:work-runtime-ktx')
      // Release signing (the Play upload key) comes from the environment.
      expect(gradle).toContain('System.getenv("CRAFT_ANDROID_KEYSTORE")')
      expect(gradle).toContain('signingConfig = signingConfigs.getByName("release")')
      const config = JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft.config.json'), 'utf8'))
      expect(config.nativeScreens['/m/workout/:id']).toBe('Workout')
      expect(config.tabs[0]).toEqual({ id: '/m', title: 'Today', symbol: 'sun.max', selectedSymbol: 'sun.max.fill', selectedIconTint: '#ff3b30', selectedIconPulse: false })

      // The app's icons go in as an asset the shell draws.
      const iconTable = join(root, 'icons.json')
      writeFileSync(iconTable, JSON.stringify({ viewBox: 24, strokeWidth: 2, icons: { 'sun.max': '<circle cx="12" cy="12" r="4"/>' } }))
      const bundlePath = join(root, 'screen.js')
      writeFileSync(bundlePath, 'globalThis.__stxNativeRoute = "Today";')
      await build({ output, nativeBundlePath: bundlePath, iconsPath: iconTable, compile: false, runtimeDir: null })
      expect(JSON.parse(readFileSync(join(output, 'app/src/main/assets/craft-icons.json'), 'utf8')).icons['sun.max']).toContain('circle')

      // Without Health Connect or push, the stub compiles in their place.
      const plain = join(root, 'plain')
      await init({ name: 'Plain', packageName: 'dev.craft.plain', output: plain, runtimeDir: null, config: { renderer: 'native' } })
      const plainJava = join(plain, 'app/src/main/java/dev/craft/plain')
      expect(readFileSync(join(plainJava, 'CraftNativeHealth.kt'), 'utf8')).toContain('CAPABILITY_DISABLED')
      expect(readFileSync(join(plainJava, 'CraftHealthServices.kt'), 'utf8')).toContain('CAPABILITY_DISABLED')
      expect(existsSync(join(plainJava, 'CraftNativeMessagingService.kt'))).toBe(false)
      expect(readFileSync(join(plainJava, 'CraftNativeServices.kt'), 'utf8')).toContain('Push notifications are disabled')
    }
    finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
