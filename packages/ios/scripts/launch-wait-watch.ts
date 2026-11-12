#!/usr/bin/env bun
/**
 * Watches a running test command's log for the moment XCTest begins (#508).
 *
 *   bun launch-wait-watch.ts <live log> <bytes printed before> <command started, ms> <udid> <kept path> <parent pid>
 *
 * A process of its own, because the test command blocks the script that
 * started it and a job at its time limit is killed without running anyone's
 * `finally`. What it writes is on disk, and in the job's log, as it happens.
 * SIGTERM tells it the test command has returned. Evidence only: it exits 0
 * whatever it finds.
 */
import { appendFileSync, closeSync, existsSync, openSync, readSync, statSync } from 'node:fs'
import { hostActivityCommands, launchWaitStep, simulatorLogWindow } from './launch-wait'

const [liveLog, printedBefore, startedMs, udid, kept, parent] = process.argv.slice(2)
const commandStarted = new Date(Number(startedMs))
const processes = `${kept.replace(/\.log$/, '')}.host.txt`

function printedSinceCommand(): string {
  if (!existsSync(liveLog)) return ''
  const from = Number(printedBefore), size = statSync(liveLog).size
  if (size <= from) return ''
  const bytes = Buffer.alloc(size - from), file = openSync(liveLog, 'r')
  try { readSync(file, bytes, 0, bytes.length, from) }
  finally { closeSync(file) }
  return bytes.toString('utf8')
}

function parentIsRunning(): boolean {
  try { process.kill(Number(parent), 0); return true }
  catch { return false }
}

function noteHostActivity(waited: number, state: string): void {
  appendFileSync(processes, `--- ${new Date().toISOString()}, ${waited}s after the test command, ${state}\n`)
  for (const command of hostActivityCommands) {
    const shown = Bun.spawnSync(command, { stdout: 'pipe', stderr: 'pipe', timeout: 20_000 })
    // A simulator's processes run from inside its runtime, 170 characters deep.
    appendFileSync(processes, `${shown.stdout.toString().split('\n').slice(0, 25).map(line => line.replace(/\/Library\/Developer\/CoreSimulator\/.*?\/RuntimeRoot/, 'simulator:').slice(0, 200)).join('\n')}\n`)
  }
}

// The test command has returned: say so if no runner ever began. A signal
// that arrives while the simulator's log is being read waits for it.
let commandReturned = false
process.on('SIGTERM', () => { commandReturned = true })

let snapshots = 0, began = false
try {
  while (parentIsRunning() && !commandReturned) {
    const step = launchWaitStep(printedSinceCommand(), commandStarted, new Date(), snapshots)
    if (step.began) {
      console.log(`XCTest began running tests ${step.seconds}s after the test command`)
      // What every run was sharing the host with as its tests began.
      noteHostActivity(step.seconds, 'XCTest running tests')
      if (step.keepLog) {
        const until = new Date(commandStarted.getTime() + (step.seconds + 5) * 1000)
        const shown = Bun.spawnSync(simulatorLogWindow(udid, commandStarted, until), { stdout: Bun.file(kept), stderr: 'pipe', timeout: 120_000 })
        console.log(shown.exitCode === 0
          ? `Kept the simulator's log for that wait: ${kept}`
          : `Could not read the simulator's log for that wait (${shown.exitCode ?? 'timed out'}): ${shown.stderr.toString().trim().split('\n')[0]}`)
      }
      began = true
      break
    }
    if (step.snapshot) {
      noteHostActivity(step.seconds, 'XCTest still silent')
      if (snapshots === 0) console.log(`XCTest has not begun running tests ${step.seconds}s after the test command; what the host is busy with is in ${processes}`)
      snapshots += 1
    }
    await Bun.sleep(1000)
  }
  if (!began && commandReturned) console.log('XCTest did not report that it began running tests')
}
catch (error) {
  console.log(`Could not measure the wait before the tests: ${error}`)
}
