import { closeSync, cpSync, existsSync, mkdirSync, openSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

interface EvidenceOptions {
  project: string
  directory: string
  serial?: string
  adbPath?: string
  /** Each read-only ADB command has its own deadline. */
  timeoutMs?: number
}

/** Capture before the caller deletes the project or stops its selected device. */
export function retainNativeNavigationEvidence(options: EvidenceOptions): void {
  const { project, directory, serial, adbPath = 'adb', timeoutMs = 20_000 } = options
  mkdirSync(directory, { recursive: true })
  const report: {
    serial: string | null
    deviceCaptureSkipped?: string
    copies: { source: string, missing?: boolean, error?: string }[]
    commands: { args: string[], exitCode?: number, signalCode?: string | number | null, error?: string }[]
  } = { serial: serial || null, copies: [], commands: [] }

  // These outputs, unlike generated source/build caches, are needed to locate
  // the first failing case even if a later diagnostic command cannot connect.
  for (const [source, destination] of [
    ['app/build/outputs/androidTest-results', 'androidTest-results'],
    ['app/build/reports/androidTests', 'androidTests'],
    ['app/build/outputs/connected_android_test_additional_output', 'connected_android_test_additional_output'],
  ]) {
    const record: typeof report.copies[number] = { source: source! }
    report.copies.push(record)
    try {
      if (existsSync(join(project, source!))) cpSync(join(project, source!), join(directory, destination!), { recursive: true })
      else record.missing = true
    }
    catch (error) { record.error = String(error) }
  }

  if (!serial) report.deviceCaptureSkipped = 'ANDROID_SERIAL is required to query only the selected device'
  else {
    for (const [file, args] of [
      ['logcat-all.txt', ['logcat', '-d', '-b', 'all', '-v', 'threadtime']],
      ['activity-processes.txt', ['shell', 'dumpsys', 'activity', 'processes']],
      ['activity-exit-info.txt', ['shell', 'dumpsys', 'activity', 'exit-info']],
    ] as const) {
      const command: typeof report.commands[number] = { args: [adbPath, '-s', serial, ...args] }
      report.commands.push(command)
      let descriptor: number | undefined
      try {
        descriptor = openSync(join(directory, file), 'w')
        // Files avoid pipe buffering/EOF dependencies. SIGKILL bounds even an
        // unresponsive diagnostic client; it never signals the device/server.
        const result = Bun.spawnSync(command.args, {
          cwd: project, stdin: 'ignore', stdout: descriptor, stderr: descriptor,
          timeout: timeoutMs, killSignal: 'SIGKILL',
        })
        command.exitCode = result.exitCode
        command.signalCode = result.signalCode
      }
      catch (error) { command.error = String(error) }
      finally { if (descriptor !== undefined) closeSync(descriptor) }
    }
  }
  writeFileSync(join(directory, 'diagnostics.json'), JSON.stringify(report, null, 2) + '\n')
}
