/**
 * The home-screen controls journeys, which run in legs of their own. They
 * were one case (#505); a new case joins a core leg unless it is named here.
 *
 * Two legs of three, balanced by measured time (#508): on the runs that
 * finished them the first three took about 800 s and the last three about
 * 790 s. One leg of all six took 1,540 to 1,900 s of a 45-minute job that
 * spends 500 to 1,000 s before its first case, and was cut off at the limit.
 */
const controlsLegs: readonly (readonly string[])[] = [
  [
    'testImagesListsAndControlStylesReconcile',
    'testGridFlexAndMeasuredLayoutFrames',
    'testAShortScrollFromAPressableDoesNotPressIt',
  ],
  [
    'testLinksPressablesAndAccessibilityState',
    'testSwitchPickerModalSliderAndIndicators',
    'testPushNativeBackSwipeReplaceAndRetainedHomeState',
  ],
]
const controlsCases = new Set(controlsLegs.flat())

/** The required UI groups, one CI leg each. */
export const nativeNavigationGroups = ['core-1', 'core-2', 'controls-1', 'controls-2'] as const

/**
 * Which core leg a case runs in: from its name alone, so adding a case never
 * moves an existing one between legs and their timings stay comparable from
 * run to run (FNV-1a, 32 bit).
 */
export function coreLeg(name: string): 1 | 2 {
  let hash = 0x811C9DC5
  for (let index = 0; index < name.length; index++) {
    hash ^= name.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return hash % 2 === 0 ? 1 : 2
}

/** Partition every UI case; new cases automatically join a core leg. */
export function nativeNavigationGroup(source: string, group: string): string[] {
  if (!(nativeNavigationGroups as readonly string[]).includes(group))
    throw new Error(`Unknown native navigation UI group: ${group}`)
  const cases = [...source.matchAll(/^\s*func\s+(test\w+)\s*\(/gm)].map(match => match[1]!)
  // Every controls journey must be there: one renamed away would otherwise
  // leave its leg quietly smaller, or move into a core leg unannounced.
  if (cases.length < 2 || new Set(cases).size !== cases.length || [...controlsCases].some(name => !cases.includes(name)))
    throw new Error('Native navigation UI coverage must contain unique cases and every controls journey')
  const [kind, leg] = group.split('-') as ['core' | 'controls', string]
  const selected = kind === 'controls'
    ? cases.filter(name => controlsLegs[Number(leg) - 1]!.includes(name))
    : cases.filter(name => !controlsCases.has(name) && coreLeg(name) === Number(leg))
  if (!selected.length) throw new Error(`Empty native navigation UI group: ${group}`)
  return selected.map(name => `NativeNavigationUITests/NativeNavigationUITests/${name}`)
}

/** An ignored XCTest selector must not silently reduce required coverage. */
export function verifyNativeNavigationResults(counts: Record<string, unknown>, expectedTestCount?: number): number {
  const count = counts.totalTestCount
  if (counts.result !== 'Passed' || typeof count !== 'number' || !Number.isInteger(count) || count < 1
    || counts.passedTests !== count || counts.failedTests !== 0 || counts.skippedTests !== 0
    || (expectedTestCount !== undefined && count !== expectedTestCount))
    throw new Error(`Expected complete native navigation coverage (${expectedTestCount ?? 'nonempty'} tests): ${JSON.stringify(counts)}`)
  return count
}
