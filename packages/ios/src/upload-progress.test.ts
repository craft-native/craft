import { expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** Exercise URLSession's actual task byte observations and cancellation, not an estimated timer. */
test.skipIf(process.platform !== 'darwin')('URLSession reports sent bytes and cancellation stops a real upload', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'craft-upload-progress-'))
  let received = 0
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, maxRequestBodySize: 64 * 1024 * 1024, async fetch(request) {
    const reader = request.body!.getReader()
    try {
      while (true) {
        const { value, done } = await reader.read()
        if (done) break
        received += value.byteLength
        await Bun.sleep(2)
      }
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
    expect(received).toBeLessThan(size)
  }
  finally { server.stop(true); rmSync(directory, { recursive: true, force: true }) }
}, 65000)
