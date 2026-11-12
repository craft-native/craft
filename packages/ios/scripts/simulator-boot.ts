/**
 * Start a simulator booting, and say when it finished, without waiting for it.
 *
 * A cold simulator on a CI runner took between 124 and 582 seconds to boot
 * across four runs of the same job, and the fixtures waited for it before
 * starting a build that takes 259 to 419 seconds and does not need a booted
 * device (#508). Booting while that build runs spends the longer of the two
 * instead of their sum.
 *
 * `simctl bootstatus -b` boots the device when it is not booted and returns
 * once it can install and launch, so one process is both the boot and the
 * wait, and a device named by an environment variable is booted like any
 * other instead of being assumed booted.
 */
export interface SimulatorBootResult {
  /** Seconds from the start of the boot to the moment the device was ready. */
  seconds: number
  /** `simctl`'s exit code; null when it was killed or never ran. */
  exitCode: number | null
}

export interface SimulatorBoot {
  /** Settles when the device is ready or the boot gave up. Never rejects. */
  ready: Promise<SimulatorBootResult>
}

export interface RecordedExit {
  exitCode: number | null
  /** Epoch milliseconds at which the command itself finished. */
  finishedAt: number
}

export function simulatorBootCommand(udid: string): string[] {
  return ['xcrun', 'simctl', 'bootstatus', udid, '-b']
}

/**
 * Run a command to completion and report when it finished by its own clock.
 *
 * The caller builds with `Bun.spawnSync`, which holds the event loop: an exit
 * observed from JavaScript would be dated when the build let go, not when the
 * command ended. The shell that ran it writes the time down instead.
 */
export async function runRecorded(command: string[]): Promise<RecordedExit> {
  const child = Bun.spawn(
    ['/bin/sh', '-c', '"$@" >/dev/null 2>&1; code=$?; date +%s; exit $code', 'sh', ...command],
    { stdin: 'ignore', stdout: 'pipe', stderr: 'ignore' },
  )
  const [printed, exitCode] = await Promise.all([new Response(child.stdout).text(), child.exited])
  const seconds = Number.parseInt(printed.trim(), 10)
  return { exitCode, finishedAt: Number.isFinite(seconds) ? seconds * 1000 : Date.now() }
}

export function startSimulatorBoot(
  udid: string,
  run: (command: string[]) => Promise<RecordedExit> = runRecorded,
  now: () => number = Date.now,
): SimulatorBoot {
  const started = now()
  const elapsed = (finishedAt: number) => Math.max(0, Math.round((finishedAt - started) / 1000))
  let running: Promise<RecordedExit>
  try {
    running = run(simulatorBootCommand(udid))
  }
  catch (error) {
    running = Promise.reject(error)
  }
  return {
    ready: running.then(
      ({ exitCode, finishedAt }) => ({ exitCode, seconds: elapsed(finishedAt) }),
      () => ({ exitCode: null, seconds: elapsed(now()) }),
    ),
  }
}

/** One line for the job log: how long the boot took, and how much of it was waited for. */
export function describeSimulatorBoot(result: SimulatorBootResult, waitedSeconds: number): string {
  const waited = Math.max(0, Math.round(waitedSeconds))
  const outcome = result.exitCode === 0
    ? `Simulator ready ${result.seconds}s after its boot began`
    : `Simulator boot ended after ${result.seconds}s with ${result.exitCode === null ? 'no exit code' : `exit code ${result.exitCode}`}; xcodebuild decides whether the device is usable`
  return `${outcome}; waited ${waited}s for it after the build`
}
