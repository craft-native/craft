#!/usr/bin/env bun

/**
 * A/B binary load time, measured on one machine in one sitting.
 *
 * ## What this measures, and what it does not
 *
 * `craft --help` parses its arguments, prints, and exits. It never opens a
 * window, never touches AppKit or GTK, and never starts a WebContent process.
 * So this measures **binary load time** — process spawn, dynamic linking,
 * relocation, and argument parsing — and nothing about how long an app takes
 * to appear on screen.
 *
 * That distinction is the reason this file exists. The benchmark workflow
 * called the same measurement "Startup Time" and failed pull requests on it,
 * which meant a number that cannot move when window creation gets slower was
 * gating changes to window creation. Naming it for what it is stops the next
 * person trusting it for something it cannot see. Real startup — window,
 * webview, first paint — is `startup.bench.ts`, and it needs a display.
 *
 * ## Why A/B rather than a stored number
 *
 * Load time on a shared CI runner is noisy and heavy-tailed. Measured on one
 * unchanging binary on an idle laptop: p50 22.9ms, p95 38.8ms, max 65.6ms.
 * Comparing today's measurement against a number recorded on another machine
 * on another day compares the machines, not the binaries — on identical
 * binaries that method spread 22ms to 32ms, a 45% swing, against a gate that
 * fired at 20%.
 *
 * Running both binaries interleaved on the same machine cancels almost all of
 * it, because whatever slows one round slows both halves of it. Same
 * experiment, same laptop, byte-identical binaries: worst case 3.5%.
 *
 * Interleaving is what does the work. Measuring all of A and then all of B
 * would leave a drift between the halves attributed to the change.
 */

interface Options {
  base: string
  head: string
  rounds: number
  threshold: number
}

function parseArgs(argv: string[]): Options {
  const get = (flag: string): string | undefined => {
    const i = argv.indexOf(flag)
    return i === -1 ? undefined : argv[i + 1]
  }
  const base = get('--base')
  const head = get('--head')
  if (!base || !head) {
    console.error('usage: bun run binary-load-ab.ts --base <binary> --head <binary> [--rounds N] [--threshold 1.2]')
    process.exit(2)
  }
  return {
    base,
    head,
    rounds: Number(get('--rounds') ?? 25),
    threshold: Number(get('--threshold') ?? 1.2),
  }
}

function runOnce(binary: string): number {
  const start = Bun.nanoseconds()
  Bun.spawnSync({ cmd: [binary, '--help'], stdout: 'ignore', stderr: 'ignore' })
  return (Bun.nanoseconds() - start) / 1e6
}

function quantile(sorted: number[], q: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))]
}

interface Stats { p50: number, p95: number, min: number, max: number }

function stats(times: number[]): Stats {
  const s = [...times].sort((a, b) => a - b)
  return { p50: quantile(s, 0.5), p95: quantile(s, 0.95), min: s[0], max: s[s.length - 1] }
}

const opts = parseArgs(Bun.argv)

// The first launch of each binary pays for a cold page cache and is not
// representative of anything. Warm both, then start measuring.
runOnce(opts.base)
runOnce(opts.head)

const baseTimes: number[] = []
const headTimes: number[] = []
for (let i = 0; i < opts.rounds; i++) {
  // Alternate which goes first so neither consistently occupies the same
  // position in a round — an ordering effect would otherwise land entirely on
  // one side.
  if (i % 2 === 0) {
    baseTimes.push(runOnce(opts.base))
    headTimes.push(runOnce(opts.head))
  }
  else {
    headTimes.push(runOnce(opts.head))
    baseTimes.push(runOnce(opts.base))
  }
}

const base = stats(baseTimes)
const head = stats(headTimes)
const ratio = head.p50 / base.p50
const percent = (ratio - 1) * 100
const regressed = ratio > opts.threshold

const fmt = (n: number) => n.toFixed(1)
console.log(`rounds:    ${opts.rounds} interleaved`)
console.log(`base:      p50 ${fmt(base.p50)}ms   p95 ${fmt(base.p95)}ms   (${fmt(base.min)}–${fmt(base.max)}ms)`)
console.log(`head:      p50 ${fmt(head.p50)}ms   p95 ${fmt(head.p95)}ms   (${fmt(head.min)}–${fmt(head.max)}ms)`)
console.log(`delta:     ${percent >= 0 ? '+' : ''}${fmt(percent)}%  (fails above +${fmt((opts.threshold - 1) * 100)}%)`)

const summary = {
  base_p50_ms: Number(base.p50.toFixed(2)),
  head_p50_ms: Number(head.p50.toFixed(2)),
  delta_percent: Number(percent.toFixed(2)),
  regressed,
}
await Bun.write('binary-load-ab.json', `${JSON.stringify(summary, null, 2)}\n`)

if (regressed) {
  console.error(`\nBinary load time regressed by ${fmt(percent)}%.`)
  process.exit(1)
}
console.log('\nNo binary load time regression.')
