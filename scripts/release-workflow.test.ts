import { afterAll, expect, test } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { runInNewContext } from 'node:vm'
import { requiredReleaseAssets } from './release-manifest'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'
import { nativeTestResultBundle } from '../packages/ios/scripts/native-test-result'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

type Job = {
  env?: Record<string, string>
  needs?: string | string[]
  if?: string
  uses?: string
  with?: { enforce_high?: boolean, 'release-draft'?: string, release?: string, version?: string }
  steps?: { name?: string, if?: string, run?: string, uses?: string, 'working-directory'?: string, env?: Record<string, string>, with?: { 'version'?: string, 'bun-version'?: string, 'publish'?: string, 'release-draft'?: string, release?: string, 'package-dir'?: string, install?: string } }[]
  strategy?: { 'fail-fast'?: boolean, matrix: { platform: { name: string, os: string }[] } }
}
const release = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/release.yml'), 'utf8')) as { jobs: Record<string, Job> }
const artifactDownload = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
const needs = (job: Job) => typeof job.needs === 'string' ? [job.needs] : job.needs ?? []
const steps = (job: Job) => job.steps?.map(step => step.run ?? '').join('\n') ?? ''

const androidDiskAction = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/actions/prepare-android-disk/action.yml'), 'utf8')) as { runs: { steps: Array<{ run: string }> } }

function rehearseAndroidDisk(envOverrides: Record<string, string> = {}) {
  const dir = createTempDir('craft-android-disk-')
  const workspace = join(dir, 'workspace with spaces')
  const runnerTemp = join(dir, 'runner temp')
  const cleanupLog = join(dir, 'cleanup-args')
  const environmentFile = join(dir, 'github-env')
  mkdirSync(workspace)
  mkdirSync(runnerTemp)
  // Intercept sudo: tests must never delete the host's real toolchains.
  writeFileSync(join(dir, 'sudo'), '#!/bin/bash\nprintf "%s\\n" "$@" >> "$CLEANUP_LOG"\nexit "${MOCK_CLEANUP_EXIT:-0}"\n')
  writeFileSync(join(dir, 'df'), `#!/bin/bash
if [[ "\${MOCK_DF_EXIT:-0}" != "0" ]]; then exit "$MOCK_DF_EXIT"; fi
available="$MOCK_TEMP_KIB"
if [[ "$2" == "$GITHUB_WORKSPACE" ]]; then available="$MOCK_WORKSPACE_KIB"; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/fixture 70000000 1 %s 1%% /fixture\\n' "$available"
`)
  chmodSync(join(dir, 'sudo'), 0o755)
  chmodSync(join(dir, 'df'), 0o755)
  const result = Bun.spawnSync(['bash', '-c', androidDiskAction.runs.steps[0]!.run], {
    env: {
      ...process.env, PATH: `${dir}:${process.env.PATH}`, GITHUB_ACTIONS: 'true',
      RUNNER_ENVIRONMENT: 'github-hosted', RUNNER_OS: 'Linux', RUNNER_TEMP: runnerTemp,
      GITHUB_WORKSPACE: workspace, GITHUB_ENV: environmentFile, CLEANUP_LOG: cleanupLog,
      MOCK_TEMP_KIB: '25000000', MOCK_WORKSPACE_KIB: '25000000', ...envOverrides,
    },
  })
  return { result, runnerTemp, environment: existsSync(environmentFile) ? readFileSync(environmentFile, 'utf8') : '', cleanup: existsSync(cleanupLog) ? readFileSync(cleanupLog, 'utf8').trim().split('\n') : [] }
}

test('Android disk preparation routes Bun temporary data onto the checked runner volume', () => {
  const { result, runnerTemp, environment } = rehearseAndroidDisk({ TMPDIR: '/tmp' })
  expect(result.exitCode).toBe(0)
  const temporary = /^TMPDIR=(.+)$/m.exec(environment)?.[1]
  expect(temporary).toBeDefined()
  expect(temporary!.startsWith(`${runnerTemp}/craft-android-tmp.`)).toBe(true)
  expect(existsSync(temporary!)).toBe(true)
  const child = Bun.spawnSync([process.execPath, '-e', 'const { tmpdir } = require("node:os"); const { mkdtempSync } = require("node:fs"); console.log(mkdtempSync(require("node:path").join(tmpdir(), "craft-device-")))'], {
    env: { ...process.env, TMPDIR: temporary! },
  })
  expect(child.exitCode).toBe(0)
  expect(child.stdout.toString().trim().startsWith(`${temporary}/craft-device-`)).toBe(true)
})

test('Android disk preparation refuses a missing environment destination before deleting tools', () => {
  const { result, cleanup, environment } = rehearseAndroidDisk({ GITHUB_ENV: '' })
  expect(result.exitCode).not.toBe(0)
  expect(cleanup).toEqual([])
  expect(environment).toBe('')
})

test('Android disk preparation deletes only the explicit unused hosted toolchains', () => {
  const { result, cleanup } = rehearseAndroidDisk()
  expect(result.exitCode).toBe(0)
  expect(cleanup).toEqual(['rm', '-rf', '--', '/usr/share/dotnet', '/opt/ghc', '/usr/local/.ghcup', '/usr/local/swift', '/opt/hostedtoolcache/CodeQL'])
})

test.each([
  { RUNNER_ENVIRONMENT: 'self-hosted' }, { RUNNER_ENVIRONMENT: '' },
  { RUNNER_OS: 'macOS' }, { GITHUB_ACTIONS: 'false' },
])('Android disk preparation refuses non-hosted Linux contexts before cleanup: %j', (env) => {
  const { result, cleanup, environment } = rehearseAndroidDisk(env)
  expect(result.exitCode).not.toBe(0)
  expect(cleanup).toEqual([])
  expect(environment).toBe('')
  expect(result.stdout.toString()).toContain('requires a GitHub-hosted Linux runner')
})

test.each([
  { MOCK_TEMP_KIB: '20971519' }, { MOCK_WORKSPACE_KIB: '20971519' },
  { MOCK_TEMP_KIB: 'not-a-number' }, { MOCK_WORKSPACE_KIB: '' },
])('Android disk preparation rejects insufficient or unreadable capacity on either volume: %j', (env) => {
  const { result, environment } = rehearseAndroidDisk(env)
  expect(result.exitCode).not.toBe(0)
  expect(result.stdout.toString()).toContain('needs at least 20 GiB free')
  expect(environment).toBe('')
})

test('Android disk preparation accepts the exact capacity floor and propagates command failures', () => {
  expect(rehearseAndroidDisk({ MOCK_TEMP_KIB: '20971520', MOCK_WORKSPACE_KIB: '20971520' }).result.exitCode).toBe(0)
  expect(rehearseAndroidDisk({ MOCK_CLEANUP_EXIT: '17' }).result.exitCode).toBe(17)
  const dfFailure = rehearseAndroidDisk({ MOCK_DF_EXIT: '19' })
  expect(dfFailure.result.exitCode).toBe(19)
  expect(dfFailure.cleanup).toEqual([])
})

test('SDK and native Android acceptance reserve disk before installing toolchains', () => {
  for (const [file, names] of [
    ['ci.yml', ['android-sdk-emulator', 'android-software-cold-provisioning-diagnostic']],
    ['mobile-e2e.yml', ['android-navigation']],
  ] as const) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows', file), 'utf8')) as { jobs: Record<string, Job> }
    for (const name of names) {
      const jobSteps = workflow.jobs[name]!.steps!
      expect(jobSteps[0]!.uses).toBe('actions/checkout@v6')
      expect(jobSteps[1]!.uses).toBe('./.github/actions/prepare-android-disk')
      expect(jobSteps[1]!.if).toBeUndefined()
      expect(jobSteps.filter(step => step.uses === './.github/actions/prepare-android-disk')).toHaveLength(1)
    }
  }
})

test('release rehearsals include the actual host-neutral native CI contract', () => {
  const ci = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/ci.yml'), 'utf8')) as { jobs: Record<string, Job> }
  const contract = ci.jobs.lint.steps?.find(step => step.name === 'Test host-neutral native renderer contract')?.run
  expect(contract).toBeDefined()
  const invocation = contract?.match(/^bun test (\.\/scripts\/[\w-]+\.test\.ts)$/)
  expect(invocation).not.toBeNull()
  const manifest = JSON.parse(readFileSync(join(import.meta.dir, '../package.json'), 'utf8'))
  expect(manifest.scripts['test:release'].split(/\s+/)).toContain(invocation![1])
})

test('Win32 Vulkan publication requires native command ownership and displayed scene acceptance', () => {
  const ci = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/ci.yml'), 'utf8')) as { jobs: Record<string, Job & { 'runs-on'?: string, 'continue-on-error'?: boolean }> }
  const job = ci.jobs['windows-native-vulkan']
  expect(job['runs-on']).toBe('windows-2025')
  expect(job['continue-on-error']).not.toBe(true)
  expect(steps(job)).toContain('zig cc -target x86_64-windows-gnu -O2 -municode scripts/native/windows-command-owner.c')
  expect(steps(job)).toContain('bun test ./scripts/native/windows-command.test.ts')
  expect(steps(job)).toContain('bun scripts/test-vulkan-surface-windows.ts --owner')
  expect(needs(ci.jobs['publish-commit'])).toContain('windows-native-vulkan')
  const evidence = job.steps?.find(step => step.name === 'Retain native Win32 Vulkan display evidence')
  expect(evidence?.if).toBe('always()')
})

test('the Vulkan ABI matrix requires managed Git on every platform and still runs the exact compiler probe', () => {
  const ci = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/ci.yml'), 'utf8')) as any
  const job = ci.jobs['vulkan-abi']
  const platforms = job.strategy.matrix.include as Array<{ os: string, tools: string }>
  expect(platforms.map(platform => platform.os)).toEqual(['ubuntu-latest', 'macos-latest', 'windows-latest'])
  for (const platform of platforms) {
    expect(platform.tools).toContain('bun.com@1.4.2')
    expect(platform.tools).toContain('ziglang.org@0.18.0-dev.146+35accc06e')
    expect(platform.tools).toContain('git-scm.org@2.53.0')
  }
  expect(job.steps.find((step: any) => step.name === 'Install the pinned ABI toolchain').with.packages).toBe('${{ matrix.tools }}')
  expect(steps(job)).toContain('zig build test:vulkan-abi')
  expect(steps(job)).toContain('bun scripts/managed-git.ts --verify')
  const dependencies = readFileSync(join(import.meta.dir, '../.github/actions/first-party-zig-deps/action.yml'), 'utf8')
  expect(dependencies).toContain('bun scripts/zig.ts --core build --fetch')
  expect(dependencies).not.toContain('git -C')
  expect(steps(job)).toContain('bun scripts/verify-zig-package-consumer.ts')
  const checkout = job.steps.find((step: any) => step.name === 'Check out the exact Khronos SDK headers').run
  expect(checkout).toContain('bun scripts/managed-git.ts -C .zig-cache/vulkan-headers fetch --depth 1 origin 6802bb4733b63ed5efd3adb308a6c885ef180ea1')
  expect(checkout).toContain('bun scripts/managed-git.ts -C .zig-cache/vulkan-headers checkout --detach FETCH_HEAD')
  expect(checkout).toContain('rev-parse HEAD')
  expect(job.steps.find((step: any) => step.name === 'Execute the independent SDK ABI probe and C callback').if).toBeUndefined()
})

test('macOS signing reads credentials from the declared Stacks CLI, not the shared buddy binary', () => {
  const loader = release.jobs.pantry.steps?.find(step => step.name === 'Load macOS release credentials')?.run
  expect(loader).toBeTruthy()
  const dir = createTempDir('craft-signing-cli-')
  const executable = join(dir, 'bun')
  const output = join(dir, 'github-env')
  try {
    writeFileSync(executable, '#!/bin/sh\n[ "$1" = "node_modules/@stacksjs/buddy/dist/cli.js" ] || exit 22\n[ "$2" = "env:get" ] || exit 23\nprintf "fixture-value"\n')
    chmodSync(executable, 0o755)
    const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, GITHUB_ENV: output, DOTENV_PRIVATE_KEY_PRODUCTION: 'fixture-key' }
    const success = Bun.spawnSync(['bash', '-euo', 'pipefail', '-c', loader!], { env })
    expect(success.exitCode).toBe(0)
    expect(readFileSync(output, 'utf8')).toContain('APPLE_TEAM_ID=fixture-value\nSIGNING_AVAILABLE=true')
    // A failed getter must stop before its diagnostic can be written as a secret.
    writeFileSync(executable, '#!/bin/sh\nprintf "getter failed"\nexit 17\n')
    writeFileSync(output, '')
    const failure = Bun.spawnSync(['bash', '-euo', 'pipefail', '-c', loader!], { env })
    expect(failure.exitCode).not.toBe(0)
    expect(readFileSync(output, 'utf8')).toBe('')
  }
  finally { rmSync(dir, { recursive: true, force: true }) }
})

test('shared native layout changes trigger mobile acceptance for pushes and pull requests', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as {
    on: { push: { paths: string[] }, pull_request: { paths: string[] } }
  }
  for (const event of ['push', 'pull_request'] as const) {
    const matchesLayout = workflow.on[event].paths.some(pattern => new Bun.Glob(pattern).match('packages/zig/src/native_layout.zig'))
    expect(matchesLayout, `${event} must exercise the shared iOS and Android layout engine`).toBe(true)
  }
})

test.each(['microphone', 'location', 'kTCCServiceSpeechRecognition'])('the Zig slice stops when %s cannot be granted', (service) => {
  const fixture = readFileSync(join(import.meta.dir, '../packages/ios/fixtures/zig-slice/build-and-run.sh'), 'utf8')
  const grants = fixture.split('\n').filter(line => line.startsWith('xcrun simctl privacy ')).join('\n')
  expect(grants).toBeTruthy()
  const dir = createTempDir('craft-slice-permissions-')
  const executable = join(dir, 'xcrun')
  writeFileSync(executable, '#!/bin/sh\nif [ "$5" = "$FAILED_SERVICE" ]; then\n  printf "permission service unavailable\\n" >&2\n  exit 23\nfi\n')
  chmodSync(executable, 0o755)
  const result = Bun.spawnSync(['bash', '-euo', 'pipefail', '-c', `${grants}\nprintf 'launched app'`], {
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, UDID: 'fixture-device', BUNDLE_ID: 'app.craft.slice', FAILED_SERVICE: service },
  })
  expect(result.exitCode).toBe(23)
  expect(result.stderr.toString()).toContain('permission service unavailable')
  expect(result.stdout.toString()).not.toContain('launched app')
})

test.each(['navigation', 'uikit'])('interrupted %s results survive temporary workspace cleanup', (suite) => {
  const workspace = createTempDir('craft-navigation-work-')
  const evidence = createTempDir('craft-navigation-evidence-')
  const destination = join(evidence, 'ios-native', `${suite}.xcresult`)
  const actual = nativeTestResultBundle(workspace, destination)
  expect(existsSync(actual)).toBe(false)
  mkdirSync(actual)
  writeFileSync(join(actual, 'progress.log'), 'unfinished XCTest evidence')
  rmSync(workspace, { recursive: true, force: true })
  expect(existsSync(destination)).toBe(true)
  expect(readFileSync(join(destination, 'progress.log'), 'utf8')).toBe('unfinished XCTest evidence')
})

test.each(['ci.yml', 'mobile-e2e.yml'])('%s lets Main acceptance finish while superseding pull request runs', (file) => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows', file), 'utf8')) as {
    concurrency: { 'group': string, 'cancel-in-progress': boolean | string, 'queue'?: string }
  }
  const policy = workflow.concurrency
  const expression = String(policy['cancel-in-progress']).replace(/^\$\{\{\s*|\s*\}\}$/g, '')
  for (const [event, cancel] of [['push', false], ['workflow_dispatch', false], ['pull_request', true]] as const)
    expect(runInNewContext(expression, { github: { event_name: event } }), `${file}: ${event}`).toBe(cancel)
  // Keep one active run and GitHub's single pending slot, without adding runners.
  expect(policy.group).toContain('github.ref')
  expect(policy.queue ?? 'single').toBe('single')
})

test('cold-provisioning measurements cannot replace pending release acceptance', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/ci.yml'), 'utf8')) as { concurrency: { group: string } }
  const group = (diagnostic: boolean) => workflow.concurrency.group.replace(/\$\{\{.*?\}\}/g, expression => String(runInNewContext(expression.slice(3, -2), {
    inputs: { software_cold_provisioning_diagnostic: diagnostic },
    github: { workflow: 'CI', head_ref: '', ref: 'refs/heads/main' },
  })))
  expect(group(true)).not.toBe(group(false))
})

test('a release commit keeps its own acceptance run, which later pushes cannot replace', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/ci.yml'), 'utf8')) as { concurrency: { group: string } }
  const group = (message: string, sha: string, event = 'push') => workflow.concurrency.group.replace(/\$\{\{.*?\}\}/g, expression => String(runInNewContext(expression.slice(3, -2), {
    inputs: { software_cold_provisioning_diagnostic: false },
    startsWith: (text: string, prefix: string) => String(text ?? '').startsWith(prefix),
    github: { workflow: 'CI', head_ref: '', ref: 'refs/heads/main', sha, event_name: event, event: { head_commit: { message } } },
  })))
  // Ordinary pushes share Main's single pending slot, as before.
  expect(group('feat: a change', 'a1')).toBe(group('fix: another', 'b2'))
  // Each release commit has a slot of its own, so the next push cannot drop the run its Releaser waits for.
  expect(group('chore: release v0.0.409', 'c3')).not.toBe(group('feat: a change', 'a1'))
  expect(group('chore: release v0.0.409', 'c3')).not.toBe(group('chore: release v0.0.410', 'd4'))
  // A pull request titled like a release is still a pull request.
  expect(group('chore: release v0.0.409', 'e5', 'pull_request')).toBe(group('feat: a change', 'f6', 'pull_request'))
})

test('mobile device jobs use the same released stx compiler version', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { env: Record<string, string>, jobs: Record<string, Job> }
  expect(workflow.env.STX_COMPILER_VERSION).toMatch(/^v\d+\.\d+\.\d+$/)
  const compilerCheckouts = Object.values(workflow.jobs).flatMap(job => job.steps ?? []).filter((step) => {
    const options = step.with as Record<string, string> | undefined
    return options?.repository === 'stacksjs/stx'
  })
  expect(compilerCheckouts).toHaveLength(4)
  for (const step of compilerCheckouts)
    expect((step.with as Record<string, string>).ref).toBe('${{ env.STX_COMPILER_VERSION }}')
  const compilerInstalls = Object.values(workflow.jobs).flatMap(job => job.steps ?? [])
    .filter(step => step['working-directory'] === '.stx-compiler')
  expect(compilerInstalls).toHaveLength(4)
  for (const step of compilerInstalls)
    expect(step.run).toBe('bun install --frozen-lockfile')
})

test('native compiler jobs use a supported Bun and preserve its frozen lockfile', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { jobs: Record<string, Job> }
  for (const name of ['ios-native', 'ios-hybrid', 'android-emulator', 'android-navigation']) {
    const job = workflow.jobs[name]
    const jobSteps = job.steps ?? []
    const tool = jobSteps.findIndex(step => step.uses === 'oven-sh/setup-bun@v2' && step.with?.['bun-version'] === '1.4.3')
    const install = jobSteps.findIndex(step => step['working-directory'] === '.stx-compiler')
    expect(tool).toBeGreaterThanOrEqual(0)
    expect(install).toBeGreaterThan(tool)
    expect(jobSteps[install].run).toBe('bun install --frozen-lockfile')
    expect(steps(job)).not.toContain('bun install --no-save')
  }
})

test('native iOS suites and protocol checks have independent required jobs', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { jobs: Record<string, Job> }
  const native = workflow.jobs['ios-native']
  const protocol = workflow.jobs['ios-simulator']
  const hybrid = workflow.jobs['ios-hybrid']
  expect(needs(native)).toEqual([])
  expect(needs(protocol)).toEqual([])
  expect(steps(native)).toContain('test-native-render.ts')
  expect(steps(native)).toContain('test-native-navigation.ts')
  expect(needs(hybrid)).toEqual([])
  expect(steps(hybrid)).toContain('test-hybrid-navigation.ts')
  expect(steps(hybrid)).not.toContain('zig build')
  expect(steps(protocol)).not.toContain('test-hybrid-navigation.ts')
  expect(steps(protocol)).not.toContain('.stx-compiler')
  expect(steps(protocol)).toContain('scripts/mobile-e2e.ts --platform ios')
  expect(steps(protocol)).not.toContain('test-native-render.ts')
  expect(steps(protocol)).not.toContain('test-native-navigation.ts')
  const summary = workflow.jobs['mobile-summary']
  expect(needs(summary)).toContain('ios-native')
  expect(needs(summary)).toContain('ios-simulator')
  expect(needs(summary)).toContain('ios-hybrid')
  expect(summary.steps?.find(step => step.name === 'Fail if any leg failed')?.if).toContain('needs.ios-hybrid.result')
  expect(summary.steps?.find(step => step.name === 'Fail if any leg failed')?.if).toContain('needs.ios-native.result')
  for (const name of ['ios-native', 'ios-hybrid', 'ios-simulator', 'ios-zig-slice'])
    expect(workflow.jobs[name].env?.DEVELOPER_DIR).toBe('/Applications/Xcode_26.2.app/Contents/Developer')
})

test('focused native diagnostics retain their service gates and complete releases retain every required leg', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as {
    on: { workflow_dispatch: { inputs: { scope: { options: string[] } } } }
    jobs: Record<string, Job>
  }
  expect(workflow.on.workflow_dispatch.inputs.scope.options).toContain('ios-hybrid')
  expect(workflow.on.workflow_dispatch.inputs.scope.options).toContain('ios-checkpoints')
  const legs = ['media-cache', 'harness', 'ios-native', 'ios-metal', 'ios-hybrid', 'ios-simulator', 'android-emulator', 'ios-zig-slice', 'android-navigation']
  const evaluate = (expression: string | undefined, scope: string, outcomes: Record<string, string> = {}) => expression === undefined || runInNewContext(expression.replace(/^\$\{\{\s*|\s*\}\}$/g, '').replace(/\bneeds\.([\w-]+)\.result/g, 'needs["$1"].result'), {
    inputs: { scope },
    needs: Object.fromEntries(legs.map(name => [name, { result: outcomes[name] ?? 'success' }])),
    fromJSON: JSON.parse,
    contains: (values: string[], value: string) => values.includes(value),
  }, { timeout: 100 })
  const reject = workflow.jobs['mobile-summary'].steps?.find(step => step.name === 'Fail if any leg failed')?.if
  expect(reject).toBeDefined()
  for (const scope of ['', 'all']) {
    expect(legs.filter(name => evaluate(workflow.jobs[name].if, scope))).toEqual(legs)
    for (const name of legs) {
      expect(evaluate(reject, scope, { [name]: 'failure' })).toBe(true)
      expect(evaluate(reject, scope, { [name]: 'skipped' })).toBe(true)
    }
    expect(evaluate(reject, scope)).toBe(false)
  }
  for (const [scope, service] of [['ios-hybrid', 'ios-hybrid'], ['ios-checkpoints', 'ios-native']]) {
    const selected = ['harness', service]
    expect(legs.filter(name => evaluate(workflow.jobs[name].if, scope))).toEqual(selected)
    const skipped = Object.fromEntries(legs.filter(name => !selected.includes(name)).map(name => [name, 'skipped']))
    expect(evaluate(reject, scope, skipped)).toBe(false)
    for (const name of selected) {
      expect(evaluate(reject, scope, { ...skipped, [name]: 'failure' })).toBe(true)
      expect(evaluate(reject, scope, { ...skipped, [name]: 'skipped' })).toBe(true)
    }
  }
})

test('navigation shards retain both complete XCTest targets and focused selection', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { jobs: Record<string, Job> }
  const native = workflow.jobs['ios-native']
  const expression = (native.strategy?.matrix as unknown as { suite: string }).suite
  const navigation = native.steps?.find(step => step.name === 'Test native multi-screen navigation')
  const evaluate = (value: string, scope: string, selectors = '', suite = '') => runInNewContext(value.replace(/^\$\{\{\s*|\s*\}\}$/g, ''), {
    inputs: { scope, selectors }, matrix: { suite }, fromJSON: JSON.parse,
    startsWith: (text: string, prefix: string) => text.startsWith(prefix), cancelled: () => false,
  }, { timeout: 100 })
  for (const scope of ['', 'all'])
    expect(evaluate(expression, scope)).toEqual(['uikit', 'navigation-unit', 'navigation-ui-core', 'navigation-ui-controls'])
  expect(evaluate(expression, 'ios-navigation')).toEqual(['navigation-unit', 'navigation-ui-core', 'navigation-ui-controls'])
  expect(evaluate(expression, 'ios-render')).toEqual(['uikit'])
  expect(evaluate(expression, 'ios-checkpoints')).toEqual(['uikit'])
  const uikit = native.steps!.find(step => step.name === 'Test native UIKit reconciliation')!
  expect(evaluate(uikit.env!.CRAFT_ONLY_TESTING, 'ios-checkpoints')).toBe('NativeRenderUnitTests/PersistentRecordingCheckpointUnitTests')
  const focused = 'NativeNavigationUITests/NativeNavigationUITests/testMultilineInputKeepsKeyboardFocusWhenTapped'
  expect(evaluate(expression, 'ios-navigation', focused)).toEqual(['navigation'])
  expect(evaluate(navigation!.env!.CRAFT_ONLY_TESTING, 'all', '', 'navigation-unit')).toBe('NativeNavigationUnitTests')
  for (const [suite, group] of [['navigation-ui-core', 'core'], ['navigation-ui-controls', 'controls']]) {
    expect(evaluate(navigation!.env!.CRAFT_ONLY_TESTING, 'all', '', suite)).toBe('')
    expect(evaluate(navigation!.env!.CRAFT_NATIVE_NAVIGATION_GROUP, 'all', '', suite)).toBe(group)
  }
  expect(evaluate(navigation!.env!.CRAFT_ONLY_TESTING, 'ios-navigation', focused, 'navigation')).toBe(focused)
  expect(evaluate(navigation!.env!.CRAFT_NATIVE_NAVIGATION_GROUP, 'ios-navigation', focused, 'navigation')).toBe('')
  for (const suite of ['navigation-unit', 'navigation-ui-core', 'navigation-ui-controls', 'navigation'])
    expect(evaluate(navigation!.if!, 'all', '', suite)).toBe(true)
  expect(evaluate(navigation!.if!, 'all', '', 'uikit')).toBe(false)
  expect(native.strategy?.['fail-fast']).toBe(false)
  expect(workflow.jobs['mobile-summary'].steps?.find(step => step.name === 'Fail if any leg failed')?.if).toContain('needs.ios-native.result')
})

test('native teardown diagnostics require both Android APIs and keep queued cancellation coverage', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { jobs: Record<string, Job> }
  const job = workflow.jobs['android-navigation']!
  const api = (job.strategy!.matrix as unknown as Record<string, string>)['api-level']!
  const evaluate = (expression: string, scope: string, android_suite: string) => runInNewContext(expression.replace(/^\$\{\{\s*|\s*\}\}$/g, ''), { inputs: { scope, android_suite }, fromJSON: JSON.parse }, { timeout: 100 })
  expect(evaluate(api, 'android-navigation', 'teardown')).toEqual([34, 35])
  expect(evaluate(job.env!.CRAFT_ANDROID_TEST_CLASS!, 'android-navigation', 'teardown')).toBe('dev.craft.navigationtest.NativeCapabilitiesTest,dev.craft.navigationtest.NativeNavigationTest#nativeTeardownRecordsSynchronousStorageBeforeReturning')
  for (const scope of ['', 'all']) {
    expect(evaluate(api, scope, '')).toEqual([34, 35])
    expect(evaluate(job.env!.CRAFT_ANDROID_TEST_CLASS!, scope, '')).toBe('')
    expect(evaluate(job.env!.CRAFT_ANDROID_NATIVE_SUITE!, scope, '')).toBe('full')
  }
})

test('mobile device jobs preserve runner diagnostics when the harness fails', () => {
  const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/mobile-e2e.yml'), 'utf8')) as { jobs: Record<string, Job> }
  for (const [jobName, evidenceDir, expectedCommand] of [
    ['ios-simulator', 'ios-simulator/diagnostics', 'run_bounded 20 xcrun simctl'],
    ['ios-native', 'ios-native/diagnostics', 'run_bounded 20 xcrun simctl'],
    ['android-emulator', 'android-emulator/diagnostics', 'run_bounded 20 adb logcat'],
  ] as const) {
    const job = workflow.jobs[jobName]
    const diagnostics = job.steps?.find(step => step.name?.startsWith('Collect '))
    expect(diagnostics?.if, `${jobName} diagnostics must run after any harness outcome`).toBe('always()')
    expect(diagnostics?.run).toContain(evidenceDir)
    expect(diagnostics?.run).toContain(expectedCommand)

    const upload = job.steps?.find(step => step.name?.startsWith('Upload '))
    expect(upload?.if, `${jobName} evidence must upload after a failure`).toBe('always()')
    expect((upload?.with as Record<string, string>)?.path).toContain(`artifacts/mobile-e2e/${evidenceDir.split('/')[0]}/**`)
  }
})

test('workflow setup uses a known Pantry CLI instead of resolving latest', () => {
  for (const file of ['ci.yml', 'release.yml', 'mobile-e2e.yml', 'benchmarks.yml', 'binary-size.yml', 'native-lifecycle.yml', 'windows-source-provenance.yml', 'windows-managed-git.yml']) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/', file), 'utf8')) as { jobs: Record<string, Job> }
    for (const [name, job] of Object.entries(workflow.jobs)) {
      for (const step of job.steps ?? []) {
        if (step.uses?.startsWith('pantry-pm/pantry/packages/action@')) {
          // Keep each workflow on the released Pantry version it declares.
          // Source, release and their required mobile acceptance all use the
          // qualified provider. An older fixture pin hit PathAlreadyExists
          // while reconciling a restored Git cache and blocked v0.0.302.
          const version = ['ci.yml', 'release.yml', 'mobile-e2e.yml', 'windows-managed-git.yml'].includes(file)
            ? '0.11.120'
            : file === 'windows-source-provenance.yml' || (file === 'ci.yml' && name === 'windows-multi-window')
              ? '0.11.109'
              : ['benchmarks.yml', 'binary-size.yml'].includes(file)
                ? '0.11.106'
                : '0.11.101'
          const source = file === 'release.yml' && name === 'publish-pantry'
            ? 'ba9c66fc12af6bca2dd50dcad421f4a824531bcc'
            : version === '0.11.120'
              ? '3de609e1a7e305393b3d94e2848d859b39c5b5de'
              : version === '0.11.109'
                ? 'd160044a6fe4ad7e8463828f80dfbc55bcdc07d9'
                : version === '0.11.106'
                  ? 'e62755c21d946ed0f8dc8e4af39f6ea5f084537a'
                  : 'ae59a7b7fc5f4e6f7b8041a75e6b5772680bebdf'
          expect(step.with?.version, `${file} ${name} must pin Pantry CLI`).toBe(version)
          expect(step.uses, `${file} ${name} must pin the matching action source`).toBe(`pantry-pm/pantry/packages/action@${source}`)
        }
      }
    }
  }
})

test('jobs that only run Bun get Bun alone, not the pinned Zig they cannot always download', () => {
  // Setup Pantry installs every pinned system package. The pinned Zig dev build
  // has no Intel-Mac download once ziglang.org prunes it, which failed v0.0.114
  // in two jobs that compile nothing.
  const bunVersion = String((Bun.YAML.parse(readFileSync(join(import.meta.dir, '../deps.yaml'), 'utf8')) as { dependencies: Record<string, string> }).dependencies['bun.sh'])
  const pantry = Bun.JSONC.parse(readFileSync(join(import.meta.dir, '../pantry.jsonc'), 'utf8'))
  expect(pantry.dependencies['bun.sh']).toBe(bunVersion)
  const lock = JSON.parse(readFileSync(join(import.meta.dir, '../pantry.lock'), 'utf8'))
  expect(lock.workspaces[''].system['bun.sh']).toBe(bunVersion)
  expect(lock.packages[`bun.sh@${bunVersion}`].version).toBe(bunVersion)
  for (const file of ['mobile-e2e.yml', 'native-lifecycle.yml', 'release.yml', 'sbom.yml', 'media-cache.yml']) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows', file), 'utf8')) as { jobs: Record<string, Job> }
    for (const [name, job] of Object.entries(workflow.jobs)) {
      for (const step of job.steps ?? []) {
        if (step.uses === 'oven-sh/setup-bun@v2')
          expect(step.with?.['bun-version'], `${file} ${name} must pin the declared Bun toolchain`).toBe(bunVersion)
      }
    }
  }
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
    expect(release.jobs[name].if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.pantry.result == 'success' }}")
  expect(needs(release.jobs['prepare-npm'])).toEqual(['validate-release', 'release-sbom'])
  expect(release.jobs['prepare-npm'].if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.release-sbom.result == 'success' }}")
  expect(needs(release.jobs.npm)).toEqual(['validate-release', 'release-sbom', 'prepare-npm', 'publish-release'])
  expect(release.jobs.npm.if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.release-sbom.result == 'success' && needs.prepare-npm.result == 'success' && needs.publish-release.result == 'success' }}")
})

test('tag publication requires the complete source and native acceptance workflows', () => {
  for (const [gateName, suiteName, file] of [['source-acceptance', 'source-suite', 'ci.yml'], ['native-acceptance', 'native-suite', 'mobile-e2e.yml']]) {
    // The gate reuses main's push run of the same workflow on this exact SHA.
    const gate = release.jobs[gateName]
    expect(needs(gate)).toEqual(['validate-release'])
    expect(gate.if).toBeUndefined()
    const reuse = (gate.steps ?? []).find(step => step.run?.includes('scripts/release-acceptance.ts'))
    expect(reuse?.run).toBe(`bun scripts/release-acceptance.ts ${file}`)
    expect((reuse?.env as Record<string, string>)?.RELEASE_SHA).toBe('${{ github.sha }}')
    // With nothing to reuse, the release runs the complete suite on its tag.
    const suite = release.jobs[suiteName]
    expect(suite.uses).toBe(`./.github/workflows/${file}`)
    expect(needs(suite)).toEqual([gateName])
    expect(suite.if).toBe(`needs.${gateName}.outputs.reused != 'true'`)
    expect(suite.with).toBeUndefined() // A release cannot request a focused suite.
    const called = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows', file), 'utf8')) as { on: Record<string, unknown> }
    expect(called.on.workflow_call).toEqual({}) // No selectors or diagnostic inputs are accepted by callers.
  }
  // Publishing needs both gates, and each suite passed or was reused.
  const accepted = "needs.source-acceptance.result == 'success' && needs.native-acceptance.result == 'success' && (needs.source-acceptance.outputs.reused == 'true' || needs.source-suite.result == 'success') && (needs.native-acceptance.outputs.reused == 'true' || needs.native-suite.result == 'success')"
  for (const name of ['pantry', 'publish-release']) {
    for (const job of ['source-acceptance', 'source-suite', 'native-acceptance', 'native-suite'])
      expect(needs(release.jobs[name])).toContain(job)
    expect(release.jobs[name].if).toContain(accepted)
    expect(release.jobs[name].if?.startsWith("${{ !cancelled() && needs.validate-release.result == 'success'")).toBe(true)
    // Every other prerequisite still has to succeed.
    for (const dependency of needs(release.jobs[name]).filter(job => !job.endsWith('-suite')))
      expect(release.jobs[name].if).toContain(`needs.${dependency}.result == 'success'`)
  }
  function prerequisites(name: string, found = new Set<string>()): Set<string> {
    for (const dependency of needs(release.jobs[name])) {
      if (found.has(dependency)) continue
      found.add(dependency)
      prerequisites(dependency, found)
    }
    return found
  }
  for (const name of ['pantry', 'publish-release', 'publish-pantry', 'npm', 'notify-registry']) {
    expect(prerequisites(name).has('source-acceptance')).toBe(true)
    expect(prerequisites(name).has('native-acceptance')).toBe(true)
  }
})

test('called source and native acceptance have independent concurrency groups', () => {
  const parse = (file: string): { concurrency: { group: string } } => Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows', file), 'utf8'))
  const source = parse('ci.yml').concurrency.group
  const native = parse('mobile-e2e.yml').concurrency.group
  expect(source.startsWith('source-ci-')).toBe(true)
  expect(native.startsWith('mobile-e2e-')).toBe(true)
})

test('registry indexing waits for the public release and all of its verification gates', () => {
  const notify = release.jobs['notify-registry']
  expect(notify).toBeDefined()
  expect(needs(notify)).toEqual(['publish-release', 'publish-pantry'])
  expect(needs(release.jobs['publish-release']).sort()).toEqual(['attach-release-sbom', 'native-acceptance', 'native-suite', 'prepare-npm', 'source-acceptance', 'source-suite', 'validate-release', 'verify-desktop-downloads', 'verify-macos-downloads', 'verify-release'])
  // A failed or skipped gate cannot publish a draft; only a suite skipped
  // because its acceptance was reused may be.
  for (const dependency of needs(release.jobs['publish-release']).filter(job => !job.endsWith('-suite')))
    expect(release.jobs['publish-release'].if).toContain(`needs.${dependency}.result == 'success'`)
  expect(notify.if).toBe("${{ !cancelled() && needs.publish-release.result == 'success' && needs.publish-pantry.result == 'success' }}")
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
  // Not skipped by a reused acceptance's skipped suite, and still blocked by
  // any other prerequisite that did not succeed.
  for (const dependency of needs(finalizer).filter(job => !job.endsWith('-suite')))
    expect(finalizer.if).toContain(`needs.${dependency}.result == 'success'`)
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
  expect(registry.if).toBe("${{ !cancelled() && needs.validate-release.result == 'success' && needs.publish-release.result == 'success' }}")
  expect(needs(registry)).toEqual(['validate-release', 'publish-release'])
  // A native or downloaded-archive failure must not publish npm packages
  // while the GitHub release remains a draft. The explicit npm `if` must
  // check the finalizer result; listing it in `needs` alone is insufficient.
  expect(needs(release.jobs.npm)).toContain('publish-release')
  expect(release.jobs.npm.if).toContain("needs.prepare-npm.result == 'success'")
  expect(release.jobs.npm.if).toContain("needs.publish-release.result == 'success'")
  const zigPublish = registry.steps!.find(step => step.name === 'Publish Zig package')
  expect(zigPublish?.with).toMatchObject({ version: '0.11.120', install: 'false', publish: 'zig', 'package-dir': 'packages/zig' })
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
  const root = createTempDir('craft-incomplete-draft-')
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
  const root = createTempDir('craft-registry-notify-')
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
  const root = createTempDir('craft-release-announcement-')
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

test('every run script in every workflow is valid bash', async () => {
  // 5d65a10 dropped the `done` closing the notarization loop in release.yml.
  // Nothing parses a run script until a runner executes it, and the step only
  // runs on a macOS release after signing and the launch check - so the first
  // sign was v0.0.95's macOS build failing with "syntax error: unexpected end
  // of file" after everything before it had passed.
  const checks: Array<{ script: string, label: string }> = []
  for (const file of ['ci.yml', 'release.yml', 'sbom.yml', 'mobile-e2e.yml']) {
    const workflow = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/', file), 'utf8')) as { jobs: Record<string, Job & { defaults?: { run?: { shell?: string } } }> }
    for (const [name, job] of Object.entries(workflow.jobs)) {
      for (const step of job.steps ?? []) {
        if (!step.run || (step as { shell?: string }).shell === 'pwsh' || (step as { shell?: string }).shell === 'powershell')
          continue
        // Actions substitutes `${{ ... }}` before bash sees the script.
        const script = step.run.replace(/\$\{\{[\s\S]*?\}\}/g, 'X')
        checks.push({ script, label: `${file} job ${name} step "${step.name ?? step.run.slice(0, 40)}"` })
      }
    }
  }
  // Parse each snippet independently. Bounded parallel processes avoid a
  // growing serial spawn cost without letting scripts balance each other's
  // syntax. The integration budget covers all process startups on a cold host.
  for (let index = 0; index < checks.length; index += 4) {
    const results = await Promise.all(checks.slice(index, index + 4).map(async ({ script, label }) => {
      const check = Bun.spawn(['bash', '-n'], { stdin: new TextEncoder().encode(script), stdout: 'ignore', stderr: 'pipe' })
      const stderr = await new Response(check.stderr).text()
      return { label, stderr, code: await check.exited }
    }))
    for (const { label, stderr, code } of results) {
      expect(stderr, label).toBe('')
      expect(code, label).toBe(0)
    }
  }
}, 30000)

test('Linux and Windows release binaries target a baseline CPU, not the build runner', () => {
  // A host build compiles for the runner's own CPU; the published binary then
  // dies with SIGILL wherever those extensions are missing (v0.0.108).
  const builds = steps(release.jobs.pantry).split('\n').filter(line => /^\s*zig build\b/.test(line) && !/-Dtarget="\$(?:X64|ARM64)_TARGET"/.test(line))
  expect(builds.length).toBeGreaterThan(0)
  for (const line of builds)
    expect(line, line.trim()).toContain('-Dcpu=baseline')
})

// A skipped reused suite also affects descendants of a successful direct need.
test('every descendant of a reused suite has explicit, fail-closed status gating', () => {
  function dependsOnSuite(name: string): boolean {
    return needs(release.jobs[name]).some(parent => parent.endsWith('-suite') || dependsOnSuite(parent))
  }
  for (const [name, job] of Object.entries(release.jobs)) {
    if (!dependsOnSuite(name)) continue
    expect(job.if, name).toContain('!cancelled()')
    for (const parent of needs(job).filter(parent => !parent.endsWith('-suite')))
      expect(job.if, `${name} must reject a failed ${parent}`).toContain(`needs.${parent}.result == 'success'`)
  }
})


test('macOS publishes, signs and verifies both webview distribution variants from the tagged source', () => {
  const commands = steps(release.jobs.pantry)
  expect(commands).toContain('-Djs-runtime=false -Dprivate-apis="$PRIVATE_APIS"')
  for (const name of ['craft-webview', 'craft-webview-app-store']) {
    expect(commands).toContain(`packages/zig/zig-out/bin/${name}`)
    expect(commands).toContain(`packages/zig/zig-out/cross/darwin-x64/${name}`)
  }
  expect(commands).toContain('"packages/zig/zig-out/bin/craft-webview:arm64-webview"')
  expect(commands).toContain('"packages/zig/zig-out/bin/craft-webview-app-store:arm64-webview-app-store"')
  expect(steps(release.jobs['verify-macos-downloads'])).toContain('for RUNTIME in craft craft-app-store craft-webview craft-webview-app-store')
})
