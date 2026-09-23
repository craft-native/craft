import { expect, test } from 'bun:test'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

type Job = {
  needs?: string | string[]
  if?: string
  uses?: string
  steps?: { name?: string, run?: string, uses?: string }[]
  strategy?: { matrix: { platform: { name: string, os: string }[] } }
}
const release = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/release.yml'), 'utf8')) as { jobs: Record<string, Job> }
const needs = (job: Job) => typeof job.needs === 'string' ? [job.needs] : job.needs ?? []
const steps = (job: Job) => job.steps?.map(step => step.run ?? '').join('\n') ?? ''

test('every publishing path depends on release identity validation', () => {
  for (const name of ['pantry', 'npm', 'release-sbom', 'verify-release', 'verify-macos-downloads'])
    expect(needs(release.jobs[name])).toContain('validate-release')
  for (const name of ['npm', 'verify-release', 'verify-macos-downloads'])
    expect(release.jobs[name].if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' }}")
})

test('registry indexing waits for the final manifest, macOS downloads and attached SBOMs', () => {
  const notify = release.jobs['notify-registry']
  expect(notify).toBeDefined()
  expect(needs(notify).sort()).toEqual(['attach-release-sbom', 'verify-macos-downloads', 'verify-release'])
  expect(notify.if).toBeUndefined() // Default success gating: never bypass failed prerequisites.
  expect(steps(notify)).toContain('https://registry.pantry.dev/api/rebuild')
  expect(steps(release.jobs['verify-release'])).not.toContain('/api/rebuild')
})

test('npm publication follows artifact validation, and macOS downloads run on both matching architectures', () => {
  const npm = release.jobs.npm.steps!.map(step => step.run ?? '')
  const verify = npm.indexOf('bun run verify:npm')
  expect(verify).toBeGreaterThan(-1)
  expect(npm.indexOf('pantry publish --npm --access public')).toBeGreaterThan(verify)
  expect(release.jobs['verify-macos-downloads'].strategy?.matrix.platform).toEqual([
    { os: 'macos-15', name: 'darwin-arm64' },
    { os: 'macos-15-intel', name: 'darwin-x64' },
  ])
  expect(steps(release.jobs['verify-macos-downloads'])).toContain('scripts/verify-macos-release.ts')
  expect(release.jobs['release-sbom'].uses).toBe('./.github/workflows/sbom.yml')
  expect(needs(release.jobs['attach-release-sbom'])).toContain('release-sbom')
  expect(steps(release.jobs['attach-release-sbom'])).toContain('cmp "sbom/$document" "$VERIFY_DIR/$document"')
})

test('a registry network failure remains a visible best-effort warning', () => {
  const command = steps(release.jobs['notify-registry'])
  expect(command).not.toBe('')
  const root = mkdtempSync(join(tmpdir(), 'craft-registry-notify-'))
  try {
    const curl = join(root, 'curl')
    writeFileSync(curl, '#!/bin/sh\nexit 28\n')
    chmodSync(curl, 0o755)
    const result = Bun.spawnSync(['/bin/bash', '-e', '-o', 'pipefail', '-c', command], {
      env: { ...process.env, PATH: root, PANTRY_TOKEN: 'fixture-not-a-token' },
      stdout: 'pipe', stderr: 'pipe',
    })
    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString()).toContain('::warning::Registry request failed')
  }
  finally { rmSync(root, { recursive: true, force: true }) }
})
