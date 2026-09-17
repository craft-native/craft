import { describe, expect, it } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ANDROID_DECLINE_PHRASES, androidDeclines, awaitedNeeds, deepLinkProblems, deepLinkReports, deepLinkResults, DISMISS_SHARE_MENU, elfSectionNames, evaluateRun, hasTerminated, parseDriverOutput, REQUIRED_CASES, requiredCaseProblems, runtimePermissionGranted, shareMenuInFront, strippedLibraryProblems, ZIG_REFUSED_ACTIONS, ZIG_SERVED_ACTIONS, ZIG_TESTED_ACTIONS, zigDispatchedActions, zigHandBacks, zigRefusals } from './protocol'

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
    expect(verdict.failures).toContain('required case share.disabled.rejects is not in the suite the page ran')
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
      `CRAFT-E2E ${JSON.stringify({ event: 'plan', platform: 'ios', cases: REQUIRED_CASES.ios })}`,
      ...REQUIRED_CASES.ios.map(name => `CRAFT-E2E {"event":"case","name":"${name}","status":"pass","detail":""}`),
      'CRAFT-E2E {"event":"done","passed":99,"failed":0}',
    ].join('\n')

    const verdict = evaluateRun('ios', text)
    expect(verdict.ok).toBe(false)
    expect(verdict.failures).toEqual([`done says 99 passed / 0 failed, transcript shows ${REQUIRED_CASES.ios.length} / 0`])
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
    const text = [
      'info: ios: refusing startListening; enableSpeechRecognition is not enabled in craft.config.json',
      'info: ios: refusing share; enableShare is not enabled in craft.config.json',
    ].join('\n')
    expect(zigRefusals(text)).toEqual(ZIG_REFUSED_ACTIONS)
  })

  it('reads both ways Zig hands an action back to Swift', () => {
    const text = [
      'info: craft-bridge dispatch t=mobile a=requestPermission i=9',
      'info: ios: requestPermission is not served here; handing it back to the host',
      `${ESC}[32minfo: ios: openSettings is declared unavailable; leaving it to the host${ESC}[0m`,
      'info: craft-bridge dispatch t=mobile a=getCurrentPosition i=10',
    ].join('\n')

    expect(zigHandBacks(text)).toEqual(['openSettings', 'requestPermission'])
    expect(zigHandBacks(iosTranscript())).toEqual([])
  })

  // The one deliberate hand-back. Swift owns location authorization, and
  // listing it as served would fail every run for doing what it was designed to.
  it('expects Zig to serve every tested action except the one it leaves to Swift', () => {
    expect(ZIG_TESTED_ACTIONS.filter(action => !ZIG_SERVED_ACTIONS.includes(action))).toEqual(['requestPermission'])
  })

  it('expects refusals only for actions the suite actually exercises', () => {
    for (const action of ZIG_REFUSED_ACTIONS)
      expect(ZIG_TESTED_ACTIONS).toContain(action)
  })
})

describe('share menu', () => {
  it('reads what the page is waiting for, once, from either log channel', () => {
    const awaiting = JSON.stringify({ event: 'awaiting', name: 'share.dismissed.resolvesFalse', need: DISMISS_SHARE_MENU })
    const text = [
      `09-16 11:29:25.000  2611  2611 I CraftBridge: CRAFT-E2E ${awaiting}`,
      `09-16 11:29:25.001  2611  2611 I chromium: [INFO:CONSOLE(1)] "CRAFT-E2E ${awaiting}", source: https://appassets.androidplatform.net/ (1)`,
    ].join('\n')

    expect(awaitedNeeds(text)).toEqual([DISMISS_SHARE_MENU])
    expect(awaitedNeeds('CRAFT-E2E {"event":"case","name":"a","status":"pass"}')).toEqual([])
  })

  // Both spellings the chooser has had, as `dumpsys window` prints them.
  it('sees the menu holding focus on Android 14 and on 13', () => {
    expect(shareMenuInFront([
      '  mCurrentFocus=Window{56c630c u0 com.android.intentresolver/com.android.intentresolver.ChooserActivity}',
      '  mFocusedApp=ActivityRecord{144007559 u0 com.android.intentresolver/.ChooserActivity t7}',
    ].join('\n'))).toBe(true)

    expect(shareMenuInFront(
      '  mCurrentFocus=Window{2b7a1f u0 android/com.android.internal.app.ChooserActivity}',
    )).toBe(true)
  })

  it('does not see a menu that is resumed but not yet focused', () => {
    // The gap the first CI run fell into. The activity manager already calls
    // the chooser the focused app while the probe's window still has input
    // focus, so Back here would close the app rather than the menu.
    const dumpsys = [
      '  mCurrentFocus=Window{77aa u0 dev.craft.e2e.probe/dev.craft.e2e.probe.MainActivity}',
      '  mFocusedApp=ActivityRecord{144007559 u0 com.android.intentresolver/.ChooserActivity t7}',
    ].join('\n')
    expect(shareMenuInFront(dumpsys)).toBe(false)
  })
})

describe('cold-start deep links', () => {
  const LINK = 'crafte2eprobe://e2e/cold?run=craft-e2e-ios-shim-1'
  const line = (receive: string, report: object) =>
    `CRAFT-E2E-DEEPLINK-RESULT ${receive} ${LINK}&receive=${receive} CRAFT-E2E-DEEPLINK ${JSON.stringify(report)}`
  const passing = [
    'Test Case started.',
    line('subscribe', { launch: `${LINK}&receive=subscribe`, receive: 'subscribe', onLink: [{ url: `${LINK}&receive=subscribe`, initial: true }], initialURL: null }),
    line('both', { launch: `${LINK}&receive=both`, receive: 'both', onLink: [], initialURL: `${LINK}&receive=both` }),
  ].join('\n')

  it('passes a page that got the launch link once either way', () => {
    expect(deepLinkProblems(deepLinkResults(passing), LINK)).toEqual([])
  })

  // The bug: the link was dispatched before onLink could exist.
  it('fails a subscriber that never received the launch link', () => {
    const text = line('subscribe', { launch: `${LINK}&receive=subscribe`, receive: 'subscribe', onLink: [], initialURL: null })
    expect(deepLinkProblems(deepLinkResults(`${text}\n${passing.split('\n')[2]}`), LINK))
      .toEqual(['a page that only subscribes received [] from onLink, expected the launch link once'])
  })

  // The guard on the fix: replaying to subscribers must not double-deliver.
  it('fails a page handed the launch link by both getInitialURL and onLink', () => {
    const text = line('both', { launch: `${LINK}&receive=both`, receive: 'both', onLink: [{ url: `${LINK}&receive=both`, initial: true }], initialURL: `${LINK}&receive=both` })
    const problems = deepLinkProblems(deepLinkResults(`${passing.split('\n')[1]}\n${text}`), LINK)
    expect(problems).toHaveLength(1)
    expect(problems[0]).toContain('handed the launch link again by onLink')
  })

  it('names a cold start that never reported, and one launched by something else', () => {
    const stale = line('subscribe', { launch: 'crafte2eprobe://e2e/cold?run=an-earlier-run&receive=subscribe', receive: 'subscribe', onLink: [], initialURL: null })
    expect(deepLinkProblems(deepLinkResults(stale), LINK)).toEqual([
      'the subscribe cold start was not launched by its link: the page saw "crafte2eprobe://e2e/cold?run=an-earlier-run&receive=subscribe"',
      'the both cold start never reported; see xcodebuild-deeplink.log',
    ])
  })

  it('fails an onLink that returns no way to unsubscribe, and ignores a report that predates the field', () => {
    const noUnsubscribe = line('subscribe', { launch: `${LINK}&receive=subscribe`, receive: 'subscribe', onLink: [{ url: `${LINK}&receive=subscribe`, initial: true }], initialURL: null, unsubscribe: 'undefined' })
    expect(deepLinkProblems(deepLinkResults(`${noUnsubscribe}\n${passing.split('\n')[2]}`), LINK))
      .toEqual(['onLink returned undefined in the subscribe cold start, expected a function that unsubscribes'])
    expect(deepLinkProblems(deepLinkResults(passing), LINK)).toEqual([])
  })
})

describe('cold-start deep links on Android', () => {
  const LINK = 'crafte2eprobe://e2e/cold?run=craft-e2e-android-shim-1'
  const report = { launch: `${LINK}&receive=subscribe`, receive: 'subscribe', onLink: [{ url: `${LINK}&receive=subscribe`, initial: true }], initialURL: null, unsubscribe: 'function' }
  const json = JSON.stringify(report)

  it('reads the report once, from either log channel', () => {
    // console.log reaches logcat under chromium, quoted, with its source; the
    // same line through craft.log arrives under the bridge's tag.
    const text = [
      `09-17 11:29:25.000  2611  2611 I chromium: [INFO:CONSOLE(1)] "CRAFT-E2E-DEEPLINK ${json}", source: https://appassets.androidplatform.net/ (1)`,
      `09-17 11:29:25.001  2611  2611 D CraftBridge: CRAFT-E2E-DEEPLINK ${json}`,
    ].join('\n')

    expect(deepLinkReports(text)).toEqual([report])
  })

  it('keeps two different reports apart, so the runner can refuse them', () => {
    const other = JSON.stringify({ ...report, onLink: [] })
    expect(deepLinkReports(`D CraftBridge: CRAFT-E2E-DEEPLINK ${json}\nD CraftBridge: CRAFT-E2E-DEEPLINK ${other}`)).toHaveLength(2)
  })

  it('is not mistaken for a driver event, or a malformed one, by the run verdict', () => {
    const lines = parseDriverOutput(`D CraftBridge: CRAFT-E2E-DEEPLINK ${json}`)
    expect(lines.events).toEqual([])
    expect(lines.malformed).toEqual([])
  })

  it('names the logcat file for a cold start that never reported', () => {
    expect(deepLinkProblems([{ ...report, receive: 'subscribe', link: `${LINK}&receive=subscribe` }], LINK, receive => `android-shim/deeplink-${receive}-logcat.txt`))
      .toEqual(['the both cold start never reported; see android-shim/deeplink-both-logcat.txt'])
  })
})

/** A minimal ELF64 little-endian file whose section header table names `sections`. */
function elfWith(sections: string[]): Uint8Array {
  const names = ['', ...sections, '.shstrtab']
  const strtab = new TextEncoder().encode(`${names.join('\0')}\0`)
  const headerSize = 64
  const entrySize = 64
  const tableOffset = headerSize + strtab.length
  const bytes = new Uint8Array(tableOffset + entrySize * names.length)
  const view = new DataView(bytes.buffer)
  bytes.set([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1], 0)
  view.setBigUint64(0x28, BigInt(tableOffset), true)
  view.setUint16(0x3A, entrySize, true)
  view.setUint16(0x3C, names.length, true)
  view.setUint16(0x3E, names.length - 1, true)
  bytes.set(strtab, headerSize)
  let nameOffset = 0
  names.forEach((name, index) => {
    const at = tableOffset + entrySize * index
    view.setUint32(at, nameOffset, true)
    nameOffset += new TextEncoder().encode(name).length + 1
    if (name === '.shstrtab') {
      view.setBigUint64(at + 0x18, BigInt(headerSize), true)
      view.setBigUint64(at + 0x20, BigInt(strtab.length), true)
    }
  })
  return bytes
}

describe('the shipped Android library', () => {
  const stripped = ['.dynsym', '.text', '.symtab', '.gnu_debuglink']
  const debug = ['.debug_info', '.debug_line', '.symtab']

  it('reads section names out of an ELF64 file, and refuses anything else', () => {
    expect(elfSectionNames(elfWith(['.text', '.debug_info']))).toEqual(['', '.text', '.debug_info', '.shstrtab'])
    expect(elfSectionNames(new Uint8Array([0x7F, 0x45, 0x4C, 0x46]))).toBeNull()
    expect(elfSectionNames(new TextEncoder().encode('not an elf file at all, but long enough to have a header, surely'))).toBeNull()
  })

  it('passes a stripped library with its DWARF moved beside it', () => {
    expect(strippedLibraryProblems(elfSectionNames(elfWith(stripped)), elfSectionNames(elfWith(debug)))).toEqual([])
  })

  // #204 as found: the release library still carrying its debug info.
  it('fails a library that still ships DWARF', () => {
    const unstripped = elfSectionNames(elfWith(['.dynsym', '.text', '.debug_info', '.debug_str', '.symtab']))
    expect(strippedLibraryProblems(unstripped, elfSectionNames(elfWith(debug)))).toEqual([
      'libcraft.so still carries .debug_info, .debug_str; release builds ship without DWARF (#204)',
      'libcraft.so has no .gnu_debuglink, so nothing ties it to its symbols file',
    ])
  })

  it('fails a strip that threw the DWARF away instead of keeping it', () => {
    expect(strippedLibraryProblems(elfSectionNames(elfWith(stripped)), null))
      .toEqual(['android-symbols has no libcraft.so.debug beside the stripped library'])
    expect(strippedLibraryProblems(elfSectionNames(elfWith(stripped)), elfSectionNames(elfWith(['.symtab']))))
      .toEqual(['libcraft.so.debug holds no .debug_info; the strip discarded the DWARF instead of moving it'])
  })
})

describe('runtime permission state', () => {
  // As `dumpsys package` prints a coarse-only grant on Android 14.
  const dumpsys = [
    '    runtime permissions:',
    '      android.permission.ACCESS_FINE_LOCATION: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]',
    '      android.permission.ACCESS_COARSE_LOCATION: granted=true, flags=[ USER_SET|USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]',
    '      android.permission.ACCESS_BACKGROUND_LOCATION: granted=false, flags=[ RESTRICTION_INSTALLER_EXEMPT]',
  ].join('\n')

  it('reads granted and not granted apart', () => {
    expect(runtimePermissionGranted(dumpsys, 'android.permission.ACCESS_COARSE_LOCATION')).toBe(true)
    expect(runtimePermissionGranted(dumpsys, 'android.permission.ACCESS_FINE_LOCATION')).toBe(false)
  })

  it('says nothing about a permission the output never mentions', () => {
    expect(runtimePermissionGranted(dumpsys, 'android.permission.CAMERA')).toBeUndefined()
  })

  it('does not read one permission as another that ends the same way', () => {
    // A dot left unescaped would match any character, and a name without a
    // boundary would match inside a longer one.
    expect(runtimePermissionGranted(dumpsys, 'permission.ACCESS_COARSE_LOCATION')).toBeUndefined()
    expect(runtimePermissionGranted('androidXpermissionXCAMERA: granted=true', 'android.permission.CAMERA')).toBeUndefined()
  })
})

describe('android declines', () => {
  // The lines the first Android runtime run actually produced, plus the two
  // decline kinds it did not hit, so all three are read the way they are
  // written.
  const logcat = [
    '09-16 11:29:24.000  2611  2611 I CraftNative: craft: libcraft.so loaded',
    '09-16 11:29:24.001  2611  2611 I CraftNative: craft: registered 103 natives on com/craft/runtime/CraftNative',
    '09-16 11:29:24.535  2611  2705 W System.err: java.lang.NoSuchFieldError: no "J" field "longVersionCode"',
    '09-16 11:29:24.535  2611  2705 W CraftNative: craft: getDeviceInfo fell through to the shim (JavaException)',
    '09-16 11:29:25.000  2611  2705 E CraftNative: craft: locationResult failed with no fallback (OutOfMemory)',
    '09-16 11:29:26.000  2611  2705 E CraftNative: craft: reviewError could not reach the page (NoWebView)',
    '09-16 11:29:26.100  2611  2705 D CraftBridge: CRAFT-E2E {"event":"done","passed":4,"failed":0}',
  ].join('\n')

  it('reads every kind of decline, and names the action and the error', () => {
    expect(androidDeclines(logcat)).toEqual([
      'getDeviceInfo: fell through to the shim (JavaException)',
      'locationResult: failed with no fallback (OutOfMemory)',
      'reviewError: could not reach the page (NoWebView)',
    ])
  })

  // The case that shipped: bound, every page case passing, and Kotlin
  // answering. Registration is not a decline and must not be read as one —
  // and a run with nothing but registration is the clean result.
  it('does not mistake loading or registration for a decline', () => {
    const clean = logcat.split('\n').filter(line => !/fell through|no fallback|reach the page/.test(line)).join('\n')
    expect(androidDeclines(clean)).toEqual([])
  })

  it('matches the wording android_dispatch.zig actually writes', () => {
    // Read from the Zig source rather than trusted, because each side alone
    // would let a reworded helper turn the runtime leg blind: Zig would log a
    // phrase this suite no longer matched, and every decline would pass.
    const dispatch = readFileSync(join(import.meta.dir, '../../packages/zig/src/android_dispatch.zig'), 'utf8')
    for (const phrase of ANDROID_DECLINE_PHRASES)
      expect(dispatch).toContain(`" ${phrase} ({s})"`)
  })
})

