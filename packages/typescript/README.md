# craft-native

Build lightning-fast desktop apps with web languages, powered by Zig.

## Features

- **Lightning Fast**: 50ms startup vs Electron's 230ms (4.5x faster)
- **Tiny Memory Footprint**: ~14 KB idle vs Electron's 68 MB (4857x less)
- **Small Binaries**: 3 MB vs Electron's 135 MB (45x smaller)
- **TypeScript First**: Full type safety with zero dependencies
- **Zero Config**: Just write HTML/CSS/JS and run
- **Cross-Platform**: macOS, Linux, Windows
- **GPU Accelerated**: Direct Metal/Vulkan access for blazing performance
- **Hot Reload**: Built-in development mode with auto-refresh

## Installation

```bash
bun add craft-native
```

## Quick Start

### Minimal Example (1 line!)

```ts
import { show } from 'craft-native'

await show('<h1>Hello Craft!</h1>', { title: 'My App', width: 600, height: 400 })
```

### Hello World

```ts
import { createApp } from 'craft-native'

const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    body {
      margin: 0;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
      font-family: system-ui, sans-serif;
    }
  </style>
</head>
<body>
  <h1>⚡ Lightning Fast Desktop Apps</h1>
</body>
</html>
`

const app = createApp({
  html,
  window: {
    title: 'My Craft App',
    width: 800,
    height: 600,
  },
})

await app.show()
```

### Load a URL

```ts
import { loadURL } from 'craft-native'

// Load any website or local dev server
await loadURL('http://localhost:3000', {
  title: 'My Web App',
  width: 1200,
  height: 800,
  devTools: true,
  hotReload: true,
})
```

## API Reference

### `createApp(config)`

Create a new Craft app instance.

```ts
import { createApp } from 'craft-native'

const app = createApp({
  html: '<h1>Hello</h1>',  // HTML content
  url: 'https://example.com',  // Or load a URL
  window: {
    title: 'My App',
    width: 800,
    height: 600,
    // ... more options
  },
})

await app.show()
```

### `show(html, options)`

Quick helper to show a window with HTML.

```ts
import { show } from 'craft-native'

await show('<h1>Hello World</h1>', {
  title: 'My App',
  width: 600,
  height: 400,
})
```

### `loadURL(url, options)`

Quick helper to load a URL.

```ts
import { loadURL } from 'craft-native'

await loadURL('http://localhost:3000', {
  title: 'Dev Server',
  width: 1200,
  height: 800,
  devTools: true,
})
```

## Window Options

```ts
interface WindowOptions {
  title?: string              // Window title
  width?: number              // Width in pixels (default: 800)
  height?: number             // Height in pixels (default: 600)
  x?: number                  // X position
  y?: number                  // Y position
  resizable?: boolean         // Can resize (default: true)
  frameless?: boolean         // Frameless window (default: false)
  transparent?: boolean       // Transparent background (default: false)
  alwaysOnTop?: boolean       // Always on top (default: false)
  fullscreen?: boolean        // Start fullscreen (default: false)
  darkMode?: boolean          // Enable dark mode
  hotReload?: boolean         // Enable hot reload (default: dev mode)
  devTools?: boolean          // Enable dev tools (default: dev mode)
  systemTray?: boolean        // Enable system tray (default: false)
  hideDockIcon?: boolean      // Hide dock icon (macOS menubar-only mode)
  menubarOnly?: boolean       // No window, tray icon only
  titlebarHidden?: boolean    // Hide titlebar (content extends into titlebar)
  vibrancy?: string           // macOS vibrancy effect
}
```

## Menubar Apps

Craft supports menubar/system tray apps with or without a popup window.

### Menubar with Popup Window

```ts
import { createApp } from 'craft-native'

const app = createApp({
  html: `<h1>Pomodoro Timer</h1>`,
  window: {
    title: 'Timer',
    width: 320,
    height: 380,
    systemTray: true,      // Enable system tray icon
    hideDockIcon: true,    // Hide dock icon (menubar-only)
    frameless: true,
    transparent: true,
  },
})

await app.show()
```

### Menubar-Only (No Window)

```ts
const app = createApp({
  window: {
    title: 'System Monitor',
    menubarOnly: true,     // No window, tray icon only
    systemTray: true,
    hideDockIcon: true,
  },
})

await app.show()
```

### Tray API (from JavaScript in your HTML)

```js
// Update menubar title (e.g., "🍅 25:00")
window.craft.tray.setTitle('🍅 25:00')

// Set context menu
window.craft.tray.setMenu([
  { label: 'Start', action: 'start' },
  { label: 'Pause', action: 'pause' },
  { type: 'separator' },
  { label: 'Quit', action: 'quit' }
])

// Listen for menu actions
window.addEventListener('craft:tray:menu', (e) => {
  switch (e.detail.action) {
    case 'start': startTimer(); break
    case 'pause': pauseTimer(); break
    case 'quit': window.craft.app.quit(); break
  }
})
```

## Window API (JavaScript)

Control the window from your HTML/JavaScript:

```js
// Visibility
window.craft.window.show()
window.craft.window.hide()
window.craft.window.toggle()
window.craft.window.focus()

// State
window.craft.window.minimize()
window.craft.window.maximize()
window.craft.window.close()
window.craft.window.toggleFullscreen()
window.craft.window.center()

// Properties
window.craft.window.setTitle('New Title')
window.craft.window.setPosition(100, 100)

// Events
window.craft.window.on('focus', () => console.log('Focused'))
window.craft.window.on('blur', () => console.log('Blurred'))
```

## App API (JavaScript)

Application lifecycle and system integration:

```js
// Lifecycle
window.craft.app.quit()
window.craft.app.hide()
window.craft.app.show()

// Dock (macOS)
window.craft.app.hideDockIcon()
window.craft.app.showDockIcon()
window.craft.app.setBadge('3')
window.craft.app.bounce()

// Notifications
window.craft.app.notify({
  title: 'Timer Complete',
  body: 'Your focus session is done!'
})

// System info
window.craft.app.isDarkMode()  // Returns true/false
window.craft.app.getLocale()   // Returns 'en-US', etc.
```

## Sidebar Styles

Craft includes pre-built CSS styles for three popular sidebar designs:

### Tahoe Style (macOS Finder)

```ts
import { tahoeStyles, renderTahoeSidebar, tahoeDemoData } from 'craft-native'

// Use Tailwind classes
const sidebar = `<div class="${tahoeStyles.sidebar}">...</div>`

// Or render full HTML
const html = renderTahoeSidebar(tahoeDemoData)
```

### Arc Style (Arc Browser)

```ts
import { arcStyles, renderArcSidebar, arcDemoData } from 'craft-native'

// Gradient pills, collapsible sections
const html = renderArcSidebar(arcDemoData, false) // collapsed = false
```

### OrbStack Style (Minimal Dark)

```ts
import { orbstackStyles, renderOrbStackSidebar, orbstackDemoData } from 'craft-native'

// Dark #1a1a1a theme with status indicators
const html = renderOrbStackSidebar(orbstackDemoData)
```

## Auto-Updating

`AutoUpdater` fetches a manifest, verifies the download, replaces the app bundle,
and relaunches.

```ts
import { AutoUpdater } from 'craft-native'

const updater = new AutoUpdater({
  updateUrl: 'https://github.com/you/app/releases/latest/download/update.json',
  currentVersion: '1.0.0',
  appPath: '/Applications/MyApp.app',
  autoDownload: false,
  macos: { teamId: 'ABCDE12345' },
})

updater.on('update-available', info => console.log('available:', info.version))
updater.on('download-progress', p => console.log(`${p.percent}%`))

if (await updater.checkForUpdates()) {
  await updater.downloadUpdate()
  await updater.installUpdate()
}
```

### macOS trust

The manifest's SHA-256 proves the download matches what the manifest asked for. It
says nothing about *who published it* — whoever can rewrite the manifest can rewrite
the hash with it. So on macOS the staged bundle is also put through the checks
Gatekeeper runs at launch, before anything is swapped:

- `codesign --verify --deep --strict` — the signature covers the bytes on disk
- `spctl -a -t exec` — Apple has notarized this build
- `TeamIdentifier` equals `macos.teamId` — *you* published it

Pin `teamId`. Without it an updater accepts any notarized bundle, and notarization is
available to every Apple developer account there is. `@stacksjs/desktop`'s
`createSelfUpdater` fills it in from the signature on the running copy, which is the
version most apps want.

### Replacing the bundle

The swap is deliberately not `rm -rf app && cp -R new app`:

- **`ditto`, not `cp -R`.** `cp` and `fs.cpSync` drop the extended attributes and ACLs
  a code signature is computed over, so a byte-identical copy fails `codesign --verify`.
- **Two renames, not a delete.** The new bundle lands on the destination volume first,
  then the old one is renamed aside and the new one renamed in. Both are atomic within
  a directory, so there is no window in which an interrupted update leaves the user
  with no app.
- **Quarantine last.** The flag is cleared only after verification passes — clearing it
  first is how an updater becomes a way to install anything at all.

These are exported on their own for installers and CI: `verifyBundleTrust`,
`readBundleIdentity`, `extractBundle`, `extractBundleFromDmg`, `extractBundleFromZip`,
`swapBundle`, `dittoBundle`, `clearQuarantine`, `canReplaceBundle`.

### Relaunching

`restartApp` opens the bundle and exits. Pass `relaunch` when the updater does not run
in the process the user launched — an agent behind a webview that calls
`process.exit(0)` kills a child, leaves the window on a dead server, and relaunches
nothing.

### Deltas

Delta updates are used only when `bspatch` or `xdelta3` is on the machine. Neither
ships with macOS or a default Linux install, so a manifest that offers a delta falls
back to the full bundle rather than failing.

## Examples

See the [examples directory](../examples-ts) for more:

### Basic Apps

- **minimal.ts** - Simplest possible app
- **hello-world.ts** - Modern styled app
- **todo-app.ts** - Interactive todo list

### Menubar Apps

- **menubar-timer.ts** - Pomodoro timer with popup window
- **menubar-only.ts** - System monitor (no window, tray icon only)

### Sidebar Apps

- **file-browser.ts** - Finder-like app with Tahoe sidebar
- **arc-browser.ts** - Browser with Arc-style vertical tabs
- **orbstack-containers.ts** - Container manager with OrbStack style
- **sidebar-showcase.ts** - All three sidebar styles side-by-side

Run examples:

```bash
# Basic apps
bun run packages/examples-ts/hello-world.ts
bun run packages/examples-ts/todo-app.ts

# Menubar apps
bun run packages/examples-ts/menubar-timer.ts
bun run packages/examples-ts/menubar-only.ts

# Sidebar apps
bun run packages/examples-ts/file-browser.ts
bun run packages/examples-ts/arc-browser.ts
bun run packages/examples-ts/sidebar-showcase.ts
```

## Performance Comparison

| Metric | Craft | Electron | Advantage |
|--------|------|----------|-----------|
| **Startup Time**| 50ms | 230ms |**4.5x faster** |
| **Idle Memory**| 14 KB | 68 MB |**4857x less** |
| **Binary Size**| 3 MB | 135 MB |**45x smaller** |
| **IPC Throughput**| 2.89 µs | 2.16 ms |**748x faster** |

See [benchmarks](../../benchmarks) for detailed performance comparisons.

## Why Craft

### vs Electron

- **4.5x faster startup** - Your app opens instantly
- **4857x less memory** - More performant on any machine
- **45x smaller binaries** - Faster downloads, less disk space
- **No Chromium** - Native webview means better integration
- **GPU accelerated** - Direct Metal/Vulkan for smooth rendering

### vs Tauri

- **2.77x faster startup** - Even quicker than Tauri
- **186x less idle memory** - Extremely lightweight
- **No Rust required** - Just TypeScript/JavaScript
- **Zero dependencies** - Pure Node.js APIs only
- **Better DX** - Hot reload and dev tools built-in

## Native bridge error codes

The mobile bridge declarations in `types/craft.d.ts` distinguish canonical
`NativeBridgeErrorCode` values from the broader compatible `CraftErrorCode` union.
The native wire vocabulary comes from `packages/zig/src/bridge_error.zig`; SDK
parity tests fail if the declaration drifts. It includes `INVALID_PARAMETER`,
`PLATFORM_NOT_SUPPORTED`, `NATIVE_CALL_FAILED`, `WEBVIEW_HANDLE_NOT_SET`, `BUSY`,
and `CAPABILITY_DISABLED`.

Existing mobile/shim names such as `INVALID_PARAMS` and `NOT_AVAILABLE` remain
accepted by `CraftErrorCode` for source compatibility. They are not aliases that
the SDK rewrites on the wire. Applications supporting multiple host versions
should handle the codes those hosts actually return; new native error handling
should use the canonical spellings. A capability disabled by app configuration
is distinct from a user denying permission, and `BUSY` is distinct from a failed
native call.

On iOS, `window.addEventListener('craftTabBarLayout', ...)` reports the native
tab bar's current height as `{ detail: { height } }` in CSS pixels.

## Requirements

- Bun >= 1.0.0 (for development)
- Craft binary (automatically built on install)

## Building from Source

```bash
# Clone the monorepo
git clone https://github.com/home-lang/craft
cd craft

# Install dependencies
bun install

# Build the Zig core
bun run build:core

# Build the TypeScript SDK
bun run build:sdk

# Run examples
cd packages/examples-ts
bun run hello-world
```

## Mobile restart and update tests

Use the Bun-only `craft-native/testing` entrypoint to interrupt an installed app
on an explicitly selected iOS Simulator or Android emulator:

```ts
import { createMobileTestDevice } from 'craft-native/testing'

const device = createMobileTestDevice({
  platform: 'android', device: 'emulator-5582', appId: 'org.example.app',
})
await device.restart()
const { previousBuild, build } = await device.installUpdate('/path/to/update.apk')
```

For iOS use `platform: 'ios'`, the simulator UUID, and an `.app` directory.
`restart()` waits for a new boot; `installUpdate()` requires an existing app and
preserves its data. Android updates must use the original signing key. Supply a
higher build number and assert the returned installed builds, then run your
app's UI checks for persisted progress and offline content. Neither operation
uninstalls an app or clears its data. The controls deliberately refuse physical
devices and implicit device selectors.

For guest-frame evidence on a headless iOS runner, use
`recordIosSimulatorVideo({ device: simulatorUuid, path: '/absolute/path/video.mp4' })`
from the same entrypoint. It resolves after Apple's first-frame acknowledgement.
Call `await recording.stop()` in `finally` before restarting the simulator or
installing an update; repeated stops share the same finalization. Startup and
stop are bounded (30 seconds by default, `timeoutMs` to change it), and an empty
or failed recording rejects. Existing files are preserved unless `overwrite: true`
is set. Capture retains a display-frame sink independently of the Device Hub viewer;
it does not change the application's animations or test assertions.

## Contributing

We love contributions! Please see our [contributing guide](../../CONTRIBUTING.md).

### Offline video storage failures

On iOS and Android native screens, `craft.media.keep(url)` rejects with
`code: 'NO_SPACE'` when the filesystem runs out of room, including wrapped
URLSession and Android write errors. Treat that separately from connectivity:
stop downloading and let the person free space before retrying the same URL.
A failed transfer is never published as a playable cached video.
`craft.media.prune(keepUrls)` removes only unwanted files in the media cache;
it does not clear app storage, workout progress, snapshots or databases.

The Bun-only testing entrypoint verifies those guarantees on native devices:

```ts
import { verifyMobileMediaCache } from 'craft-native/testing'

await verifyMobileMediaCache({ platform: 'ios' }) // creates and deletes its own simulator
await verifyMobileMediaCache({ platform: 'android', device: 'emulator-5554', online: true })
```

Android requires an explicitly selected rootable AOSP emulator and an installed
Gradle CLI. Xcode and an available simulator runtime are required for iOS. The
probe uses a bounded 16 MB disk image on iOS and a 16 MB tmpfs mounted only over
the probe's cache on Android. The Android cache keeps its app UID and SELinux
label; enforcement stays on. It never fills the host disk or an athlete's data partition. It
checks `NO_SPACE`, partial-file cleanup, preserved state outside the cache,
redownloading, interrupted transfers and decoding a local video frame. Set
`storageOnly: true` for only the disk-full cases, or `sourceRoot` to Craft's
absolute `packages` path during upstream development before publication.

## License

MIT © [Chris Breuer](https://github.com/chrisbbreuer)

## Links

- [Documentation](https://github.com/home-lang/craft#readme)
- [Examples](../examples-ts)
- [Benchmarks](../../benchmarks)
- [Issues](https://github.com/home-lang/craft/issues)

### Recording ownership and recovery

Native STX screens and the mobile page use the same native recorder. Before
starting an account-owned GPS or heart-rate session, require
`location.supportsRecordingOwnership()` or `heartRate.supportsRecordingOwnership()`.
The check requires both the current SDK adapter and a capable native host.
Unsupported hosts reject guarded operations with
`RECORDING_OWNERSHIP_UNSUPPORTED`; they never discard the guard and retry.

For account-owned recordings, also require `supportsRecordingIntentIdentity()`
on the chosen service. Allocate distinct GPS and heart-rate IDs with
`await crypto.randomUUID()` from `craft-native/mobile`, capture the account,
workout and clock generation, and persist those IDs **before** calling
`startRecording({ recordingId: id })`. Recheck the captured owner after each
await. The native recorder starts that exact ID and refuses reuse of a current,
completed or acknowledged ID. The SDK checks the response ID; older hosts and
adapters reject with `RECORDING_INTENT_IDENTITY_UNSUPPORTED`. A lost start
response or a full disk during a later checkpoint can then recover the exact
precommitted ID without adopting an unknown recording. The asynchronous Crypto
service uses the platform's secure UUID generator; an unsupported native host
rejects with `CRYPTO_UNSUPPORTED` without falling back to JavaScript entropy.

Pass `{ expectedId: id }` to pause, resume, stop, read and get-state calls. Heart-rate reads also accept
`since`. A supplied empty, whitespace or non-string ID rejects with
`INVALID_ARGUMENT`. Starting while another session is active rejects with
`RECORDING_ALREADY_ACTIVE`, preserving its files.

Completed recordings survive relaunch and subsequent sessions. Guarded reads,
get-state and repeated stops can recover a completed A while B is recording;
pausing or resuming A rejects with `RECORDING_CONFLICT`. The native recorder
archives A before reusing its current track. A failed archive or unreadable
known track refuses replacement rather than truncating the only copy.

After stopping, await durable storage of the result under the captured account
owner, then call `acknowledgeRecording({ expectedId: id })`. ACK is idempotent,
refuses active recordings and never removes another owner's current session.
It writes a persistent tombstone before cleanup, so interrupted deletion cannot
resurrect acknowledged data. Subsequent guarded reads return
`RECORDING_NOT_FOUND`. A failed account checkpoint must leave the native copy
unacknowledged for recovery. Stopping alone does not acknowledge a recording.

For account drafts, use `storage.supportsCompareAndSet()` and
`storage.compareAndSet(key, expectedValue, nextValue)`. This operation replaces
an **existing** matching JSON value under the native storage lock and waits for
its durable write. Object key order does not matter; array order and JSON types
do. A missing or changed key returns `false` without creating or changing it.
A storage failure rejects, preserving the previous value. Hosts without the
explicit `storageCompareAndSet` capability reject with
`STORAGE_COMPARE_AND_SET_UNSUPPORTED`; there is no read-then-set fallback.

For a missing draft, require `storage.supportsSetIfAbsent()` and atomically
register it with `storage.setIfAbsent(key, intent)`. It returns `true` only after
durable creation; any existing value, including JSON `null`, returns `false`.
An unsupported host rejects with `STORAGE_SET_IF_ABSENT_UNSUPPORTED`. Use CAS
for an existing draft; neither registration path uses ordinary `set` after a
read. The browser driver uses Web Locks across tabs for all Storage operations
and account cleanup. A queued operation whose captured account changes rejects
with `STORAGE_SCOPE_CHANGED`, so a previous account cannot write into the new
account's namespace or mistake that namespace for a deleted draft.

When keeping a completed result, read the latest value through asynchronous
`storage.get`, validate its captured account/session/recording identity, merge
its latest feedback, then compare-and-set that exact value. Retry concurrent
feedback changes with at most two fresh reads; never overwrite a newer session
or recreate a deleted draft. Only a successful durable checkpoint permits the
normal ACK. A failed write or exhausted conflict leaves the native archive.
An explicit discard may ACK the captured old ID only after a fresh committed
native read proves that its previously registered intent was deleted or
replaced. A cached missing draft or an unsuccessful initial registration is
not evidence of deletion.

### Browser lifecycle

`createBrowserPlatform()` from `craft-native/browser` supplies
`craft.lifecycle.getState()` and `onStateChange(callback)` (also `onChange`).
States are `active` and `background`. The host emits the native-compatible
`APP_STATE { state }` event on visibility changes and page cache navigation,
coalesces duplicate transitions, and releases listeners in `dispose()`.
This lets browser simulations checkpoint on backgrounding with the same contract
as a native shell. Storage failures must still be handled by the caller.

Await `platform.call('Storage', 'set', [key, value], signal)` before reporting
a saved checkpoint. The browser captures the key and JSON value when the call
starts, before waiting for a Web Lock. Later mutations of your simulation state
or argument array cannot retarget or change that pending save. `setIfAbsent`
captures its value too; `compareAndSet` captures both the expected and next JSON
values (including their `toJSON` representation). Invalid JSON input rejects
without changing the previous checkpoint. Cancellation and account-scope checks
still run before committing the captured value.

The browser keeps its Web Lock until the next task after the operation, so
localStorage implementations that publish task-local snapshots (Firefox) make
the write visible before a competing tab acquires the lock. Storage exceptions
reject the call rather than escaping a synchronous Web Lock callback. All
competing writers must use Craft's locking API; direct localStorage writes or
other code that ignores this lock are not covered by the atomic contract.

`craft.storage.setSync` updates the immediate UI cache and
queues its write when Web Locks are available; it cannot acknowledge durability
or propagate a later quota failure. Background events are an opportunity to
checkpoint, but browsers can terminate a page before queued work finishes, so
also save periodically during play.

Browser audio assigns one owner per sound ID. A newer play or stop invalidates
pending media resolution for that ID; stopping all sounds, changing accounts,
aborting a call or disposing the host also releases active audio. Superseded
play calls reject with `AbortError`.

### Packaging sandboxed macOS apps

Pass `macos.appBundlePath` to package a complete STX app without discarding its
resources. Distribution options also apply to prebuilt bundles: `buildNumber`,
`provisioningProfile`, `privacyManifest`, and the icon are embedded before signing.
Craft signs nested Mach-O code before the main bundle and verifies the result.
Use `helperEntitlements` for a compiled backend's runtime permissions; App Store
helpers inherit the main sandbox by default. `signingKeychain` selects the
keychain for both application and installer identities.

Craft's bundled-backend host reads `backend: { executable: 'stx-backend' }` from
`Contents/Resources/craft.json`. The native app remains the main process, starts
the helper with `--serve --managed`, and consumes its authenticated loopback URL.
The helper's standard input is a lifetime lease: it must stop when that pipe
closes. `craft --capabilities` advertises `bundleBackend` on macOS.
