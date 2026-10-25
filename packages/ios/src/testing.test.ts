import { afterAll, afterEach, describe, expect, it } from 'bun:test'
import { readFileSync, rmSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { init, restoreShell } from './index'
import type { SimulatorStep, TimedTouchPoint } from './testing'
import { createNativeMutationValidator, initSimulatorDriver, serializeSimulatorSteps } from './testing'
import { createTempDir, removeAllTempDirs } from '../../typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const folders: string[] = []
function folder(): string {
  const path = createTempDir('craft-shell-test-')
  folders.push(path)
  return path
}
afterEach(() => folders.splice(0).forEach(path => rmSync(path, { recursive: true, force: true })))

describe('package-owned iOS shells', () => {
  it('restores missing Swift for the app, widget and watch without rewriting project metadata', async () => {
    const output = folder()
    await init({ name: 'Zero Swift', bundleId: 'org.example.zero', output, runtimeDir: null, config: { enableWatchApp: true, enableLiveActivities: true } })
    const project = readFileSync(join(output, 'project.yml'), 'utf8')
    const sources = ['Sources/ZeroSwiftApp.swift', 'Shared/CraftActivityAttributes.swift', 'WidgetExtension/ZeroSwiftLiveActivity.swift', 'WatchExtension/ZeroSwiftWatchApp.swift']
    const original = sources.map(path => readFileSync(join(output, path), 'utf8'))
    for (const path of ['Sources', 'Shared', 'WidgetExtension', 'WatchExtension']) rmSync(join(output, path), { recursive: true })
    restoreShell(output)
    expect(sources.map(path => readFileSync(join(output, path), 'utf8'))).toEqual(original)
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).toBe(project)
  })

  it('generates a driver configured for any app and preserves timestamps on a repeat run', () => {
    const output = folder()
    const options = { output, bundleId: 'org.example.app', tabs: ['One', 'A "quote"', 'A \\(literal)'], controlUrl: 'http://localhost:4444', projectName: 'ExampleDriver' }
    initSimulatorDriver(options)
    const file = join(output, 'UITests/DriverTests.swift')
    const source = readFileSync(file, 'utf8')
    expect(source).toContain('XCUIApplication(bundleIdentifier: "org.example.app")')
    expect(source).toContain('"CRAFT_TEST_CONTROL"')
    expect(source).toContain('XCTAssertTrue(ok, what)')
    expect(source).toContain('let tabIdentifiers: [String: String] = [:]')
    expect(source).not.toContain('{{')
    expect(source).not.toContain('training.hq')
    const mtime = statSync(file).mtimeMs
    initSimulatorDriver(options)
    expect(statSync(file).mtimeMs).toBe(mtime)
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).toContain('ExampleDriverUITests:')
    expect(() => initSimulatorDriver({ ...options, projectName: '../escape' })).toThrow()
    expect(() => initSimulatorDriver({ ...options, bundleId: 'bad"id' })).toThrow()
  })

  it('generates stable native tab identities independently of changing captions', () => {
    const output = folder()
    const identifier = 'tab-quote"\\value'
    const options = { output, bundleId: 'org.example.app', tabs: ['Health', 'Second'], tabIdentifiers: { Health: 'tab-heart', Second: identifier } }
    initSimulatorDriver(options)
    const path = join(output, 'UITests/DriverTests.swift')
    const source = readFileSync(path, 'utf8')
    expect(source).toContain(`let tabIdentifiers: [String: String] = ["Health": "tab-heart", "Second": ${JSON.stringify(identifier)}]`)
    expect(source).toContain('if let identifier = tabIdentifiers[name]')
    expect(source).toContain('NSPredicate(format: "identifier == %@", identifier)).firstMatch')
    expect(source).toContain('NSPredicate(format: "label == %@", name)')
    expect(source).not.toContain('{{')
    const mtime = statSync(path).mtimeMs
    initSimulatorDriver(options)
    expect(statSync(path).mtimeMs).toBe(mtime)
    expect(() => initSimulatorDriver({ ...options, tabIdentifiers: { Health: ' ' } })).toThrow('nonempty')
    expect(() => initSimulatorDriver({ ...options, tabIdentifiers: { '': 'tab-heart' } })).toThrow('nonempty')
    expect(readFileSync(path, 'utf8')).toBe(source)
  })

  it('starts a universal-link handoff after XCTest finishes launching the host', () => {
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app' })
    const host = readFileSync(join(output, 'Host/HostApp.swift'), 'utf8')
    const driver = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    expect(host).toContain('.accessibilityIdentifier("craft-driver-open-universal-link")')
    expect(host).not.toContain('.task { await openUniversalLinkIfRequested() }')
    expect(host).toContain('[.universalLinksOnly: true]')
    expect(driver).toMatch(/host\.launch\(\)\s+host\.buttons\["craft-driver-open-universal-link"\]\.tap\(\)\s+let opened = app\.wait\(for: \.runningForeground, timeout: 75\)/)
  })

  it('stops a journey when a control-server hook fails', () => {
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app' })
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    expect(source).toContain('(200..<300).contains(response.statusCode)')
    expect(source).toContain('if error == nil, let response = response as? HTTPURLResponse')
    const hook = source.slice(source.indexOf('case "exec":'), source.indexOf('case "openurl":'))
    expect(hook).toContain('guard let data = get(')
    expect(hook).toContain('check(false, "exec ')
    expect(hook).not.toContain('?? "no answer"')
    expect(source).toContain('continueAfterFailure = false')
  })

  it('serializes typed journeys and rejects extra wire commands and invalid coordinates', () => {
    expect(serializeSimulatorSteps([
      { command: 'launch' }, { command: 'field', index: 0, text: 'demo@example.org' },
      { command: 'tap', text: 'Sign in' }, { command: 'expect', text: 'Today', seconds: 10 },
      { command: 'net', state: 'offline' }, { command: 'tabbar', state: 'shown' },
    ])).toBe('launch\nfield 0 demo@example.org\ntap Sign in\nexpect Today | 10\nnet offline\ntabbar shown\n')
    expect(() => serializeSimulatorSteps([{ command: 'tap', text: 'One\nterminate' }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'tapxy', x: 2, y: 0 }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'wait', seconds: NaN }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'typeid', id: 'two words', text: 'x' }])).toThrow()
    expect(serializeSimulatorSteps([{ command: 'universallink', url: 'https://example.org/profile' }]))
      .toBe('universallink https://example.org/profile\n')
    expect(() => serializeSimulatorSteps([{ command: 'universallink', url: 'example://profile' }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'universallink', url: 'https://example.org\nterminate' }])).toThrow()
  })

  it('serializes controlled drags and rejects coordinates outside the app', () => {
    expect(serializeSimulatorSteps([
      { command: 'drag', fromX: 0.6, fromY: 0.32, toX: 0.5, toY: 0.32 },
    ])).toBe('drag 0.6 0.32 0.5 0.32\n')
    for (const coordinate of [-0.1, 1.1, NaN, Infinity]) {
      expect(() => serializeSimulatorSteps([
        { command: 'drag', fromX: coordinate, fromY: 0.3, toX: 0.5, toY: 0.3 },
      ])).toThrow()
    }
  })

  it('serializes native slider interactions and verifies app handoffs without launching another app', () => {
    expect(serializeSimulatorSteps([
      { command: 'sliderid', id: 'elevation', position: 0.5 },
      { command: 'expectapp', text: 'com.apple.Maps', seconds: 10 },
    ])).toBe('sliderid elevation 0.5\nexpectapp com.apple.Maps | 10\n')
    for (const position of [-1, 1.1, NaN, Infinity])
      expect(() => serializeSimulatorSteps([{ command: 'sliderid', id: 'elevation', position }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'sliderid', id: 'two sliders', position: 0.5 }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'expectapp', text: 'Maps\nlaunch' }])).toThrow()
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app' })
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    expect(source).toContain('slider.adjust(toNormalizedSliderPosition: CGFloat(position))')
    const handoff = source.slice(source.indexOf('case "expectapp":'), source.indexOf('case "field":'))
    expect(handoff).toContain('target.wait(for: .runningForeground')
    expect(handoff).not.toContain('target.launch()')
  })

  it('types once a field holds the keyboard, and scrolls by held drags', () => {
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app' })
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    const command = (name: string, next: string) => source.slice(source.indexOf(`case "${name}":`), source.indexOf(`case "${next}":`))
    // A tap is not focus: a cold simulator keyboard took 20s to take one.
    for (const typing of [command('typeid', 'sliderid'), command('field', 'expect')]) {
      expect(typing).toContain('guard focus(')
      expect(typing).not.toContain('Thread.sleep')
    }
    expect(source).toContain('func focus(_ target: XCUIElement, seconds: Double = 15) -> Bool')
    expect(source).toContain('"hasKeyboardFocus == 1"')
    // A flick's distance depends on how its touches arrive; a held drag's does not.
    const scrolling = command('scrollto', 'swipe')
    expect(scrolling).toContain('scrollPage(towardTop: towardTop)')
    expect(scrolling).not.toContain('app.swipeUp()')
    expect(source).toContain('thenHoldForDuration: 0.2')
    expect(source).toContain('keyboard.frame.minY - 24')
    // A fresh simulator's first request to the runner can outlast one wait.
    expect(source).toContain('data = remoteScript()')
    expect(source).toContain('XCTWaiter().wait(for: [done], timeout: 15) == .completed')
  })

  it('checks actual native field values after a real edit-menu gesture', () => {
    expect(serializeSimulatorSteps([
      { command: 'longpressid', text: 'route-name' },
      { command: 'tapexact', text: 'Paste' },
      { command: 'valueid', id: 'route-name', text: 'https://example.org/trail/7' },
    ])).toBe('longpressid route-name\ntapexact Paste\nvalueid route-name https://example.org/trail/7\n')
    expect(() => serializeSimulatorSteps([{ command: 'longpressid', text: 'two fields' }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'valueid', id: 'route-name', text: 'x\nlaunch' }])).toThrow()
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app' })
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    expect(source).toContain('target.press(forDuration: 1.2)')
    expect(source).toContain('(target.value as? String) == want')
  })

  it('holds a tab with standard XCTest input and retains bounded timing evidence', () => {
    expect(serializeSimulatorSteps([{ command: 'holdtab', text: 'Health' }])).toBe('holdtab Health | 6\n')
    expect(serializeSimulatorSteps([{ command: 'holdtab', text: 'Today', seconds: 4 }])).toBe('holdtab Today | 4\n')
    for (const seconds of [0, 1.9, 10.1, NaN, Infinity])
      expect(() => serializeSimulatorSteps([{ command: 'holdtab', text: 'Health', seconds }])).toThrow()
    for (const text of ['', ' ', 'Health | 6', 'Health\nlaunch'])
      expect(() => serializeSimulatorSteps([{ command: 'holdtab', text }])).toThrow()
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app', tabs: ['Health'] })
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    const hold = source.slice(source.indexOf('case "holdtab":'), source.indexOf('case "touches":'))
    expect(hold).toContain('coordinate.press(forDuration: duration)')
    expect(hold).toContain('duration.isFinite, (2...10).contains(duration)')
    expect(hold.indexOf('BEGIN holdtab')).toBeLessThan(hold.indexOf('coordinate.press('))
    expect(hold.indexOf('END holdtab')).toBeGreaterThan(hold.indexOf('coordinate.press('))
    expect(hold).toContain('"returnedAt": returnedAt')
    expect(hold).toContain('"startedAt": startedAt')
    expect(hold).not.toContain('CraftTimedInput')
    expect(hold).not.toContain('waitForQuiescence')
  })

  it('bundles an on-device journey with native XCTest evidence and removes it when returning to server mode', () => {
    const output = folder()
    const options = { output, bundleId: 'org.example.app', script: 'activate\nshot current\ntree current\n' }
    initSimulatorDriver(options)
    const path = join(output, 'UITests/journey.txt')
    expect(readFileSync(path, 'utf8')).toBe(options.script)
    const mtime = statSync(path).mtimeMs
    initSimulatorDriver(options)
    expect(statSync(path).mtimeMs).toBe(mtime)
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    expect(source).toContain('Bundle(for: DriverTests.self).url(forResource: "journey", withExtension: "txt")')
    expect(source).toContain('attachment.lifetime = .keepAlways')
    expect(source).toContain('if !bundledJourney { post("/note"')
    initSimulatorDriver({ output, bundleId: options.bundleId })
    expect(() => readFileSync(path)).toThrow()
  })

  it('preserves timed native paths and rejects unsafe schedules before generation', () => {
    const paths: TimedTouchPoint[][] = [[{ x: 0.2, y: 0.92, at: 0 }, { x: 0.2, y: 0.92, at: 0.025 }],
      [{ x: 0.4, y: 0.92, at: 0.08 }, { x: 0.4, y: 0.92, at: 0.105 }]]
    expect(serializeSimulatorSteps([{ command: 'touches', paths: [[{ tab: 'Today', at: 0 }, { tab: 'Today', at: 0.02 }]] }])).toContain('Today')
    expect(serializeSimulatorSteps([{ command: 'touches', paths }])).toBe(`touches ${JSON.stringify(paths)}\n`)
    for (const invalid of [[], [paths[0]!.slice(0, 1)], [[paths[0]![1]!, paths[0]![0]!]],
      [[{ x: 2, y: 0, at: 0 }, { x: 0, y: 0, at: 1 }]],
      [[{ x: 0, y: 0, at: 0 }, { x: 0, y: 0, at: 13 }]],
      [[{ x: NaN, y: 0, at: 0 }, { x: 0, y: 0, at: 1 }]]])
      expect(() => serializeSimulatorSteps([{ command: 'touches', paths: invalid }])).toThrow()
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.release' })
    expect(readFileSync(join(output, 'project.yml'), 'utf8')).toContain('SWIFT_OBJC_BRIDGING_HEADER: UITests/CraftTimedInput.h')
    expect(readFileSync(join(output, 'UITests/CraftTimedInput.m'), 'utf8')).toContain('return [record synthesizeWithError:error]')
  })

  it('serializes guarded steps and exact label checks', () => {
    expect(serializeSimulatorSteps([
      { command: 'ifid', id: 'welcome-skip', step: { command: 'tapid', text: 'welcome-skip' } },
      { command: 'ifid', id: 'consent', step: { command: 'ifid', id: 'consent-agree', step: { command: 'expect', text: 'Agree', seconds: 5 } } },
      { command: 'labelid', id: 'cart-count', text: '2 items' },
    ])).toBe('ifid welcome-skip tapid welcome-skip\nifid consent ifid consent-agree expect Agree | 5\nlabelid cart-count 2 items\n')
    expect(() => serializeSimulatorSteps([{ command: 'ifid', id: 'two words', step: { command: 'launch' } }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'ifid', id: 'x', step: { command: 'tap', text: 'a\nterminate' } }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'labelid', id: '', text: 'x' }])).toThrow()
  })

  it('serializes system journeys without allowing injected commands', () => {
    expect(serializeSimulatorSteps([
      { command: 'notifications' },
      { command: 'systemexpect', text: 'Workout paused', seconds: 15 },
      { command: 'systemtree', name: 'paused-activity' },
      { command: 'systemtap', text: 'Evening unwind' },
      { command: 'systemabsent', text: 'Workout paused' },
    ])).toBe('notifications\nsystemexpect Workout paused | 15\nsystemtree paused-activity\nsystemtap Evening unwind\nsystemabsent Workout paused\n')
    expect(() => serializeSimulatorSteps([{ command: 'systemtap', text: 'Workout\nterminate' }])).toThrow()
    expect(() => serializeSimulatorSteps([{ command: 'systemtree', name: 'two words' }])).toThrow()
  })

  it('handles every typed command in the driver template', () => {
    const output = folder()
    initSimulatorDriver({ output, bundleId: 'org.example.app' })
    const source = readFileSync(join(output, 'UITests/DriverTests.swift'), 'utf8')
    const handled = new Set([...source.matchAll(/case "([a-z]+)"/g)].map(match => match[1]))
    const commands: SimulatorStep['command'][] = ['launch', 'activate', 'terminate', 'home', 'back', 'return', 'unlabelled', 'background', 'wait', 'delay', 'net', 'swipe', 'drag', 'edge', 'tabbar', 'tapxy', 'touches', 'field', 'typeid', 'labelid', 'valueid', 'sliderid', 'expectapp', 'expect', 'expectexact', 'expectid', 'tap', 'tapif', 'tapid', 'longpressid', 'holdtab', 'tapexact', 'type', 'absent', 'absentid', 'selected', 'tab', 'scrollto', 'dismiss', 'log', 'shot', 'tree', 'audit', 'exec', 'openurl', 'universallink', 'ifid', 'notifications', 'systemexpect', 'systemabsent', 'systemtap', 'systemtree']
    expect(commands.filter(command => !handled.has(command))).toEqual([])
    // ifid re-enters the same dispatcher, so a guarded command is any command.
    expect(source).toContain('func run(_ line: String)')
    expect(source).toMatch(/case "ifid":[\s\S]*?run\(rest\[1\]\)/)
  })

  const macTest = process.platform === 'darwin' ? it : it.skip
  macTest('runs the real Swift mutation host and rejects an update to an absent node', () => {
    const validator = createNativeMutationValidator()
    try {
      const render = { type: 'RENDER', payload: { document: { id: 'root', type: 'View', props: {}, style: {}, events: {}, children: [] } } }
      const accepted = validator.validate([render])
      expect(accepted.exitCode, accepted.stdout + accepted.stderr).toBe(0)
      const rejected = validator.validate([render, { type: 'MUTATE', payload: { batchId: 'bad', version: 1, baseRevision: 0, revision: 1, operations: [{ op: 'updateNode', id: 'absent', patch: { props: { text: 'x' } } }] } }])
      expect(rejected.exitCode).not.toBe(0)
      expect(rejected.stdout).toContain('UNKNOWN_NODE')
    }
    finally { validator.dispose() }
    expect(() => validator.validate([])).toThrow('disposed')
  }, 60_000)
})
