import { expect, test } from 'bun:test'
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { requiredReleaseAssets } from './release-manifest'

type Job = {
  needs?: string | string[]
  if?: string
  uses?: string
  with?: { enforce_high?: boolean, 'release-draft'?: string, release?: string, version?: string }
  steps?: { name?: string, run?: string, uses?: string, env?: Record<string, string>, with?: { 'version'?: string, 'bun-version'?: string, 'publish'?: string, 'release-draft'?: string, release?: string, 'package-dir'?: string, install?: string } }[]
  strategy?: { 'fail-fast'?: boolean, matrix: { platform: { name: string, os: string }[] } }
}
const release = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/release.yml'), 'utf8')) as { jobs: Record<string, Job> }
const artifactDownload = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
const stxCompilerCommit = '6151b9e73c03107dc6ed778bd2b68ab769f41f85'
const needs = (job: Job) => typeof job.needs === 'string' ? [job.needs] : job.needs ?? []
const steps = (job: Job) => job.steps?.map(step => step.run ?? '').join('\n') ?? ''

test('mobile device jobs use the same pinned stx compiler', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { jobs: Record<string, Job> }
  const compilerCheckouts = Object.values(workflow.jobs).flatMap(job => job.steps ?? []).filter((step) => {
    const options = step.with as Record<string, string> | undefined
    return options?.repository === 'stacksjs/stx'
  })
  expect(compilerCheckouts).toHaveLength(2)
  for (const step of compilerCheckouts)
    expect((step.with as Record<string, string>).ref).toBe(stxCompilerCommit)
})

test('workflow setup uses a known Pantry CLI instead of resolving latest', () => {
  for (const file of ['ci.yml', 'release.yml', 'mobile-e2e.yml', 'benchmarks.yml', 'binary-size.yml', 'native-lifecycle.yml']) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/', file), 'utf8')) as { jobs: Record<string, Job> }
    for (const [name, job] of Object.entries(workflow.jobs)) {
      for (const step of job.steps ?? []) {
        if (step.uses?.startsWith('pantry-pm/pantry/packages/action@'))
          expect(step.with?.version, `${file} ${name} must pin Pantry CLI`).toBe('0.11.64')
      }
    }
  }
})

test('jobs that only run Bun get Bun alone, not the pinned Zig they cannot always download', () => {
  // Setup Pantry installs every pinned system package. The pinned Zig dev build
  // has no Intel-Mac download once ziglang.org prunes it, which failed v0.0.114
  // in two jobs that compile nothing.
  const bunVersion = String((Bun.YAML.parse(readFileSync(join(import.meta.dir, '../deps.yaml'), 'utf8')) as { dependencies: Record<string, string> }).dependencies['bun.sh'])
  const lifecycle = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/native-lifecycle.yml'), 'utf8')) as { jobs: Record<string, Job> }
  for (const [file, job] of [['release.yml verify-macos-downloads', release.jobs['verify-macos-downloads']], ['native-lifecycle.yml lifecycle', lifecycle.jobs.lifecycle]] as const) {
    const uses = (job.steps ?? []).map(step => step.uses ?? '')
    expect(uses.some(u => u.startsWith('pantry-pm/pantry/packages/action@')), `${file} must not install Zig`).toBe(false)
    expect((job.steps ?? []).find(step => step.uses === 'oven-sh/setup-bun@v2')?.with?.['bun-version'], `${file} must pin Bun`).toBe(bunVersion)
  }
})

test('every publishing path depends on release identity validation', () => {
  for (const name of ['pantry', 'prepare-npm', 'npm', 'release-sbom', 'verify-release', 'verify-macos-downloads', 'verify-desktop-downloads', 'publish-release', 'publish-pantry'])
    expect(needs(release.jobs[name])).toContain('validate-release')
  for (const name of ['verify-release', 'verify-macos-downloads'])
    expect(release.jobs[name].if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' }}")
  expect(needs(release.jobs['prepare-npm'])).toEqual(['validate-release', 'release-sbom'])
  expect(release.jobs['prepare-npm'].if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.release-sbom.result == 'success' }}")
  expect(needs(release.jobs.npm)).toEqual(['validate-release', 'release-sbom', 'prepare-npm', 'publish-release'])
  expect(release.jobs.npm.if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.release-sbom.result == 'success' && needs.prepare-npm.result == 'success' && needs.publish-release.result == 'success' }}")
})

test('registry indexing waits for the public release and all of its verification gates', () => {
  const notify = release.jobs['notify-registry']
  expect(notify).toBeDefined()
  expect(needs(notify)).toEqual(['publish-release', 'publish-pantry'])
  expect(needs(release.jobs['publish-release']).sort()).toEqual(['attach-release-sbom', 'prepare-npm', 'validate-release', 'verify-desktop-downloads', 'verify-macos-downloads', 'verify-release'])
  expect(release.jobs['publish-release'].if).toBeUndefined() // A failed or skipped gate cannot publish a draft.
  expect(notify.if).toBeUndefined() // Default success gating: never bypass failed prerequisites.
  expect(steps(notify)).toContain('https://registry.pantry.dev/api/rebuild')
  expect(steps(notify)).toContain('All platform archives and release SBOMs verified.')
  expect(notify.steps!.find(step => step.name === 'Announce only the complete public release')?.env?.DISCORD_WEBHOOK_URL).toBe('${{ secrets.DISCORD_WEBHOOK_URL }}')
  expect(steps(release.jobs['verify-release'])).not.toContain('/api/rebuild')
  const stage = release.jobs.pantry.steps!.find(step => step.name === 'Stage draft release')
  expect((stage?.with as Record<string, unknown>)?.['discord-webhook']).toBeUndefined()
})

test('npm publication follows artifact validation, and macOS downloads run on both matching architectures', () => {
  const prepare = release.jobs['prepare-npm'].steps!
  const verify = prepare.findIndex(step => step.run === 'bun scripts/npm-packages.ts --archive-dir "$RUNNER_TEMP/craft-npm-archives"')
  const scan = prepare.findIndex(step => step.run === 'bun scripts/scan-release-artifacts.ts npm "$RUNNER_TEMP/craft-npm-archives" "$RUNNER_TEMP/npm-release-scan"')
  const upload = prepare.findIndex(step => step.name === 'Stage verified npm archives privately')
  const npm = release.jobs.npm.steps!
  const download = npm.findIndex(step => step.name === 'Download verified npm archives')
  const publish = npm.findIndex(step => step.run === 'bun scripts/publish-npm-archives.ts "$RUNNER_TEMP/craft-npm-archives"')
  expect(verify).toBeGreaterThan(-1)
  expect(scan).toBeGreaterThan(verify)
  expect(upload).toBeGreaterThan(scan)
  expect(prepare[upload]?.uses).toBe('actions/upload-artifact@v4')
  expect(prepare[upload]?.with).toMatchObject({ name: 'npm-archives', path: '${{ runner.temp }}/craft-npm-archives/', 'if-no-files-found': 'error', overwrite: true })
  expect(download).toBeGreaterThan(-1)
  expect(npm[download]?.uses).toBe(artifactDownload)
  expect(npm[download]?.with).toMatchObject({ name: 'npm-archives', path: '${{ runner.temp }}/craft-npm-archives' })
  expect(publish).toBeGreaterThan(download)
  expect(steps(release.jobs.npm)).not.toContain('pantry publish --npm')
  expect(steps(release.jobs.npm)).not.toContain('npm-packages.ts')
  expect(steps(release.jobs['prepare-npm'])).not.toContain('publish-npm-archives.ts')
  expect(release.jobs.npm.steps!.find(step => step.name === 'Publish scanned npm archives')?.env?.NODE_AUTH_TOKEN).toBe('${{ secrets.NPM_TOKEN }}')
  const native = release.jobs.pantry.steps!
  expect(native.findIndex(step => step.name === 'Scan binaries prepared for publication')).toBeGreaterThan(native.findIndex(step => step.name === 'Notarize macOS binaries'))
  expect(native.findIndex(step => step.name === 'Stage draft release')).toBeGreaterThan(native.findIndex(step => step.name === 'Scan binaries prepared for publication'))
  expect(native.find(step => step.name === 'Scan binaries prepared for publication')?.run)
    .toBe('bun scripts/scan-release-artifacts.ts "$CRAFT_PLATFORM" packages/zig/zig-out "$RUNNER_TEMP/native-release-scan"')
  expect(native.filter(step => step.uses === './.github/actions/setup-release-scanners')).toHaveLength(1)
  expect(prepare.filter(step => step.uses === './.github/actions/setup-release-scanners')).toHaveLength(1)
  expect(npm.filter(step => step.uses === './.github/actions/setup-release-scanners')).toHaveLength(0)
  expect(release.jobs['verify-macos-downloads'].strategy?.matrix.platform).toEqual([
    { os: 'macos-15', name: 'darwin-arm64' },
    { os: 'macos-15-intel', name: 'darwin-x64' },
  ])
  expect(steps(release.jobs['verify-macos-downloads'])).toContain('scripts/verify-macos-release.ts')
  expect(release.jobs['verify-desktop-downloads'].strategy?.matrix.platform).toEqual([
    { os: 'ubuntu-latest', name: 'linux-x64' },
    { os: 'windows-2025', name: 'windows-x64' },
  ])
  expect(steps(release.jobs['verify-desktop-downloads'])).toContain('craft-$PLATFORM.zip')
  expect(steps(release.jobs['verify-desktop-downloads'])).toContain('scripts/verify-native-startup.ts')
  expect(steps(release.jobs['verify-desktop-downloads'])).toContain('WebView2Loader.dll')
  expect(release.jobs['release-sbom'].uses).toBe('./.github/workflows/sbom.yml')
  expect(release.jobs['release-sbom'].with?.enforce_high).toBe(false)
  expect(needs(release.jobs.pantry)).toContain('release-sbom')
  expect(steps(release.jobs.pantry)).toContain('bun install --frozen-lockfile')
  expect(steps(release.jobs['prepare-npm'])).toContain('bun install --frozen-lockfile')
  expect(needs(release.jobs['attach-release-sbom'])).toContain('release-sbom')
  expect(steps(release.jobs['attach-release-sbom'])).toContain('cmp "sbom/$document" "$VERIFY_DIR/$document"')
})

test('Windows release stages the pinned WebView2 loader before scanning and draft upload', () => {
  const native = release.jobs.pantry.steps!
  const staged = native.findIndex(step => step.name === 'Stage Windows WebView2 loader')
  const scan = native.findIndex(step => step.name === 'Scan binaries prepared for publication')
  const publish = native.findIndex(step => step.name === 'Stage draft release')
  expect(staged).toBeGreaterThan(native.findIndex(step => step.name === 'Cross-compile additional targets (Linux)'))
  expect(scan).toBeGreaterThan(staged)
  expect(publish).toBeGreaterThan(scan)
  const command = native[staged]?.run ?? ''
  expect(command).toContain('1.0.4191.47')
  expect(command).toContain('f492bbf547d0da329553b6727435b677579b1e9f91cc9e4a1ad029366d5f23d0')
  expect(command).toContain('zig-out/cross/windows-x64/WebView2Loader.dll')
})

test('a failed native leg cannot publish a partial GitHub, Zig, or npm release', () => {
  const stage = release.jobs.pantry.steps!.find(step => step.name === 'Stage draft release')
  expect(release.jobs.pantry.strategy?.['fail-fast']).toBe(false)
  expect(stage?.with?.release).toBe('true')
  expect(stage?.with?.['release-draft']).toBe('true')
  expect(stage?.with?.publish).toBeUndefined()
  expect(release.jobs.pantry.steps!.filter(step => step.with?.publish === 'zig')).toHaveLength(0)
  expect(steps(release.jobs.pantry)).not.toContain('gh release edit')
  expect(steps(release.jobs['verify-release'])).toContain('--json isDraft -q .isDraft')
  const assetPrecheck = steps(release.jobs['verify-release']).match(/REQUIRED="([^"]+)"/)
  expect(assetPrecheck?.[1]?.split(' ')).toEqual([...requiredReleaseAssets])

  const finalizer = release.jobs['publish-release']
  expect(finalizer).toBeDefined()
  expect(finalizer.if).toBeUndefined()
  expect(needs(finalizer)).toContain('verify-release')
  expect(needs(finalizer)).toContain('verify-macos-downloads')
  expect(needs(finalizer)).toContain('verify-desktop-downloads')
  expect(needs(finalizer)).toContain('attach-release-sbom')
  expect(needs(finalizer)).toContain('prepare-npm')
  const verify = finalizer.steps!.findIndex(step => step.name === 'Recheck the draft and its exact staged artifacts')
  const publish = finalizer.steps!.findIndex(step => step.name === 'Publish the complete draft')
  expect(verify).toBeGreaterThan(-1)
  expect(publish).toBeGreaterThan(verify)
  expect(finalizer.steps![verify]?.run).toContain('--json isDraft -q .isDraft')
  expect(finalizer.steps![verify]?.run).toContain('scripts/release-manifest.ts verify')
  expect(finalizer.steps![verify]?.run).toContain('scripts/verify-sbom.ts')
  expect(finalizer.steps![publish]?.run).toContain('--draft=false')
  const registry = release.jobs['publish-pantry']
  expect(registry.if).toBeUndefined()
  expect(needs(registry)).toEqual(['validate-release', 'publish-release'])
  // A native or downloaded-archive failure must not publish npm packages
  // while the GitHub release remains a draft. The explicit npm `if` must
  // check the finalizer result; listing it in `needs` alone is insufficient.
  expect(needs(release.jobs.npm)).toContain('publish-release')
  expect(release.jobs.npm.if).toContain("needs.prepare-npm.result == 'success'")
  expect(release.jobs.npm.if).toContain("needs.publish-release.result == 'success'")
  const zigPublish = registry.steps!.find(step => step.name === 'Publish Zig package')
  expect(zigPublish?.with).toMatchObject({ version: '0.11.64', install: 'false', publish: 'zig', 'package-dir': 'packages/zig' })
  expect(zigPublish?.with?.release).toBeUndefined()
  expect(Object.entries(release.jobs).flatMap(([name, job]) =>
    (job.steps ?? []).filter(step => step.with?.publish === 'zig').map(() => name))).toEqual(['publish-pantry'])
  for (const [name, job] of Object.entries(release.jobs)) {
    if (name !== 'publish-release')
      expect(steps(job), `${name} must not publish the draft`).not.toContain('--draft=false')
  }
})

test('the finalizer refuses a draft missing any required archive without publishing it', () => {
  const command = release.jobs['publish-release'].steps!.find(step => step.name === 'Recheck the draft and its exact staged artifacts')?.run
  const publish = release.jobs['publish-release'].steps!.find(step => step.name === 'Publish the complete draft')?.run
  expect(command).toBeDefined()
  expect(publish).toBeDefined()
  const root = mkdtempSync(join(tmpdir(), 'craft-incomplete-draft-'))
  try {
    const gh = join(root, 'gh')
    const edits = join(root, 'release-edits')
    writeFileSync(gh, `#!/bin/sh
if [ "$2" = view ]; then
  printf 'true\\n'
elif [ "$2" = edit ]; then
  printf '%s\\n' "$*" >> "$CRAFT_TEST_GH_EDITS"
  exit 0
elif [ "$2" = download ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then
      mkdir -p "$2"
      for asset in craft-darwin-arm64.zip craft-darwin-x64.zip craft-linux-x64.zip craft-windows-x64.zip; do
        if [ "$asset" != "$CRAFT_TEST_MISSING_ASSET" ]; then
          printf '%s' "$asset" > "$2/$asset"
        fi
      done
      exit 0
    fi
    shift
  done
fi
exit 1
`)
    chmodSync(gh, 0o755)
    for (const missing of requiredReleaseAssets) {
      const result = Bun.spawnSync(['bash', '-e', '-o', 'pipefail', '-c', `${command}\n${publish}`], {
        cwd: join(import.meta.dir, '..'),
        env: {
          ...process.env,
          PATH: `${root}:${process.env.PATH}`,
          TMPDIR: root,
          GH_TOKEN: 'fixture-not-a-token',
          CRAFT_TEST_GH_EDITS: edits,
          CRAFT_TEST_MISSING_ASSET: missing,
          TAG: 'v0.0.106',
          GITHUB_REPOSITORY: 'craft-native/craft',
          GITHUB_REF_NAME: 'v0.0.106',
          GITHUB_SHA: 'a'.repeat(40),
        },
        stdout: 'pipe', stderr: 'pipe',
      })
      expect(result.exitCode, missing).not.toBe(0)
      expect(result.stderr.toString()).toContain(`Missing release archives: ${missing}`)
      expect(existsSync(edits), `${missing} must not publish`).toBe(false)
    }
  }
  finally { rmSync(root, { recursive: true, force: true }) }
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

test('the post-publication Discord announcement names the complete release', () => {
  const command = release.jobs['notify-registry'].steps!.find(step => step.name === 'Announce only the complete public release')?.run
  expect(command).toBeDefined()
  const root = mkdtempSync(join(tmpdir(), 'craft-release-announcement-'))
  try {
    const curl = join(root, 'curl')
    const calls = join(root, 'curl-args')
    writeFileSync(curl, '#!/bin/sh\nprintf "%s\\n" "$*" > "$CRAFT_TEST_CURL_ARGS"\nprintf 204\n')
    chmodSync(curl, 0o755)
    const result = Bun.spawnSync(['/bin/bash', '-e', '-o', 'pipefail', '-c', command!], {
      env: {
        ...process.env,
        PATH: `${root}:${process.env.PATH}`,
        DISCORD_WEBHOOK_URL: 'https://example.invalid/webhook',
        CRAFT_TEST_CURL_ARGS: calls,
        GITHUB_REPOSITORY: 'craft-native/craft',
        TAG: 'v0.0.106',
      },
      stdout: 'pipe', stderr: 'pipe',
    })
    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString()).toContain('Complete release announced')
    expect(readFileSync(calls, 'utf8')).toContain('craft v0.0.106 — Published')
    expect(readFileSync(calls, 'utf8')).toContain('https://github.com/craft-native/craft/releases/tag/v0.0.106')
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

test('Linux and Windows release binaries target a baseline CPU, not the build runner', () => {
  // A host build compiles for the runner's own CPU; the published binary then
  // dies with SIGILL wherever those extensions are missing (v0.0.108).
  const builds = steps(release.jobs.pantry).split('\n').filter(line => /^\s*zig build\b/.test(line) && !/-Dtarget="\$(?:X64|ARM64)_TARGET"/.test(line))
  expect(builds.length).toBeGreaterThan(0)
  for (const line of builds)
    expect(line, line.trim()).toContain('-Dcpu=baseline')
})
