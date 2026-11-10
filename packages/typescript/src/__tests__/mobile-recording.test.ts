import { afterEach, describe, expect, it } from 'bun:test'
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { recordIosSimulatorVideo } from '../mobile-testing'

const uuid = '219981F8-E211-45DF-8ACD-61F214EF09B1'
const directories: string[] = []
afterEach(async () => {
  for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true })
})

async function recorder(mode = 'normal') {
  const root = await mkdtemp(join(tmpdir(), 'craft recording '))
  directories.push(root)
  const xcrun = join(root, 'xcrun')
  const path = join(root, 'movie.mp4')
  const ready = join(root, 'first-frame')
  const stopped = join(root, 'stops')
  const commands = join(root, 'commands.json')
  await writeFile(xcrun, `#!/usr/bin/env bun
import { appendFileSync, writeFileSync } from 'node:fs'
const args = process.argv.slice(2)
const mode = ${JSON.stringify(mode)}
writeFileSync(${JSON.stringify(commands)}, JSON.stringify(args))
if (mode === 'error') { console.error('DISPLAY_UNAVAILABLE'); process.exit(2) }
process.on('SIGINT', () => {
  if (mode === 'ignore-stop') return
  appendFileSync(${JSON.stringify(stopped)}, 'stop\\n')
  if (mode !== 'empty') writeFileSync(args.at(-1), 'finalized movie')
  process.exit(mode === 'failed-stop' ? 2 : 0)
})
if (mode !== 'no-frame') {
  setTimeout(() => {
    writeFileSync(${JSON.stringify(ready)}, 'ready')
    process.stderr.write('Recording sta')
    setTimeout(() => process.stderr.write('rted\\n'), 20)
  }, 80)
}
else console.error('Not Recording started yet')
await Bun.sleep(60_000)
`)
  await chmod(xcrun, 0o755)
  // Includes launching a separate Bun runtime, not just the fake's 100ms delay.
  // A 500ms budget expired during cold starts before the behavior under test.
  return { options: { device: uuid, path, xcrun, timeoutMs: 2000 }, ready, stopped, commands }
}

describe('iOS simulator test recordings', () => {
  it('rejects implicit devices and non-local paths before launching a recorder', async () => {
    await expect(recordIosSimulatorVideo({ device: 'booted', path: '/tmp/movie.mp4' })).rejects.toThrow('UUID')
    await expect(recordIosSimulatorVideo({ device: uuid, path: 'movie.mp4' })).rejects.toThrow('absolute')
    await expect(recordIosSimulatorVideo({ device: uuid, path: '/tmp/movie.mp4', timeoutMs: 0 })).rejects.toThrow('positive')
  }, 30_000)

  it('waits for the first frame and finalizes once, even when stop is called twice', async () => {
    const test = await recorder()
    const recording = await recordIosSimulatorVideo(test.options)
    try {
      expect(await Bun.file(test.ready).exists()).toBe(true)
      expect(JSON.parse(await readFile(test.commands, 'utf8'))).toEqual(['simctl', 'io', uuid, 'recordVideo', '--codec=h264', test.options.path])
      const one = recording.stop()
      expect(recording.stop()).toBe(one)
      await one
      expect(await readFile(test.stopped, 'utf8')).toBe('stop\n')
      expect(await readFile(recording.path, 'utf8')).toBe('finalized movie')
    }
    finally { await recording.stop() }
  }, 30_000)

  it('surfaces a recorder that exits before producing any frames', async () => {
    const test = await recorder('error')
    await expect(recordIosSimulatorVideo(test.options)).rejects.toThrow('DISPLAY_UNAVAILABLE')
  }, 30_000)

  it('stops a recorder that never acknowledges its first frame', async () => {
    const test = await recorder('no-frame')
    await expect(recordIosSimulatorVideo({ ...test.options, timeoutMs: 500 })).rejects.toThrow('did not produce its first frame')
    expect(await Bun.file(test.options.path).exists()).toBe(false)
  }, 30_000)

  it('bounds a failed stop instead of blocking the next device restart', async () => {
    const test = await recorder('ignore-stop')
    const recording = await recordIosSimulatorVideo(test.options)
    await expect(recording.stop()).rejects.toThrow('did not finalize')
  }, 30_000)

  it('refuses to treat a failed or empty finalization as a saved movie', async () => {
    for (const [mode, reason] of [['failed-stop', 'Recorder failed'], ['empty', 'did not write a movie']]) {
      const test = await recorder(mode)
      const recording = await recordIosSimulatorVideo(test.options)
      await expect(recording.stop()).rejects.toThrow(reason)
    }
  }, 10_000)
})
