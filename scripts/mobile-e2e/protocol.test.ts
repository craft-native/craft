import { describe, expect, it } from 'bun:test'
import { evaluateRun, hasTerminated, parseDriverOutput, REQUIRED_CASES, requiredCaseProblems, ZIG_REFUSED_ACTION, ZIG_TESTED_ACTIONS, zigDispatchedActions, zigRefusals } from './protocol'

const ESC = String.fromCharCode(27)

/** A transcript shaped like the one a real iOS run produces. */
const RUN = 'craft-e2e-ios-shim-1234'

function iosTranscript(overrides: { cases?: string[], omit?: string[], fail?: Record<string, string>, done?: boolean, run?: string } = {}): string {
  const planned = overrides.cases ?? REQUIRED_CASES.ios
  const omit = overrides.omit ?? []
  const fail = overrides.fail ?? {}
  const reported = planned.filter(name => !omit.includes(name))

  const lines = [
    'Some unrelated system chatter from the device',
    `[Craft Web] CRAFT-E2E ${JSON.stringify({ event: 'plan', platform: 'ios', run: overrides.run ?? RUN, cases: planned })}`,
    ...reported.map(name => `[Craft Web] CRAFT-E2E ${JSON.stringify({
      event: 'case',
      name,
      status: fail[name] ? 'fail' : 'pass',
      detail: fail[name] ?? '',
    })}`),
  ]

  if (overrides.done !== false) {
    const failed = reported.filter(name => fail[name]).length
    lines.push(`[Craft Web] CRAFT-E2E ${JSON.stringify({ event: 'done', passed: reported.length - failed, failed })}`)
  }

  return `${lines.join('\n')}\n`
}

describe('required cases', () => {
  it('keeps a success path and a rejection path on every platform', () => {
    expect(requiredCaseProblems()).toEqual([])
  })

  it('names the same bridge.ready case on both platforms', () => {
    expect(REQUIRED_CASES.ios).toContain('bridge.ready')
    expect(REQUIRED_CASES.android).toContain('bridge.ready')
  })
})

describe('parseDriverOutput', () => {
  it('finds events inside noisy, colour-coded device logs', () => {
    const text = [
      'unrelated',
      `${ESC}[33m[Craft Web] CRAFT-E2E {"event":"plan","platform":"ios","cases":["a"]}${ESC}[0m`,
      'more unrelated',
    ].join('\n')

    const { events, malformed } = parseDriverOutput(text)
    expect(malformed).toEqual([])
    expect(events).toEqual([{ event: 'plan', platform: 'ios', cases: ['a'] }])
  })

  it('reports a garbled event rather than skipping it', () => {
    const { events, malformed } = parseDriverOutput('CRAFT-E2E {"event":"plan"\n')
    expect(events).toEqual([])
    expect(malformed).toEqual(['{"event":"plan"'])
  })

  it('tolerates carriage returns from the console pty', () => {
    const { events } = parseDriverOutput('CRAFT-E2E {"event":"done","passed":1,"failed":0}\r\n')
    expect(events).toEqual([{ event: 'done', passed: 1, failed: 0 }])
  })

  // The exact shape the first Android run produced. Chromium wraps a page's
  // console.log before it reaches logcat, and taking the rest of the line
  // turned every event into an unparseable one - six of them, which failed a
  // run whose bridge had in fact worked.
  it('reads an event out of a Chromium console wrapper', () => {
    const line = '09-15 13:49:12.345  1234  1234 I chromium: [INFO:CONSOLE(39)] "CRAFT-E2E '
      + '{"event":"case","name":"clipboard.roundTrip","status":"pass","detail":""}", '
      + 'source: https://appassets.androidplatform.net/ (39)'

    const { events, malformed } = parseDriverOutput(line)
    expect(malformed).toEqual([])
    expect(events).toEqual([{ event: 'case', name: 'clipboard.roundTrip', status: 'pass', detail: '' }])
  })

  it('keeps one copy when the page reports through both channels', () => {
    const payload = '{"event":"case","name":"bridge.ready","status":"pass","detail":""}'
    const { events } = parseDriverOutput([
      `I chromium: [INFO:CONSOLE(39)] "CRAFT-E2E ${payload}", source: https://appassets.androidplatform.net/ (39)`,
      `D CraftBridge: CRAFT-E2E ${payload}`,
    ].join('\n'))

    expect(events).toEqual([{ event: 'case', name: 'bridge.ready', status: 'pass', detail: '' }])
  })

  it('does not stop at a brace inside a string', () => {
    const { events, malformed } = parseDriverOutput(
      'CRAFT-E2E {"event":"case","name":"a","status":"fail","detail":"read back \\"{oops}\\""}',
    )
    expect(malformed).toEqual([])
    expect(events).toEqual([{ event: 'case', name: 'a', status: 'fail', detail: 'read back "{oops}"' }])
  })

  it('still reports a genuinely truncated event', () => {
    const { events, malformed } = parseDriverOutput('CRAFT-E2E {"event":"plan","cases":["a"')
    expect(events).toEqual([])
    expect(malformed).toEqual(['{"event":"plan","cases":["a"'])
  })
})

describe('evaluateRun', () => {
  it('passes a complete run', () => {
    const verdict = evaluateRun('ios', iosTranscript())
    expect(verdict.failures).toEqual([])
    expect(verdict.ok).toBe(true)
    expect(verdict.passed).toEqual(REQUIRED_CASES.ios)
  })

  // The failure the workflow this replaces actually shipped: nothing ran, and
  // nothing said so.
  it('fails an empty log instead of finding nothing to complain about', () => {
    const verdict = evaluateRun('ios', '')
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toEqual(['the test page never announced a plan; it did not reach the native bridge'])
  })

  it('fails a log with device chatter but no driver output', () => {
    const verdict = evaluateRun('ios', 'Booting\nAssertion failed somewhere unrelated\n')
    expect(verdict.ok).toBe(false)
  })

  it('fails when a planned case never reports', () => {
    const verdict = evaluateRun('ios', iosTranscript({ omit: ['clipboard.roundTrip'], done: false }))
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('case clipboard.roundTrip was planned but never reported; the suite stopped early')
    expect(verdict.failures).toContain('the suite never reported done')
  })

  it('fails when the suite is hollowed out to the easy cases', () => {
    const verdict = evaluateRun('ios', iosTranscript({ cases: ['bridge.ready'] }))
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('required case geolocation.disabled.rejects is not in the suite the page ran')
    expect(verdict.failures).toContain('required case clipboard.roundTrip is not in the suite the page ran')
  })

  it('carries the page detail into the failure so the reason is the value seen', () => {
    const verdict = evaluateRun('ios', iosTranscript({ fail: { 'clipboard.roundTrip': 'read back ""' } }))
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('case clipboard.roundTrip failed: read back ""')
    expect(verdict.failed).toEqual(['clipboard.roundTrip'])
  })

  it('fails when the tally disagrees with the transcript', () => {
    const text = [
      'CRAFT-E2E {"event":"plan","platform":"ios","cases":["bridge.ready","deviceInfo.isSimulator","clipboard.roundTrip","geolocation.disabled.rejects"]}',
      ...REQUIRED_CASES.ios.map(name => `CRAFT-E2E {"event":"case","name":"${name}","status":"pass","detail":""}`),
      'CRAFT-E2E {"event":"done","passed":99,"failed":0}',
    ].join('\n')

    const verdict = evaluateRun('ios', text)
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('done says 99 passed / 0 failed, transcript shows 4 / 0')
  })

  it('fails when the app is not the platform the leg was built for', () => {
    const text = iosTranscript().replace('"platform":"ios"', '"platform":"android"')
    const verdict = evaluateRun('ios', text)
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('the app reports platform android, expected ios')
  })

  // Android reads its transcript out of a ring buffer that survives an
  // uninstall, so a leg whose app printed nothing could otherwise be evaluated
  // against the previous run's output.
  it('refuses a transcript left over from an earlier run', () => {
    const verdict = evaluateRun('ios', iosTranscript({ run: 'craft-e2e-ios-shim-OLD' }), RUN)
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain(
      `the transcript is from run "craft-e2e-ios-shim-OLD", not "${RUN}"; this is stale output, not this run's`,
    )
  })

  it('accepts the transcript when the run matches', () => {
    expect(evaluateRun('ios', iosTranscript(), RUN).ok).toBe(true)
  })

  it('does not check the run when none was given', () => {
    expect(evaluateRun('ios', iosTranscript({ run: 'anything' })).ok).toBe(true)
  })

  // "Planned, and did report" is not the same as "passed". A third status
  // satisfies both of the other checks while leaving the case unasserted.
  it('refuses a status that is neither pass nor fail', () => {
    const text = [
      `CRAFT-E2E ${JSON.stringify({ event: 'plan', platform: 'ios', run: RUN, cases: REQUIRED_CASES.ios })}`,
      ...REQUIRED_CASES.ios.map((name, index) => `CRAFT-E2E ${JSON.stringify({
        event: 'case',
        name,
        status: index === 0 ? 'skipped' : 'pass',
        detail: '',
      })}`),
      `CRAFT-E2E ${JSON.stringify({ event: 'done', passed: 3, failed: 0 })}`,
    ].join('\n')

    const verdict = evaluateRun('ios', text, RUN)
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('case bridge.ready reported status "skipped", which is neither pass nor fail')
  })

  it('reports the driver fatal when the bridge never appeared', () => {
    const verdict = evaluateRun('ios', 'CRAFT-E2E {"event":"fatal","reason":"window.craft never appeared"}\n')
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toContain('driver reported a fatal condition: window.craft never appeared')
  })

  it('evaluates an android transcript against the android list', () => {
    const lines = [
      `CRAFT-E2E ${JSON.stringify({ event: 'plan', platform: 'android', run: RUN, cases: REQUIRED_CASES.android })}`,
      ...REQUIRED_CASES.android.map(name => `CRAFT-E2E ${JSON.stringify({ event: 'case', name, status: 'pass', detail: '' })}`),
      `CRAFT-E2E ${JSON.stringify({ event: 'done', passed: REQUIRED_CASES.android.length, failed: 0 })}`,
    ].join('\n')

    expect(evaluateRun('android', lines).ok).toBe(true)
    // The same transcript must not satisfy the iOS leg.
    expect(evaluateRun('ios', lines).ok).toBe(false)
  })
})

describe('hasTerminated', () => {
  it('waits for the whole event, not the first bytes of it', () => {
    // The harness kills the app the moment this is true, so a substring match
    // would cut the line it was waiting for and report it as malformed.
    expect(hasTerminated('[Craft Web] CRAFT-E2E {"event":"done","pa')).toBe(false)
    expect(hasTerminated('[Craft Web] CRAFT-E2E {"event":"done","passed":4,"failed":0}')).toBe(true)
  })

  it('treats a fatal as terminal too', () => {
    expect(hasTerminated('CRAFT-E2E {"event":"fatal","reason":"window.craft never appeared"}')).toBe(true)
  })

  it('is false while cases are still arriving', () => {
    expect(hasTerminated('CRAFT-E2E {"event":"case","name":"a","status":"pass"}')).toBe(false)
  })
})

describe('zig attribution', () => {
  it('names the actions the Zig dispatcher saw', () => {
    const text = [
      'info: craft-bridge dispatch t=mobile a=getDeviceInfo i=3',
      `${ESC}[32minfo: craft-bridge dispatch t=mobile a=clipboardWrite i=4${ESC}[0m`,
      'info: something else entirely',
    ].join('\n')

    expect(zigDispatchedActions(text)).toEqual(['clipboardWrite', 'getDeviceInfo'])
  })

  // The reason this counts actions and not lines: every report the page makes
  // goes through craft.log, and log is itself dispatched. A bare count is
  // satisfied by the reporting traffic while Swift serves everything tested.
  it('is not satisfied by the page reporting through craft.log', () => {
    const logOnly = Array.from({ length: 12 }, () => 'info: craft-bridge dispatch t=mobile a=log i=null').join('\n')
    const dispatched = zigDispatchedActions(logOnly)

    expect(dispatched).toEqual(['log'])
    expect(ZIG_TESTED_ACTIONS.filter(action => !dispatched.includes(action))).toEqual(ZIG_TESTED_ACTIONS)
  })

  it('is empty for a run the platform shim served alone', () => {
    expect(zigDispatchedActions(iosTranscript())).toEqual([])
    expect(zigRefusals(iosTranscript())).toEqual([])
  })

  it('reads the refusal Zig writes through its own capability gate', () => {
    const text = 'info: ios: refusing getCurrentPosition; enableGeolocation is not enabled in craft.config.json'
    expect(zigRefusals(text)).toEqual([ZIG_REFUSED_ACTION])
  })

  it('expects a refusal for an action the suite actually exercises', () => {
    expect(ZIG_TESTED_ACTIONS).toContain(ZIG_REFUSED_ACTION)
  })
})
