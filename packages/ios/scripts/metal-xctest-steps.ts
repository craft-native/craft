import { nativeFixtureBuildTimeoutMs } from './native-fixture-command'

/** Compilation and each native suite own independent bounded command lifetimes. */
export function metalXCTestSteps(simulator: string, derivedData: string, results: string): { name: string, args: string[], timeoutMs: number, resultBundle?: string }[] {
  const common = ['xcodebuild', '-project', 'MetalSurfaceFixture.xcodeproj', '-scheme', 'MetalSurfaceFixture', '-destination', `platform=iOS Simulator,id=${simulator}`, '-derivedDataPath', derivedData, '-parallel-testing-enabled', 'NO', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES']
  return [
    { name: 'build-native-uikit-tests', args: [...common, 'build-for-testing'], timeoutMs: nativeFixtureBuildTimeoutMs },
    // A hosted cold simulator can spend several minutes installing and launching
    // XCTest's host before the first assertion. Test-level deadlines stay unchanged.
    ...['MetalSurfaceUnitTests', 'MetalSurfaceUITests'].map(suite => {
      const resultBundle = `${results}.${suite}`
      return { name: suite, args: [...common, `-only-testing:${suite}`, '-resultBundlePath', resultBundle, 'test-without-building'], timeoutMs: 600_000, resultBundle }
    }),
  ]
}

/** Both actual suites must run; neither a skipped UI suite nor a unit-only pass suffices. */
export function verifyMetalXCTestSummaries(summaries: Record<string, unknown>[]): void {
  if (summaries.length !== 2 || summaries.some(summary => summary.result !== 'Passed'
    || typeof summary.totalTestCount !== 'number' || summary.totalTestCount < 1
    || summary.passedTests !== summary.totalTestCount || summary.failedTests !== 0 || summary.skippedTests !== 0))
    throw new Error('Native Metal acceptance requires both suites to execute successfully without skips')
}

/**
 * How long reading a result bundle's summary may take. It runs after the
 * suite has finished, and a loaded hosted runner has taken longer than the
 * 30 s metadata commands get, failing a leg whose tests had passed (#556).
 * Every other native harness reads its summary with no limit at all.
 */
export const xcresultSummaryTimeoutMs = 120_000

/** The command that reads a finished suite's summary as JSON. */
export function xcresultSummaryCommand(resultBundle: string): string[] {
  return ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', resultBundle]
}

/**
 * The first CoreSimulator query on a runner may start its service. This limit
 * only guards against a wedged simctl holding the job; it is not a budget
 * (#447). Passing runs took 19, 36 and 95 s, and 120 s killed two attempts
 * that may only have been slow (#509), so it sits well clear of those.
 */
export const coreSimulatorFirstQueryTimeoutMs = 300_000
