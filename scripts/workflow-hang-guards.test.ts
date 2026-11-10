import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

/**
 * Every job on the gate workflows declares a hang guard.
 *
 * GitHub's default job timeout is **360 minutes**, and both gate workflows set
 * `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` — so on a
 * push to main it is false, and the concurrency group holds one running run
 * plus one pending run. A newer push replaces the pending one and cannot touch
 * the running one.
 *
 * Those two facts compose badly. One wedged job holds main's only running slot
 * for up to six hours, every later push queues behind a verdict for a commit
 * nobody will release, and the pending slot keeps being overwritten so those
 * runs are cancelled without ever starting. That is not hypothetical: on
 * 2026-11-10 `ios-native-templates` ran past ninety minutes against a
 * six-run maximum of sixty-four, three commits deep, and had to be cancelled
 * by hand to let HEAD start — twice.
 *
 * The caps are hang guards, not budgets. Each is roughly double the slowest of
 * the last six successful runs, so a slow runner still finishes and only a
 * stuck job is killed — the same distinction #447 drew for a wall clock that
 * could not tell stopped from slow.
 *
 * Scope is the two workflows that gate main, which is where the cost lands.
 * `release.yml`, `sbom.yml`, `binary-size.yml`, `benchmarks.yml` and
 * `buddy-bot.yml` have 23 uncapped jobs between them and are tracked
 * separately — sizing release jobs wants its own change, not a drive-by one
 * made while cutting a release.
 */
const root = resolve(import.meta.dir, '..')
const gates = ['.github/workflows/ci.yml', '.github/workflows/mobile-e2e.yml']

interface Job { name: string, head: string, caller: boolean, timeout: number | null }

/** Each job in a workflow, with the text above its `steps:`. */
function jobs(source: string): Job[] {
  // Only the `jobs:` section. `on:` holds `push` and `pull_request` at the
  // same two-space indent, and reading those as jobs made the first version
  // of this rule report trigger names as uncapped jobs.
  const at = source.indexOf('\njobs:')
  expect(at, 'the workflow must declare jobs').toBeGreaterThan(0)
  const lines = source.slice(at).split('\n')
  const found: Job[] = []
  let name: string | null = null, body: string[] = []
  const flush = (): void => {
    if (name === null) return
    const head = body.join('\n').split('\n    steps:')[0]!
    found.push({
      name,
      head,
      // A job that calls a reusable workflow cannot declare timeout-minutes at
      // all, so requiring one of it would be requiring invalid YAML.
      caller: /^ {4}uses:/m.test(head),
      timeout: Number(/^ {4}timeout-minutes:\s*(\d+)/m.exec(head)?.[1] ?? '') || null,
    })
  }
  for (const line of lines) {
    const header = /^ {2}([a-z][\w-]*):$/.exec(line)
    if (header) { flush(); name = header[1]!; body = []; continue }
    if (name !== null) body.push(line)
  }
  flush()
  return found
}

test('the scan finds the gate workflows\' jobs', () => {
  // A floor, so a parser that matches nothing cannot pass every case below.
  for (const path of gates) {
    const found = jobs(readFileSync(join(root, path), 'utf8'))
    expect(found.length, `${path} must have jobs`).toBeGreaterThan(5)
  }
})

test('both gate workflows still decline to cancel a running push', () => {
  // The caps only matter because of this. If a workflow ever starts cancelling
  // in progress on push, the reasoning above changes and this should be
  // re-read rather than silently kept.
  for (const path of gates) {
    expect(readFileSync(join(root, path), 'utf8'),
      `${path} no longer matches the concurrency this rule reasons about`)
      .toContain("cancel-in-progress: ${{ github.event_name == 'pull_request' }}")
  }
})

for (const path of gates) {
  test(`every job in ${path.split('/').pop()} declares a hang guard`, () => {
    const uncapped = jobs(readFileSync(join(root, path), 'utf8'))
      .filter(job => !job.caller && job.timeout === null)
      .map(job => job.name)
    expect(uncapped,
      `these jobs take GitHub's 360-minute default, so one hang blocks main's only running slot for six hours`)
      .toEqual([])
  })

  test(`no hang guard in ${path.split('/').pop()} is set so high it stops guarding`, () => {
    // 180 minutes is already three hours of a held slot. A cap above it is not
    // a guard; it is the default with extra steps.
    const loose = jobs(readFileSync(join(root, path), 'utf8'))
      .filter(job => job.timeout !== null && job.timeout > 180)
      .map(job => `${job.name} at ${job.timeout} minutes`)
    expect(loose).toEqual([])
  })
}

test('a reusable-workflow caller is exempt rather than overlooked', () => {
  // mobile-e2e's media-cache job is `uses:`-based. The rule has to know the
  // difference between a job that may not declare a timeout and one that
  // forgot to, or it would demand YAML GitHub rejects.
  const found = jobs(readFileSync(join(root, '.github/workflows/mobile-e2e.yml'), 'utf8'))
  const callers = found.filter(job => job.caller).map(job => job.name)
  expect(callers, 'mobile-e2e must still call media-cache as a reusable workflow').toContain('media-cache')
  for (const job of found.filter(entry => entry.caller))
    expect(job.timeout, `${job.name} calls a reusable workflow and cannot carry a timeout`).toBeNull()
})
