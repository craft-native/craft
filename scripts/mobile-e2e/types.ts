export interface RunnerOptions {
  /** Repository root, used to shorten evidence paths in the report. */
  root: string
  /** artifacts/mobile-e2e/<label>, created before any leg runs. */
  evidenceDir: string
  /** Scratch space for generated projects; kept under the evidence dir in CI. */
  workDir: string
  /** How long one app may run before its leg is called a failure. */
  timeoutMs: number
  /** Distinguishes this run's clipboard nonce from a stale one. */
  runId: string
  /** Directory holding the Zig iOS simulator archives. */
  iosRuntimeDir: string | null
  /** Directory holding the Zig Android `<abi>/libcraft.so` tree. */
  androidRuntimeDir: string | null
}

export interface LegOutcome {
  name: string
  status: 'passed' | 'failed'
  /** Empty on a pass. Each entry is one reason, in the words of what was seen. */
  failures: string[]
  planned: string[]
  passed: string[]
  failed: string[]
  /** Which actions reached the Zig dispatcher, i.e. which side answered. */
  zigActions: string[]
  /** Repo-relative path to this leg's evidence. */
  evidence: string
}
