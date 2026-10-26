import { nativeFixtureCommand } from './native-fixture-command'

type CommandResult = Awaited<ReturnType<typeof nativeFixtureCommand>>
interface StatusOptions { simctl: string, simulator: string, cwd: string }

/** Display-only stimulus on an explicitly supplied owned test simulator.
 * A static system viewer otherwise need not produce a new video sample.
 * Existing overrides are never cleared or replaced: nonpristine devices fail.
 */
export class HeldViewerStatusBar {
  readonly calls: { args: string[], startedAt: number, finishedAt?: number, result?: CommandResult }[] = []
  restored = false
  private pristine = false
  private attempted = false
  private restoration?: Promise<void>

  constructor(private options: StatusOptions, private command = nativeFixtureCommand) {}

  private async run(operation: string[], signal?: AbortSignal, runner?: (args: string[]) => Promise<CommandResult>): Promise<CommandResult> {
    const args = [this.options.simctl, 'status_bar', this.options.simulator, ...operation]
    const call: typeof this.calls[number] = { args, startedAt: Date.now() / 1000 }
    this.calls.push(call)
    try {
      const result = await (runner ? runner(args) : this.command(args, { cwd: this.options.cwd, timeoutMs: 5000, signal }))
      call.result = result
      if (result.code !== 0 || result.timedOut || result.cancelled)
        throw new Error(`Owned status-bar stimulus failed: ${JSON.stringify(result)}`)
      return result
    }
    finally { call.finishedAt = Date.now() / 1000 }
  }

  private requirePristine(output: string): void {
    const lines = output.trim().split(/\r?\n/).map(line => line.trim()).filter(Boolean)
    if (lines.length !== 2 || lines[0] !== 'Current Status Bar Overrides:' || !/^=+$/.test(lines[1]!))
      throw new Error('Viewer stimulus requires a pristine owned test simulator status bar')
  }

  async prepare(runner?: (args: string[]) => Promise<CommandResult>): Promise<void> {
    this.requirePristine((await this.run(['list'], undefined, runner)).stdout)
    this.pristine = true
  }

  async redraw(signal?: AbortSignal): Promise<void> {
    if (!this.pristine) throw new Error('Viewer stimulus requires a verified pristine owned status bar')
    this.attempted = true
    // A non-ISO clock string changes display text, never the device date.
    await this.run(['override', '--time', '02:17'], signal)
  }

  async restore(): Promise<void> {
    if (!this.attempted) return
    this.restoration ??= (async () => {
      // Restoration has its own bounded ownership even if capture was cancelled.
      await this.run(['clear'])
      this.requirePristine((await this.run(['list'])).stdout)
      this.restored = true
    })()
    await this.restoration
  }
}
