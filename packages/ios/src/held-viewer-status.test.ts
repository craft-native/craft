import { expect, test } from 'bun:test'
import { HeldViewerStatusBar } from '../scripts/held-viewer-status'

const pristine = 'Current Status Bar Overrides:\n=============================\n'
const result = { code: 0, signal: null, stdout: '', stderr: '', timedOut: false, cancelled: false, processGroup: 123, groupDisposed: true as const }
const options = { simctl: '/verified/simctl', simulator: '9E10C320-E7FF-4D3E-ADE8-9A75FC60EC16', cwd: '/tmp' }

test('owned display stimulus lists pristine state, redraws only the displayed clock, then clears and verifies restoration', async () => {
  const calls: string[][] = []
  const status = new HeldViewerStatusBar(options, async args => { calls.push(args); return { ...result, stdout: args.at(-1) === 'list' ? pristine : '' } })
  await status.prepare()
  await status.redraw()
  await status.restore()
  await status.restore()
  expect(calls).toEqual([
    [options.simctl, 'status_bar', options.simulator, 'list'],
    [options.simctl, 'status_bar', options.simulator, 'override', '--time', '02:17'],
    [options.simctl, 'status_bar', options.simulator, 'clear'],
    [options.simctl, 'status_bar', options.simulator, 'list'],
  ])
  expect(status.restored).toBe(true)
  expect(status.calls.every(call => call.result?.groupDisposed && call.finishedAt! >= call.startedAt)).toBe(true)
})

test('preexisting or unrecognized overrides fail before any display mutation or clear', async () => {
  for (const text of [pristine + 'time = 09:41\n', 'unexpected tool output']) {
    const calls: string[][] = []
    const status = new HeldViewerStatusBar(options, async args => { calls.push(args); return { ...result, stdout: text } })
    await expect(status.prepare()).rejects.toThrow('pristine')
    await status.restore()
    expect(calls).toHaveLength(1)
    await expect(status.redraw()).rejects.toThrow('pristine')
    expect(calls).toHaveLength(1)
  }
})

test('partially failed redraw is not accepted and still restores only its known pristine owned state', async () => {
  const calls: string[][] = []
  const status = new HeldViewerStatusBar(options, async args => {
    calls.push(args)
    return args.includes('override') ? { ...result, code: 143, timedOut: true } : { ...result, stdout: args.at(-1) === 'list' ? pristine : '' }
  })
  await status.prepare()
  await expect(status.redraw()).rejects.toThrow('timedOut')
  await status.restore()
  expect(calls.at(-2)?.at(-1)).toBe('clear')
  expect(status.restored).toBe(true)
})

test('failed restoration blocks acceptance instead of claiming reset from a successful clear alone', async () => {
  let listed = false
  const status = new HeldViewerStatusBar(options, async args => {
    if (args.at(-1) === 'list') {
      const stdout = listed ? pristine + 'time = 02:17\n' : pristine
      listed = true
      return { ...result, stdout }
    }
    return result
  })
  await status.prepare()
  await status.redraw()
  await expect(status.restore()).rejects.toThrow('pristine')
  expect(status.restored).toBe(false)
})
