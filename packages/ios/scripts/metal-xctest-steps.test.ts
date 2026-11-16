import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { coreSimulatorFirstQueryTimeoutMs, metalXCTestSteps, verifyMetalXCTestSummaries, xcresultSummaryCommand, xcresultSummaryTimeoutMs } from './metal-xctest-steps'

test('Metal compilation and each XCTest suite get independent deadlines and separate real result bundles', () => {
  const [build, unit, ui] = metalXCTestSteps('owned-simulator', '/owned/DerivedData', '/evidence/TestResults.xcresult')
  expect(build.args.at(-1)).toBe('build-for-testing')
  expect(build.args).not.toContain('-resultBundlePath')
  expect(unit.args).toContain('-only-testing:MetalSurfaceUnitTests')
  expect(ui.args).toContain('-only-testing:MetalSurfaceUITests')
  expect(unit.resultBundle).not.toBe(ui.resultBundle)
  for (const step of [unit, ui]) {
    expect(step.args.slice(-3)).toEqual(['-resultBundlePath', step.resultBundle!, 'test-without-building'])
  }
  for (const step of [build, unit, ui]) {
    expect(step.args[step.args.indexOf('-destination') + 1]).toBe('platform=iOS Simulator,id=owned-simulator')
    expect(step.args[step.args.indexOf('-derivedDataPath') + 1]).toBe('/owned/DerivedData')
    expect(step.args[step.args.indexOf('-parallel-testing-enabled') + 1]).toBe('NO')
    expect(step.timeoutMs).toBe(step === build ? 300_000 : 600_000)
  }
})

test('release acceptance requires actual successful execution of both native suites without skips', () => {
  const passed = { result: 'Passed', totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0 }
  expect(() => verifyMetalXCTestSummaries([passed, passed])).not.toThrow()
  for (const summaries of [[], [passed], [passed, { ...passed, totalTestCount: 0, passedTests: 0 }],
    [passed, { ...passed, skippedTests: 1 }], [passed, { ...passed, result: 'Failed', failedTests: 1 }],
    [passed, { ...passed, passedTests: 0 }]]) {
    expect(() => verifyMetalXCTestSummaries(summaries)).toThrow('both suites')
  }
})

test('both Metal harnesses read a finished suite\'s summary with its own limit, not the 30 s metadata one (#556)', () => {
  expect(xcresultSummaryCommand('/evidence/TestResults.xcresult')).toEqual(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', '/evidence/TestResults.xcresult'])
  expect(xcresultSummaryTimeoutMs).toBeGreaterThanOrEqual(120_000)
  const root = join(import.meta.dir, '../../..')
  for (const [harness, call] of [
    ['packages/ios/scripts/test-metal-surface.ts', 'capture(xcresultSummaryCommand(step.resultBundle), { timeoutMs: xcresultSummaryTimeoutMs })'],
    ['scripts/test-metal-surface-macos.ts', 'capture(xcresultSummaryCommand(results), false, xcresultSummaryTimeoutMs)'],
  ] as const) {
    const source = readFileSync(join(root, harness), 'utf8')
    expect(source).toContain(call)
    // No summary read may bypass the shared command and its limit.
    expect(source.match(/xcresulttool/g)).toBeNull()
  }
})

test('the first CoreSimulator query gets a hang guard clear of the 95 s a passing run took (#509)', () => {
  expect(coreSimulatorFirstQueryTimeoutMs).toBeGreaterThanOrEqual(300_000)
  const source = readFileSync(join(import.meta.dir, 'test-metal-surface.ts'), 'utf8')
  expect(source).toContain("capture(['xcrun', 'simctl', 'list', 'runtimes', '--json'], { timeoutMs: coreSimulatorFirstQueryTimeoutMs })")
})
