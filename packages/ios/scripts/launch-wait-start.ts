import { existsSync, statSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Say how long XCTest took to begin, and keep the simulator's log for a wait
 * nobody can yet explain (#508). Evidence only: a process of its own reads
 * what the test command prints into the live log while the command runs, so
 * a job ended by its time limit has already written it, and nothing here
 * fails a run. The navigation and driver-text harnesses both start it with
 * their test command (#542).
 */
export function watchLaunchWait(liveLog: string | undefined, udid: string, resultBundle: string): { stop: () => Promise<void> } | undefined {
  if (!liveLog || !existsSync(liveLog)) return undefined
  const watch = Bun.spawn([
    process.execPath, join(import.meta.dir, 'launch-wait-watch.ts'), liveLog, String(statSync(liveLog).size),
    String(Date.now()), udid, `${resultBundle}.launch-wait.log`, String(process.pid),
  ], { stdout: 'inherit', stderr: 'inherit' })
  return {
    // It left when the tests began; one still here is told the command has
    // returned, and given the time reading a simulator's log can take.
    stop: async () => {
      watch.kill('SIGTERM')
      let timer: ReturnType<typeof setTimeout> | undefined
      const left = await Promise.race([
        watch.exited,
        new Promise<undefined>(resolve => { timer = setTimeout(() => resolve(undefined), 130_000) }),
      ])
      clearTimeout(timer)
      if (left === undefined) watch.kill('SIGKILL')
    },
  }
}
