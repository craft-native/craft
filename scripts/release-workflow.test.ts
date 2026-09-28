import { expect, test } from 'bun:test'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

type Job = {
  needs?: string | string[]
  if?: string
  uses?: string
  with?: { enforce_high?: boolean }
  steps?: { name?: string, run?: string, uses?: string, env?: Record<string, string> }[]
  strategy?: { matrix: { platform: { name: string, os: string }[] } }
}
const release = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/release.yml'), 'utf8')) as { jobs: Record<string, Job> }
const artifactDownload = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
const needs = (job: Job) => typeof job.needs === 'string' ? [job.needs] : job.needs ?? []
const steps = (job: Job) => job.steps?.map(step => step.run ?? '').join('\n') ?? ''

test('every publishing path depends on release identity validation', () => {
  for (const name of ['pantry', 'npm', 'release-sbom', 'verify-release', 'verify-macos-downloads'])
    expect(needs(release.jobs[name])).toContain('validate-release')
  for (const name of ['verify-release', 'verify-macos-downloads'])
    expect(release.jobs[name].if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' }}")
  expect(release.jobs.npm.if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.release-sbom.result == 'success' }}")
  expect(needs(release.jobs.npm)).toContain('release-sbom')
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
  const verify = npm.indexOf('bun scripts/npm-packages.ts --archive-dir "$RUNNER_TEMP/craft-npm-archives"')
  const scan = npm.indexOf('bun scripts/scan-release-artifacts.ts npm "$RUNNER_TEMP/craft-npm-archives" "$RUNNER_TEMP/npm-release-scan"')
  const publish = npm.indexOf('bun scripts/publish-npm-archives.ts "$RUNNER_TEMP/craft-npm-archives"')
  expect(verify).toBeGreaterThan(-1)
  expect(scan).toBeGreaterThan(verify)
  expect(publish).toBeGreaterThan(scan)
  expect(steps(release.jobs.npm)).not.toContain('pantry publish --npm')
  expect(release.jobs.npm.steps!.find(step => step.name === 'Publish scanned npm archives')?.env?.NODE_AUTH_TOKEN).toBe('${{ secrets.NPM_TOKEN }}')
  const native = release.jobs.pantry.steps!
  expect(native.findIndex(step => step.name === 'Scan binaries prepared for publication')).toBeGreaterThan(native.findIndex(step => step.name === 'Notarize macOS binaries'))
  expect(native.findIndex(step => step.name === 'Publish & Release')).toBeGreaterThan(native.findIndex(step => step.name === 'Scan binaries prepared for publication'))
  expect(native.find(step => step.name === 'Scan binaries prepared for publication')?.run)
    .toBe('bun scripts/scan-release-artifacts.ts "$CRAFT_PLATFORM" packages/zig/zig-out "$RUNNER_TEMP/native-release-scan"')
  expect(native.filter(step => step.uses === './.github/actions/setup-release-scanners')).toHaveLength(1)
  expect(release.jobs.npm.steps!.filter(step => step.uses === './.github/actions/setup-release-scanners')).toHaveLength(1)
  expect(release.jobs['verify-macos-downloads'].strategy?.matrix.platform).toEqual([
    { os: 'macos-15', name: 'darwin-arm64' },
    { os: 'macos-15-intel', name: 'darwin-x64' },
  ])
  expect(steps(release.jobs['verify-macos-downloads'])).toContain('scripts/verify-macos-release.ts')
  expect(release.jobs['release-sbom'].uses).toBe('./.github/workflows/sbom.yml')
  expect(release.jobs['release-sbom'].with?.enforce_high).toBe(false)
  expect(needs(release.jobs.pantry)).toContain('release-sbom')
  expect(steps(release.jobs.pantry)).toContain('bun install --frozen-lockfile')
  expect(steps(release.jobs.npm)).toContain('bun install --frozen-lockfile')
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

test('SBOM generation validates required documents before uploading artifacts', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/sbom.yml'), 'utf8')) as { jobs: Record<string, Job> }
  const generate = workflow.jobs.generate.steps!
  expect(generate.find(step => step.name === 'Install dependencies')?.run).toBe('bun install --frozen-lockfile')
  const validation = generate.findIndex(step => step.name === 'Validate SBOMs')
  const upload = generate.findIndex(step => step.uses?.startsWith('actions/upload-artifact@'))
  expect(validation).toBeGreaterThan(-1)
  expect(upload).toBeGreaterThan(validation)
  const command = generate[validation]!.run!
  expect(command).toContain('bun scripts/verify-sbom.ts sbom "v$VERSION"')
  expect(command).toContain("require('./package.json').version")
  expect(command).not.toContain('||')
  const scan = workflow.jobs['vulnerability-scan'].steps!.find(step => step.name === 'Scan and validate vulnerability report')
  expect(scan?.env?.CRAFT_FAIL_HIGH).toBe('${{ inputs.enforce_high || false }}')
  expect(workflow.jobs['vulnerability-scan'].steps!.find(step => step.uses?.startsWith('actions/download-artifact@'))?.uses).toBe(artifactDownload)
  expect(release.jobs['attach-release-sbom'].steps!.find(step => step.uses?.startsWith('actions/download-artifact@'))?.uses).toBe(artifactDownload)
})

// A composite action under .github/actions is setup: it clones pinned
// dependencies, installs a toolchain, and returns early when the work is
// already done. Running one twice in a job is therefore always waste rather
// than intent, and it happens by accident when two pull requests insert steps
// into the same region. Repeating a published action can be deliberate --
// uploading two artifacts, say -- so only local ones are checked here.
test('no job runs the same local composite action twice', () => {
  for (const file of ['ci.yml', 'release.yml', 'sbom.yml', 'mobile-e2e.yml']) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/', file), 'utf8')) as { jobs: Record<string, Job> }
    for (const [name, job] of Object.entries(workflow.jobs)) {
      const local = (job.steps ?? []).map(step => step.uses).filter((uses): uses is string => uses?.startsWith('./') ?? false)
      expect(new Set(local).size, `${file} job ${name} repeats a local action: ${local.join(', ')}`).toBe(local.length)
    }
  }
})

test('every workflow names its bun test files as paths, not filters', () => {
  // `bun test scripts/x.test.ts` is a substring FILTER: Bun walks the whole
  // repository, pantry/ included, to match it. Under the pinned Bun 1.3.14 that
  // walk leaves Bun.spawnSync unable to capture a child's output - /bin/echo
  // came back empty with exit 1 - so the release's "Verify standalone macOS
  // launch" step failed on a binary that launches fine, and v0.0.94 shipped no
  // macOS build. `./scripts/x.test.ts` is a path and runs only that file.
  for (const file of ['ci.yml', 'release.yml', 'sbom.yml', 'mobile-e2e.yml']) {
    const text = readFileSync(join(import.meta.dir, '../.github/workflows/', file), 'utf8')
    for (const line of text.split('\n').filter(l => /\bbun test\b/.test(l))) {
      const files = line.replace(/.*\bbun test\b/, '').trim().split(/\s+/).filter(arg => /\.(?:ts|tsx|js)$/.test(arg))
      for (const arg of files)
        expect(arg.startsWith('./') || arg.startsWith('/'), `${file}: \`${line.trim()}\` passes ${arg} as a filter; write ./${arg}`).toBe(true)
    }
  }
})

test('every run script in every workflow is valid bash', () => {
  // 5d65a10 dropped the `done` closing the notarization loop in release.yml.
  // Nothing parses a run script until a runner executes it, and the step only
  // runs on a macOS release after signing and the launch check - so the first
  // sign was v0.0.95's macOS build failing with "syntax error: unexpected end
  // of file" after everything before it had passed.
  for (const file of ['ci.yml', 'release.yml', 'sbom.yml', 'mobile-e2e.yml']) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/', file), 'utf8')) as { jobs: Record<string, Job & { defaults?: { run?: { shell?: string } } }> }
    for (const [name, job] of Object.entries(workflow.jobs)) {
      for (const step of job.steps ?? []) {
        if (!step.run || (step as { shell?: string }).shell === 'pwsh' || (step as { shell?: string }).shell === 'powershell')
          continue
        // Actions substitutes `${{ ... }}` before bash sees the script.
        const script = step.run.replace(/\$\{\{[\s\S]*?\}\}/g, 'X')
        const check = Bun.spawnSync(['bash', '-n'], { stdin: new TextEncoder().encode(script), stderr: 'pipe' })
        expect(check.stderr.toString(), `${file} job ${name} step "${step.name ?? step.run.slice(0, 40)}"`).toBe('')
      }
    }
  }
})
