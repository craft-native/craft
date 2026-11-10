import { expect, test } from 'bun:test'
import { waitForRelease } from './release-complete'

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
