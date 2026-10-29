import assert from 'node:assert/strict'
import { test } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { macOSRuntimeExecutablePath, packageApp } from '../package'

const dragTest = process.platform === 'darwin'
  && process.env.CRAFT_NATIVE_TEST_BIN && process.env.CRAFT_MENUBAR_DRAG_E2E === '1' ? test : test.skip

interface GroupState {
  initialized: boolean
  collapsed: boolean
  busy: boolean
  markerWidth: number
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
}

dragTest('Command-drag preserves the visible boundary and hides only its left side', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'craft-menubar-drag-'))
  const bundleId = `org.craft-native.menubar-drag.p${process.pid}.t${Date.now()}`
  const input = join(dir, 'menubar-input')
  let state: GroupState | undefined
  let nativeError = ''
  let child: ReturnType<typeof Bun.spawn> | undefined
  let stderr: Promise<string> | undefined
  let passed = false
  async function run(args: string[]): Promise<string> {
    const process = Bun.spawn(args, { stdout: 'pipe', stderr: 'pipe' })
    const [output, errors, code] = await Promise.all([
      new Response(process.stdout).text(), new Response(process.stderr).text(), process.exited,
    ])
    assert.equal(code, 0, `${args[0]} failed: ${errors || output}`)
    return output
  }
  async function control(selector = 'arrow'): Promise<Control> {
    return JSON.parse(await run([input, 'inspect', String(child!.pid), selector]))
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
  async function click(collapsed: boolean) {
    await run([input, 'click', String(child!.pid), 'arrow'])
    await until(() => state?.collapsed === collapsed && !state.busy, `native click must ${collapsed ? 'collapse' : 'reveal'} the group`)
    assert.equal(state?.markerWidth, 20)
    const arrow = await control()
    assert.equal(arrow.description, collapsed ? 'Show menu bar items' : 'Hide menu bar items')
    assert.equal((await hit(arrow)).pid, child!.pid, 'the control must remain in the visible native bar')
  }
  const script = `(async () => {
    await craft.tray.setTitle('TEST');
    await craft.tray.setTooltip('Craft grouping boundary target');
    await craft.menubar.init({backend:'legacy'});
    for (;;) await fetch('/state',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
  })().catch(error => fetch('/error',{method:'POST',body:String(error)}));`
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === '/state') {
      state = await request.json() as GroupState
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
    await run(['clang', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'ApplicationServices', join(import.meta.dir, 'fixtures/menubar-input.m'), '-o', input])
    await run([input, 'permissions'])
    const result = await packageApp({
      name: 'MenubarDrag', version: '1.0.0', bundleId, binaryPath: '/usr/bin/true', outDir: dir, platforms: ['macos'],
      macos: { nativeRuntimePath: process.env.CRAFT_NATIVE_TEST_BIN!, dmg: false, signIdentity: '-' },
    })
    assert.equal(result[0].success, true, result[0].error)
    const launched = Bun.spawn([macOSRuntimeExecutablePath(result[0].outputPath!), '--headless', '--system-tray', '--log-level', 'debug', '--url', server.url.toString()], {
      env: { ...process.env, __CFBundleIdentifier: `${bundleId}.runtime` }, stdout: 'ignore', stderr: 'pipe',
    })
    child = launched
    stderr = new Response(launched.stderr).text()
    await until(() => state?.initialized === true && !state.busy, 'the packaged native group must initialize')
    await click(true)
    await click(false)

    // Move the actual native control towards the notch with the test icon on
    // its right. Keeping every compact spacer visible used to overflow here.
    const target = await control('tray')
    const initialArrow = await control()
    await run([input, 'drag', String(child.pid), 'arrow', String(target.x - 24)])
    const leftArrow = await control()
    const rightTarget = await control('tray')
    assert(leftArrow.x < rightTarget.x, 'Command-drag must put the arrow to the left of the target')
    assert(Math.abs(leftArrow.x - initialArrow.x) > 20, 'the native item must actually move')
    await click(true)
    const stillRight = await control('tray')
    assert.equal(stillRight.x, rightTarget.x, 'items to the right must stay in place')
    assert.equal((await hit(rightTarget)).help, 'Craft grouping boundary target', 'the right-side target must stay visible')
    await Bun.sleep(400)
    assert.equal(state?.collapsed, true, 'the moved group must not restore itself')
    await click(false)

    // Put the same target to the left of the boundary, then verify it really
    // disappears from the bar and comes back at its original position.
    const revealedTarget = await control('tray')
    await run([input, 'drag', String(child.pid), 'arrow', String(revealedTarget.x + revealedTarget.width + 100)])
    const rightArrow = await control()
    const leftTarget = await control('tray')
    assert(rightArrow.x > leftTarget.x + leftTarget.width, 'the arrow must move to the other side of the target')
    assert.equal((await hit(leftTarget)).help, 'Craft grouping boundary target')
    await click(true)
    assert.notEqual((await hit(leftTarget)).help, 'Craft grouping boundary target', 'only the selected left-side target must disappear')
    await click(false)
    assert.equal((await hit(leftTarget)).help, 'Craft grouping boundary target', 'reveal must restore the target')

    for (let cycle = 0; cycle < 2; cycle++) {
      const start = Date.now()
      await click(true)
      assert(Date.now() - start < 2000, 'a validated layout must be reused without calibrating the spacers again')
      await click(false)
    }

    await click(true)
    const collapsedArrow = await control()
    await run([input, 'drag', String(child.pid), 'arrow', String(collapsedArrow.x + 60)])
    await until(() => state?.collapsed === false && !state.busy, 'dropping a reordered collapsed control must reveal the group')
    const reorderedArrow = await control()
    assert(Math.abs(reorderedArrow.x - collapsedArrow.x) > 10, 'a collapsed arrow must also be movable')
    assert.equal((await hit(reorderedArrow)).pid, child.pid)
    await click(true)
    await click(false)
    passed = true
  }
  finally {
    if (child && child.exitCode === null) {
      child.kill('SIGTERM')
      await Promise.race([child.exited, Bun.sleep(500)])
      if (child.exitCode === null) child.kill('SIGKILL')
      await child.exited
    }
    if (stderr) {
      const output = await stderr
      if (!passed && output) console.error(output)
    }
    server.stop(true)
    await rm(dir, { recursive: true, force: true })
    Bun.spawnSync(['/usr/bin/defaults', 'delete', `${bundleId}.runtime`], { stdout: 'ignore', stderr: 'ignore' })
  }
}, 90000)
