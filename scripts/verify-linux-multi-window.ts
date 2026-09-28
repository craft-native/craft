/** Exercise the shipped Linux binary's page-to-native multi-window bridge. */
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'

const binary = process.argv[2]
if (!binary) throw new Error('usage: bun scripts/verify-linux-multi-window.ts <craft-binary>')

const mainPage = `<!doctype html><script>
(async () => {
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
  })
  try {
    if (!window.craft || !window.craft.window || !window.craft.window.open)
      throw new Error('document-start Craft bridge missing')
    await report('main')
    const first = await child(1)
    if (first.name !== 'settings') throw new Error('wrong child handle')
    await waitFor('child-1')
    const bounds = await window.craft.window._call('getBounds', {}, 'settings')
    if (!(bounds.width > 0 && bounds.height > 0)) throw new Error('child bounds not routed to creator')
    const title = await window.craft.window._call('getTitle', {}, 'settings')
    if (title !== 'Child 1') throw new Error('child title not routed to creator: ' + title)

    const closed = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('child close event missing')), 20000)
      window.addEventListener('craft:window:close', (event) => {
        if (event.detail.windowId !== 'settings') return
        clearTimeout(timeout)
        resolve()
      })
    })
    await window.craft.window._call('close', {}, 'settings')
    await closed
    await report('closed')
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
    const bounds = await window.craft.window._call('getBounds', {}, 'main')
    const title = await window.craft.window._call('getTitle', {}, 'main')
    if (!(bounds.width > 0 && bounds.height > 0) || title !== 'Child ' + cycle)
      throw new Error('child page read targeted another webview')
    await fetch('/report?step=child-' + cycle, { method: 'POST' })
  }
  catch (error) {
    await fetch('/report?error=' + encodeURIComponent(String(error)), { method: 'POST' })
  }
})()
</script>`

const steps = new Set<string>()
let resolveDone!: () => void
let rejectDone!: (error: Error) => void
const done = new Promise<void>((resolve, reject) => {
  resolveDone = resolve
  rejectDone = reject
})
const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1')
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
      const required = ['main', 'child-1', 'closed', 'child-2', 'done']
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
const child = spawn('timeout', ['110s', 'xvfb-run', '-a', binary, '--url', `http://127.0.0.1:${port}/main`], {
  detached: true,
  stdio: ['ignore', 'pipe', 'pipe'],
})
let output = ''
for (const stream of [child.stdout, child.stderr]) {
  stream.on('data', chunk => { output = (output + chunk.toString()).slice(-16_000) })
}
child.once('error', error => rejectDone(error))
child.once('exit', (code, signal) => rejectDone(new Error(`Craft exited before smoke completed (${code ?? signal})`)))
const timer = setTimeout(() => rejectDone(new Error('Linux multi-window smoke timed out')), 100_000)

try {
  await done
  console.log(`Linux multi-window smoke passed: ${[...steps].join(', ')}`)
}
catch (error) {
  throw new Error(`${String(error)}\nCraft output:\n${output}`)
}
finally {
  clearTimeout(timer)
  if (child.pid) {
    try { process.kill(-child.pid, 'SIGTERM') }
    catch { /* The process group may have already exited. */ }
  }
  await new Promise<void>(resolve => server.close(() => resolve()))
}
