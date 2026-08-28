# Window Management

Craft provides comprehensive window management capabilities, giving you full control over window appearance, behavior, and lifecycle.

## Overview

Window management in Craft includes:

- **Window Creation**: Create and configure windows
- **Position Control**: Precise window positioning
- **State Management**: Minimize, maximize, fullscreen
- **Multi-Window**: Multiple window support
- **Multi-Monitor**: Multi-monitor awareness

## Creating Windows

### Basic Window

```typescript
import { show } from 'craft-native'

await show(html, {
  title: 'My App',
  width: 800,
  height: 600,
})
```

### Advanced Window Creation

```typescript
import { createWindow } from 'craft-native'

const window = await createWindow(html, {
  // Identification
  title: 'My Application',

  // Size
  width: 1200,
  height: 800,
  minWidth: 400,
  minHeight: 300,
  maxWidth: 1920,
  maxHeight: 1080,

  // Position
  x: 100,
  y: 100,
  center: true, // Overrides x, y if true

  // Appearance
  frameless: false,
  transparent: false,
  resizable: true,

  // Behavior
  alwaysOnTop: false,
  visible: true,
  focused: true,
})
```

## Window Positioning

### Center on Screen

```typescript
const window = await createWindow(html, {
  center: true,
})
```

### Specific Position

```typescript
const window = await createWindow(html, {
  x: 100,
  y: 200,
})
```

### Move Window

```typescript
// Move to specific position
window.setPosition(100, 200)

// Get current position
const { x, y } = window.getPosition()
```

### Center Programmatically

```typescript
window.center()
```

## Window Size

### Initial Size

```typescript
const window = await createWindow(html, {
  width: 1200,
  height: 800,
})
```

### Size Constraints

```typescript
const window = await createWindow(html, {
  width: 800,
  height: 600,
  minWidth: 400,
  minHeight: 300,
  maxWidth: 1920,
  maxHeight: 1080,
})
```

### Resize Programmatically

```typescript
// Set size
window.setSize(1024, 768)

// Get current size
const { width, height } = window.getSize()

// Get inner size (content area)
const { width: innerWidth, height: innerHeight } = window.getInnerSize()
```

### Resizable Control

```typescript
// Make non-resizable
window.setResizable(false)

// Check if resizable
const isResizable = window.isResizable()
```

## Window State

### Minimize

```typescript
window.minimize()

// Check state
const isMinimized = window.isMinimized()
```

### Maximize

```typescript
window.maximize()

// Toggle maximize
window.toggleMaximize()

// Check state
const isMaximized = window.isMaximized()
```

### Fullscreen

```typescript
// Enter fullscreen
window.setFullscreen(true)

// Exit fullscreen
window.setFullscreen(false)

// Toggle fullscreen
window.toggleFullscreen()

// Check state
const isFullscreen = window.isFullscreen()
```

### Show/Hide

```typescript
// Hide window
window.hide()

// Show window
window.show()

// Check visibility
const isVisible = window.isVisible()
```

### Focus

```typescript
// Focus window
window.focus()

// Check focus
const isFocused = window.isFocused()
```

## Window Controls (Traffic Lights)

The close, minimise and zoom buttons are the platform's. Craft never asks the
web layer to draw them, and the web layer should never try: on macOS AppKit
draws real ones on every window Craft creates except a `frameless` one, so a
page that renders its own puts six circles in the corner — three live buttons
and three coloured `<div>`s that only look like buttons, in the wrong shade,
missing the hover glyphs, and dead to keyboard and accessibility.

Because a page cannot ask AppKit where those buttons are, Craft tells it at
document start, on every window:

```javascript
window.craft.windowControls
// { style: 'overlay', native: true, x: 10, y: 8, width: 62, height: 28 }
```

| `style` | What the platform drew | What the page must do |
| --- | --- | --- |
| `titlebar` | Buttons in a titlebar above the web content | Nothing |
| `overlay` | Buttons floating over the top-left of the content (`titlebarHidden`, native sidebar, web sidebar material) | Keep that corner clear |
| `none` | Nothing — `frameless: true` | Draw its own chrome, if it wants any |

The same facts land on the document, so CSS can use them without JavaScript:

```css
/* <html data-craft-window-controls="overlay"> */
.sidebar-header {
  /* 62px under an overlay, 0 otherwise, and the fallback covers a browser tab */
  padding-left: var(--craft-window-controls-width, 62px);
}
```

`--craft-window-controls-height`, `--craft-window-controls-inset-x` and
`--craft-window-controls-inset-y` are published alongside it.

A UI shared between a Craft window and a browser — a component library, a page
that is also a marketing demo — often wants mock traffic lights in the browser
and must not draw them here. `--craft-window-controls-replicas` is the `display`
value a replica should take: `none` wherever the platform drew real buttons, and
unset in a frameless window, where the page really does own its chrome. Written
as a fallback, it needs no JavaScript and cannot flash, because the host sets it
before the document is parsed:

```css
.traffic-lights {
  display: var(--craft-window-controls-replicas, flex);
}
```

A frameless window is the one case where a page owns its window chrome, and it
gets `style: 'none'` to say so — see below.

## Window Styles

### Frameless Window

Remove the native window frame:

```typescript
const window = await createWindow(html, {
  frameless: true,
})
```

Implement a custom title bar in HTML:

```html
<div class="titlebar" style="-webkit-app-region: drag;">
  <span>My App</span>
  <button onclick="window.craft.close()" style="-webkit-app-region: no-drag;">
    Close
  </button>
</div>
```

### Transparent Window

```typescript
const window = await createWindow(html, {
  frameless: true,
  transparent: true,
})
```

```html
<body style="background: transparent;">
  <div style="
    background: rgba(255, 255, 255, 0.95);
    border-radius: 12px;
    padding: 20px;
    box-shadow: 0 10px 40px rgba(0,0,0,0.2);
  ">
    Content here
  </div>
</body>
```

### Always on Top

```typescript
// Set always on top
window.setAlwaysOnTop(true)

// Toggle
window.setAlwaysOnTop(!window.isAlwaysOnTop())
```

## Multi-Window

### Creating Multiple Windows

```typescript
import { createApp, createWindow } from 'craft-native'

const app = await createApp()

// Main window
const mainWindow = await createWindow(mainHtml, {
  title: 'Main Window',
  width: 1200,
  height: 800,
})

// Child window
const childWindow = await createWindow(childHtml, {
  title: 'Child Window',
  width: 400,
  height: 300,
  parent: mainWindow,
})
```

### Modal Windows

```typescript
const modalWindow = await createWindow(modalHtml, {
  title: 'Dialog',
  width: 400,
  height: 200,
  parent: mainWindow,
  modal: true, // Blocks parent interaction
})
```

### Window List

```typescript
const windows = app.getWindows()
windows.forEach((win) => {
  console.log(win.getTitle())
})
```

## Multi-Monitor

### Get Monitors

```typescript
import { getMonitors, getPrimaryMonitor } from 'craft-native'

// All monitors
const monitors = await getMonitors()
monitors.forEach((monitor) => {
  console.log(`${monitor.name}: ${monitor.width}x${monitor.height}`)
})

// Primary monitor
const primary = await getPrimaryMonitor()
```

### Position on Specific Monitor

```typescript
const monitors = await getMonitors()
const secondMonitor = monitors[1]

const window = await createWindow(html, {
  x: secondMonitor.x + 100,
  y: secondMonitor.y + 100,
  width: 800,
  height: 600,
})
```

### Get Monitor for Window

```typescript
const monitor = window.getCurrentMonitor()
console.log(`Window is on: ${monitor.name}`)
```

## Window Events

### State Events

```typescript
// Window events
window.on('close', () => {
  console.log('Window closing')
})

window.on('closed', () => {
  console.log('Window closed')
})

window.on('focus', () => {
  console.log('Window focused')
})

window.on('blur', () => {
  console.log('Window lost focus')
})

window.on('resize', ({ width, height }) => {
  console.log(`Resized to ${width}x${height}`)
})

window.on('move', ({ x, y }) => {
  console.log(`Moved to ${x}, ${y}`)
})

window.on('minimize', () => {
  console.log('Window minimized')
})

window.on('maximize', () => {
  console.log('Window maximized')
})

window.on('fullscreen', (isFullscreen) => {
  console.log(`Fullscreen: ${isFullscreen}`)
})
```

### Prevent Close

```typescript
window.on('close', (event) => {
  const shouldClose = confirm('Are you sure?')
  if (!shouldClose) {
    event.preventDefault()
  }
})
```

## Window Title

### Dynamic Title

```typescript
// Set title
window.setTitle('My App - Document.txt')

// Get title
const title = window.getTitle()
```

### Title from Web Content

```html
<head>
  <title>Dynamic Title</title>
</head>
<script>
  document.title = 'Updated Title'
  // Automatically syncs to window title
</script>
```

## Window Icon

### Set Icon

```typescript
const window = await createWindow(html, {
  icon: './assets/icon.png',
})

// Or change later
window.setIcon('./assets/new-icon.png')
```

## Best Practices

### Window State Persistence

```typescript
import { readFile, writeFile } from 'node:fs/promises'

// Save window state
async function saveWindowState(window) {
  const state = {
    x: window.getPosition().x,
    y: window.getPosition().y,
    width: window.getSize().width,
    height: window.getSize().height,
    maximized: window.isMaximized(),
  }
  await writeFile('window-state.json', JSON.stringify(state))
}

// Restore window state
async function restoreWindowState() {
  try {
    const data = await readFile('window-state.json', 'utf-8')
    return JSON.parse(data)
  }
  catch {
    return null
  }
}

// Usage
const savedState = await restoreWindowState()
const window = await createWindow(html, {
  ...defaultOptions,
  ...savedState,
})

window.on('close', () => saveWindowState(window))
```

### Graceful Shutdown

```typescript
app.on('window-all-closed', () => {
  // Save state, cleanup, etc.
  app.quit()
})

// Prevent accidental close
window.on('close', async (event) => {
  if (hasUnsavedChanges()) {
    event.preventDefault()
    const save = await showSaveDialog()
    if (save) {
      await saveDocument()
      window.close()
    }
  }
})
```

## Next Steps

- [Webview Integration](/features/webview-integration) - Configure webview
- [IPC Communication](/features/ipc-communication) - Window-web communication
- [Native APIs](/features/native-apis) - System integration
