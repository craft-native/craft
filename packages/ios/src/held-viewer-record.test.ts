import { expect, test } from 'bun:test'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { nativeFixtureCommand } from '../scripts/native-fixture-command'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

test('public video host acknowledges first frame and finalizes only its owned child with SIGINT', async () => {
  const dir = createTempDir('craft-held-record-test-')
  try {
    const simctl = join(dir, 'simctl'), ready = join(dir, 'ready'), stop = join(dir, 'stop'), receipt = join(dir, 'receipt.json')
    writeFileSync(simctl, `#!${process.execPath}\nprocess.stderr.write('Recording started\\n'); process.once('SIGINT', () => { require('fs').writeFileSync(process.argv.at(-1), 'finalized movie'); process.exit(0) }); setInterval(() => {}, 1000)\n`, { mode: 0o755 })
    const command = nativeFixtureCommand([process.execPath, join(import.meta.dir, '../scripts/held-viewer-record.ts'), simctl,
      '9E10C320-E7FF-4D3E-ADE8-9A75FC60EC16', join(dir, 'movie.mov'), ready, stop, receipt], { cwd: dir, timeoutMs: 3000 })
    const deadline = performance.now() + 2000
    while (!existsSync(ready) && performance.now() < deadline) await Bun.sleep(20)
    expect(existsSync(ready)).toBe(true)
    expect(existsSync(join(dir, 'movie.mov'))).toBe(false)
    await Bun.write(stop, 'six-second gesture released')
    const result = await command
    expect(result).toMatchObject({ code: 0, cancelled: false, timedOut: false, groupDisposed: true })
    expect(readFileSync(join(dir, 'movie.mov'), 'utf8')).toBe('finalized movie')
    const proof = JSON.parse(readFileSync(receipt, 'utf8'))
    expect(proof.completed).toBe(true)
    expect(proof.spawnWall).toBeLessThanOrEqual(proof.readyWall)
    expect(proof.readyWall).toBeLessThanOrEqual(proof.stopWall)
    expect(proof.code).toBe(0)
    expect(proof.args.slice(1, 5)).toEqual(['io', '9E10C320-E7FF-4D3E-ADE8-9A75FC60EC16', 'recordVideo', '--codec=h264'])
  }
  finally { removeTempDir(dir) }
})

test('recording cannot qualify when the public tool exits before first-frame acknowledgement', async () => {
  const dir = createTempDir('craft-held-record-test-')
  try {
    const simctl = join(dir, 'simctl'), ready = join(dir, 'ready'), receipt = join(dir, 'receipt.json')
    writeFileSync(simctl, `#!${process.execPath}\nprocess.exit(2)\n`, { mode: 0o755 })
    const result = await nativeFixtureCommand([process.execPath, join(import.meta.dir, '../scripts/held-viewer-record.ts'), simctl,
      '9E10C320-E7FF-4D3E-ADE8-9A75FC60EC16', join(dir, 'movie.mov'), ready, join(dir, 'stop'), receipt], { cwd: dir, timeoutMs: 3000 })
    expect(result.code).not.toBe(0)
    expect(result.groupDisposed).toBe(true)
    expect(existsSync(ready)).toBe(false)
    expect(JSON.parse(readFileSync(receipt, 'utf8')).completed).toBe(false)
  }
  finally { removeTempDir(dir) }
})
