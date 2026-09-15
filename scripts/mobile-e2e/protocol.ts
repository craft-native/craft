/**
 * The wire between the test page and the harness, and the rules for reading it.
 *
 * Kept separate from the two runners because this is the part that can be
 * tested without a simulator: `scripts/mobile-e2e/protocol.test.ts` feeds it
 * transcripts a device would have produced, including the ones that matter
 * most - a suite that died halfway, a case that never ran, a run with no
 * output at all. The runners stay untested; the reading of their output does
 * not. Same split as scripts/native-lifecycle-plan.ts and its test.
 */

/** Emitted once, before any case runs, so a truncated run is detectable. */
export interface PlanEvent {
  event: 'plan'
  platform: string
  cases: string[]
  /** This run's nonce, so a stale transcript cannot be mistaken for this one. */
  run?: string
}

export interface CaseEvent {
  event: 'case'
  name: string
  status: 'pass' | 'fail'
  /** Empty on pass; on failure, what the page actually saw. */
  detail?: string
}

export interface DoneEvent {
  event: 'done'
  passed: number
  failed: number
}

export interface FatalEvent {
  event: 'fatal'
  reason: string
}

export interface ObservedEvent {
  event: 'observed'
  name: string
  value: unknown
}

export type DriverEvent = PlanEvent | CaseEvent | DoneEvent | FatalEvent | ObservedEvent

export type MobilePlatform = 'ios' | 'android'

/**
 * The cases each platform must run, named here and nowhere else.
 *
 * The page decides what a case *asserts*; this decides which ones have to
 * exist. Both halves are needed: without the page there is nothing to assert,
 * and without this list a suite can be hollowed out to one trivially passing
 * case and still report green - which is the failure mode the workflow this
 * replaces actually had, for months, with `if: hashFiles(...)` guards that
 * skipped every real step.
 *
 * Each platform's list must contain at least one success path and one
 * rejection path; `requiredCaseProblems` enforces that rather than trusting
 * whoever edits it next.
 */
export const REQUIRED_CASES: Record<MobilePlatform, string[]> = {
  ios: [
    'bridge.ready',
    'deviceInfo.isSimulator',
    'clipboard.roundTrip',
    'geolocation.disabled.rejects',
  ],
  android: [
    'bridge.ready',
    'deviceInfo.isEmulator',
    'clipboard.roundTrip',
    'push.disabled.rejects',
  ],
}

/** Cases whose whole point is that the native side *refuses*. */
const REJECTION_SUFFIX = '.rejects'

/**
 * Guard the list above against being watered down.
 *
 * A platform that lost its rejection case would still look like a passing
 * suite - every remaining case is a success path, and success paths are the
 * easy half. Run from the protocol test.
 */
export function requiredCaseProblems(): string[] {
  const problems: string[] = []

  for (const [platform, names] of Object.entries(REQUIRED_CASES)) {
    if (!names.some(name => name.endsWith(REJECTION_SUFFIX)))
      problems.push(`${platform} has no ${REJECTION_SUFFIX} case; a suite of success paths only proves half the bridge`)

    if (!names.some(name => !name.endsWith(REJECTION_SUFFIX) && name !== 'bridge.ready'))
      problems.push(`${platform} has no success case beyond bridge.ready`)

    const duplicated = names.filter((name, index) => names.indexOf(name) !== index)
    if (duplicated.length)
      problems.push(`${platform} lists ${duplicated.join(', ')} more than once`)
  }

  return problems
}

const MARKER = 'CRAFT-E2E '

/**
 * Colour codes the iOS console adds, stripped before matching.
 *
 * Built from a char code rather than written as an escape so this file stays
 * free of literal control characters.
 */
const ANSI = new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*m`, 'g')

/**
 * The first complete JSON object in `text`, or null.
 *
 * Taking the rest of the line would be enough on iOS, where the console shows
 * exactly what the app printed. It is not enough on Android: the page's
 * `console.log` reaches logcat through Chromium, which wraps it -
 *
 *     [INFO:CONSOLE(1)] "CRAFT-E2E {...}", source: https://appassets... (1)
 *
 * - so the rest of the line carries a trailing quote and a source reference.
 * Scanning to the matching brace reads the event out of either shape, while
 * still rejecting a line that was genuinely truncated.
 */
function firstJsonObject(text: string): string | null {
  const start = text.indexOf('{')
  if (start === -1) return null

  let depth = 0
  let inString = false
  let escaped = false

  for (let index = start; index < text.length; index++) {
    const character = text[index]!

    if (escaped) { escaped = false; continue }
    if (character === '\\' && inString) { escaped = true; continue }
    if (character === '"') { inString = !inString; continue }
    if (inString) continue

    if (character === '{') depth++
    else if (character === '}') {
      depth--
      if (depth === 0) return text.slice(start, index + 1)
    }
  }

  return null
}

/**
 * Pull the driver's events out of a device log.
 *
 * The log is not ours: on iOS it is the app's whole stderr as
 * `simctl launch --console-pty` saw it, on Android a logcat slice, both
 * carrying unrelated system chatter and, on iOS, ANSI colouring. So lines are
 * found by marker rather than by position, colour codes are stripped first,
 * and a marker line with no readable event is reported rather than skipped -
 * a garbled event is evidence of a problem, not something to shrug at.
 *
 * The page emits each event twice on purpose, through `console.log` and
 * through the bridge's own `log` action, so that a run whose bridge never
 * arrived can still say so. Only one of those reaches the log on iOS; both do
 * on Android. Duplicates are dropped here rather than being left for
 * `evaluateRun` to trip over.
 */
export function parseDriverOutput(text: string): { events: DriverEvent[], malformed: string[] } {
  const events: DriverEvent[] = []
  const malformed: string[] = []
  const seen = new Set<string>()

  for (const rawLine of text.split('\n')) {
    const line = rawLine.replace(ANSI, '').replace(/\r$/, '')
    const at = line.indexOf(MARKER)
    if (at === -1) continue

    const rest = line.slice(at + MARKER.length).trim()
    const payload = firstJsonObject(rest)
    if (payload === null) {
      malformed.push(rest)
      continue
    }

    let parsed: DriverEvent
    try {
      parsed = JSON.parse(payload) as DriverEvent
    }
    catch {
      malformed.push(payload)
      continue
    }

    if (!parsed || typeof parsed !== 'object' || typeof parsed.event !== 'string') {
      malformed.push(payload)
      continue
    }

    if (seen.has(payload)) continue
    seen.add(payload)
    events.push(parsed)
  }

  return { events, malformed }
}

/**
 * Has the suite finished, as a complete event rather than a substring?
 *
 * The callers kill the app the moment this is true, so matching `"event":"done"`
 * in a half-written line would truncate the very event being waited for, and
 * the truncation would then be reported as a malformed event - a passing run
 * failing on a race. Requiring the object to parse means the line is whole.
 */
export function hasTerminated(text: string): boolean {
  return parseDriverOutput(text).events.some(event => event.event === 'done' || event.event === 'fatal')
}

export interface RunVerdict {
  ok: boolean
  /** One line per reason the run is not a pass. Empty when ok. */
  failures: string[]
  planned: string[]
  passed: string[]
  failed: string[]
}

/**
 * Decide whether a captured run is a pass.
 *
 * Silence is the thing being guarded against. A run that produced no output
 * at all, or announced a plan and then died, or ran every case it planned but
 * planned only one - each of those reads as "nothing went wrong" to a naive
 * reader, and each is a failure here.
 */
export function evaluateRun(platform: MobilePlatform, text: string, expectedRun?: string): RunVerdict {
  const { events, malformed } = parseDriverOutput(text)
  const failures: string[] = []

  for (const line of malformed)
    failures.push(`driver emitted an unparseable event: ${line}`)

  const fatal = events.find((event): event is FatalEvent => event.event === 'fatal')
  if (fatal) failures.push(`driver reported a fatal condition: ${fatal.reason}`)

  const plan = events.find((event): event is PlanEvent => event.event === 'plan')
  const cases = events.filter((event): event is CaseEvent => event.event === 'case')
  const done = events.find((event): event is DoneEvent => event.event === 'done')

  const planned = plan?.cases ?? []
  const passed = cases.filter(entry => entry.status === 'pass').map(entry => entry.name)
  const failed = cases.filter(entry => entry.status === 'fail').map(entry => entry.name)

  if (!plan) {
    // No plan means the page never reached the bridge - the app crashed, the
    // page never loaded, or the bridge refused it. Everything below would be
    // vacuously true, so say this and stop adding noise.
    failures.push('the test page never announced a plan; it did not reach the native bridge')
    return { ok: false, failures, planned, passed, failed }
  }

  if (plan.platform !== platform)
    failures.push(`the app reports platform ${plan.platform}, expected ${platform}`)

  // Android reads its transcript out of the device's logcat ring buffer, which
  // survives an uninstall and is cleared only on a best-effort basis. Without
  // this, a leg whose app printed nothing at all could be evaluated against —
  // and pass on — the previous run's output still sitting in the buffer.
  if (expectedRun !== undefined && plan.run !== expectedRun)
    failures.push(`the transcript is from run ${JSON.stringify(plan.run)}, not ${JSON.stringify(expectedRun)}; this is stale output, not this run's`)

  for (const required of REQUIRED_CASES[platform]) {
    if (!planned.includes(required))
      failures.push(`required case ${required} is not in the suite the page ran`)
  }

  for (const name of planned) {
    if (!cases.some(entry => entry.name === name))
      failures.push(`case ${name} was planned but never reported; the suite stopped early`)
  }

  for (const entry of cases) {
    if (entry.status === 'fail')
      failures.push(`case ${entry.name} failed: ${entry.detail || 'no detail'}`)
    // Neither a pass nor a fail is not a third outcome to be tolerated. A case
    // reporting anything else satisfies "was planned and did report" while
    // never appearing in `passed`, which would leave it unasserted inside a
    // green run - the precise shape of failure this harness exists to remove.
    else if (entry.status !== 'pass')
      failures.push(`case ${entry.name} reported status ${JSON.stringify(entry.status)}, which is neither pass nor fail`)
  }

  if (!done)
    failures.push('the suite never reported done')
  else if (done.failed !== failed.length || done.passed !== passed.length)
    failures.push(`done says ${done.passed} passed / ${done.failed} failed, transcript shows ${passed.length} / ${failed.length}`)

  return { ok: failures.length === 0, failures, planned, passed, failed }
}

/**
 * The actions the Zig dispatcher saw, by name.
 *
 * Zig and the platform shim answer the same actions with the same shapes -
 * that is the point of the hand-off design - so the only way to tell them
 * apart from outside is what Zig's own logger writes
 * (`packages/zig/src/ios_dispatch.zig`). With no archive linked, `dlsym`
 * misses and none of this is emitted at all, which is what separates the two
 * iOS legs.
 *
 * By name rather than by count, because the page routes every report through
 * `craft.log`, and `log` is itself a dispatched action: a bare count is
 * satisfied by the reporting traffic alone and would pass while Swift served
 * every capability under test.
 */
export function zigDispatchedActions(text: string): string[] {
  const plain = text.replace(ANSI, '')
  const seen = new Set<string>()
  for (const match of plain.matchAll(/craft-bridge dispatch t=\w+ a=(\w+)/g)) seen.add(match[1]!)
  return [...seen].sort()
}

/**
 * The actions Zig refused through its own capability gate.
 *
 * A dispatch line proves Zig was *offered* an action - it is logged on entry,
 * before the decision. This proves Zig *answered* one: `ios_config`'s gate
 * writes the line, and the rejection the page then sees came off Zig's error
 * route rather than Swift's.
 */
export function zigRefusals(text: string): string[] {
  const plain = text.replace(ANSI, '')
  const seen = new Set<string>()
  for (const match of plain.matchAll(/ios: refusing (\w+);/g)) seen.add(match[1]!)
  return [...seen].sort()
}

/**
 * The capability actions the page exercises, which the runtime leg expects to
 * see Zig dispatch.
 *
 * Kept in step with the cases in driver.html by hand. Derived from the page it
 * would have to be parsed out of HTML; named here it is at least checkable,
 * and a case removed from the page fails the leg loudly rather than quietly
 * reducing what the assertion covers.
 */
export const ZIG_TESTED_ACTIONS = [
  'clipboardRead',
  'clipboardWrite',
  'getCurrentPosition',
  'getDeviceInfo',
]

/** The one action the suite configures off, so Zig must refuse it by name. */
export const ZIG_REFUSED_ACTION = 'getCurrentPosition'
