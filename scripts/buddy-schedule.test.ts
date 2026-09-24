import { expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/buddy-bot.yml'), 'utf8')) as any
const selector = workflow.jobs['determine-jobs'].steps.find((step: any) => step.id === 'determine')

function select(event: string, schedule = '', job = '') {
  const directory = mkdtempSync(join(tmpdir(), 'craft-buddy-schedule-'))
  try {
    const output = join(directory, 'output')
    // Substitute the old workflow's expressions too, so this executes the
    // actual selector before and after its move to environment variables.
    const script = selector.run
      .replaceAll('${{ github.event_name }}', event)
      .replaceAll('${{ github.event.schedule }}', schedule)
      .replaceAll("${{ github.event.inputs.job || 'all' }}", job || 'all')
    const result = Bun.spawnSync(['/bin/bash', '-eo', 'pipefail', '-c', script], {
      env: { ...process.env, GITHUB_OUTPUT: output, EVENT_NAME: event, EVENT_SCHEDULE: schedule, REQUESTED_JOB: job },
      stdout: 'pipe', stderr: 'pipe',
    })
    const values = Object.fromEntries(readFileSync(output, 'utf8').trim().split('\n').map(line => line.split('=')))
    return { exitCode: result.exitCode, values }
  }
  finally { rmSync(directory, { recursive: true, force: true }) }
}

test('every declared schedule selects exactly its intended job', () => {
  const expected = { '0 * * * *': 'check', '0 3,15 * * *': 'update', '15 3,15 * * *': 'dashboard' }
  expect(workflow.on.schedule.map((item: any) => item.cron).sort()).toEqual(Object.keys(expected).sort())
  for (const [cron, job] of Object.entries(expected)) {
    const result = select('schedule', cron)
    expect(result.exitCode).toBe(0)
    expect(result.values).toEqual({ run_check: String(job === 'check'), run_update: String(job === 'update'), run_dashboard: String(job === 'dashboard') })
  }
})

test('manual dispatch preserves individual jobs and the all/default choice', () => {
  expect(selector.env).toEqual({ EVENT_NAME: '${{ github.event_name }}', EVENT_SCHEDULE: '${{ github.event.schedule }}', REQUESTED_JOB: '${{ github.event.inputs.job }}' })
  expect(readFileSync(join(import.meta.dir, '../.github/workflows/buddy-bot.yml'), 'utf8')).not.toContain('github.event.inputs.pin')
  for (const job of ['', 'all', 'check', 'update', 'dashboard']) {
    const result = select('workflow_dispatch', '', job)
    expect(result.exitCode).toBe(0)
    expect(result.values).toEqual(Object.fromEntries(['check', 'update', 'dashboard'].map(name => [`run_${name}`, String(!job || job === 'all' || name === job)])))
  }
})

test('unknown schedules and jobs fail visibly instead of silently doing nothing', () => {
  expect(select('schedule', '*/1 * * * *').exitCode).not.toBe(0)
  expect(select('workflow_dispatch', '', 'typo').exitCode).not.toBe(0)
})
