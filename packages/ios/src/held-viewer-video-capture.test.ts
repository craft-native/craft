import { expect, test } from 'bun:test'
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { captureHeldViewerVideo } from '../scripts/held-viewer-capture'
import { buildHeldViewerExtractor } from '../scripts/held-viewer-extractor'
import type { nativeFixtureCommand } from '../scripts/native-fixture-command'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

const simulator = '9E10C320-E7FF-4D3E-ADE8-9A75FC60EC16'
const pixel = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=', 'base64')

for (const alteredAnchor of [false, true]) {
  test(`video evidence ${alteredAnchor ? 'rejects a substituted anchor' : 'records before readiness and verifies actual captured PTS after release'}`, async () => {
    const dir = createTempDir('craft-held-video-pipeline-')
    try {
      const output = join(dir, 'evidence'), log = join(dir, 'log'), ready = join(dir, 'ready'), swiftc = join(dir, 'swiftc'), macosSdk = join(dir, 'MacOSX.sdk')
      writeFileSync(swiftc, 'synthetic compiler')
      mkdirSync(macosSdk)
      writeFileSync(log, '')
      const calls: string[][] = []
      const completed = { code: 0, signal: null, stdout: '', stderr: '', timedOut: false, cancelled: false, processGroup: 123, groupDisposed: true as const }
      const now = 102
      const command: typeof nativeFixtureCommand = async (args) => {
        calls.push(args)
        if (args[1] === 'status_bar') throw new Error('A live compositor fixture must not depend on a system display RPC during its held gesture')
        if (args.includes('--find')) {
          expect(args).toEqual(['/usr/bin/xcrun', '--sdk', 'macosx', '--find', 'swiftc'])
          return { ...completed, stdout: swiftc }
        }
        if (args.includes('--show-sdk-path')) {
          expect(args).toEqual(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'])
          return { ...completed, stdout: macosSdk }
        }
        if (args[0] === swiftc) {
          expect(args).toEqual([swiftc, '-sdk', macosSdk, join(import.meta.dir, '../scripts/held-viewer-frame.swift'), '-o', join(output, 'held-viewer-frame')])
          await Bun.write(args.at(-1)!, 'built extractor bytes')
          chmodSync(args.at(-1)!, 0o700)
          return completed
        }
        if (args[1]?.endsWith('held-viewer-record.ts')) {
          expect(existsSync(ready)).toBe(false)
          await Bun.write(args[4]!, 'actual synthetic movie')
          await Bun.write(args[7]!, JSON.stringify({ completed: true, spawnWall: 99, readyWall: 99.1 }))
          await Bun.write(args[5]!, 'Recording started')
          const deadline = performance.now() + 4000
          while (!existsSync(args[6]!) && performance.now() < deadline) await Bun.sleep(10)
          expect(existsSync(args[6]!)).toBe(true)
          return completed
        }
        expect(args[0]).toBe(join(output, 'held-viewer-frame'))
        expect(args.slice(4)).toEqual(['99', '99.1', '102', '108'])
        await Bun.write(args[2]!, pixel)
        const hash = (bytes: Uint8Array | string) => new Bun.CryptoHasher('sha256').update(bytes).digest('hex')
        await Bun.write(args[3]!, JSON.stringify({
          verified: true, recordSpawnWall: alteredAnchor ? 98 : 99, recordingStartedObservedWall: 99.1,
          synthesisWall: 102, releasedWall: 108, firstPTS: { value: 0, timescale: 1 },
          selectedPTS: { value: 4, timescale: 1 }, actualPTS: { value: 4, timescale: 1 },
          pngSha256: hash(pixel), movieSha256: hash('actual synthetic movie'),
        }))
        return completed
      }
      const extractorManifest = await buildHeldViewerExtractor({ output }, { command, xcrun: '/usr/bin/xcrun' })
      const buildCallCount = calls.length
      const run = captureHeldViewerVideo({ output, log, done: join(dir, 'done'), ready, simulator, timeoutMs: 5000, extractorManifest }, {
        prepare: async () => ({ simctl: '/synthetic/simctl', simctlSha256: 'verified-tool' }),
        now: () => now, command,
      })
      const deadline = performance.now() + 2000
      while (!existsSync(ready) && performance.now() < deadline) await Bun.sleep(10)
      expect(existsSync(ready)).toBe(true)
      expect(existsSync(join(output, 'recording-ready'))).toBe(true)
      appendFileSync(log, 'CRAFT_TAB_LCV_HOLD_BEGIN 100\nPress Home for 6 seconds\nSynthesize event\n')
      await Bun.sleep(50)
      appendFileSync(log, 'CRAFT_TAB_LCV_HOLD_END 108\n')
      if (alteredAnchor) await expect(run).rejects.toThrow('Frame timing does not match')
      else await run
      expect(calls.some(args => args.includes('screenshot'))).toBe(false)
      // Capture admission verifies the owned artifact; it never launches a
      // compiler inside the independent public recording-readiness deadline.
      expect(calls.slice(buildCallCount).some(args => args[0] === swiftc || args[0] === '/usr/bin/xcrun')).toBe(false)
      const receipt = JSON.parse(readFileSync(join(output, 'receipt.json'), 'utf8'))
      expect(receipt.verifiedDuringHold).toBe(!alteredAnchor)
      expect(calls.some(args => args[1] === 'status_bar')).toBe(false)
      if (!alteredAnchor) {
        expect(receipt.method).toBe('public-simctl-recordVideo-decoded-frame')
        expect(receipt.validated).toEqual({ frameWallEarliest: 103, frameWallLatest: 103.1, frameOffsetFromFirstPTS: 4 })
      }
    }
    finally { removeTempDir(dir) }
  })
}


test('capture refuses a missing host build manifest before starting live simulator setup', async () => {
  const dir = createTempDir('craft-held-unbuilt-')
  try {
    let prepared = false, commands = 0
    const capture = captureHeldViewerVideo({ output: join(dir, 'evidence'), log: join(dir, 'log'), done: join(dir, 'done'), simulator }, {
      prepare: async () => { prepared = true; return { simctl: '/synthetic/simctl', simctlSha256: 'tool' } },
      command: async () => {
        commands++
        throw new Error('Unexpected native command before build admission')
      },
    })
    await expect(capture).rejects.toThrow('fixture-build extractor manifest')
    expect(prepared).toBe(false)
    expect(commands).toBe(0)
  }
  finally { removeTempDir(dir) }
})
