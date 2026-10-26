import { expect, test } from 'bun:test'
import { mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { buildHeldViewerExtractor, verifyHeldViewerExtractor } from '../scripts/held-viewer-extractor'
import { nativeFixtureBuildTimeoutMs } from '../scripts/native-fixture-command'
import { metalXCTestSteps } from '../scripts/metal-xctest-steps'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

function fixture() {
  const dir = createTempDir('craft-extractor-build-test-'), output = join(dir, 'build'), sdk = join(dir, 'sdk'), swiftc = join(dir, 'swiftc')
  mkdirSync(sdk)
  writeFileSync(swiftc, 'synthetic Swift compiler', { mode: 0o755 })
  const calls: { args: string[], timeout: number }[] = []
  const command: NonNullable<Parameters<typeof buildHeldViewerExtractor>[1]>['command'] = async (args, options) => {
    calls.push({ args, timeout: options.timeoutMs })
    let stdout = ''
    if (args.includes('--find')) stdout = `${swiftc}\n`
    else if (args.includes('--show-sdk-path')) stdout = `${sdk}\n`
    else writeFileSync(args.at(-1)!, 'synthetic compiled extractor', { mode: 0o755 })
    return { code: 0, signal: null, timedOut: false, cancelled: false, stdout, stderr: '', processGroup: 123, groupDisposed: true }
  }
  return { dir, output, sdk, swiftc, calls, command, build: () => buildHeldViewerExtractor({ output }, { xcrun: '/usr/bin/xcrun', command }) }
}

test('build phase resolves the public compiler/SDK and retains the verified executable and command provenance', async () => {
  const f = fixture()
  try {
    const manifest = await f.build()
    expect(manifest).toBe(join(f.output, 'extractor-build.json'))
    const receipt = JSON.parse(readFileSync(manifest, 'utf8'))
    expect(f.calls.map(call => call.args)).toEqual([
      ['/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'swiftc'],
      ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
      [f.swiftc, '-sdk', f.sdk, join(import.meta.dir, '../scripts/held-viewer-frame.swift'), '-o', join(f.output, 'held-viewer-frame')],
    ])
    expect(receipt.verified).toBe(true)
    expect(receipt.totalBuildBudgetMs).toBe(nativeFixtureBuildTimeoutMs)
    for (const call of receipt.calls) {
      expect(call.timeoutMs).toBeGreaterThan(0)
      expect(call.timeoutMs).toBeLessThanOrEqual(nativeFixtureBuildTimeoutMs)
      expect(call.finishedWall).toBeGreaterThanOrEqual(call.startedWall)
      expect(call.result).toMatchObject({ code: 0, timedOut: false, groupDisposed: true })
    }
    expect(await verifyHeldViewerExtractor(manifest, f.output)).toEqual({
      path: join(f.output, 'held-viewer-frame'), binarySha256: receipt.binarySha256,
      sourceSha256: receipt.sourceSha256, swiftc: f.swiftc, swiftcSha256: receipt.swiftcSha256, macosSdk: f.sdk,
    })
    expect(receipt.binarySha256).toBe(new Bun.CryptoHasher('sha256').update('synthetic compiled extractor').digest('hex'))
    await expect(f.build()).rejects.toThrow('overwrite')
  }
  finally { removeTempDir(f.dir) }
})

test('all build commands share the remaining deadline rather than receiving fresh compilation budgets', async () => {
  const f = fixture()
  try {
    await buildHeldViewerExtractor({ output: f.output }, { xcrun: '/usr/bin/xcrun', command: async (args, options) => {
      const result = await f.command!(args, options)
      await Bun.sleep(25)
      return result
    } })
    expect(f.calls[1]!.timeout).toBeLessThan(f.calls[0]!.timeout - 15)
    expect(f.calls[2]!.timeout).toBeLessThan(f.calls[1]!.timeout - 15)
  }
  finally { removeTempDir(f.dir) }
})

test('compiler failure keeps full status and diagnostics and never verifies an extractor', async () => {
  const f = fixture()
  try {
    await expect(buildHeldViewerExtractor({ output: f.output }, { xcrun: '/usr/bin/xcrun', command: async (args, options) => {
      if (args[0] !== f.swiftc) return await f.command!(args, options)
      return { code: 143, signal: 'SIGTERM', timedOut: true, cancelled: false, stdout: 'partial build', stderr: 'compile timeout', processGroup: 456, groupDisposed: true }
    } })).rejects.toThrow('"timedOut":true')
    const manifest = join(f.output, 'extractor-build.json'), receipt = JSON.parse(readFileSync(manifest, 'utf8'))
    expect(receipt.verified).toBe(false)
    expect(receipt.calls.at(-1).result).toMatchObject({ code: 143, signal: 'SIGTERM', timedOut: true, stdout: 'partial build', stderr: 'compile timeout', groupDisposed: true })
    await expect(verifyHeldViewerExtractor(manifest, f.output)).rejects.toThrow('verified build')
  }
  finally { removeTempDir(f.dir) }
})

test('a successful command without a fresh executable cannot create a verified manifest', async () => {
  const f = fixture()
  try {
    await expect(buildHeldViewerExtractor({ output: f.output }, { xcrun: '/usr/bin/xcrun', command: async (args, options) => {
      if (args[0] !== f.swiftc) return await f.command!(args, options)
      return { code: 0, signal: null, timedOut: false, cancelled: false, stdout: '', stderr: '', processGroup: 456, groupDisposed: true }
    } })).rejects.toThrow('fresh executable')
    expect(JSON.parse(readFileSync(join(f.output, 'extractor-build.json'), 'utf8')).verified).toBe(false)
  }
  finally { removeTempDir(f.dir) }
})

test('verification rejects substituted binary, compiler, source hash and escaped paths', async () => {
  for (const substitution of ['binary', 'compiler', 'source-hash', 'source-path', 'escaped', 'symlink']) {
    const f = fixture()
    try {
      const manifest = await f.build(), receipt = JSON.parse(readFileSync(manifest, 'utf8'))
      if (substitution === 'binary') writeFileSync(receipt.path, 'different binary')
      else if (substitution === 'compiler') writeFileSync(f.swiftc, 'different compiler')
      else if (substitution === 'source-hash') receipt.sourceSha256 = '0'.repeat(64)
      else if (substitution === 'source-path') receipt.source = f.swiftc
      else if (substitution === 'escaped') receipt.path = join(f.dir, 'outside')
      else { unlinkSync(receipt.path); symlinkSync(f.swiftc, receipt.path) }
      writeFileSync(manifest, JSON.stringify(receipt))
      await expect(verifyHeldViewerExtractor(manifest, f.output)).rejects.toThrow()
    }
    finally { removeTempDir(f.dir) }
  }
})

test('changing the compiler during compilation invalidates the build manifest', async () => {
  const f = fixture()
  try {
    await expect(buildHeldViewerExtractor({ output: f.output }, { xcrun: '/usr/bin/xcrun', command: async (args, options) => {
      const result = await f.command!(args, options)
      if (args[0] === f.swiftc) writeFileSync(f.swiftc, 'compiler replaced during build')
      return result
    } })).rejects.toThrow('changed during its build')
    expect(JSON.parse(readFileSync(join(f.output, 'extractor-build.json'), 'utf8')).verified).toBe(false)
  }
  finally { removeTempDir(f.dir) }
})

test('relative output and wrong manifest output cannot qualify', async () => {
  await expect(buildHeldViewerExtractor({ output: 'relative-output' })).rejects.toThrow('absolute')
  const f = fixture()
  try {
    const manifest = await f.build()
    await expect(verifyHeldViewerExtractor(manifest, f.dir)).rejects.toThrow('expected absolute output')
  }
  finally { removeTempDir(f.dir) }
})


test('cold tool resolution and compilation consume the normal fixture build phase instead of capture readiness', async () => {
  const f = fixture()
  let clock = 1000
  const timeouts: number[] = []
  try {
    const manifest = await buildHeldViewerExtractor({ output: f.output }, {
      xcrun: '/usr/bin/xcrun', monotonicNow: () => clock,
      command: async (args, options) => {
        timeouts.push(options.timeoutMs)
        const result = await f.command!(args, options)
        clock += args.includes('--find') ? 31_000 : args[0] === f.swiftc ? 45_000 : 1000
        return result
      },
    })
    const buildBudget = metalXCTestSteps('owned-simulator', '/owned/build', '/owned/results')[0]!.timeoutMs
    expect(timeouts).toEqual([buildBudget, buildBudget - 31_000, buildBudget - 32_000])
    expect(JSON.parse(readFileSync(manifest, 'utf8')).totalBuildBudgetMs).toBe(buildBudget)
    expect(await verifyHeldViewerExtractor(manifest, f.output)).toHaveProperty('binarySha256')
  }
  finally { removeTempDir(f.dir) }
})


test('exhausting the normal build deadline cannot start another tool or qualify an extractor', async () => {
  const f = fixture()
  let clock = 0
  try {
    await expect(buildHeldViewerExtractor({ output: f.output }, {
      xcrun: '/usr/bin/xcrun', monotonicNow: () => clock,
      command: async (args, options) => {
        const result = await f.command!(args, options)
        clock += nativeFixtureBuildTimeoutMs + 1
        return result
      },
    })).rejects.toThrow('compilation deadline')
    expect(f.calls).toHaveLength(1)
    expect(JSON.parse(readFileSync(join(f.output, 'extractor-build.json'), 'utf8')).verified).toBe(false)
  }
  finally { removeTempDir(f.dir) }
})
