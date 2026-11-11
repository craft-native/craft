import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const source = readFileSync(join(import.meta.dir, 'verify-desktop-bridge.ts'), 'utf8')
const ci = Bun.YAML.parse(readFileSync(join(import.meta.dir, '../.github/workflows/ci.yml'), 'utf8')) as {
  jobs: Record<string, { steps: Array<{ name?: string, run?: string, if?: string }> }>
}

test('every bridge namespace the smoke claims is a step the page must report', () => {
  const required = source.match(/const requiredSteps = \[([^\]]+)\]/)?.[1]
  expect(required).toBeTruthy()
  const names = [...required!.matchAll(/'([^']+)'/g)].map(match => match[1]!)
  expect(names).toEqual(['surface', 'menu', 'context-menu', 'message-dialogs', 'file-dialogs', 'file-drop', 'single-instance', 'menu-cleared', 'relaunch-requested'])
  for (const name of names) expect(source).toContain(`await report('${name}')`)
  // A step that is only reported, and never required, would pass while missing.
  const reported = [...source.matchAll(/await report\('([^']+)'\)/g)].map(match => match[1]!)
  expect(new Set(reported)).toEqual(new Set(names))
})

test('the smoke only passes after the relaunch command ran for the exiting Craft process', () => {
  expect(source).toContain('CRAFT_RELAUNCH_EXECUTABLE: process.execPath')
  expect(source).toContain('relaunchedFromPid !== String(child.pid)')
  expect(source).toContain('craftExit.code !== 0')
})

test('both desktop legs of CI run the bridge smoke against the binary they built', () => {
  const linux = ci.jobs['zig-core']!.steps.find(step => step.name === 'Smoke Linux desktop bridge')
  expect(linux).toBeTruthy()
  expect(linux!.if).toBe('runner.os == \'Linux\'')
  // Inside the wrapper: its second launch needs the same display and session bus.
  expect(linux!.run).toContain('sh scripts/run-linux-with-wm.sh bun scripts/verify-desktop-bridge.ts packages/zig/zig-out/bin/craft')

  const windows = ci.jobs['windows-multi-window']!.steps.find(step => step.name === 'Smoke Windows desktop bridge')
  expect(windows).toBeTruthy()
  expect(windows!.run).toContain('bun scripts/verify-desktop-bridge.ts packages/zig/zig-out/bin/craft.exe')

  // The smoke drives real input, so its tools have to be installed first.
  const packages = ci.jobs['zig-core']!.steps.find(step => step.name === 'Install Linux dependencies')!.run!
  for (const tool of ['xdotool', 'wmctrl', 'python3-gi', 'gir1.2-gtk-3.0']) expect(packages).toContain(tool)
})

test('this test file and the support-table test are named in CI', () => {
  const lint = ci.jobs.lint!.steps.map(step => step.run ?? '').join('\n')
  expect(lint).toContain('./scripts/verify-desktop-bridge.test.ts')
  expect(lint).toContain('./scripts/platform-support.test.ts')
})
