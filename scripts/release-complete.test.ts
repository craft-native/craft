import { expect, test } from 'bun:test'
import { waitForRelease } from './release-complete'
import { bumpxReleaseCommand, runRelease } from './release-cli'

const released = { databaseId: 12, headBranch: 'v1.2.3', headSha: 'abc', event: 'push', status: 'completed', conclusion: 'success', url: 'https://github.com/craft-native/craft/actions/runs/12' }
const ok = (runs: unknown[]) => ({ exitCode: 0, stdout: JSON.stringify(runs), stderr: '' })

test('release completion waits for the exact tag and commit rather than another green run', async () => {
  let time = 0
  const result = await waitForRelease('v1.2.3', 'abc', () => ok(time === 0
    ? [{ ...released, headBranch: 'main' }, { ...released, headSha: 'other' }]
    : time === 10 ? [{ ...released, status: 'in_progress', conclusion: null }] : [released]), {
    now: () => time, sleep: async ms => { time += ms }, intervalMs: 10, timeoutMs: 100,
  })
  expect(time).toBe(20)
  expect(result).toBe(released.url)
})

test('a failed release cannot be reported as completed or trigger another version bump', async () => {
  const calls: string[][] = []
  await expect(waitForRelease('v1.2.3', 'abc', args => { calls.push(args); return ok([{ ...released, conclusion: 'failure' }]) })).rejects.toThrow('do not create another version')
  expect(calls).toHaveLength(1)
  expect(calls[0]!.slice(0, 3)).toEqual(['gh', 'run', 'list'])
})

test('a delayed workflow retains a resumable release instead of bumping again', async () => {
  let time = 0
  await expect(waitForRelease('v1.2.3', 'abc', () => ok([]), {
    now: () => time, sleep: async ms => { time += ms }, intervalMs: 10, timeoutMs: 25,
  })).rejects.toThrow('release:finish')
  expect(time).toBe(25)
})

test('temporary GitHub failures recover; repeated authentication failures remain visible', async () => {
  const failed = { exitCode: 1, stdout: '', stderr: 'authentication failed' }
  let requests = 0
  expect(await waitForRelease('v1.2.3', 'abc', () => ++requests === 1 ? failed : ok([released]), { sleep: async () => {} })).toBe(released.url)
  await expect(waitForRelease('v1.2.3', 'abc', () => failed, { sleep: async () => {} })).rejects.toThrow('gh auth status')
})

test('a requested version and flags reach Bumpx before the independent publication watcher', async () => {
  const calls: string[][] = []
  await runRelease('version', ['1.2.4', '--yes'], async args => { calls.push(args) })
  expect(calls).toHaveLength(3)
  expect(calls[0]!.slice(1)).toEqual(['scripts/release-version.ts', '--preflight'])
  expect(calls[1]!.slice(1, 4)).toEqual(['x', '--bun', '@stacksjs/bumpx'])
  expect(calls[1]!.slice(-2)).toEqual(['1.2.4', '--yes'])
  expect(calls[2]!.slice(1)).toEqual(['scripts/release-complete.ts'])
})

test('dry runs and local-only releases cannot start a publication wait', async () => {
  for (const option of ['--dry-run', '--no-push', '--no-tag', '--no-commit']) {
    const calls: string[][] = []
    await runRelease('patch', [option], async args => { calls.push(args) })
    expect(calls).toHaveLength(2)
    expect(calls[1]!.at(-1)).toBe(option)
  }
})

test('a failed preflight or bump cannot start any subsequent step', async () => {
  for (const failAt of [1, 2]) {
    let calls = 0
    await expect(runRelease('patch', [], async () => { if (++calls === failAt) throw new Error('stopped') })).rejects.toThrow('stopped')
    expect(calls).toBe(failAt)
  }
  expect(bumpxReleaseCommand('patch', [])).toContain('--yes')
  expect(bumpxReleaseCommand('prompt', [])).toContain('prompt')
  expect(bumpxReleaseCommand('prompt', [])).not.toContain('--yes')
})
