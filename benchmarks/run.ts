#!/usr/bin/env bun

/**
 * Benchmark Runner
 *
 * Runs all benchmarks in sequence and produces a combined report.
 *
 * Usage:
 *   bun run bench              # Run all benchmarks
 *   bun run bench:startup      # Startup time only
 *   bun run bench:size         # Bundle size only
 *   bun run bench:ipc          # IPC overhead only
 *   bun run bench:native-mutations # Native STX update protocol only
 *   bun run bench:memory       # Memory (RSS) only
 */
import { checkFrameworks, header } from './utils'

console.log('╔══════════════════════════════════════════════════════════════════════════╗')
console.log('║  Desktop Framework Benchmark Suite — Hello World                       ║')
console.log('║  Craft vs Electron vs Tauri vs Electrobun vs React Native macOS        ║')
console.log('╚══════════════════════════════════════════════════════════════════════════╝')

// Report framework availability
const frameworks = checkFrameworks()
console.log('\nFramework availability:')
for (const f of frameworks) {
  const status = f.available ? '  ready' : '  not found'
  const note = f.available ? '' : ` — ${f.reason}`
  console.log(`  ${f.name.padEnd(15)} ${status}${note}`)
}
console.log()

const benchmarks = [
  { name: 'Bundle Size', file: 'size.bench.ts' },
  { name: 'IPC Protocol Overhead', file: 'ipc.bench.ts' },
  { name: 'Native STX Updates', file: 'native-mutations.bench.ts' },
  { name: 'Process Memory (RSS)', file: 'memory.bench.ts' },
  { name: 'Startup Time', file: 'startup.bench.ts' },
]

for (const b of benchmarks) {
  console.log(`--- Running: ${b.name} ---\n`)
  const result = Bun.spawnSync({
    cmd: ['bun', 'run', b.file],
    cwd: import.meta.dir,
    stdout: 'inherit',
    stderr: 'inherit',
  })
  if (result.exitCode !== 0) {
    console.log(`  Warning: ${b.name} exited with code ${result.exitCode}`)
  }
}

console.log('╔══════════════════════════════════════════════════════════════════════════╗')
console.log('║  All benchmarks complete                                                ║')
console.log('╚══════════════════════════════════════════════════════════════════════════╝\n')
