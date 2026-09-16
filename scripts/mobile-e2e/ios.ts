import type { LegOutcome, RunnerOptions } from './types'
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { bootSimulator, init, pickSimulator } from '../../packages/ios/src/index'
import { evaluateRun, hasTerminated, ZIG_REFUSED_ACTIONS, ZIG_TESTED_ACTIONS, zigDispatchedActions, zigRefusals } from './protocol'
import { command, driverPage, waitForFile } from './support'

/**
 * The app the suite runs against.
 *
 * Clipboard on, geolocation and sharing off, and that pairing is the whole
 * point: the success case needs a capability that is enabled and reachable
 * without a permission prompt, and the rejection cases need ones that are
 * switched off so the refusal is a property of the configuration rather than
 * of the machine. Reading a pasteboard the app itself just wrote raises no iOS
 * paste prompt, which is what makes the round trip scriptable.
 *
 * `enableShare` is spelled out although false is the default, because the
 * share case depends on it and a default is not something this file controls.
 */
const CONFIG = {
  enableClipboard: true,
  enableGeolocation: false,
  enableShare: false,
}

const BUNDLE_ID = 'dev.craft.e2e.probe'
const APP_NAME = 'CraftE2EProbe'

/**
 * One leg is one answer to "who served the call".
 *
 * `shim` is what every generated app is today: no Zig archive, every dlsym
 * miss, Swift serving the whole surface. `runtime` links the archive so Zig
 * takes the actions it owns. They assert the same cases, because the hand-off
 * is supposed to be invisible to the page - and that is exactly why the
 * runtime leg also counts Zig's dispatch log lines. Identical behaviour is the
 * requirement; identical behaviour with the archive silently absent is the bug
 * that requirement would otherwise hide.
 */
interface Leg {
  name: 'shim' | 'runtime'
  runtimeDir: string | null
  requireZigDispatch: boolean
}

function legs(runtimeDir: string | null): Leg[] {
  return [
    { name: 'shim', runtimeDir: null, requireZigDispatch: false },
    { name: 'runtime', runtimeDir, requireZigDispatch: true },
  ]
}

async function runLeg(leg: Leg, options: RunnerOptions): Promise<LegOutcome> {
  const label = `ios-${leg.name}`
  const evidence = join(options.evidenceDir, label)
  const project = join(options.workDir, label)
  const failures: string[] = []

  mkdirSync(evidence, { recursive: true })
  rmSync(project, { force: true, recursive: true })

  await init({
    name: APP_NAME,
    bundleId: BUNDLE_ID,
    output: project,
    config: CONFIG,
    runtimeDir: leg.runtimeDir,
  })

  // The archive is linked through project.yml's {{CRAFT_RUNTIME_SETTINGS}},
  // which init() leaves empty when it installed no runtime. Checking the
  // generated file rather than trusting the option means a leg cannot quietly
  // become a second copy of the shim leg.
  const projectYml = readFileSync(join(project, 'project.yml'), 'utf8')
  const linksRuntime = projectYml.includes('-lcraft-ios')
  if (leg.requireZigDispatch && !linksRuntime)
    failures.push(`the ${leg.name} leg generated a project that does not link the Zig archive; check ${leg.runtimeDir}`)
  if (!leg.requireZigDispatch && linksRuntime)
    failures.push(`the ${leg.name} leg was supposed to have no runtime but its project links one`)

  const nonce = `craft-e2e-${label}-${options.runId}`
  writeFileSync(join(project, 'dist', 'index.html'), driverPage(nonce, 'ios'))
  copyFileSync(join(project, 'dist', 'index.html'), join(evidence, 'index.html'))
  copyFileSync(join(project, 'craft.config.json'), join(evidence, 'craft.config.json'))
  copyFileSync(join(project, 'project.yml'), join(evidence, 'project.yml'))

  await command(['xcodegen', 'generate'], { cwd: project, logPath: join(evidence, 'xcodegen.log') })

  const derived = join(project, 'DerivedData')
  await command([
    'xcodebuild',
    '-project', `${APP_NAME}.xcodeproj`,
    '-scheme', APP_NAME,
    '-configuration', 'Debug',
    // The simulator SDK, which no existing job builds against: the templates
    // gate compiles -sdk iphoneos only. A generated app that links for a
    // device and not for a simulator would have gone unnoticed.
    '-sdk', 'iphonesimulator',
    '-derivedDataPath', derived,
    'CODE_SIGNING_ALLOWED=NO',
    'build',
  ], { cwd: project, logPath: join(evidence, 'xcodebuild.log') })

  const app = join(derived, 'Build', 'Products', 'Debug-iphonesimulator', `${APP_NAME}.app`)
  if (!existsSync(app))
    throw new Error(`xcodebuild reported success but ${app} is missing`)

  const device = await pickSimulator()
  if (!device)
    throw new Error('no iOS simulator is available; `xcrun simctl list devices available` found none')
  await bootSimulator(device)
  writeFileSync(join(evidence, 'device.json'), `${JSON.stringify(device, null, 2)}\n`)

  await command(['xcrun', 'simctl', 'uninstall', device.udid, BUNDLE_ID], { allowFailure: true })
  await command(['xcrun', 'simctl', 'install', device.udid, app])

  // Clear the pasteboard first. Without this a nonce left by the previous leg
  // would still be there, and the external check below would pass on a value
  // this run never wrote.
  await command(['xcrun', 'simctl', 'pbcopy', device.udid], { stdin: 'craft-e2e-pasteboard-cleared', allowFailure: true })

  // The app's own stdout and stderr, straight to a file. `--console-pty` is
  // what makes Swift's `print` - and therefore the page's `craft.log` - leave
  // the device at all; without it the launch returns a pid and says nothing.
  // A raw descriptor rather than a pipe, so the writing outlives this process
  // reading it and the poll below sees the file grow.
  const consolePath = join(evidence, 'console.log')
  const consoleFd = openSync(consolePath, 'w')
  const launched = Bun.spawn(['xcrun', 'simctl', 'launch', '--console-pty', device.udid, BUNDLE_ID], {
    stdout: consoleFd,
    stderr: consoleFd,
  })

  // The suite is quick once the app is up, but a cold simulator is not, so
  // poll for the terminator rather than sleeping a fixed amount.
  //
  // `hasTerminated` parses rather than matching a substring, because the very
  // next statement kills the writer: a poll landing mid-write of the final
  // line would otherwise leave a truncated event in the file and turn a
  // passing suite into "driver emitted an unparseable event".
  const finished = await waitForFile(consolePath, options.timeoutMs, hasTerminated)

  launched.kill()
  closeSync(consoleFd)
  await command(['xcrun', 'simctl', 'terminate', device.udid, BUNDLE_ID], { allowFailure: true })

  // Evidence before assertions, always: a leg that dies here is the one whose
  // screenshot is worth the most.
  await command(['xcrun', 'simctl', 'io', device.udid, 'screenshot', join(evidence, 'screen.png')], { allowFailure: true })
  const pasteboard = await command(['xcrun', 'simctl', 'pbpaste', device.udid], { allowFailure: true })
  writeFileSync(join(evidence, 'pasteboard.txt'), pasteboard.stdout)

  const consoleText = existsSync(consolePath) ? readFileSync(consolePath, 'utf8') : ''
  if (!finished)
    failures.push(`the app produced no terminating event within ${options.timeoutMs}ms; see ${label}/console.log`)

  const verdict = evaluateRun('ios', consoleText, nonce)
  failures.push(...verdict.failures)

  // The one assertion the page cannot fake. simctl reads the device's own
  // pasteboard from the host, so a nonce found here travelled from JavaScript
  // through the bridge into real UIPasteboard state.
  if (!pasteboard.stdout.includes(nonce))
    failures.push(`the simulator pasteboard does not hold the nonce this run wrote; it holds ${JSON.stringify(pasteboard.stdout.trim().slice(0, 80))}`)

  const dispatched = zigDispatchedActions(consoleText)
  const refused = zigRefusals(consoleText)

  if (leg.requireZigDispatch) {
    const missing = ZIG_TESTED_ACTIONS.filter(action => !dispatched.includes(action))
    if (missing.length)
      failures.push(`the runtime leg links the Zig archive but ${missing.join(', ')} never reached the Zig dispatcher; Swift served ${missing.length === 1 ? 'it' : 'them'} and the archive was not in the loop for the cases under test`)

    // A dispatch line is logged on entry, before Zig decides whether it owns
    // the action, so it alone does not prove Zig answered. The refusal line is
    // written by Zig's own capability gate, which means the rejection the page
    // saw came off Zig's error route.
    for (const action of ZIG_REFUSED_ACTIONS.filter(action => !refused.includes(action)))
      failures.push(`Zig never refused ${action}; the rejection the page saw came from Swift, not from the Zig gate`)
  }
  else {
    if (dispatched.length)
      failures.push(`the shim leg reached the Zig dispatcher for ${dispatched.join(', ')}; it was supposed to link no runtime`)
    if (refused.length)
      failures.push(`the shim leg saw Zig refuse ${refused.join(', ')}; it was supposed to link no runtime`)
  }

  return {
    name: label,
    status: failures.length ? 'failed' : 'passed',
    failures,
    planned: verdict.planned,
    passed: verdict.passed,
    failed: verdict.failed,
    zigActions: dispatched,
    evidence: evidence.replace(`${options.root}/`, ''),
  }
}

export async function runIos(options: RunnerOptions): Promise<LegOutcome[]> {
  const runtimeDir = options.iosRuntimeDir
  if (!runtimeDir)
    throw new Error('no iOS Zig runtime directory; run `zig build build-ios-all` in packages/zig and pass --ios-runtime <dir>')

  // The device archive as well as the simulator ones, because that is what
  // `installRuntime` requires: it resolves every SDK in RUNTIME_ARCHIVES before
  // writing anything and throws when one has none. Checking only the simulator
  // slices here would accept a zig-out that project generation then rejects,
  // several minutes later, with a message about a different build step.
  const simulator = ['libcraft-ios-simulator-arm64.a', 'libcraft-ios-simulator-x64.a']
  const missing: string[] = []
  if (!simulator.some(name => existsSync(join(runtimeDir, name)))) missing.push(...simulator)
  if (!existsSync(join(runtimeDir, 'libcraft-ios.a'))) missing.push('libcraft-ios.a')

  if (missing.length) {
    throw new Error(
      `${runtimeDir} is missing ${missing.join(', ')}. `
      + 'Run `zig build build-ios-all -Doptimize=ReleaseSafe` in packages/zig first — '
      + 'build-ios-simulator alone is not enough, because the generated project links a device slice too. '
      + 'Skipping the runtime leg instead would leave the Zig bridge untested while the suite still reported green.',
    )
  }

  const outcomes: LegOutcome[] = []
  for (const leg of legs(runtimeDir)) {
    try {
      outcomes.push(await runLeg(leg, options))
    }
    catch (caught) {
      outcomes.push({
        name: `ios-${leg.name}`,
        status: 'failed',
        failures: [caught instanceof Error ? caught.message : String(caught)],
        planned: [],
        passed: [],
        failed: [],
        zigActions: [],
        evidence: join(options.evidenceDir, `ios-${leg.name}`).replace(`${options.root}/`, ''),
      })
    }
  }

  return outcomes
}
