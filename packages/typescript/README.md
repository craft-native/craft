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

## Contributing

We love contributions! Please see our [contributing guide](../../CONTRIBUTING.md).

## License

MIT © [Chris Breuer](https://github.com/chrisbbreuer)

## Links

- [Documentation](https://github.com/home-lang/craft#readme)
- [Examples](../examples-ts)
- [Benchmarks](../../benchmarks)
- [Issues](https://github.com/home-lang/craft/issues)
