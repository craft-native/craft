/** Exercise the shipped Linux or Windows binary's page-to-native multi-window bridge. */
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { platform } from 'node:os'

const binary = process.argv[2]
if (!binary) throw new Error('usage: bun scripts/verify-desktop-multi-window.ts <craft-binary>')
const isWindows = platform() === 'win32'
const platformName = isWindows ? 'Windows' : 'Linux'

const mainPage = `<!doctype html><script>
(async () => {
  const isWindows = ${isWindows}
  const report = (step) => fetch('/report?step=' + encodeURIComponent(step), { method: 'POST' })
  const waitFor = async (step) => {
    for (let attempt = 0; attempt < 200; attempt++) {
      const status = await (await fetch('/status')).json()
      if (status.steps.includes(step)) return
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    throw new Error('timed out waiting for ' + step)
  }
  const child = (cycle) => window.craft.window.open({
    name: 'settings', title: 'Child ' + cycle,
    url: location.origin + '/child?cycle=' + cycle,
    minWidth: 300, maxWidth: 1200,
  })
  const call = (action, data = {}, id = 'settings') => window.craft.window._call(action, data, id)
  const waitSize = async (predicate, label) => {
    for (let attempt = 0; attempt < 40; attempt++) {
      const size = await call('getSize')
      if (predicate(size)) return size
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    throw new Error(label + ': child size never reached expected bounds')
  }
  const waitWindowEvent = (name) => new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(name + ' event missing')), 10000)
    window.addEventListener('craft:window:' + name, (event) => {
      if (event.detail.windowId !== 'settings') return
      clearTimeout(timeout)
      resolve()
    }, { once: true })
  })
  const checkRacedEvaluation = async (pending, label) => {
    let timer
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(label + ' evaluation never settled')), 10000)
    })
    try {
      const outcome = await Promise.race([
        pending.then(value => ({ value }), error => ({ error })),
        timeout,
      ])
      // Evaluation may win the race. If navigation/close wins, it must reject
      // the surviving creator page, never leave its promise stranded.
      if (outcome.error) {
        if (outcome.error.code !== 'CANCELLED') throw new Error(label + ' rejected with ' + outcome.error.code)
      }
      else if (outcome.value !== 42) throw new Error(label + ' returned a stale result')
    }
    finally { clearTimeout(timer) }
  }
  try {
    if (!window.craft || !window.craft.window || !window.craft.window.open)
      throw new Error('document-start Craft bridge missing')
    await report('main')
    const first = await child(1)
    if (first.name !== 'settings') throw new Error('wrong child handle')
    await waitFor('child-1')
    const bounds = await window.craft.window._call('getBounds', {}, 'settings')
    if (!(bounds.width > 0 && bounds.height > 0)) throw new Error('child bounds not routed to creator')
    await call('setSize', { width: 100, height: 100 })
    await waitSize(size => size.width >= 280, 'one-axis creation limits')
    await window.craft.window._call('setSize', { width: 640, height: 480 }, 'settings')
    let resized = false
    for (let attempt = 0; attempt < 40; attempt++) {
      const size = await window.craft.window._call('getSize', {}, 'settings')
      if (Math.abs(size.width - 640) <= 40 && Math.abs(size.height - 480) <= 40) {
        resized = true
        break
      }
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    if (!resized) throw new Error('live child resize did not change its size')
    const title = await window.craft.window._call('getTitle', {}, 'settings')
    if (title !== 'Child 1') throw new Error('child title not routed to creator: ' + title)
    const [childTitle, answer, localTitle] = await Promise.all([
      call('executeJavaScript', { code: 'document.title' }),
      call('executeJavaScript', { code: '21 * 2' }),
      call('executeJavaScript', { code: 'document.title' }, 'main'),
    ])
    if (childTitle !== 'Child 1' || answer !== 42 || localTitle === 'Child 1')
      throw new Error('concurrent evaluations answered the wrong requesting page')
    const object = await call('executeJavaScript', { code: '({ nested: [true, "child"] })' })
    if (object?.nested?.[0] !== true || object.nested[1] !== 'child')
      throw new Error('child evaluation lost its JSON result')
    const undefinedResult = await call('executeJavaScript', { code: 'undefined' })
    if (undefinedResult !== null)
      throw new Error('undefined evaluation did not resolve as null: ' + JSON.stringify(undefinedResult))
    let rejected = false
    try { await call('executeJavaScript', { code: 'throw new Error("evaluation failed")' }) }
    catch (error) { rejected = error?.code === 'NATIVE_CALL_FAILED' }
    if (!rejected) throw new Error('a JavaScript exception did not reject the requesting page')

    const mainBefore = await call('getBounds', {}, 'main')
    await call('setBounds', { x: bounds.x + 20, y: bounds.y + 15, width: 700, height: 500 })
    await waitSize(size => Math.abs(size.width - 700) <= 40 && Math.abs(size.height - 500) <= 40, 'setBounds')
    const moved = await call('getBounds')
    if (isWindows && (Math.abs(moved.x - bounds.x - 20) > 16 || Math.abs(moved.y - bounds.y - 15) > 16))
      throw new Error('setBounds did not move the addressed Windows child')
    await call('center')
    const centered = await call('getBounds')
    if (!Number.isFinite(centered.x) || !Number.isFinite(centered.y))
      throw new Error('center returned invalid child coordinates')
    await call('setResizable', { resizable: false })
    if (await call('isResizable') !== false) throw new Error('child stayed resizable')
    await call('setResizable', { resizable: true })
    if (await call('isResizable') !== true) throw new Error('child stayed fixed-size')
    await call('setMinimumSize', { width: 600, height: 420 })
    await call('setMaximumSize', { width: 820, height: 620 })
    await call('setSize', { width: 300, height: 200 })
    await waitSize(size => size.width >= 580 && size.height >= 400, 'minimum size')
    await call('setSize', { width: 1000, height: 800 })
    await waitSize(size => size.width <= 860 && size.height <= 660, 'maximum size')
    await call('setMinimumSize', { width: 1, height: 1 })
    await call('setMaximumSize', { width: 4096, height: 4096 })
    await call('setSize', { width: 700, height: 500 })
    await waitSize(size => Math.abs(size.width - 700) <= 40 && Math.abs(size.height - 500) <= 40, 'restored size')
    if (isWindows) {
      const entered = waitWindowEvent('enter-fullscreen')
      await call('setFullscreen', { fullscreen: true })
      await entered
      const left = waitWindowEvent('leave-fullscreen')
      await call('toggleFullscreen')
      await left
    }
    else {
      // A bare Xvfb server has no window manager to honor fullscreen requests.
      await call('setFullscreen', { fullscreen: true })
      await call('toggleFullscreen')
      await call('setFullscreen', { fullscreen: false })
    }
    const mainAfter = await call('getBounds', {}, 'main')
    if (Math.abs(mainAfter.width - mainBefore.width) > 40 || Math.abs(mainAfter.height - mainBefore.height) > 40)
      throw new Error('child controls changed the main window size')
    await report('controls')

    const navigatingEvaluation = call('executeJavaScript', {
      code: '(() => { const until = Date.now() + 250; while (Date.now() < until) {} return 42 })()',
    })
    await call('loadURL', { url: location.origin + '/child?cycle=1&reload=1' })
    await waitFor('child-1-reloaded')
    await checkRacedEvaluation(navigatingEvaluation, 'navigation')
    if (await call('executeJavaScript', { code: 'document.title' }) !== 'Child 1')
      throw new Error('new child page did not answer after navigation')

    const [queuedA, queuedB] = await Promise.all([
      window.craft.window.open({ name: 'queue-a', title: 'Child queue-a', url: location.origin + '/child?cycle=queue-a' }),
      window.craft.window.open({ name: 'queue-b', title: 'Child queue-b', url: location.origin + '/child?cycle=queue-b' }),
    ])
    if (queuedA.name !== 'queue-a' || queuedB.name !== 'queue-b')
      throw new Error('concurrent child opens returned the wrong handles')
    await waitFor('child-queue-a')
    await waitFor('child-queue-b')
    const queueClosed = new Set()
    const queueClosedDone = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('queued child close events missing')), 20000)
      window.addEventListener('craft:window:close', (event) => {
        if (event.detail.windowId !== 'queue-a' && event.detail.windowId !== 'queue-b') return
        queueClosed.add(event.detail.windowId)
        if (queueClosed.size !== 2) return
        clearTimeout(timeout)
        resolve()
      })
    })
    await window.craft.window._call('close', {}, 'queue-a')
    await window.craft.window._call('close', {}, 'queue-b')
    await queueClosedDone
    for (const name of ['queue-a', 'queue-b']) {
      let rejected = false
      try { await window.craft.window._call('getBounds', {}, name) }
      catch (_) { rejected = true }
      if (!rejected) throw new Error('closed queued child still answered a read: ' + name)
    }
    await report('queued-closed')

    const closed = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('child close event missing')), 20000)
      window.addEventListener('craft:window:close', (event) => {
        if (event.detail.windowId !== 'settings') return
        clearTimeout(timeout)
        resolve()
      })
    })
    const closingEvaluation = call('executeJavaScript', {
      code: '(() => { const until = Date.now() + 250; while (Date.now() < until) {} return 42 })()',
    })
    await window.craft.window._call('close', {}, 'settings')
    await closed
    await checkRacedEvaluation(closingEvaluation, 'close')
    await report('closed')
    const survivingMain = await window.craft.window._call('getBounds', {}, 'main')
    if (!(survivingMain.width > 0 && survivingMain.height > 0))
      throw new Error('closing child invalidated main controller')
    let staleRejected = false
    try { await window.craft.window._call('getBounds', {}, 'settings') }
    catch (_) { staleRejected = true }
    if (!staleRejected) throw new Error('destroyed child still answered a read')

    const second = await child(2)
    if (second.name !== 'settings') throw new Error('reopened child has wrong handle')
    await waitFor('child-2')
    const reopenedTitle = await window.craft.window._call('getTitle', {}, 'settings')
    if (reopenedTitle !== 'Child 2') throw new Error('reopened child retained stale title')
    await report('done')
  }
  catch (error) {
    await fetch('/report?error=' + encodeURIComponent(String(error)), { method: 'POST' })
  }
})()
</script>`

const childPage = `<!doctype html><script>
(async () => {
  try {
    const cycle = new URLSearchParams(location.search).get('cycle')
    const reloaded = new URLSearchParams(location.search).has('reload')
    const expectedTitle = ['Child', cycle].join(' ')
    document.title = expectedTitle
    const bounds = await window.craft.window._call('getBounds', {}, 'main')
    const title = await window.craft.window._call('getTitle', {}, 'main')
    if (!(bounds.width > 0 && bounds.height > 0) || title !== expectedTitle)
      throw new Error('child page read targeted another webview')
    const ownTitle = await window.craft.window._call('executeJavaScript', { code: 'document.title' }, 'main')
    if (ownTitle !== expectedTitle)
      throw new Error('child evaluation reply escaped to its creator page')
    await fetch('/report?step=child-' + cycle + (reloaded ? '-reloaded' : ''), { method: 'POST' })
  }
  catch (error) {
    await fetch('/report?error=' + encodeURIComponent(String(error)), { method: 'POST' })
  }
})()
</script>`

const steps = new Set<string>()
const requests: string[] = []
let resolveDone!: () => void
let rejectDone!: (error: Error) => void
const done = new Promise<void>((resolve, reject) => {
  resolveDone = resolve
  rejectDone = reject
})
const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1')
  requests.push(url.pathname)
  if (url.pathname === '/main' || url.pathname === '/child') {
    response.setHeader('content-type', 'text/html; charset=utf-8')
    response.end(url.pathname === '/main' ? mainPage : childPage)
  }
  else if (url.pathname === '/status') {
    response.setHeader('content-type', 'application/json')
    response.end(JSON.stringify({ steps: [...steps] }))
  }
  else if (url.pathname === '/report') {
    const error = url.searchParams.get('error')
    const step = url.searchParams.get('step')
    if (error) rejectDone(new Error(error))
    if (step) steps.add(step)
    response.end('ok')
    if (step === 'done') {
      const required = ['main', 'child-1', 'controls', 'child-1-reloaded', 'child-queue-a', 'child-queue-b', 'queued-closed', 'closed', 'child-2', 'done']
      if (required.every(name => steps.has(name))) resolveDone()
      else rejectDone(new Error(`incomplete smoke steps: ${[...steps].join(', ')}`))
    }
  }
  else {
    response.writeHead(404).end()
  }
})

await new Promise<void>((resolve, reject) => {
  server.once('error', reject)
  server.listen(0, '127.0.0.1', resolve)
})
const port = (server.address() as AddressInfo).port
const startedAt = Date.now()
const child = spawn(isWindows ? binary : 'timeout', isWindows
  ? ['--url', `http://127.0.0.1:${port}/main`]
  : ['110s', 'xvfb-run', '-a', binary, '--url', `http://127.0.0.1:${port}/main`], {
  detached: !isWindows,
  stdio: ['ignore', 'pipe', 'pipe'],
})
let output = ''
for (const stream of [child.stdout, child.stderr]) {
  stream.on('data', chunk => { output = (output + chunk.toString()).slice(-16_000) })
}
child.once('error', error => rejectDone(error))
child.once('exit', (code, signal) => rejectDone(new Error(`Craft exited before smoke completed (${code ?? signal}, ${Date.now() - startedAt} ms)`)))
const timer = setTimeout(() => rejectDone(new Error(`${platformName} multi-window smoke timed out`)), 100_000)

try {
  await done
  console.log(`${platformName} multi-window smoke passed: ${[...steps].join(', ')}`)
}
catch (error) {
  throw new Error(`${String(error)}\nElapsed: ${Date.now() - startedAt} ms\nHTTP requests: ${requests.join(', ')}\nCraft output:\n${output}`)
}
finally {
  clearTimeout(timer)
  if (child.pid) {
    try {
      if (isWindows) child.kill()
      else process.kill(-child.pid, 'SIGTERM')
    }
    catch { /* The process group may have already exited. */ }
  }
  await new Promise<void>(resolve => server.close(() => resolve()))
}
