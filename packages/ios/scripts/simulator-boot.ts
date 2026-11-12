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
  /** Whether the push daemon was suspended once the device was ready; absent when nobody asked. */
  pushSuspended?: boolean
}

export interface SimulatorBoot {
  /** Settles when the device is ready or the boot gave up. Never rejects. */
  ready: Promise<SimulatorBootResult>
}

export interface RecordedExit {
  exitCode: number | null
  /** Epoch milliseconds at which the command itself finished. */
  finishedAt: number
  /** The exit code of the command that followed a success; absent when none ran. */
  followedBy?: number
}

export function simulatorBootCommand(udid: string): string[] {
  return ['xcrun', 'simctl', 'bootstatus', udid, '-b']
}

/**
 * Suspend a booted simulator's push daemon.
 *
 * A simulator's `apsd` asks its host for an activation certificate before it
 * tells Apple's sandbox push server who it is. A virtual Mac, which is what a
 * hosted CI runner is, answers `MobileActivation ... Code=-25 "Client is not
 * supported."`. The daemon has by then connected, so it counts no failure and
 * waits for nothing: it closes the connection and opens another, 5 to 20
 * times a second for as long as the simulator is up, each one a TLS handshake
 * and a certificate check, and writes 1,000 to 5,000 log lines a second doing
 * it (#521). Seven other daemons are told of every change. No push reaches
 * such a simulator either way.
 *
 * Suspended, it holds its place: launchd does not start another, and the
 * daemons connected to it see nothing change. Booted out instead, each of
 * them retries its connection about once a second.
 */
export function suspendPushCommand(udid: string): string[] {
  // The daemon's domain is `user/foreground` on iOS 26.5, where `system`
  // still answers with a warning; an older runtime knows only `system`.
  const kill = (service: string) => `xcrun simctl spawn "$1" launchctl kill SIGSTOP ${service}/com.apple.apsd`
  return ['/bin/sh', '-c', `${kill('user/foreground')} || ${kill('system')}`, 'sh', udid]
}

/** Whether this host is a virtual machine, by the kernel's own account. */
export function hostIsVirtual(read: () => string = () => Bun.spawnSync(['sysctl', '-n', 'kern.hv_vmm_present'], { stdout: 'pipe', stderr: 'ignore' }).stdout.toString()): boolean {
  try { return read().trim() === '1' }
  catch { return false }
}

/**
 * For a script that waits for its own boot: suspend the push daemon of a
 * device that is already up, on a virtual host. Returns the line for the log,
 * or undefined where the daemon is left alone.
 */
export function suspendSimulatorPush(
  udid: string,
  virtual: boolean = hostIsVirtual(),
  run: (command: string[]) => number | null = command => Bun.spawnSync(command, { stdout: 'ignore', stderr: 'ignore', timeout: 30_000 }).exitCode,
): string | undefined {
  if (!virtual) return undefined
  return describePushSuspension(run(suspendPushCommand(udid)) === 0)
}

export function describePushSuspension(suspended: boolean): string {
  return suspended
    ? 'Suspended the simulator\'s push daemon: a virtual host cannot activate it, and it reconnects without pause (#521)'
    : 'Could not suspend the simulator\'s push daemon; on a virtual host it reconnects without pause (#521)'
}

/**
 * Run a command to completion and report when it finished by its own clock.
 *
 * The caller builds with `Bun.spawnSync`, which holds the event loop: an exit
 * observed from JavaScript would be dated when the build let go, not when the
 * command ended. The shell that ran it writes the time down instead, and
 * runs `then` after a success without waiting for the build either.
 */
export async function runRecorded(command: string[], then?: string[]): Promise<RecordedExit> {
  const child = Bun.spawn(
    ['/bin/sh', '-c', recordedScript(command, then), 'sh'],
    { stdin: 'ignore', stdout: 'pipe', stderr: 'ignore' },
  )
  const [printed, exitCode] = await Promise.all([new Response(child.stdout).text(), child.exited])
  const [finished, followed] = printed.trim().split('\n')
  const seconds = Number.parseInt(finished ?? '', 10)
  const followedBy = Number.parseInt(followed ?? '', 10)
  return {
    exitCode,
    finishedAt: Number.isFinite(seconds) ? seconds * 1000 : Date.now(),
    ...(Number.isFinite(followedBy) ? { followedBy } : {}),
  }
}

function shellWord(word: string): string {
  return `'${word.replaceAll('\'', '\'\\\'\'')}'`
}

/** The shell that runs `command`, writes down when it ended, and then runs `then` if it succeeded. */
export function recordedScript(command: string[], then?: string[]): string {
  const words = (list: string[]) => list.map(shellWord).join(' ')
  const follow = then?.length ? ` if [ $code -eq 0 ]; then ${words(then)} >/dev/null 2>&1; echo $?; fi;` : ''
  return `${words(command)} >/dev/null 2>&1; code=$?; date +%s;${follow} exit $code`
}

export function startSimulatorBoot(
  udid: string,
  run: (command: string[], then?: string[]) => Promise<RecordedExit> = runRecorded,
  now: () => number = Date.now,
  virtual: boolean = hostIsVirtual(),
): SimulatorBoot {
  const started = now()
  const elapsed = (finishedAt: number) => Math.max(0, Math.round((finishedAt - started) / 1000))
  let running: Promise<RecordedExit>
  try {
    // On a virtual host the push daemon is suspended the moment the device
    // is up, while the build is still running.
    running = virtual ? run(simulatorBootCommand(udid), suspendPushCommand(udid)) : run(simulatorBootCommand(udid))
  }
  catch (error) {
    running = Promise.reject(error)
  }
  return {
    ready: running.then(
      ({ exitCode, finishedAt, followedBy }) => ({
        exitCode,
        seconds: elapsed(finishedAt),
        ...(virtual && exitCode === 0 ? { pushSuspended: followedBy === 0 } : {}),
      }),
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
  const push = result.pushSuspended === undefined ? '' : `\n${describePushSuspension(result.pushSuspended)}`
  return `${outcome}; waited ${waited}s for it after the build${push}`
}
