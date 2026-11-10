import { expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** Exercise URLSession's actual task byte observations and cancellation, not an estimated timer. */
test.skipIf(process.platform !== 'darwin')('URLSession reports sent bytes and cancellation stops a real upload', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-upload-progress-'))
  let received = 0
  // Read one chunk, then stop reading until the client goes away.
  //
  // Draining the body is what made `received < size` below a coin flip: 32 MiB
  // fits in loopback socket buffers, so the client can hand the whole file to
  // the kernel before its first `countOfBytesSent` callback fires, and a
  // draining server then reads all of it regardless of the cancel. That is how
  // v0.0.491's release gate failed with `Received: 33554432` — exactly `size`.
  //
  // Holding the body instead applies real backpressure, so the bytes the peer
  // sees are bounded by one chunk and the assertion becomes a property of
  // cancellation rather than of this machine's buffer sizes.
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, maxRequestBodySize: 64 * 1024 * 1024, async fetch(request) {
    const reader = request.body!.getReader()
    try {
      const first = await reader.read()
      received += first.value?.byteLength ?? 0
      // Bounded, so a client that never disconnects cannot wedge the handler
      // and with it `server.stop(true)` in the finally below.
      await Promise.race([
        new Promise<void>((resolve) => { request.signal.addEventListener('abort', () => resolve(), { once: true }) }),
        Bun.sleep(10_000),
      ])
    }
    catch { /* A cancelled client must disconnect before the body completes. */ }
    return new Response('ok')
  } })
  const source = join(directory, 'progress.swift')
  const file = join(directory, 'video.bin')
  const size = 32 * 1024 * 1024
  writeFileSync(file, Buffer.alloc(size, 1))
  writeFileSync(source, `import Foundation
var request = URLRequest(url: URL(string: CommandLine.arguments[1])!)
request.httpMethod = "POST"
var observation: NSKeyValueObservation?
let task = URLSession.shared.uploadTask(with: request, fromFile: URL(fileURLWithPath: CommandLine.arguments[2])) { _, _, error in
  if (error as? URLError)?.code == .cancelled { print("CANCELLED"); exit(0) }
  print("Unexpected completion: \\(String(describing: error))"); exit(1)
}
observation = task.observe(\\.countOfBytesSent, options: [.initial, .new]) { task, _ in
  if task.countOfBytesSent > 0 {
    print("PROGRESS \\(task.countOfBytesSent)")
    task.cancel()
  }
}
task.resume()
dispatchMain()
`)
  try {
    const child = Bun.spawn(['swift', source, `http://127.0.0.1:${server.port}/video`, file], { stdout: 'pipe', stderr: 'pipe', signal: AbortSignal.timeout(60000) })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect({ code, stderr }).toEqual({ code: 0, stderr: '' })
    expect(stdout).toContain('PROGRESS ')
    expect(stdout).toContain('CANCELLED')
    // Strictly less, and now by a wide margin rather than a coin flip. With the
    // server holding the body, three local runs delivered 65 KiB, 163 KiB and
    // 163 KiB — 0.19% to 0.49% of the file, against 100% when it drained.
    // Half the payload is far above anything a cancelled upload should reach
    // and still fails the moment the server goes back to draining.
    expect(received, `a cancelled upload delivered ${received} of ${size} bytes`).toBeLessThan(size / 2)
  }
  finally { server.stop(true); rmSync(directory, { recursive: true, force: true }) }
}, 65000)
