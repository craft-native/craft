# Craft Benchmarks

Hello World benchmarks comparing **Craft**, **Electron**, **Tauri**, **Electrobun**, and **React Native macOS** using [Bun](https://bun.sh) and [Mitata](https://github.com/evanwashere/mitata).

All five frameworks render the same Hello World content. No synthetic simulations — every measurement comes from real processes, real binaries, and real serialization.

## Quick Start

```bash
cd benchmarks
bun install

# Set up frameworks
bun run setup

# Run the full suite
bun run bench
```

## Results

Measured on Apple M3 Pro, macOS:

### Startup Time

| Framework | p50 | Method |
|-----------|-----|--------|
| **Craft** | **168 ms** | `--benchmark` flag: create window, print "ready", exit |
| React Native | 243 ms | Auto-quit after `applicationDidFinishLaunching` + 100ms |
| Electrobun | 246 ms | Auto-quit after window creation + 50ms |
| Tauri | 259 ms | Auto-quit after setup + 50ms event loop |
| Electron | 412 ms | Auto-quit after `did-finish-load` |

Craft is **1.4x** faster than React Native, **1.5x** faster than Electrobun, **1.5x** faster than Tauri, and **2.4x** faster than Electron at startup.

### Bundle Size

| Framework | Binary Size | Distributable |
|-----------|-------------|---------------|
| **Craft** | **297 KB** | **297 KB** |
| Tauri | 7.69 MB | 7.69 MB |
| React Native | 20.65 MB | 21.63 MB |
| Electrobun | 131 KB | 60.12 MB |
| Electron | 392.37 MB | 392.37 MB |

Craft is **26x** smaller than Tauri, **74x** smaller than React Native, **207x** smaller than Electrobun, and **1351x** smaller than Electron.

### Process Memory (RSS)

Measured as total RSS across the entire process tree (parent + child processes).

| Framework | Median RSS |
|-----------|-----------|
| **Craft** | **86 MB** |
| Tauri | 106 MB |
| React Native | 109 MB |
| Electrobun | 148 MB |
| Electron | 369 MB |

Craft uses **1.2x** less memory than Tauri, **1.3x** less than React Native, **1.7x** less than Electrobun, and **4.3x** less than Electron.

### IPC Protocol Overhead

All four use JSON serialization — this measures the overhead of each framework's message envelope format.

| Framework | Single message | 1k messages |
|-----------|---------------|-------------|
| **Craft** | **532 ns** | **221 us** |
| Electrobun | 760 ns | 257 us |
| Tauri | 778 ns | 302 us |
| Electron | 837 ns | 333 us |

Craft's minimal envelope is **1.4x** faster than Electrobun, **1.5x** faster than Tauri, and **1.6x** faster than Electron.

## What's Measured

| Benchmark | File | What it measures | Method |
|-----------|------|-----------------|--------|
| **Bundle Size** | `size.bench.ts` | Real binary/distributable sizes on disk | `fs.statSync` + recursive `dirSize` |
| **IPC Overhead** | `ipc.bench.ts` | JSON serialization with each framework's message format | mitata micro-benchmark |
| **Memory** | `memory.bench.ts` | RSS of entire process tree after 3s stabilization | `ps -o rss=` across all child PIDs |
| **Startup** | `startup.bench.ts` | Cold-start time (spawn -> ready -> exit) | `performance.now()` across 10 iterations |
| **Binary load** | `binary-load-ab.ts` | Process spawn, dynamic linking and argument parsing — **not** window startup | p50 of interleaved A/B runs of two binaries on one machine |

## Run Individual Benchmarks

```bash
bun run bench:size      # Bundle/binary size comparison
bun run bench:ipc       # IPC protocol micro-benchmarks
bun run bench:memory    # Process memory (RSS)
bun run bench:startup   # Startup time
bun run bench:load --base <binary> --head <binary>   # A/B binary load time
```

## What CI gates on

`binary-load-ab.ts`, and only that one. It needs no display, so it is the only
benchmark here that can run on a CI runner honestly.

It compares two binaries **interleaved on the same runner**, rather than a
measurement against a number recorded elsewhere. That matters more than it
sounds: on one unchanging binary this measurement reads p50 22.9ms, p95
38.8ms, max 65.6ms, and comparing a mean-of-5 against a stored baseline swung
22ms to 32ms — a 45% spread, through a gate that fired at 20%. Interleaving
brought the same experiment to 3.5% worst case.

`startup.bench.ts` measures the thing people actually mean by startup — window,
webview, first paint — and needs a display, so it is run by hand rather than
gated.

## Hello World Apps

Each framework runs the same minimal Hello World content:

```
apps/
├── hello.html                      # Shared HTML for Craft/Electron/Tauri
├── craft.ts                        # Craft: CraftApp + show()
├── electron/
│   ├── main.js                     # Electron: BrowserWindow + did-finish-load
│   └── package.json
├── tauri/
│   ├── src/index.html
│   └── src-tauri/
│       ├── src/main.rs             # Tauri: Builder + setup()
│       ├── Cargo.toml
│       └── tauri.conf.json
├── electrobun/
│   ├── src/bun/index.ts            # Electrobun: BrowserWindow + data URI
│   ├── electrobun.config.ts
│   └── package.json
└── react-native-macos/
    ├── App.tsx                     # React Native: View + Text
    └── macos/
        └── RNMacBench-macOS/
            └── AppDelegate.mm      # Benchmark auto-quit support
```

## Fairness Notes

- **IPC**: All benchmarks do `JSON.stringify` + `JSON.parse`. The only variable is the message envelope structure each framework uses. Craft does NOT get a free pass — it uses the same serialization mechanism. Electrobun uses `{type, id, method, params}` request / `{type, id, success, payload}` response envelopes.
- **Memory**: RSS is measured for the **entire process tree**, not just the main process. This is critical for Electron which spawns renderer + GPU helper processes, and Electrobun which also uses helper processes.
- **Startup**: All five frameworks auto-quit in benchmark mode. Craft uses `--benchmark` flag, others use `BENCHMARK=1` env var. Electron quits after `did-finish-load` (full page load), Tauri quits ~50ms after `setup()`, Electrobun quits ~50ms after window creation, React Native quits ~100ms after `applicationDidFinishLaunching`, and Craft quits immediately after window creation.
- **Size**: Measures actual files on disk. Craft is built with `ReleaseSmall` + `strip` + `single_threaded` + `unwind_tables=none`. Tauri uses `cargo build --release`. React Native uses xcodebuild Release configuration. Electron's size includes the full Chromium + Node.js runtime.

## Prerequisites

| Framework | Required | Install |
|-----------|----------|---------|
| **Craft** | Zig binary | `bun run setup` (builds automatically) |
| **Electron** | npm package | `cd benchmarks/apps/electron && bun install` |
| **Tauri** | Rust binary | `cd benchmarks/apps/tauri/src-tauri && cargo build --release` |
| **Electrobun** | Bun package | `cd benchmarks/apps/electrobun && bun install && npx electrobun build` |
| **React Native** | Xcode build | See setup instructions in `apps/react-native-macos/` |

Benchmarks gracefully skip any framework that isn't installed.
