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

/**
 * The page asking the harness to do what a person would. Emitted just before
 * the call that needs it, because the page cannot tap the device itself.
 */
export interface AwaitingEvent {
  event: 'awaiting'
  /** The case that is waiting. */
  name: string
  /** What it is waiting for, one of the needs the harness knows how to meet. */
  need: string
}

export type DriverEvent = PlanEvent | CaseEvent | DoneEvent | FatalEvent | ObservedEvent | AwaitingEvent

export type MobilePlatform = 'ios' | 'android'

// The local notification must survive UI discovery and synchronous app
// termination before it fires. CI has spent 32 seconds in terminate() alone.
export const LOCAL_NOTIFICATION_DELAY_MS = 120_000
export const NOTIFICATION_TEST_TIMEOUT_MS = 300_000 + LOCAL_NOTIFICATION_DELAY_MS

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
    'permissions.location.granted',
    'geolocation.currentPosition',
    'geolocation.watchPosition.resolvesTrue',
    'geolocation.clearWatch.resolvesTrue',
    'haptic.resolvesTrue',
    'vibrate.resolvesTrue',
    'share.disabled.rejects',
    'speech.disabled.rejects',
    'speech.stopListening.resolvesTrue',
  ],
  android: [
    'bridge.ready',
    'deviceInfo.isEmulator',
    'clipboard.roundTrip',
    'push.disabled.rejects',
    'share.empty.rejects',
    'share.dismissed.resolvesFalse',
    'permissions.location.granted',
    'capabilities.match.behaviour',
    'haptic.resolvesTrue',
    'vibrate.resolvesTrue',
    'speech.disabled.rejects',
    'speech.stopListening.resolvesTrue',
    'bridge.survivesSameDocumentNavigation',
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
 * The log is not ours: on iOS it is the app's whole stdout and stderr as
 * `simctl launch --stdout --stderr` wrote them, on Android a logcat slice, both
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

/** What one cold start through a link saw, as the page reported it. */
export interface DeepLinkResult {
  receive: 'subscribe' | 'both'
  link: string
  launch: string | null
  onLink: { url?: string, initial?: boolean }[]
  initialURL: string | null
  /** `typeof` what onLink returned. Absent from reports older than #215. */
  unsubscribe?: string
}

/** The report the page writes, without the label the harness adds. */
export type DeepLinkReport = Omit<DeepLinkResult, 'receive' | 'link'>

/**
 * The page's deep-link reports in an Android log, one per distinct report.
 *
 * On Android the page logs its `CRAFT-E2E-DEEPLINK {json}` line through both
 * console.log, which logcat carries under `chromium` wrapped in quotes and a
 * source suffix, and craft.log, under the bridge's own tag. The same report
 * arriving twice is one report; two different ones means the page reported
 * twice, which the caller treats as a failure.
 */
export function deepLinkReports(text: string): DeepLinkReport[] {
  const reports: DeepLinkReport[] = []
  const seen = new Set<string>()
  for (const line of text.replace(ANSI, '').split('\n')) {
    const at = line.indexOf('CRAFT-E2E-DEEPLINK ')
    if (at === -1 || line.includes('CRAFT-E2E-DEEPLINK-RESULT')) continue
    const json = firstJsonObject(line.slice(at + 'CRAFT-E2E-DEEPLINK '.length))
    if (!json || seen.has(json)) continue
    seen.add(json)
    try {
      const report = JSON.parse(json) as DeepLinkReport
      if (Array.isArray(report.onLink)) reports.push(report)
    }
    catch {}
  }
  return reports
}

/**
 * The page reports the UI test printed, read out of xcodebuild's output.
 *
 * `ios-uitests/DeepLinkColdStartTests.swift` writes one
 * `CRAFT-E2E-DEEPLINK-RESULT <receive> <link> CRAFT-E2E-DEEPLINK {json}` line
 * per cold start. A line whose JSON does not parse is skipped here and
 * surfaces as that mode being missing.
 */
export function deepLinkResults(output: string): DeepLinkResult[] {
  const results: DeepLinkResult[] = []
  for (const line of output.split('\n')) {
    const match = line.match(/CRAFT-E2E-DEEPLINK-RESULT (subscribe|both) (\S+) CRAFT-E2E-DEEPLINK (\{.*\})\s*$/)
    if (!match) continue
    try {
      const report = JSON.parse(match[3]!) as Omit<DeepLinkResult, 'receive' | 'link'>
      results.push({ receive: match[1] as DeepLinkResult['receive'], link: `${match[2]}`, ...report })
    }
    catch {}
  }
  return results
}

/**
 * Why the cold-start runs are not a pass, one line per reason.
 *
 * `subscribe` is #198 itself: a page that only subscribes, seconds after the
 * bridge appeared, must be handed the launch link once, marked initial.
 * `both` is the guard on the fix: a page that also calls getInitialURL must
 * get the link from there and not a second time from onLink.
 */
export function deepLinkProblems(
  results: DeepLinkResult[],
  link: string,
  evidence: (receive: DeepLinkResult['receive']) => string = () => 'xcodebuild-deeplink.log',
): string[] {
  const problems: string[] = []
  for (const receive of ['subscribe', 'both'] as const) {
    const result = results.find(entry => entry.receive === receive)
    const expectedLink = `${link}&receive=${receive}`
    if (!result) {
      problems.push(`the ${receive} cold start never reported; see ${evidence(receive)}`)
      continue
    }
    if (result.unsubscribe !== undefined && result.unsubscribe !== 'function')
      problems.push(`onLink returned ${result.unsubscribe} in the ${receive} cold start, expected a function that unsubscribes`)
    if (result.launch !== expectedLink) {
      problems.push(`the ${receive} cold start was not launched by its link: the page saw ${JSON.stringify(result.launch)}`)
      continue
    }
    if (receive === 'subscribe') {
      const delivered = result.onLink.filter(entry => entry.url === expectedLink)
      if (delivered.length !== 1 || result.onLink.length !== 1)
        problems.push(`a page that only subscribes received ${JSON.stringify(result.onLink)} from onLink, expected the launch link once`)
      else if (delivered[0]!.initial !== true)
        problems.push('the launch link reached onLink without initial: true')
    }
    else {
      if (result.initialURL !== expectedLink)
        problems.push(`getInitialURL answered ${JSON.stringify(result.initialURL)}, expected the launch link`)
      if (result.onLink.length)
        problems.push(`a page that called getInitialURL was handed the launch link again by onLink: ${JSON.stringify(result.onLink)}`)
    }
  }
  return problems
}

/**
 * Where the pushed notification says to go, as a custom key beside `aps`.
 *
 * The part of a push an app routes on, and the part the tap has to carry
 * intact: WildLoop opens the plant camera off a key like this one.
 */
export const NOTIFICATION_ROUTE = '/e2e/notification-tap'

/**
 * The two pushes the notification UI test asks for: `cold` once the app is
 * killed, for its banner to be tapped (#255), and `foreground` once the app
 * that tap launched is open (#256).
 */
export type PushStage = 'cold' | 'foreground'

/**
 * The banner text of a stage's notification, which the UI test finds the
 * banner by: a pushed stage, or `local`, the one the page schedules (#258).
 */
export function notificationBody(run: string, stage: PushStage | 'local'): string {
  return `${run} ${stage}`
}

/**
 * The push the harness sends with `simctl push` for one stage.
 *
 * `craftE2E` and `stage` carry the run and the stage again as data, for the
 * page to hand back, so a push from another run or the other stage cannot
 * pass for this one.
 */
export function notificationPayload(run: string, stage: PushStage): string {
  return `${JSON.stringify({ aps: { alert: { title: 'Craft E2E', body: notificationBody(run, stage) } }, craftE2E: run, stage, route: NOTIFICATION_ROUTE })}\n`
}

/** What a page that subscribed late was handed after a tap launched the app. */
export interface NotificationTapReport {
  /** craftNotificationResponse events native code dispatched, counted from the page's first line. */
  dispatched: number
  /** What notifications.onTap handed a subscriber that arrived after the suite. */
  taps: Record<string, unknown>[]
  /** `typeof` notifications.onTap. */
  onTap: string
  /** `typeof` what onTap returned, or null when there was no onTap to call. */
  unsubscribe: string | null
}

/**
 * The page's report the UI test printed, read out of xcodebuild's output.
 *
 * `ios-uitests/NotificationTapColdStartTests.swift` writes one
 * `<label> CRAFT-E2E-NOTIFICATION {json}` line per tap: labelled
 * `CRAFT-E2E-NOTIFICATION-RESULT` for the push, `CRAFT-E2E-LOCAL-RESULT` for
 * the scheduled notification. None, or one whose JSON does not parse, is
 * null: the test never got that far.
 */
export function notificationTapReport(output: string, label = 'CRAFT-E2E-NOTIFICATION-RESULT'): NotificationTapReport | null {
  for (const line of output.split('\n')) {
    const at = line.indexOf(`${label} CRAFT-E2E-NOTIFICATION `)
    const match = at === -1 ? null : line.slice(at + label.length + 1).match(/^CRAFT-E2E-NOTIFICATION (\{.*\})\s*$/)
    if (!match) continue
    try {
      const report = JSON.parse(match[1]!) as NotificationTapReport
      if (Array.isArray(report.taps)) return report
    }
    catch {}
  }
  return null
}

/**
 * Why the notification tap cold start is not a pass, one line per reason.
 *
 * #255 lost a tap in two places, and the report tells them apart: nothing
 * dispatched is the app dropping it before any page existed, dispatched but
 * not handed to onTap is the page flushing it before anyone subscribed.
 */
export function notificationTapProblems(
  report: NotificationTapReport | null,
  run: string,
  evidence = 'xcodebuild-notification.log',
): string[] {
  if (!report)
    return [`the notification tap cold start never reported; see ${evidence}`]
  if (report.onTap !== 'function')
    return [`notifications.onTap is ${report.onTap}, so a page has no way to be handed a tap`]

  const problems: string[] = []
  if (report.unsubscribe !== 'function')
    problems.push(`notifications.onTap returned ${report.unsubscribe}, expected a function that unsubscribes`)
  if (report.dispatched === 0) {
    problems.push('the app never dispatched the tap that launched it; native code dropped it before the page existed')
    return problems
  }

  const ours = report.taps.filter(tap => tap.craftE2E === run)
  if (ours.length !== 1 || report.taps.length !== 1)
    problems.push(`a page that subscribed to notifications.onTap after launch was handed ${JSON.stringify(report.taps)}, expected the tap that launched the app once`)
  else if (ours[0]!.route !== NOTIFICATION_ROUTE)
    problems.push(`the tap reached the page without the push's route: it carried ${JSON.stringify(ours[0])}`)
  return problems
}

/**
 * Why the tap on the notification the page scheduled is not a pass (#258).
 *
 * The page scheduled it with `data`, and the tap must hand that back once,
 * nested values included. The bug handed the page `{}`: neither scheduler put
 * `data` into userInfo, so there was nothing for the tap to carry.
 */
export function localNotificationProblems(
  report: NotificationTapReport | null,
  run: string,
  evidence = 'xcodebuild-notification.log',
): string[] {
  if (!report)
    return [`the tap on the scheduled notification never reported; see ${evidence}`]
  if (report.dispatched === 0)
    return ['the app never dispatched the tap on the scheduled notification']
  if (report.taps.length === 1 && Object.keys(report.taps[0]!).length === 0)
    return ['a tap on a scheduled notification handed the page {}: the data it was scheduled with never reached userInfo']

  const ours = report.taps.filter(tap => tap.craftE2E === run && tap.stage === 'local')
  if (ours.length !== 1 || report.taps.length !== 1)
    return [`a tap on the scheduled notification handed the page ${JSON.stringify(report.taps)}, expected the data it was scheduled with once`]
  if ((ours[0]!.nested as { kept?: unknown } | undefined)?.kept !== true)
    return [`the scheduled notification's nested data did not survive: it carried ${JSON.stringify(ours[0])}`]
  return []
}

/** What a page that was open when a push arrived was handed by onReceive. */
export interface NotificationReceiptReport {
  received: Record<string, unknown>[]
  /** How many taps onTap had handed the page when it reported. */
  taps: number
  /** `typeof` notifications.onReceive. */
  onReceive: string
  /** `typeof` what onReceive returned, or null when there was no onReceive to call. */
  unsubscribe: string | null
}

/**
 * The receipt report the UI test printed, as a
 * `CRAFT-E2E-NOTIFICATION-RECEIVED-RESULT CRAFT-E2E-NOTIFICATION-RECEIVED {json}`
 * line. Null when there is none, or it does not parse.
 */
export function notificationReceiptReport(output: string): NotificationReceiptReport | null {
  for (const line of output.split('\n')) {
    const match = line.match(/CRAFT-E2E-NOTIFICATION-RECEIVED-RESULT CRAFT-E2E-NOTIFICATION-RECEIVED (\{.*\})\s*$/)
    if (!match) continue
    try {
      const report = JSON.parse(match[1]!) as NotificationReceiptReport
      if (Array.isArray(report.received)) return report
    }
    catch {}
  }
  return null
}

/**
 * Why the push that arrived while the app was open is not a pass (#256).
 *
 * The page must be handed that push once, through onReceive, with its data
 * intact. Not the cold push, which arrived while the app was not running and
 * was the tap's to deliver, and not as a tap: an arrival is not a tap, and a
 * page routing on onTap would jump to a screen nobody asked for.
 */
export function notificationReceiptProblems(
  report: NotificationReceiptReport | null,
  run: string,
  evidence = 'xcodebuild-notification.log',
): string[] {
  if (!report)
    return [`the push that arrived while the app was open never reported; see ${evidence}`]
  if (report.onReceive !== 'function')
    return [`notifications.onReceive is ${report.onReceive}, so a page cannot hear about a push that arrives while it is open`]

  const problems: string[] = []
  if (report.unsubscribe !== 'function')
    problems.push(`notifications.onReceive returned ${report.unsubscribe}, expected a function that unsubscribes`)
  const ours = report.received.filter(entry => entry.craftE2E === run && entry.stage === 'foreground')
  if (ours.length !== 1 || report.received.length !== 1)
    problems.push(`a page that was open when a push arrived was handed ${JSON.stringify(report.received)} by onReceive, expected that push once`)
  else if (ours[0]!.route !== NOTIFICATION_ROUTE)
    problems.push(`the push reached onReceive without its route: it carried ${JSON.stringify(ours[0])}`)
  if (report.taps > 1)
    problems.push(`the push that arrived while the app was open was handed to onTap as well; onTap had ${report.taps} taps`)
  return problems
}

/** The need the Android share case announces before it opens the menu. */
export const DISMISS_SHARE_MENU = 'dismiss-share-menu'

/** The needs the page has announced so far, in order, without repeats. */
export function awaitedNeeds(text: string): string[] {
  const needs: string[] = []
  for (const event of parseDriverOutput(text).events) {
    if (event.event === 'awaiting' && !needs.includes(event.need))
      needs.push(event.need)
  }
  return needs
}

/**
 * Whether Android's share menu holds input focus, read from
 * `adb shell dumpsys window`.
 *
 * The harness presses Back only once this is true, because Back goes to the
 * focused window. Focus rather than the activity being *resumed*, which is
 * what this first checked: the activity manager marks the chooser resumed
 * before its process has even created it. On the first CI run the chooser was
 * resumed at 50.37s and took focus at 52.63s. Back pressed in that gap goes to
 * the app, which closes, and the page never reports anything. That run passed
 * only because the harness happened to poll late.
 *
 * Matched by class name rather than by package, because the chooser moved:
 * `android/com.android.internal.app.ChooserActivity` up to Android 13, and
 * `com.android.intentresolver/com.android.intentresolver.ChooserActivity` from
 * 14.
 */
export function shareMenuInFront(dumpsysWindow: string): boolean {
  return dumpsysWindow
    .split('\n')
    .some(line => /mCurrentFocus=/.test(line) && /ChooserActivity/.test(line))
}

/**
 * Whether `dumpsys package` says a runtime permission is granted, or
 * `undefined` when the output does not mention it at all.
 *
 * Three answers rather than two, because "not mentioned" usually means the
 * manifest never declared the permission, and reading that as "not granted"
 * would hide the cause.
 */
export function runtimePermissionGranted(dumpsysPackage: string, permission: string): boolean | undefined {
  const escaped = permission.replaceAll('.', '\\.')
  // Whitespace or line start before the name, not a word boundary, which sits
  // after every dot, so `permission.CAMERA` would match inside
  // `android.permission.CAMERA`.
  const match = dumpsysPackage.match(new RegExp(`(?:^|\\s)${escaped}: granted=(true|false)`, 'm'))
  return match ? match[1] === 'true' : undefined
}

/**
 * The section names in an ELF file, or null when `bytes` is not a 64-bit
 * little-endian ELF.
 *
 * Read directly rather than through `readelf`, which a macOS host does not
 * have and a Linux runner has only by accident. Every Android ABI the harness
 * ships (arm64-v8a, x86_64) is ELF64 little-endian, so that is all this reads.
 */
export function elfSectionNames(bytes: Uint8Array): string[] | null {
  const ELF_MAGIC = [0x7F, 0x45, 0x4C, 0x46]
  if (bytes.length < 64 || ELF_MAGIC.some((byte, index) => bytes[index] !== byte)) return null
  if (bytes[4] !== 2 || bytes[5] !== 1) return null

  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const sectionTable = Number(view.getBigUint64(0x28, true))
  const entrySize = view.getUint16(0x3A, true)
  const count = view.getUint16(0x3C, true)
  const namesIndex = view.getUint16(0x3E, true)
  if (entrySize < 0x28 || sectionTable + entrySize * count > bytes.length || namesIndex >= count) return null

  const header = (index: number) => sectionTable + entrySize * index
  const namesOffset = Number(view.getBigUint64(header(namesIndex) + 0x18, true))
  const namesSize = Number(view.getBigUint64(header(namesIndex) + 0x20, true))
  if (namesOffset + namesSize > bytes.length) return null

  const names: string[] = []
  for (let index = 0; index < count; index++) {
    const start = namesOffset + view.getUint32(header(index), true)
    let end = start
    while (end < namesOffset + namesSize && bytes[end] !== 0) end++
    names.push(new TextDecoder().decode(bytes.subarray(start, end)))
  }
  return names
}

/**
 * Why a shipped `libcraft.so` and its symbols file are not what #204 settled
 * on, one line per reason.
 *
 * The library must carry no DWARF: every generated app's APK includes it, and
 * with DWARF it was about 5.5 MB per ABI. It must carry `.gnu_debuglink`, so a
 * crash can be matched to the symbols file. And the symbols file must actually
 * hold the DWARF, or the strip threw it away rather than moving it.
 */
export function strippedLibraryProblems(library: string[] | null, symbols: string[] | null): string[] {
  const problems: string[] = []
  if (!library) return ['libcraft.so is not an ELF64 little-endian file']
  const dwarf = library.filter(name => name.startsWith('.debug_'))
  if (dwarf.length)
    problems.push(`libcraft.so still carries ${dwarf.join(', ')}; release builds ship without DWARF (#204)`)
  if (!library.includes('.gnu_debuglink'))
    problems.push('libcraft.so has no .gnu_debuglink, so nothing ties it to its symbols file')
  if (!symbols)
    problems.push('android-symbols has no libcraft.so.debug beside the stripped library')
  else if (!symbols.includes('.debug_info'))
    problems.push('libcraft.so.debug holds no .debug_info; the strip discarded the DWARF instead of moving it')
  return problems
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
  'checkPermission',
  'clearWatch',
  'clipboardRead',
  'clipboardWrite',
  'getCurrentPosition',
  'getDeviceInfo',
  'haptic',
  'requestPermission',
  'share',
  'startListening',
  'stopListening',
  'vibrate',
  'watchPosition',
]

/**
 * The tested actions Zig must answer itself rather than hand back to Swift.
 *
 * Everything in ZIG_TESTED_ACTIONS except `requestPermission`, which Zig
 * deliberately leaves to Swift for location (`bridge_mobile_permissions.zig`
 * explains why: the answer arrives through the app's own
 * `CLLocationManagerDelegate`).
 */
export const ZIG_SERVED_ACTIONS = ZIG_TESTED_ACTIONS.filter(action => action !== 'requestPermission')

/** The actions the suite configures off, so Zig must refuse each by name. */
export const ZIG_REFUSED_ACTIONS = [
  'share',
  'startListening',
]

/**
 * The actions Zig was offered and handed back to the Swift host.
 *
 * Swift answers those with the same shapes, so the page cannot tell, and a
 * dispatch line is logged whether or not Zig then serves the call. This is
 * the line that says it did not.
 */
export function zigHandBacks(text: string): string[] {
  const plain = text.replace(ANSI, '')
  const seen = new Set<string>()
  for (const match of plain.matchAll(/ios: (\w+) (?:is not served here; handing it back|is declared unavailable; leaving it) to the host/g))
    seen.add(match[1]!)
  return [...seen].sort()
}

/**
 * The three ways an Android native says it gave up, as `android_dispatch.zig`
 * writes them.
 *
 * - fell through to the shim: Kotlin served the action instead of Zig.
 * - failed with no fallback: a callback into Zig gave up, and nothing will.
 * - could not reach the page: Zig had the answer and could not deliver it.
 *
 * `test/android_declines_test.zig` keeps every decline routed through one of
 * these, and `protocol.test.ts` reads the Zig source to check the wording has
 * not drifted from what is matched here. Either half alone would let the suite
 * stop seeing declines and keep passing.
 */
export const ANDROID_DECLINE_PHRASES = [
  'fell through to the shim',
  'failed with no fallback',
  'could not reach the page',
]

/**
 * Every Android decline line in a logcat dump, as `action: phrase (error)`.
 *
 * Why the runtime leg needs this rather than the registration line alone: the
 * first run in which the Zig library loaded reported "registered 103 natives"
 * and passed every case — while `getDeviceInfo` threw `NoSuchFieldError` on
 * every call and Kotlin quietly answered instead. Registration proves the
 * library bound. Only the absence of declines, with every decline made to
 * speak, proves Zig answered.
 */
export function androidDeclines(text: string): string[] {
  const plain = text.replace(ANSI, '')
  const phrases = ANDROID_DECLINE_PHRASES.map(phrase => phrase.replace(/ /g, '\\s')).join('|')
  const pattern = new RegExp(`craft: (\\w+) (${phrases}) \\(([^)]*)\\)`, 'g')
  return [...plain.matchAll(pattern)].map(match => `${match[1]}: ${match[2]} (${match[3]})`)
}
