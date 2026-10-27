---
title: Persistent JavaScript hosting
description: Retain native JavaScript callbacks and typed buffers with bounded ownership.
---

# Persistent JavaScript hosting

`craft.js_runtime.PersistentRuntime` runs JavaScript in Craft's zig-js engine.
It needs no WebView, DOM or browser globals. It keeps one realm alive so a host
can load its bundle once and call a retained callback on later frames.

```zig
const craft = @import("craft");
var runtime = try craft.js_runtime.PersistentRuntime.init(allocator, .{
    .max_handles = 128,
    .max_arguments = 16,
    .heap_limit_bytes = 64 * 1024 * 1024,
});
defer runtime.deinit() catch unreachable;

const update = try runtime.evaluate("(function(bytes) { return ++bytes[0]; })");
const state = try runtime.create(.{ .typed_array = .{ .kind = .u8, .bytes = &.{0} } });
const result = try runtime.call(update, null, &.{state});
defer runtime.release(result) catch unreachable;
const ticks = try runtime.number(result);
var snapshot: [1]u8 = undefined;
try runtime.copyBuffer(state, 0, &snapshot);
```

`evaluate`, `create`, `call` and `exception` return numeric handles. Each handle
records its runtime, slot and generation. Released slots can be reused, but an
old handle cannot refer to the replacement value. Foreign, released and
fabricated handles fail with `InvalidHandle`; operations after disposal fail
with `Closed`. Disposal is idempotent on the owner thread. Treat the runtime as
an owning Zig value: do not copy it after initialization.

Retained handles root callbacks, closures, strings and typed buffers through
garbage collection. Release individual handles when finished, or dispose the
runtime to release them all. A call reserves capacity for its result before
executing JavaScript. `LimitExceeded` therefore does not execute a callback
whose result the host could not retain.

`create` accepts undefined, null, booleans, numbers, UTF-8 strings and typed-array
bytes. Buffers and strings are copied into the realm. Typed-array kinds are
`i8`, `u8`, `u8_clamped`, `i16`, `u16`, `i32`, `u32`, `f16`, `f32`, `f64`,
`bigint64` and `biguint64`. Buffer bytes use the host's native representation;
the byte count must be divisible by the element size.

`copyBuffer` and `writeBuffer` use byte offsets and copy only the current view.
They check bounds on every call, reject detached and shared backing storage,
reject views made out of bounds by resizing, and reject immutable writes.
They never return a borrowed pointer. `copyString` returns an owned WTF-8 copy
allocated by the supplied allocator; free that copy with the same allocator.
It remains valid after handle release or runtime disposal.

`kind`, `number` and `boolean` inspect a retained value without JavaScript
coercion. A mismatched scalar or string read returns `WrongType`.

## Bounds and failures

The one-shot `craft --eval` / `--eval-file` CLI preserves thrown error details
before its runtime is destroyed. For example, `throw new Error("distinct failure")`
reports `uncaught error: Error: distinct failure` and exits nonzero. Syntax,
runtime-unavailable and out-of-memory failures remain distinct.

Diagnostics inspect engine-owned primitive values and an Error's own string
message; they do not execute getters, proxy traps, `toString`, or prototype
lookups. Other objects receive a type placeholder. Strings above 1,024 backing
bytes receive a bounded placeholder instead of allocating an unbounded report.
The input bundle is not printed. This diagnostic path does not alter evaluation
budgets, heap limits, or timeout behavior.

The defaults allow 1024 retained handles, 64 arguments per call, 16 MiB of input
per operation, 16 MiB of copied output, and a 64 MiB realm heap. Set explicit
`Options` for the application. The handle table is bounded separately from the
realm; caller-owned output copies remain the caller's responsibility.

Syntax errors return `Parse`. JavaScript throws return `Throw`; `exception()`
retains the thrown value without invoking a user-defined `toString` or masking
the failure. A thrown string can be read with `copyString`. Objects remain
objects and can be passed to another retained callback for application-specific
inspection. Heap or host allocator exhaustion returns `OutOfMemory`.

Calls poll elapsed timers and AbortSignal timeouts before invocation and drain
the engine's host microtask/finalization checkpoint after retaining the result.
They do not keep the realm alive for future referenced timers or run a general
event loop until a returned Promise settles. A Promise remains a retained object.
Value creation and buffer copies do not execute that checkpoint.
All operations except `interrupt` belong
to the creating native thread and reject another thread with `WrongThread` in
every build mode. Do not enter the runtime concurrently or reentrantly.

A watchdog can call `interrupt` while the owner is executing JavaScript. The
engine cooperatively interrupts the call with `Terminated`. Interruption is
terminal: dispose that runtime before starting another one. Join the watchdog
before disposal; no operation may overlap disposal.

With `-Djs-runtime=false`, initialization and the unavailable backend's methods
return `Unavailable`. The API does not report successful execution on a build
without an engine.

## Verification boundary

`bun scripts/zig.ts --core build test-js-hosting` exercises the maintained Craft
API. The target is part of the normal Zig test suite and can also run with
`-Djs-runtime=false`. The engine owns typed call entry, GC registration and
exception transfer. Craft owns the numeric handle table and input/output bounds.

These are native JavaScript-hosting checks. They do not establish native game
rendering, browser/native visual parity, or original Settlers III behavior.
