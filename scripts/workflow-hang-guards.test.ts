import { expect, test } from 'bun:test'
import { readdirSync, readFileSync } from 'node:fs'
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
 * Every workflow in `.github/workflows` is covered, found by reading the
 * directory rather than by naming files, so one added later cannot arrive
 * uncapped. The two that gate main carry the reasoning above; the rest simply
 * should not hold a runner for six hours.
 *
 * `release.yml` is under the same rule (#504), with one difference that is
 * named rather than waved through. A release run starts from its tag and
 * shares no concurrency group with main, so it cannot hold main's slot, and
 * its two acceptance jobs do nothing but wait on the CI and Mobile E2E runs
 * for the release commit. Their cap is therefore a statement of how long a
 * release may wait on those runs, not a measurement of work, and it may exceed
 * the three-hour ceiling below. Nothing else may.
 */
const root = resolve(import.meta.dir, '..')
const gates = ['.github/workflows/ci.yml', '.github/workflows/mobile-e2e.yml']
/** Every workflow file, read off the directory. */
const workflows = readdirSync(join(root, '.github/workflows'))
  .filter(name => name.endsWith('.yml') || name.endsWith('.yaml'))
  .sort()
  .map(name => `.github/workflows/${name}`)
const release = '.github/workflows/release.yml'
/**
 * The jobs that only wait on other runs, and so may carry a cap above the
 * ceiling. The slowest of seventeen was 119 minutes; the longest job in the
 * runs they wait on is capped at 120, and such a run can queue behind another.
 */
const waiters: Record<string, string[]> = { [release]: ['source-acceptance', 'native-acceptance'] }
/** Above this a cap is the default with extra steps. */
const ceiling = 180

interface Job { name: string, head: string, body: string, caller: boolean, timeout: number | null }

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
      body: body.join('\n'),
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

test('the workflows are found, and the gates are among them', () => {
  // A floor: an empty directory read must not pass every case below.
  expect(workflows.length).toBeGreaterThan(8)
  for (const path of [...gates, release]) expect(workflows).toContain(path)
})

for (const path of workflows) {
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
    const allowed = waiters[path] ?? []
    const loose = jobs(readFileSync(join(root, path), 'utf8'))
      .filter(job => job.timeout !== null && job.timeout > ceiling && !allowed.includes(job.name))
      .map(job => `${job.name} at ${job.timeout} minutes`)
    expect(loose).toEqual([])
  })
}

test('a job allowed past the ceiling is still one that only waits', () => {
  // The allowance is for waiting on other runs. If a named job is capped under
  // the ceiling, or stops being a job, the entry is stale and should go; if it
  // starts doing work of its own, it needs a real guard like every other job.
  for (const [path, names] of Object.entries(waiters)) {
    const found = jobs(readFileSync(join(root, path), 'utf8'))
    for (const name of names) {
      const job = found.find(entry => entry.name === name)
      expect(job, `${name} is no longer a job in ${path}; remove it from the allowance`).toBeDefined()
      expect(job!.timeout, `${name} must still declare a cap`).not.toBeNull()
      expect(job!.timeout!, `${name} is under the ceiling now; remove it from the allowance`).toBeGreaterThan(ceiling)
      // Read off what the job runs rather than off its name: every command
      // in it must be the script that waits for main's run of this commit.
      const commands = [...job!.body.matchAll(/^ {8}run:\s*(.+)$/gm)].map(match => match[1]!)
      expect(commands.length, `${name} must run something`).toBeGreaterThan(0)
      for (const command of commands) {
        expect(command, `${name} does work of its own now, so it needs a guard sized to that work`)
          .toMatch(/^bun scripts\/release-acceptance\.ts \S+$/)
      }
    }
  }
})

test('a cap leaves room for the longest wait its own job declares', () => {
  // `notarytool --wait --timeout 30m` is a wait the workflow itself asks for.
  // A cap that does not clear it, with as much again for the work around it,
  // would kill a release that was behaving exactly as written.
  let waits = 0
  for (const path of workflows) {
    for (const job of jobs(readFileSync(join(root, path), 'utf8'))) {
      if (job.timeout === null) continue
      const declared = [...job.body.matchAll(/--timeout\s+(\d+)m\b/g)].map(match => Number(match[1]))
      for (const minutes of declared) {
        waits += 1
        expect(job.timeout, `${job.name} in ${path} waits up to ${minutes} minutes in one step`)
          .toBeGreaterThanOrEqual(minutes * 2)
      }
    }
  }
  // A floor: the notarization wait exists today, so finding none means the
  // pattern stopped matching rather than that there is nothing to check.
  expect(waits, 'no declared in-step wait was found').toBeGreaterThan(0)
})

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
