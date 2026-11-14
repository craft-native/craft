# This fork

`qcjxberin/craft` is a self-maintained fork of [craft-native/craft](https://github.com/craft-native/craft).
It exists to make the Windows backend usable to the same degree as the macOS
one, so that Craft can be used the way Tauri is: a real UI, a real filesystem,
and a real ability to shell out.

Upstream has not taken the change yet. This fork is therefore maintained on its
own, with upstream merged in on a schedule rather than waiting on review.

## Branch model

| Branch | Role |
| --- | --- |
| `main` | Mirror of upstream. Fast-forward only. Never commit here. |
| `feat/windows-bridge-parity` | The fork's work. Everything below lands here. |

Our branch takes upstream by **merge**, not rebase. With 17 local commits over a
3900-line dispatcher, rebasing means resolving the same conflict on every
upstream release; merging resolves it once per release and leaves the history
readable.

## Syncing with upstream

```powershell
# what is pending, change nothing
.\scripts\fork-sync.ps1 -Check

# fetch, merge, build, push
.\scripts\fork-sync.ps1
```

The script refuses to start on a dirty tree, fast-forwards the local `main`
mirror, merges upstream into the working branch, verifies with a build, and only
then pushes. A merge that conflicts is aborted so the branch stays buildable; a
merge that lands but fails to build is not pushed.

Two things worth knowing about the build step: a running `craft.exe` holds its own
binary open, so the script stops it first; and the repository root's `build.zig` is
a delegator, so the binary it produces lands in
`packages/zig/zig-out/bin/craft.exe`, not at the root.

Exit codes: `0` in sync or synced, `1` precondition failed, `2` dirty tree,
`3` conflict, `4` build failed, `5` push failed.

To resolve a conflict by hand:

```powershell
.\scripts\fork-sync.ps1 -KeepOnConflict -NoPush -NoBuild
# fix the files, git add, git commit -F .git/FORK_SYNC_MERGE_MSG.txt
# or: git merge --abort
```

To run it unattended, start it on a schedule that suits you:

```powershell
schtasks /create /tn "craft fork sync" /sc daily /st 10:00 ^
  /tr "powershell -NoProfile -ExecutionPolicy Bypass -File G:\Code\Zig\craft\scripts\fork-sync.ps1"
```

## What is different from upstream

Everything below is Windows-side. Nothing macOS-side was changed except where a
POSIX-only assumption had to move so that both platforms could share it.

### Namespaces routed on Windows

| Namespace | Actions |
| --- | --- |
| `system` | `getHostname`, `getUsername`, `getSystemVersion`, `getLocale`, `getLanguage`, `getTimezone`, `getAccentColor` |
| `screen` | `getDisplays`, `getPrimary` -- real `MONITORINFOEXW` data, DPI scale, primary flag |
| `app` | `getInfo` -- `executablePath`, and `version` from the PE version resource |
| `fs` | all 16 actions, including `watch` on `ReadDirectoryChangesW` |
| `capabilities` | the full namespace manifest |
| `serial` | `list`, `open`, `write`, `read`, `close`, and `onData` push |
| `notifications` | `getPermissionStatus` |
| `shell` | `openUrl`, `openPath`, `showInFinder`, `getEnv`, `setEnv`, `spawn`, `kill`, `exec` |
| `power` | `isCharging`, `isPluggedIn`, `isLowPowerMode`, `batteryLevel`, `batteryState`, `timeRemaining` |
| `autoLaunch` | `enable`, `disable`, `isEnabled` (the `Run` key) |
| `permissions` | `check`, `request`, `openSettings` |
| `log` | `debug`, `info`, `warn`, `error` |
| `tray` | `setTitle`, `setTooltip`, `getState`, `setMenu`, click events |
| `shortcuts` | `register`, `unregister`, `unregisterAll`, `enable`, `disable`, `isRegistered`, `list` |
| `timers` | `sleep`, `cancel`, `cancelAll` -- `SetTimer` on the owning window, with `SetThreadExecutionState` held while a deadline is pending |
| `menu` | `setApplicationMenu`, `onAction` |

### Defects fixed while wiring them up

- **`fs.watch` reported success and delivered nothing.** `startNative` returned
  null off macOS while `watch` still handed back a watch id, so the page waited
  forever. Now backed by a real `ReadDirectoryChangesW` reader thread.
- **Bridge failures vanished.** The dispatcher's error path was a bare
  `catch {}`, so a failing handler left the JS promise pending for good. Failures
  now produce a correlated reply.
- **The bridge was rebuilt per request.** Port tables and watcher tables lived in
  a struct that `defer deinit()` destroyed when the reply was sent. Both are
  process-wide singletons now.
- **`ShellExecuteW` said yes to unregistered schemes.** It returns >32 even when
  it only opened the app picker. The protocol handler is checked in
  `HKEY_CLASSES_ROOT` first.
- **`tray.zig`'s creation path could never succeed** -- it registered an anchor
  window under a class name nobody had registered. It anchors to the main window
  now.
- **`shell.exec` existed in Zig but had no facade.** `bridge_shell.zig` already
  implemented it; `craft-bridge.js` simply never exposed it.

### Windows-specific traps worth knowing before editing this

- `CreateProcessW` searches PATH only when `lpApplicationName` is null. Passing
  the program name there makes `spawn("ping", ...)` fail outright.
- Reading two pipes one after the other deadlocks. stdout and stderr are merged
  into one pipe, the way `2>&1` would.
- A piped `cmd` writes in the console's ANSI code page, and `chcp 65001` has no
  effect on a pipe -- the code page belongs to the console, not the pipe. Output
  is decoded from `CP_ACP` and then checked for valid UTF-8.
- WebView2 will not accept a bridge call from a reader thread. Replies go through
  a queue drained on the UI thread by a posted `WM_CRAFT_PUMP` message.

## Verification status

Measured on a real Windows machine by observing process state and window titles,
not by inspection alone.

| Area | Result |
| --- | --- |
| `system` | `DESKTOP-P6GPV4`, `qcjxb`, `Windows 10.0 (build 26200)`, `中国标准时间`, `#0078d4` |
| `screen` | 3840x1080, `workHeight` 1032, `\\.\DISPLAY1` |
| `app.getInfo` | `executablePath` exact; `version` reads `6.2.26100.9818` from notepad, empty from an exe with no version resource |
| `fs` | 70 entries in a home directory, 45 directories / 25 files; file contents read back |
| `fs.watch` | external file creation delivered `{"type":"modify","path":"...\\hello.txt"}` |
| `capabilities` | 54 namespaces |
| `serial` | `["COM1","COM3","COM4"]`; COM99 rejected; open, 4 bytes written, 0 read back, close |
| `shell` | env round-trip; unregistered scheme refused without touching https/http/mailto; spawn writes a file; `kill` stops `ping`; `opts.shell` both redirect and pipe |
| `shell.exec` | exit 0/3/1 all reported; three-line output; `中文测试` round-trips; 2000 lines / >8 KB read in full |
| `power` | `isPluggedIn` true, `isCharging` false, level null with no battery, uptime reported |
| `autoLaunch` | `false -> true -> false`, `Run` key left clean |
| `permissions`, `log` | `granted`; JS log line appears in the process output |
| `tray` | registered, state `0 -> 1`; left click delivered; right-click menu of three items (two disabled, one separator) delivered `{"action":"act-one"}` |
| `shortcuts` | registered; `Ctrl+Alt+F9` fired while the window was unfocused |
| `menu` | `WM_COMMAND` delivered `{"id":"probeItem"}`; the `Ctrl+Shift+9` accelerator matched |
| `timers` | a 400ms deadline resolved in 394-409ms; aborting a 5000ms one rejected with `AbortError`; a 200ms and a 600ms deadline armed together landed at ~200ms and ~605ms; a later 150ms deadline reused the freed slot |

### Automated check

Three scripts repeat measurements and exit non-zero when one stops holding:

| Script | What it re-checks |
| --- | --- |
| `scripts/probe-windows-timers.ps1` | a 400ms deadline, an abort, two deadlines armed together, slot reuse |
| `scripts/probe-windows-capabilities.ps1` | the rendered manifest: what is claimed and what is demoted |
| `scripts/probe-windows-single-instance.ps1` | a second launch handing off its arguments and deep link |

The rest of the table above was measured by hand.

Each was checked the way a regression check has to be -- by making it fail.
Removing the missed-deadline reply from the timer cancel path makes the timer
probe fail. Bypassing the manifest filter makes the capability probe report
`haptics=declared`. Launching the second instance under a different
`--single-instance` id makes the single-instance probe see two windows and no
delivered payload.

One trap worth knowing before editing these probes: the JS facade's `_evt`
unwraps `event.detail`, so a callback receives the detail object itself. Writing
`e.detail.args` reads a property that does not exist, throws, and silently
leaves the title unchanged -- which looks exactly like a broken native path.

## Second instance and deep links

A launch carrying `--single-instance <id>` finds the running instance through a
named mutex and forwards its payload over `WM_COPYDATA`, then exits. Measured on
Windows:

- a second launch with `--instance-arg hello` handed off in 128ms; the first
  instance's page received `craft:secondInstance` with `args: ["hello"]`, and
  exactly one window survived.
- a launch with `--deep-link craftprobe://abc` delivered both `craft:deepLink`
  (the URL on its own) and `craft:secondInstance` with `url` set, which is what
  the facade documents.
- the control: a second launch under a *different* instance id does not exit, and
  two windows appear with nothing delivered. That is the state the probe fails
  on.

## The capability manifest says something different on Windows

`capability_registry.zig` describes the audited macOS dispatch chain, and its
`declared` rows are claims about that chain. On Windows they were wrong: the
manifest said `haptics` was declared, and the first call answered
PLATFORM_NOT_SUPPORTED. `docs/FEATURES.md` has carried
`Platform feature detection` as an open item for exactly this reason.

A backend now renders the manifest through its own routed set. A `declared`
namespace the backend cannot dispatch is demoted to `unavailable` with a reason
and loses its action table, because those action names describe the chain that
does have the arm. Only `declared` is touched: `undeclared` (craft claims
nothing), `unrouted` (nothing can reach it anywhere) and `unavailable` (known not
to work) are already true on every backend.

On Windows today that demotes `haptics` and nothing else; `timers` stays declared
because it is now actually routed. `capability_registry.zig` carries a test that
fails if the registry gains a `declared` row the Windows set cannot dispatch, so
the manifest cannot drift back into overclaiming.

`scripts/probe-windows-capabilities.ps1` checks the rendered manifest end to end
and was validated the same way: with the filter bypassed it reports
`haptics=declared` and exits non-zero.

### Known gaps

- **`serial.onData` is implemented but not verified end to end.** The test
  machine has COM1 with no device attached and two Bluetooth ports that cannot be
  held open, so no bytes could be made to arrive. What was checked is that the
  reader thread does not disturb the existing flow -- open, write, read, close all
  behave as before and the process stays responsive. Delivery uses the same
  `postToUi` path that `fs.watch` proved.
- **`updater` is not implemented.** It has no Win32 API to wrap: it needs an
  agreed feed format and a decision on signature verification, and guessing at one
  would create a contract the project has not chosen.
- **`app.getInfo().bundleId` is empty.** Windows has no bundle identifier, and
  returning a placeholder would be worse than returning nothing.
- **Event channels are not demoted per platform.** The manifest's `channels`
  section answers `live` or `unknown` from whether an emitter registered, and on
  Windows the emitters for macOS-only channels never register, so a page sees
  `unknown` rather than a per-platform answer. Namespaces are filtered; channels
  are not yet.

## Test baseline

`zig build test` currently reports 56 failures and 1 module that fails to
compile (`test/log_test.zig` reaches `std.c.open`, whose Windows `O` type is
`void` in Zig 0.17.0). 44 of the failures are inside the vendored `zig_js`, 9 in
`ios_conformance_test`, the rest are CRLF fixtures and temporary directories.

None of them involve the Windows bridge, and the count is unchanged by the work
above. Treat this number as the baseline: it should not grow.

## Toolchain

`pantry.lock` pins Zig `0.18.0-dev.146`; this machine has `0.17.0` on PATH and
builds with it directly. That means `bun run build:core` is stopped by its version
guard and `zig build` is the entry point instead. `bun` is not installed here, so
the TypeScript-side checks (`bun run typecheck`, `bunx --bun pickier .`) are not
part of the local loop.
