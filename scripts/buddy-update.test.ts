import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { groupUpdates } from 'buddy-bot'
import { runUpdates, selectUpdates, updateOptions } from './buddy-update'

const update = (name: string, currentVersion: string, newVersion: string) => ({ name, currentVersion, newVersion, updateType: 'patch', file: 'package.json', dependencyType: 'dependencies' })
const candidates = [update('patch', '^1.2.3', '1.2.4'), update('minor', '~1.2.3', '1.3.0'), update('major', '1.2.3', '2.0.0')]

test('strategy bounds use versions even when every candidate is labelled patch', () => {
  for (const [strategy, names] of Object.entries({ patch: ['patch'], minor: ['patch', 'minor'], major: ['major'], all: ['patch', 'minor', 'major'] })) {
    const selected = selectUpdates(candidates, updateOptions({ BUDDY_STRATEGY: strategy }))
    expect(selected.map(item => item.name)).toEqual(names)
    expect(selected.map(item => item.updateType)).toEqual(names)
  }
})

test('package selection is exact and intersects the version strategy', () => {
  const options = updateOptions({ BUDDY_PACKAGES: ' patch, major, patch ' })
  expect(selectUpdates(candidates, options).map(item => item.name)).toEqual(['patch'])
  expect(selectUpdates(candidates, updateOptions({ BUDDY_PACKAGES: 'pat' }))).toEqual([])
})

test('pinned, ambiguous, prerelease, same-version and downgrade candidates are retained unchanged', () => {
  for (const [before, after] of [
    ['235036fa0f48bae99b2293df5a3dc35c809b1777', '0.11.62'],
    ['sha256:abc', '2.0.0'], ['v4', 'v5'], ['^3.0.0 || ^4.0.0', '5.57.1'],
    ['workspace:*', '1.0.0'], ['latest', '1.0.0'], ['1.0.0-beta.1', '1.0.0'],
    ['1.0.0', '1.0.0-beta.2'], ['1.0.0', '1.0.0'], ['2.0.0', '1.9.9'],
    ['1.2.3', '1.2.2'], ['9007199254740992.0.0', '9007199254740993.0.0'],
    ['01.2.3', '1.2.4'],
  ]) {
    expect(selectUpdates([update('candidate', before, after)], updateOptions({ BUDDY_STRATEGY: 'all' }))).toEqual([])
  }
  expect(selectUpdates([update('safe', 'v1.2.3', 'v1.2.4')], updateOptions({}))).toHaveLength(1)
})

test('dry run scans but never creates PRs; apply replaces unfiltered groups', async () => {
  let calls = 0
  const created: any[] = []
  const buddy = {
    scanForUpdates: async () => { calls++; return { updates: candidates, groups: [{ updates: candidates }] } },
    createPullRequests: async (scan: any) => { created.push(scan) },
  }
  const preview = await runUpdates(buddy, groupUpdates, updateOptions({}))
  expect(calls).toBe(1)
  expect(created).toEqual([])
  expect(preview.groups.flatMap(group => group.updates).map(item => item.name)).toEqual(['patch'])
  await runUpdates(buddy, groupUpdates, updateOptions({ BUDDY_DRY_RUN: 'false' }))
  expect(created).toHaveLength(1)
  expect(created[0].updates.map((item: any) => item.name)).toEqual(['patch'])
  expect(created[0].groups.flatMap((group: any) => group.updates).map((item: any) => item.name)).toEqual(['patch'])
  await runUpdates(buddy, groupUpdates, updateOptions({ BUDDY_DRY_RUN: 'false', BUDDY_PACKAGES: 'absent' }))
  expect(created).toHaveLength(1)
})

test('invalid options and scanner failures remain visible', async () => {
  expect(() => updateOptions({ BUDDY_STRATEGY: 'typo' })).toThrow()
  expect(() => updateOptions({ BUDDY_DRY_RUN: 'maybe' })).toThrow()
  const neverCreate = async () => { throw new Error('must not create') }
  await expect(runUpdates({ scanForUpdates: async () => { throw new Error('offline') }, createPullRequests: neverCreate }, groupUpdates, updateOptions({}))).rejects.toThrow('offline')
  await expect(runUpdates({ scanForUpdates: async () => ({}), createPullRequests: neverCreate }, groupUpdates, updateOptions({}))).rejects.toThrow('updates array')
  await expect(runUpdates({ scanForUpdates: async () => ({ updates: [{}] }), createPullRequests: neverCreate }, groupUpdates, updateOptions({}))).rejects.toThrow('malformed update')
  await expect(runUpdates({ scanForUpdates: async () => ({ updates: candidates }), createPullRequests: async () => { throw new Error('API failure') } }, groupUpdates, updateOptions({ BUDDY_DRY_RUN: 'false' }))).rejects.toThrow('API failure')
})

test('workflow applies the same guard to dry runs and real updates', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/buddy-bot.yml'), 'utf8')) as any
  const step = workflow.jobs['dependency-update'].steps.find((step: any) => step.name === 'Run Buddy dependency updates')
  expect(step.run.trim()).toBe('bun scripts/buddy-update.ts')
  expect(step.if).toBeUndefined()
  expect(step.env.BUDDY_STRATEGY).toBe("${{ github.event.inputs.strategy || 'patch' }}")
  expect(step.env.BUDDY_PACKAGES).toBe('${{ github.event.inputs.packages }}')
  expect(step.env.BUDDY_DRY_RUN).toBe("${{ github.event.inputs.dry_run || 'false' }}")
})
