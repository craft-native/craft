import assert from 'node:assert/strict'
import { test } from 'bun:test'
import { mkdtemp, readFile, rename, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { macOSRuntimeExecutablePath, packageApp } from '../package'

const dragTest = process.platform === 'darwin'
  && process.env.CRAFT_NATIVE_TEST_BIN && process.env.CRAFT_MENUBAR_DRAG_E2E === '1' ? test : test.skip

interface GroupState {
  initialized: boolean
  collapsed: boolean
  busy: boolean
  markerWidth: number
  layoutPosition?: number
  layoutAuthorized?: boolean
}

interface Control {
  pid: number
  title: string
  description: string
  help: string
  x: number
  y: number
  width: number
  height: number
  inputReleasedAt?: number
}

interface TransitionFrame {
  ms: number
  arrowVisible: boolean
  arrowX: number
  arrowWidth: number
  trayX: number
  trayVisible: boolean
}

dragTest('Command-drag preserves the visible boundary and hides only its left side', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'craft-menubar-drag-'))
  const bundleId = `org.craft-native.menubar-drag.p${process.pid}.t${Date.now()}`
  const input = join(dir, 'menubar-input')
  let state: GroupState | undefined
  let nativeError = ''
  let child: ReturnType<typeof Bun.spawn> | undefined
  let nativePid: number | undefined
  const nativeLog = join(dir, 'native.log')
  let passed = false
  let clickSequence = 0
  let collapseSettledAt: number | undefined
  const cachedDurations: number[] = []
  const controls = new Map<string, Control>()
  async function run(args: string[]): Promise<string> {
    const process = Bun.spawn(args, { stdout: 'pipe', stderr: 'pipe' })
    const [output, errors, code] = await Promise.all([
      new Response(process.stdout).text(), new Response(process.stderr).text(), process.exited,
    ])
    assert.equal(code, 0, `${args[0]} failed: ${errors || output}`)
    return output
  }
  async function ownedInput(operation: string, selector = 'arrow', extra: string[] = []): Promise<string> {
    const known = controls.get(selector)
    const hint = known ? [String(known.x + known.width / 2), String(known.y + known.height / 2)] : []
    const output = await run([input, operation, String(nativePid!), selector, ...extra, ...hint])
    if (operation !== 'trace-click') controls.set(selector, JSON.parse(output) as Control)
    return output
  }
  async function control(selector = 'arrow'): Promise<Control> {
    return JSON.parse(await ownedInput('inspect', selector))
  }
  async function drag(targetX: number) {
    await control()
    await ownedInput('drag', 'arrow', [String(targetX)])
  }
  async function hit(target: Control): Promise<Control> {
    return JSON.parse(await run([input, 'hit', String(target.x + target.width / 2), String(target.y + target.height / 2)]))
  }
  async function until(predicate: () => boolean, message: string, timeout = 12000) {
    const deadline = Date.now() + timeout
    while (!predicate() && !nativeError && Date.now() < deadline) await Bun.sleep(40)
    assert(!nativeError, nativeError)
    assert(predicate(), `${message}: ${JSON.stringify(state)}`)
  }
  async function click(collapsed: boolean, trace = false) {
    await control()
    if (trace && process.env.CRAFT_MENUBAR_TRACE_PATH)
      await Bun.write(`${process.env.CRAFT_MENUBAR_TRACE_PATH}-${clickSequence}-before.json`, JSON.stringify({ state, arrow: controls.get('arrow'), tray: controls.get('tray') }))
    const target = controls.get('tray')
    const trayHint = target ? [String(target.x + target.width / 2), String(target.y + target.height / 2)] : []
    const frames: TransitionFrame[] = trace
      ? JSON.parse(await ownedInput('trace-click', 'arrow', ['2400', ...trayHint]))
      : []
    const clicked: Control | undefined = trace ? undefined : JSON.parse(await ownedInput('click'))
    if (trace && process.env.CRAFT_MENUBAR_TRACE_PATH)
      await Bun.write(`${process.env.CRAFT_MENUBAR_TRACE_PATH}-${clickSequence++}.json`, JSON.stringify(frames))
    if (trace) {
      assert(frames[0].trayVisible, 'the target must be physically visible at the transition baseline')
      assert(frames.every(frame => frame.arrowVisible), 'the reveal arrow must remain physically visible throughout the transition')
      const changes = frames.filter((frame, index) => index > 0 && frame.trayVisible !== frames[index - 1].trayVisible)
      assert(changes.length <= 1, `icons must transition once without repeatedly disappearing and returning: ${JSON.stringify(changes)}`)
      const excursion = Math.max(...frames.map(frame => Math.abs(frame.arrowX - frames[0].arrowX)))
      assert(excursion <= 1, `the arrow must stay fixed throughout the transition: ${excursion}pt`)
      if (collapsed && frames[0].trayX < frames[0].arrowX) {
        assert(!frames[frames.length - 1].trayVisible, 'left-side icons must be hidden by the end of the transition')
      }
      if (frames[0].trayX > frames[0].arrowX) {
        assert(frames.every(frame => frame.trayVisible && Math.abs(frame.trayX - frames[0].trayX) <= 1), 'right-side icons must remain visible and fixed throughout the transition')
      }
    }
    await until(() => state?.collapsed === collapsed && !state.busy, `native click must ${collapsed ? 'collapse' : 'reveal'} the group`)
    const nativeDuration = clicked?.inputReleasedAt && collapseSettledAt ? Math.max(0, collapseSettledAt - clicked.inputReleasedAt) : undefined
    assert.equal(state?.markerWidth, 20)
    const arrow = await control()
    assert.equal(arrow.description, collapsed ? 'Show menu bar items' : 'Hide menu bar items')
    assert.equal((await hit(arrow)).pid, nativePid!, 'the control must remain in the visible native bar')
    return nativeDuration
  }
  const script = `(async () => {
    await craft.tray.setTitle('TEST');
    await craft.tray.setTooltip('Craft grouping boundary target');
    await craft.menubar.init({backend:'legacy'});
    ${process.env.CRAFT_MENUBAR_LAYOUT_PERMISSION === '1' ? 'await craft.menubar.requestPermission();' : ''}
    for (;;) await fetch('/state',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
  })().catch(error => fetch('/error',{method:'POST',body:String(error)}));`
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === '/state') {
      const next = await request.json() as GroupState
      if (next.collapsed && !next.busy && (state?.collapsed !== true || state?.busy === true)) collapseSettledAt = Date.now()
      if (!next.collapsed) collapseSettledAt = undefined
      state = next
      // Network backpressure keeps the fixture independent of hidden WebKit timers.
      await Bun.sleep(60)
      return new Response('ok')
    }
    if (path === '/error') {
      nativeError = await request.text()
      return new Response('ok')
    }
    return new Response(`<script>${script}</script>`, { headers: { 'content-type': 'text/html' } })
  } })
  try {
    await run(['clang', '-mmacosx-version-min=15.0', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'ApplicationServices', join(import.meta.dir, 'fixtures/menubar-input.m'), '-o', input])
    await run([input, 'permissions'])
    const result = await packageApp({
      name: 'MenubarDrag', version: '1.0.0', bundleId, binaryPath: '/usr/bin/true', outDir: dir, platforms: ['macos'],
      macos: { nativeRuntimePath: process.env.CRAFT_NATIVE_TEST_BIN!, dmg: false, signIdentity: '-' },
    })
    assert.equal(result[0].success, true, result[0].error)
    // MenuBarAgent also keys status items by executable name on macOS 27.
    // Isolate that identity so fixtures cannot inherit a running Craft app's layout.
    const packagedRuntime = macOSRuntimeExecutablePath(result[0].outputPath!)
    const executableName = `mb${process.pid.toString(16)}${Date.now().toString(36)}`
    const runtime = join(dirname(packagedRuntime), executableName)
    await rename(packagedRuntime, runtime)
    await run(['/usr/libexec/PlistBuddy', '-c', `Set :CFBundleExecutable ${executableName}`, join(dirname(packagedRuntime), '../Info.plist')])
    await run(['codesign', '--force', '--deep', '--sign', '-', result[0].outputPath!])
    await run(['/usr/bin/defaults', 'write', `${bundleId}.runtime`, 'NSStatusItem Preferred Position barista_tray', '-float', '2'])
    // Launch the packaged helper through Launch Services, as installed apps run.
    child = Bun.spawn(['open', '-n', '-W', '--stdout', nativeLog, '--stderr', nativeLog, dirname(dirname(dirname(runtime))), '--args', '--headless', '--system-tray', '--log-level', 'debug', '--url', server.url.toString()], {
      stdout: 'ignore', stderr: 'ignore',
    })
    await until(() => state?.initialized === true && !state.busy && (process.env.CRAFT_MENUBAR_LAYOUT_PERMISSION !== '1' || state.layoutAuthorized === true), 'the packaged native group must initialize', process.env.CRAFT_MENUBAR_LAYOUT_PERMISSION === '1' ? 300000 : 12000)
    nativePid = Number(await run([input, 'app-pid', `${bundleId}.runtime`]))
    if (process.env.CRAFT_MENUBAR_LAYOUT_PERMISSION === '1') {
      const initialTarget = await control('tray')
      await drag(initialTarget.x - 24)
      const target = await control('tray')
      await drag(target.x + target.width + 8)
      await until(() => (state?.layoutPosition ?? -1) >= 0, 'the native layout must record the dragged boundary')
    }
    await click(true, true)
    await ownedInput('command-click')
    await Bun.sleep(500)
    assert.equal(state?.collapsed, true, 'a stationary Command-click must not reveal the collapsed group')
    assert.equal((await control()).description, 'Show menu bar items')
    await click(false)

    // Move the actual native control towards the notch with the test icon on
    // its right. Keeping every compact spacer visible used to overflow here.
    const target = await control('tray')
    const initialArrow = await control()
    await drag(target.x - 24)
    const leftArrow = await control()
    const rightTarget = await control('tray')
    assert(leftArrow.x < rightTarget.x, 'Command-drag must put the arrow to the left of the target')
    assert(Math.abs(leftArrow.x - initialArrow.x) > 20, 'the native item must actually move')
    await click(true, true)
    const stillRight = await control('tray')
    assert.equal(stillRight.x, rightTarget.x, 'items to the right must stay in place')
    assert.equal((await hit(rightTarget)).help, 'Craft grouping boundary target', 'the right-side target must stay visible')
    await Bun.sleep(400)
    assert.equal(state?.collapsed, true, 'the moved group must not restore itself')
    await click(false, true)

    // Put the same target to the left of the boundary, then verify it really
    // disappears from the bar and comes back at its original position.
    const revealedTarget = await control('tray')
    await drag(revealedTarget.x + revealedTarget.width + 8)
    const rightArrow = await control()
    const leftTarget = await control('tray')
    assert(rightArrow.x > leftTarget.x + leftTarget.width, 'the arrow must move to the other side of the target')
    assert.equal((await hit(leftTarget)).help, 'Craft grouping boundary target')
    await click(true, true)
    assert.notEqual((await hit(leftTarget)).help, 'Craft grouping boundary target', 'only the selected left-side target must disappear')
    await click(false)
    assert.equal((await hit(leftTarget)).help, 'Craft grouping boundary target', 'reveal must restore the target')

    for (let cycle = 0; cycle < 2; cycle++) {
      // Measure actual mouse release to the first settled native reply;
      // AX discovery and post-click hit testing are automation overhead.
      const duration = await click(true)
      assert(duration !== undefined && duration < 2000, `a validated native layout must settle within 2s: ${duration}ms`)
      cachedDurations.push(duration)
      await click(false)
    }

    const dragTarget = await control('tray')
    await drag(dragTarget.x - 24)
    await click(true)
    const collapsedArrow = await control()
    const visibleTarget = await control('tray')
    await drag(visibleTarget.x + visibleTarget.width + 8)
    await until(() => state?.collapsed === false && !state.busy, 'dropping a reordered collapsed control must reveal the group')
    const reorderedArrow = await control()
    assert(Math.abs(reorderedArrow.x - collapsedArrow.x) > 10, 'a collapsed arrow must also be movable')
    assert.equal((await hit(reorderedArrow)).pid, nativePid!)
    await click(true, true)
    await click(false)
    passed = true
  }
  finally {
    if (process.env.CRAFT_MENUBAR_TRACE_PATH)
      await Bun.write(`${process.env.CRAFT_MENUBAR_TRACE_PATH}-timing.json`, JSON.stringify({ cachedDurations }))
    if (!nativePid) {
      try { nativePid = Number(await run([input, 'app-pid', `${bundleId}.runtime`])) }
      catch {}
    }
    if (nativePid) {
      try { process.kill(nativePid, 'SIGTERM') }
      catch {}
    }
    if (child && child.exitCode === null) {
      child.kill('SIGTERM')
      await Promise.race([child.exited, Bun.sleep(500)])
      if (child.exitCode === null) child.kill('SIGKILL')
      await child.exited
    }
    if (!passed) {
      const output = await readFile(nativeLog, 'utf8').catch(() => '')
      if (output) console.error(output)
    }
    server.stop(true)
    await rm(dir, { recursive: true, force: true })
    Bun.spawnSync(['/usr/bin/defaults', 'delete', `${bundleId}.runtime`], { stdout: 'ignore', stderr: 'ignore' })
  }
}, 600000)
