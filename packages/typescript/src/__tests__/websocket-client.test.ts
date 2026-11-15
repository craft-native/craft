/**
 * WebSocketClient against a real local server (#552): payloads that are falsy
 * reach their handlers as themselves, `maxReconnectAttempts: 0` means no
 * retries, and an intentional disconnect() does not switch reconnection off for
 * the client's next connection.
 */
import type { Server, ServerWebSocket } from 'bun'
import { afterEach, describe, expect, it } from 'bun:test'
import { WebSocketClient } from '../api/http'

interface Harness { server: Server<undefined>, url: string, sockets: Set<ServerWebSocket<undefined>>, connections: () => number }

const servers: Server<undefined>[] = []
const clients: WebSocketClient[] = []

function serve(options: { accept?: boolean } = {}): Harness {
  const sockets = new Set<ServerWebSocket<undefined>>()
  let connections = 0
  const server = Bun.serve<undefined>({
    port: 0,
    fetch(request, server) {
      connections++
      if (options.accept === false) return new Response('no', { status: 400 })
      return server.upgrade(request) ? undefined : new Response('no', { status: 400 })
    },
    websocket: {
      open: socket => void sockets.add(socket),
      close: socket => void sockets.delete(socket),
      message() {},
    },
  })
  servers.push(server)
  return { server, url: `ws://127.0.0.1:${server.port}`, sockets, connections: () => connections }
}

function client(url: string, options?: ConstructorParameters<typeof WebSocketClient>[1]): WebSocketClient {
  const made = new WebSocketClient(url, options)
  clients.push(made)
  return made
}

async function until(what: string, read: () => boolean, timeout = 3000): Promise<void> {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (read()) return
    await Bun.sleep(10)
  }
  throw new Error(`Timed out waiting for ${what}`)
}

afterEach(() => {
  for (const made of clients.splice(0)) made.disconnect()
  for (const server of servers.splice(0)) server.stop(true)
})

describe('WebSocketClient', () => {
  it('hands a handler the payload it was sent, falsy ones included', async () => {
    const harness = serve()
    const socket = client(harness.url, { reconnectDelay: 20 })
    await socket.connect()
    const received: Array<[string, unknown]> = []
    for (const type of ['count', 'flag', 'text', 'nothing', 'bare'])
      socket.on(type, data => received.push([type, data]))
    await until('the server to see the client', () => harness.sockets.size === 1)
    const [peer] = harness.sockets
    peer.send(JSON.stringify({ type: 'count', payload: 0 }))
    peer.send(JSON.stringify({ type: 'flag', payload: false }))
    peer.send(JSON.stringify({ type: 'text', payload: '' }))
    peer.send(JSON.stringify({ type: 'nothing', payload: null }))
    // A message with no payload at all still arrives as the whole message.
    peer.send(JSON.stringify({ type: 'bare', at: 1 }))
    await until('five messages', () => received.length === 5)
    expect(received).toEqual([['count', 0], ['flag', false], ['text', ''], ['nothing', null], ['bare', { type: 'bare', at: 1 }]])
  })

  it('gives a message handler non-JSON text and bare JSON values as they came', async () => {
    const harness = serve()
    const socket = client(harness.url)
    await socket.connect()
    const received: unknown[] = []
    socket.on('message', data => received.push(data))
    await until('the server to see the client', () => harness.sockets.size === 1)
    const [peer] = harness.sockets
    peer.send('hello')
    peer.send('5')
    peer.send('null')
    await until('three messages', () => received.length === 3)
    expect(received).toEqual(['hello', 5, null])
  })

  it('does not hand other handlers the raw text when one handler throws', async () => {
    const harness = serve()
    const socket = client(harness.url)
    await socket.connect()
    const raw: unknown[] = []
    const seen: unknown[] = []
    socket.on('message', data => raw.push(data))
    socket.on('tick', () => { throw new Error('handler failed') })
    socket.on('tick', data => seen.push(data))
    await until('the server to see the client', () => harness.sockets.size === 1)
    const [peer] = harness.sockets
    peer.send(JSON.stringify({ type: 'tick', payload: 1 }))
    await until('the second tick handler', () => seen.length === 1)
    await Bun.sleep(30)
    expect(seen).toEqual([1])
    expect(raw).toEqual([])
  })

  it('makes no retries when maxReconnectAttempts is 0', async () => {
    const harness = serve({ accept: false })
    const socket = client(harness.url, { maxReconnectAttempts: 0, reconnectDelay: 10 })
    await socket.connect().catch(() => {})
    await Bun.sleep(300)
    expect(harness.connections()).toBe(1)
  })

  it('still reconnects after a disconnect() and a later connect()', async () => {
    const harness = serve()
    const socket = client(harness.url, { reconnectDelay: 20 })
    await socket.connect()
    socket.disconnect()
    await until('the server to see the close', () => harness.sockets.size === 0)
    // The intentional close is not retried.
    await Bun.sleep(80)
    expect(harness.connections()).toBe(1)

    await socket.connect()
    await until('the server to see the client again', () => harness.sockets.size === 1)
    for (const peer of harness.sockets) peer.terminate()
    await until('the client to come back on its own', () => harness.connections() === 3 && socket.connected)
  })

  it('cancels a pending retry when disconnect() is called', async () => {
    const harness = serve()
    const socket = client(harness.url, { reconnectDelay: 60 })
    await socket.connect()
    await until('the server to see the client', () => harness.sockets.size === 1)
    for (const peer of harness.sockets) peer.terminate()
    await Bun.sleep(20)
    socket.disconnect()
    await Bun.sleep(150)
    expect(harness.connections()).toBe(1)
    expect(socket.connected).toBe(false)
  })
})
