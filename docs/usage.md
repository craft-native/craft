# Usage

This guide covers the basics of building applications with Craft.

## TypeScript SDK

### Basic Application

```typescript
import { show } from 'craft-native'

const html = `
<!DOCTYPE html>
<html>
<head>
  <style>
    body {
      font-family: system-ui, sans-serif;
      padding: 20px;
    }
  </style>
</head>
<body>
  <h1>Hello, Craft!</h1>
  <p>This is my first Craft application.</p>
</body>
</html>
`

await show(html, {
  title: 'My First App',
  width: 800,
  height: 600,
})
```

### Loading from File

```typescript
import { show } from 'craft-native'

// Load HTML from a file
await show({ file: './index.html' }, {
  title: 'My App',
  width: 1200,
  height: 800,
})
```

### Loading from URL

```typescript
import { show } from 'craft-native'

// Load from URL
await show({ url: 'http://localhost:3000' }, {
  title: 'Dev Server',
  width: 1200,
  height: 800,
})
```

## CLI Usage

### Basic Commands

```bash
# Launch with URL
craft http://localhost:3000

# Launch with HTML file
craft ./index.html

# Launch with options
craft http://localhost:3000 --title "My App" --width 1200 --height 800
```

### CLI Options

```bash
craft [url/file] [options]

Options:
  --title <title>       Window title
  --width <pixels>      Window width (default: 800)
  --height <pixels>     Window height (default: 600)
  --dark               Enable dark mode
  --frameless          Remove window frame
  --transparent        Make window transparent
  --always-on-top      Keep window above others
  --hot-reload         Enable hot reload for development
  --help               Show help
  --version            Show version
```

### Development Mode

```bash
# Enable hot reload and DevTools
craft http://localhost:3000 --hot-reload --dark
```

## Application Configuration

### Configuration File

Create a `craft.config.ts` or `craft.toml`:

```typescript
// craft.config.ts
export default {
  window: {
    title: 'My App',
    width: 1200,
    height: 800,
    minWidth: 400,
    minHeight: 300,
  },

  webview: {
    devTools: true,
    darkMode: true,
  },

  build: {
    outDir: './dist',
    target: ['macos', 'linux', 'windows'],
  },
}
```

### TOML Configuration

```toml
# craft.toml
[window]
title = "My App"
width = 1200
height = 800

[webview]
devTools = true
darkMode = true

[build]
outDir = "./dist"
target = ["macos", "linux", "windows"]
```

## Window Options

### Full Options

```typescript
await show(html, {
  // Window basics
  title: 'My App',
  width: 1200,
  height: 800,
  minWidth: 400,
  minHeight: 300,
  maxWidth: 1920,
  maxHeight: 1080,

  // Position
  x: 100,
  y: 100,
  center: true, // Center on screen

  // Appearance
  frameless: false,
  transparent: false,
  resizable: true,

  // Behavior
  alwaysOnTop: false,
  fullscreen: false,
  maximized: false,
  minimized: false,
  visible: true,

  // Development
  hotReload: true,
  devTools: true,
})
```

### Dark Mode

```typescript
await show(html, {
  title: 'Dark Mode App',
  darkMode: true,
})
```

### Frameless Window

```typescript
await show(html, {
  title: 'Frameless',
  frameless: true,
  // Add custom title bar in HTML
})
```

### Transparent Window

```typescript
const html = `
<body style="background: transparent;">
  <div style="
    background: rgba(255,255,255,0.9);
    border-radius: 10px;
    padding: 20px;
  ">
    Floating content
  </div>
</body>
`

await show(html, {
  frameless: true,
  transparent: true,
})
```

## Communication (IPC)

### Sending Messages to Native

```html
<!-- In your HTML -->
<script>
  // Send message to native
  window.craft.send('my-event', { data: 'hello' })
</script>
```

```typescript
// In your TypeScript
import { createApp } from 'craft-native'

const app = await createApp(html, options)

app.on('my-event', (data) => {
  console.log('Received:', data)
})
```

### Sending Messages to Web

```typescript
// Send from native to web
app.emit('native-event', { message: 'Hello from native!' })
```

```html
<!-- In your HTML -->
<script>
  window.craft.on('native-event', (data) => {
    console.log('Received:', data.message)
  })
</script>
```

### Invoke/Return Pattern

```typescript
// Register a handler
app.handle('get-user', async (userId) => {
  return { id: userId, name: 'John Doe' }
})
```

```html
<script>
  // Call from web and await response
  const user = await window.craft.invoke('get-user', 123)
  console.log(user.name) // John Doe
</script>
```

## Working with Assets

### Static Assets

```typescript
import { show, resolveAsset } from 'craft-native'

const iconPath = resolveAsset('./assets/icon.png')

await show(html, {
  title: 'My App',
  icon: iconPath,
})
```

### Bundling Assets

```typescript
// craft.config.ts
export default {
  assets: {
    include: ['./assets/**/*', './public/**/*'],
    exclude: ['**/*.map'],
  },
}
```

## Multi-Window Applications

### Creating Multiple Windows

```typescript
import { createWindow, windowManager } from 'craft-native'

const mainWindow = windowManager.current

// Settings window
const settingsWindow = await createWindow({
  id: 'settings',
  html: settingsHtml,
  title: 'Settings',
  width: 600,
  height: 400,
})

await settingsWindow.focus()
```

Calling `createWindow` again with the same `id` brings the retained native
window forward and returns the same typed handle. Runtime creation currently
uses the macOS host; modal and parent-window relationships are not supported.

### Window Lifecycle Events

```typescript
mainWindow.on('focus', () => {
  console.log('Main window focused')
})

settingsWindow.on('resize', ({ width, height }) => {
  console.log(`Settings resized to ${width}×${height}`)
})
```

The creator page receives events for `settingsWindow` on that named handle;
the Settings page receives its local events on `windowManager.current`.

## Hot Reload

### Development Setup

```typescript
await show({ url: 'http://localhost:3000' }, {
  hotReload: true,
  devTools: true,
})
```

### File Watching

```typescript
// craft.config.ts
export default {
  dev: {
    hotReload: true,
    watch: ['./src/**/*'],
    ignore: ['./node_modules/**'],
  },
}
```

## Debugging

### DevTools

Right-click in the window and select "Inspect Element" to open DevTools.

Or enable programmatically:

```typescript
await show(html, {
  devTools: true, // Auto-open DevTools
})
```

### Console Output

```typescript
import { createApp } from 'craft-native'

const app = await createApp(html, {
  verbose: true, // Log debug information
})

// Console output from web content appears in your terminal
```

## Examples

### Simple Notes App

```typescript
import { show } from 'craft-native'

const html = `
<!DOCTYPE html>
<html>
<head>
  <style>
    body { font-family: system-ui; padding: 20px; }
    textarea { width: 100%; height: 300px; }
    button { margin-top: 10px; padding: 10px 20px; }
  </style>
</head>
<body>
  <h1>Notes</h1>
  <textarea id="notes" placeholder="Write your notes..."></textarea>
  <button onclick="save()">Save</button>
  <script>
    function save() {
      window.craft.send('save', document.getElementById('notes').value)
    }
  </script>
</body>
</html>
`

const app = await show(html, { title: 'Notes' })

app.on('save', async (content) => {
  await Bun.write('./notes.txt', content)
  console.log('Notes saved!')
})
```

## Next Steps

- [Configuration](/config) - Full configuration reference
- [Window Management](/features/window-management) - Advanced window control
- [IPC Communication](/features/ipc-communication) - Native-web communication
- [Native APIs](/features/native-apis) - System integration
