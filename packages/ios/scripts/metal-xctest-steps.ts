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
