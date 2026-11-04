import { copyFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { initSimulatorDriver, serializeSimulatorSteps } from '../src/testing'
import { nativeTestResultBundle } from './native-test-result'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

const simulator = process.env.CRAFT_DRIVER_SIMULATOR
if (!simulator) throw new Error('Set CRAFT_DRIVER_SIMULATOR to an owned disposable iOS simulator UUID')
const workspace = createTempDir('driver-text-')
const result = nativeTestResultBundle(workspace, process.env.CRAFT_DRIVER_TEXT_RESULT)
const replacement = 'Bitte kürze nur meinen nächsten Lauf auf 15 Minuten. Grüße 👟'
function run(args: string[]) {
  const child = Bun.spawnSync(args, { cwd: workspace, stdout: 'inherit', stderr: 'inherit' })
  if (child.exitCode !== 0) throw new Error(`${args[0]} failed (${child.exitCode})`)
}
try {
  initSimulatorDriver({
    output: workspace, projectName: 'DriverText', bundleId: 'dev.craft.driver-text.host', bundleIdPrefix: 'dev.craft.driver-text',
    script: serializeSimulatorSteps([
      { command: 'launch' },
      { command: 'expectid', text: 'transcript', seconds: 15 },
      { command: 'longpressid', text: 'transcript' },
      { command: 'tap', text: 'Select All' },
      { command: 'typeid', id: 'transcript', text: replacement },
      { command: 'tree', name: 'replaced-transcript' },
      { command: 'valueid', id: 'transcript', text: replacement },
      { command: 'longpressid', text: 'transcript' },
      { command: 'tap', text: 'Select All' },
      { command: 'typeid', id: 'transcript', text: '\u0008' },
      { command: 'labelid', id: 'transcript-count', text: 'Transcript characters: 0' },
      { command: 'longpressid', text: 'name' },
      { command: 'tap', text: 'Select All' },
      { command: 'typeid', id: 'name', text: 'Läufer 👟' },
      { command: 'tree', name: 'replaced-name' },
      { command: 'valueid', id: 'name', text: 'Läufer 👟' },
      { command: 'longpressid', text: 'name' },
      { command: 'tap', text: 'Select All' },
      { command: 'typeid', id: 'name', text: '\u0008' },
      { command: 'labelid', id: 'name-count', text: 'Name characters: 0' },
    ]),
  })
  copyFileSync(resolve(import.meta.dir, '../fixtures/driver-text/HostApp.swift'), join(workspace, 'Host/HostApp.swift'))
  run(['xcodegen', 'generate'])
  run(['xcodebuild', '-project', 'DriverText.xcodeproj', '-scheme', 'DriverText', '-configuration', 'Debug',
    '-destination', `id=${simulator}`, '-derivedDataPath', join(workspace, 'DerivedData'),
    '-resultBundlePath', result, '-jobs', '2', '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
    'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES', 'test'])
  const summary = Bun.spawnSync(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', result])
  if (summary.exitCode !== 0) throw new Error(summary.stderr.toString())
  const counts = JSON.parse(summary.stdout.toString())
  if (counts.result !== 'Passed' || counts.totalTestCount !== 1 || counts.passedTests !== 1 || counts.failedTests !== 0 || counts.skippedTests !== 0)
    throw new Error(`Driver text acceptance failed: ${JSON.stringify(counts)}`)
  console.log('Native driver focused, selected, edited and cleared multiline and single-line Unicode text through native UI events.')
}
finally { removeTempDir(workspace) }
