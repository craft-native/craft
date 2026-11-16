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

### When github.com cannot be reached

This machine resolves github.com to an edge that times out (`Failed to connect to
github.com:443 after 21140 ms`), which makes both the fetch and the push in the
script fail. The working fix is an address override supplied through the
environment, so that no IP is pinned in the repository and nothing has to be
undone when that edge rotates:

```powershell
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'http.curloptResolve'
$env:GIT_CONFIG_VALUE_0 = 'github.com:443:140.82.112.3'
.\scripts\fork-sync.ps1
```

The override reaches the script's own git calls because the child processes
inherit it. When the fetch does fail, the script exits 1 with the fetch error and
touches nothing -- it does not half-merge.

## What is different from upstream

Everything below is Windows-side. Nothing macOS-side was changed except where a
POSIX-only assumption had to move so that both platforms could share it.

### Namespaces routed on Windows

| Namespace | Actions |
| --- | --- |
| `system` | `getHostname`, `getUsername`, `getSystemVersion`, `getLocale`, `getLanguage`, `getTimezone`, `getAccentColor` |
| `screen` | `getDisplays`, `getPrimary` -- real `MONITORINFOEXW` data, DPI scale, primary flag |
| `app` | `getInfo` -- `executablePath`, and `version` from the PE version resource |
| `fs` | all 16 actions, including `watch` on `ReadDirectoryChangesW` -- which reports a rename as `delete` + `create`, stays quiet about what the watch does not own, and ends with a `delete` of the base if the watched directory is renamed or deleted |
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
| `window` | geometry reads, `setSize`/`setPosition`/`setBounds`, `center`, always-on-top, resizable, fullscreen, `getState`, `getFocused`, `setOpacity`/`getOpacity`, `loadURL`/`loadHTML`, `executeJavaScript` |
| `menu` | `setApplicationMenu`, `onAction` |
| `dialog` | `showAlert`, `showConfirm` through `TaskDialogIndirect`, and `openFile`/`openFiles`/`openFolder`/`saveFile` through the shell `IFileOpenDialog`/`IFileSaveDialog` reached by vtable slot |

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
- **A long window title crashed the process.** `utf8ToUtf16Z` wrote through
  `std.unicode.utf8ToUtf16Le` and checked the resulting length afterwards, but
  that function indexes `dest` as it encodes: a title that did not fit trapped on
  an out-of-bounds index inside the standard library and the app was gone. It
  measures with `calcUtf16LeLen` first now. Every string through that helper is
  page-controlled -- titles, URLs, evaluated scripts.
  The same write-then-check shape was audited everywhere else in this file and is
  gone: the two remaining `utf8ToUtf16Le` calls size their buffer from the input
  (a UTF-16 unit never costs more than the UTF-8 bytes that encode it), the spawn
  and shortcut slot copies already refuse ids longer than their slot, and the one
  fixed `[4096]u16` left was in an unreferenced `setClipboard` -- it allocates to
  fit now rather than crashing for the next caller.
- **`window.setAlwaysOnTop`, `setResizable` and `setFullscreen` did nothing.** The
  facade sends `{"value":…}`; the Windows dispatcher parsed `alwaysOnTop`,
  `resizable` and `fullscreen`. `parseBool` treats a missing key as
  InvalidParameter, and these are fire-and-forget sends, so the failure had
  nowhere to surface: the call reported success and the window never changed.
  `bridge_window.zig` reads `value` first and the descriptive key as a legacy
  fallback; the Windows path now does the same through one helper.
- **`fs.appendFile` threw every append away.** It opened the file write-only and
  then asked that handle for its size and wrote at that offset, which Windows
  answers with AccessDenied -- and since the action is a fire-and-forget send, the
  page saw a resolved promise. An app appending to a log lost every line after the
  first. It opens `read_write` now, and the probe checks the append by reading the
  file back.
- **`fs.rmdir` ignored `recursive`.** The facade has always sent it; this side
  never parsed it, so removing any directory with something in it failed with
  DirNotEmpty while the caller's promise resolved. It routes to `deleteTree` now.
- **fs failures said nothing to anyone.** Every mutating fs action is
  fire-and-forget, so `sendFSError` reached no one: a failed write, copy or rmdir
  was indistinguishable from a successful one. It logs a warning naming the
  action, the path and the error now -- which is how the two bugs above were
  found rather than guessed at.
- **`window.getFocused` returned an object that did not exist.** The native side
  answers `null` when none of our windows is focused, which is the documented
  `Promise<Window | null>`; the facade's `_orEmpty` normalised every null payload
  to `{}`, so the typed SDK received a truthy window handle for a window that was
  not there. `executeJavaScript` already had the exemption this one needed.
- **Seven clipboard actions had no route.** `hasText`, `hasHTML`, `hasImage`,
  `clear`, `writeHTML` and `readHTML` were implemented in `bridge_clipboard.zig`
  for Windows and never reached: `handleDesktopText` dispatched only the two text
  actions, so the rest answered UnknownAction. A page cannot tell that apart from
  "the clipboard is empty". They are routed now, Windows-only, because the same
  entry point is the GTK path and these implementations are no-ops there.
- **A watch died silently when its directory was renamed or deleted.**
  `ReadDirectoryChangesW` reports the children of the directory it was handed,
  never that directory itself, so the change that takes the directory away ended
  the pending call instead of being reported. The reader returned, the page kept
  a watch that could never speak again, and nothing was logged. FSEvents does
  report it, so both now read as a `delete` of the watched path -- a rename
  cannot be told from a delete without also watching the parent, and what a page
  does about either is the same.
- **After a rename the watch went on reporting paths that did not exist.** The
  handle survives a rename, and so does the pending `ReadDirectoryChangesW`, so
  events kept arriving spelled from the old name: a page following them looked
  for `mv1/in.txt` while the file was at `mv2/in.txt`. Which of this and the
  silent death above happened depended on whether the call was pending when the
  rename landed, so the same action gave one or the other at random. The reader
  checks that the watched directory still resolves before handing on a batch --
  one `stat` per batch, not per event -- and ends the watch with a `delete` of
  the base when it does not.

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
| `fs.watch` | external file creation delivered `{"type":"modify","path":"...\\hello.txt"}`; a create / append / rename / delete each reported, a rename as `delete` + `create`; a non-recursive watch stayed silent about a nested write; a single-file watch ignored a sibling written beside it and delivered its own change to both `onChange` and the per-watch callback; a recursive watch reported `...\\sub\\deep2.txt`; `unwatch` stopped delivery; a missing path rejected with `NOT_FOUND`; deleting or renaming the watched directory delivered one `delete` of that path and stopped the watch |
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
| `dialog` | `showAlert` answered `{"buttonIndex":0}`; `showConfirm` answered `{"ok":true}` and `{"ok":false}` for the first and last button; `saveFile` with a `defaultName` returned `{"canceled":false,"filePath":"...\\picked-probe.txt"}`; a folder pick returned the folder it opened in; cancelling an open returned `{"canceled":true,"filePaths":[]}`. Picking a name by hand in `openFile` was **not** reachable: the shell dialog keeps the filename in its own state, so a path written into its edit box from another process leaves the OK button a no-op -- measured with `SetWindowTextW` on the edit and the `ComboBoxEx32` parent, `WM_COMMAND`/`BM_CLICK`/`WM_KEYDOWN`, and the `CBN_EDITCHANGE` notification. The pick itself is covered by `saveFile` and `openFolder`, which return through the same `slot_get_result` code; `openFiles`' array path (`slot_get_results`) is the one branch no probe reaches |

### Automated check

One entry point runs everything:

```powershell
.\scripts\probe-windows.ps1              # against the binary that is there
.\scripts\probe-windows.ps1 -Build       # build first, then probe
.\scripts\probe-windows.ps1 -Only timers # one probe
```

It exits 0 when every probe passed, 1 when one failed, and 2 when nothing could
run -- a missing binary or an unknown probe name -- so a scheduled run cannot
quietly report success against a stale build.

The probes it runs:

| Script | What it re-checks |
| --- | --- |
| `scripts/probe-windows-timers.ps1` | a 400ms deadline, an abort, two deadlines armed together, slot reuse |
| `scripts/probe-windows-capabilities.ps1` | the rendered manifest: what is claimed and what is demoted |
| `scripts/probe-windows-single-instance.ps1` | a second launch handing off its arguments and deep link |
| `scripts/probe-windows-multiwindow.ps1` | a page opening a second window, and closing it leaving one |
| `scripts/probe-windows-window-state.ps1` | geometry, always-on-top, resizable, title, getState, getFocused, opacity, an oversized title, and the clipboard |
| `scripts/probe-windows-notification.ps1` | the toast path runs, and a title or body cannot become PowerShell |
| `scripts/probe-windows-fs.ps1` | write, append, copy, move, delete, recursive rmdir -- each read back |
| `scripts/probe-windows-fs-watch.ps1` | a watch speaks about what changed and stays quiet about what it does not own, in both directions; a root that is deleted or renamed is reported once |
| `scripts/probe-windows-dialog.ps1` | an alert, both answers to a confirm, a save dialog returning a path, a folder pick, and a cancelled open -- the probe presses each button itself |

The rest of the table above was measured by hand.

Each was checked the way a regression check has to be -- by making it fail.
Removing the missed-deadline reply from the timer cancel path makes the timer
probe fail. Bypassing the manifest filter makes the capability probe report
`haptics=declared`. Launching the second instance under a different
`--single-instance` id makes the single-instance probe see two windows and no
delivered payload. Forcing `ReadDirectoryChangesW` to watch the subtree and
disabling the single-file filter makes the watch probe report `NORECURSE=LEAK`
and `SIBLING=2` -- the two assertions that say a watch stays quiet are the ones
that would otherwise pass by never firing at all. Sending the second button's id
where the first was expected turns the dialog probe's `confirmYes` into
`{"ok":false}`; note that its `alert` assertion is the weak one, since a dialog
with a single button reports index 0 however it was closed.

`probe-windows-notification.ps1` is the one probe that has failed and then passed
with nothing changed: once inside a full suite run, twice on its own. It is the
only one that has to observe a spawned `powershell` by its `StartTime`, so treat
a lone failure here as a question rather than a verdict -- read the log before
believing it.

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

## Multiple windows

`craft.window.open({ name, html | url, title, width, height })` opens a second
window running its own page, and resolves with the name it was given. On Windows
the call cannot complete inside the WebView2 message callback -- WebView2 does not
run async completion callbacks from inside its own event -- so it is queued and
pumped from a posted message (`queueWindowOpen` / `processPendingOpens`). A
regression there shows up as an `open()` that never resolves.

Measured: the child window appeared with its own title while the caller's
`open()` had already resolved with `{"name":"child"}`, and closing the child left
the main window running.

One measurement trap is worth recording. Both windows belong to a single process,
so counting `craft` processes says nothing about how many windows exist, and
`Process.MainWindowTitle` answers for only one of them. The probe enumerates
top-level windows per process with `EnumWindows` instead. Counting processes
first produced "one window" while two were on screen; the stderr log, which
showed two WebView2 initialisations, is what settled it.

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

- **A toast needs an application id that nothing documented or shipped.**
  `notification.show` reads `craft-notification-id.txt` from beside the
  executable and refuses without it -- and because `show` is a fire-and-forget
  send, "refuses" meant "does nothing, silently". An app that never heard of that
  file had a notification API that never fired. It logs a warning now, naming the
  file and where it goes, and `probe-windows-notification.ps1` creates one for its
  run. Providing a default id, or registering one through a Start-menu shortcut,
  is still open: the id is what Windows groups and names the toast with, so
  inventing one would be a product decision rather than a fix.

- **`serial.onData` is implemented but not verified end to end.** The test
  machine has COM1 with no device attached and two Bluetooth ports that cannot be
  held open, so no bytes could be made to arrive. What was checked is that the
  reader thread does not disturb the existing flow -- open, write, read, close all
  behave as before and the process stays responsive. Delivery uses the same
  `postToUi` path that `fs.watch` proved.
- **`updater` is not implemented on Windows, and what it must match now exists.**
  Upstream shipped the AppKit host's in-app updater in v0.0.503/504: the bundle
  names `feedUrl`, `publicKeys` (Ed25519, base64url SPKI DER), `channel` and
  `checkEveryHours` under `updates` in `craft-app.json`, and the host installs
  `craft.updater` with `check()` / `install()` before the screen runs. None of
  that is Windows-shaped — there is no Win32 API to wrap and the install step has
  to replace a running executable — but the feed and the signature are no longer
  open questions, so a Windows implementation now has a contract to match rather
  than one to invent.
  The status the manifest reports for `updater` on Windows is right
  (`unavailable`), though the reason it carries still quotes Sparkle, which is a
  macOS detail.
- **`app.getInfo().bundleId` is empty.** Windows has no bundle identifier, and
  returning a placeholder would be worse than returning nothing.
- **Event channels are not demoted per platform.** The manifest's `channels`
  section answers `live` or `unknown` from whether an emitter registered, and on
  Windows the emitters for macOS-only channels never register, so a page sees
  `unknown` rather than a per-platform answer. Namespaces are filtered; channels
  are not yet.
- **These window actions have no Windows arm at all**, and answer
  PLATFORM_NOT_SUPPORTED: `setMovable`, `isMovable`, `setHasShadow`,
  `setAspectRatio`, `startDrag`, `setBackgroundColor`, `setVibrancy`,
  `setWebSidebarCollapsed`. These are macOS-only concepts except
  `setBackgroundColor`, which would need per-window `WM_ERASEBKGND` handling
  rather than the class-wide brush that changes every window at once.

## Test baseline

`zig build test` reports failures on every run, and they are not all the same set:

| Module | Count | What it is |
| --- | --- | --- |
| `injected_js_test` | 44 | the vendored `zig_js` interpreter hitting its own stack/nesting limit |
| `ios_conformance_test` | 9 | the iOS spec against Zig's action tables |
| `bridge_surface_test` | 1 | |
| `bridge_fs_test` | 1 | |
| `config_test` | 0 or 1 | **flaky**: `Config - saveToFile and loadFromFile` fails with `FileNotFound` creating a file under a temp path. It failed on two runs and passed on a third, with no change in between. |
| `test/log_test.zig` | -- | does not compile: it reaches `std.c.open`, whose Windows `O` type is `void` in Zig 0.17.0 |

So the number to hold is **55**: those first four plus the module that does not
compile. A run that reports 56 has counted `config_test` as well, and that one is
the environment rather than the change.

**Do not compare the aggregate totals.** Three runs of the same command against
the same commit reported 3459, 2565 and 398 total tests. Zig's build summary
aggregates only the steps it happens to print, so those totals are not coverage
and a difference between them means nothing. The failure set is the signal.

This was measured rather than assumed: a worktree checked out at the pre-merge
commit reported 55 failures while the merge result reported 56, and the single
difference was `config_test`.

## Toolchain

`pantry.lock` pins Zig `0.18.0-dev.146`; this machine has `0.17.0` on PATH and
builds with it directly. That means `bun run build:core` is stopped by its version
guard and `zig build` is the entry point instead. `bun` is not installed here, so
the TypeScript-side checks (`bun run typecheck`, `bunx --bun pickier .`) are not
part of the local loop.
