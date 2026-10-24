import { expect, test } from 'bun:test'
import { metalXCTestSteps, verifyMetalXCTestSummaries } from './metal-xctest-steps'

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
