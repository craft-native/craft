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

### Runtime Window Creation

The `craft-native` SDK returns a typed `Window` handle. Runtime-created
windows are available on macOS, Linux, and Windows and must provide either
`html` or `url` content. The common create, close, title, geometry, and event
routes are cross-platform; some advanced window controls remain macOS-only.
Bounds, centering, resizing constraints, resizability and fullscreen controls
also work on the typed handle on all three desktop platforms. On Linux,
position and fullscreen requests are advisory to the window manager (and
global positioning can be unavailable under Wayland).

```typescript
import { createWindow } from 'craft-native'

const settings = await createWindow({
  // A stable ID makes repeated opens idempotent.
  id: 'settings',
  url: 'https://app.example/settings',
  title: 'Settings',

  // Size
  width: 720,
  height: 560,
  minWidth: 480,
  minHeight: 360,

  // Position
  x: 100,
  y: 100,

  // Native behavior
  resizable: true,
  alwaysOnTop: false,
  titlebarHidden: true,
  persistentStorage: true,
})

await settings.setTitle('Settings — Account')
await settings.setBounds({ x: 120, y: 80, width: 800 })
await settings.setMinimumSize(480, 360)
await settings.setMaximumSize(1600, 1200)
await settings.setResizable(false)
const canResize = await settings.isResizable()
await settings.center()
await settings.setFullscreen(true)
await settings.toggleFullscreen()
```

The bounds update preserves omitted coordinates and dimensions. Native window
managers can adjust requested geometry for decorations or screen constraints;
read `getBounds()` after a resize event if you need the actual result.
Creation-time `minWidth`/`minHeight` and `maxWidth`/`maxHeight` may constrain
either axis independently; the native window system's own minimum still applies.

The older `createWindow(html, options)` overload remains available when the
content is already in a string.

### Parent and modal windows

Pass `parent` when a child should stay attached to another native window.
`main` means the calling page's own window; a named parent must be a live
handle owned by that page. A modal child requires `parent` and blocks only
that parent while visible. Unrelated windows remain usable.

```typescript
const settings = await createWindow({
  id: 'settings',
  html: '<h1>Settings</h1>',
})

const accountDialog = await createWindow({
  id: 'account-dialog',
  parent: settings.id,
  modal: true,
  html: '<h1>Account</h1>',
})

await accountDialog.close()
```

Closing a parent closes its attached descendants. A named window cannot be
reparented by opening the same ID again with different `parent` or `modal`
options. On macOS an ordinary close retains the page for reopening, while
Linux and Windows release it; call `destroy()` for permanent teardown on
macOS. Application-wide events such as deep links and tray actions currently
go to the primary page, not every child page.

## Window Positioning

### Center on Screen

```typescript
const window = await createWindow(html)
await window.center()
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
await window.setPosition(100, 200)

// Get current position
const { x, y } = await window.getPosition()
```

### Center Programmatically

```typescript
await window.center()
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
await window.setSize(1024, 768)

// Get current size
const { width, height } = await window.getSize()
```

### Resizable Control

```typescript
// Make non-resizable
await window.setResizable(false)

// Check if resizable
const isResizable = await window.isResizable()
```

## Window State

### Minimize

```typescript
await window.minimize()

// Check state
const { isMinimized } = await window.getState()
```

### Maximize

```typescript
await window.maximize()

// Restore to normal size
await window.unmaximize()

// Check state
const { isMaximized } = await window.getState()
```

### Fullscreen

```typescript
// Enter fullscreen
await window.setFullscreen(true)

// Exit fullscreen
await window.setFullscreen(false)

// Toggle fullscreen
await window.toggleFullscreen()

// Check state
const { isFullscreen } = await window.getState()
```

### Show/Hide

```typescript
// Hide window
await window.hide()

// Show window
await window.show()

// Check visibility
const { isVisible } = await window.getState()
```

### Focus

```typescript
// Focus window
await window.focus()

// Check focus
const { isFocused } = await window.getState()
```

## Window Controls (Traffic Lights)

The close, minimise and zoom buttons are the platform's. Craft never asks the
web layer to draw them, and the web layer should never try: on macOS AppKit
draws real ones on every window Craft creates except a `frameless` one, so a
page that renders its own puts six circles in the corner — three live buttons
and three coloured `<div>`s that only look like buttons, in the wrong shade,
missing the hover glyphs, and dead to keyboard and accessibility.

Because a page cannot ask AppKit where those buttons are, Craft measures them on
the live window and tells it, at document start and again whenever the answer
changes:

```javascript
window.craft.windowControls
// {
//   style: 'overlay', native: true, visible: true,
//   x: 9, y: 9, width: 60, height: 14,
//   reserveWidth: 69, reserveHeight: 23, insetX: 9, insetY: 9,
//   replicas: 'none'
// }
```

| `style` | What the platform drew | What the page must do |
| --- | --- | --- |
| `titlebar` | Buttons in a titlebar above the web content | Nothing |
| `overlay` | Buttons over the top-left of the content (`titlebarHidden`, and any window whose web content runs full height) | Keep that corner clear |
| `custom` | Nothing — `frameless: true` | Draw its own chrome, if it wants any |
| `none` | No window chrome in this environment — iOS, Android | Nothing |

Nothing in that object is a constant. The buttons move between window styles,
they sit over a native sidebar rather than over the web content in a sidebar
window, they slide away in fullscreen, and Apple has resized them across
releases — 60×14 points at (9, 9) on macOS 27, and not the same on 14. Craft
re-measures and re-publishes on every resize, fullscreen transition and
navigation, so a layout that reads these values stays right; one that hardcodes
what it saw once does not.

The same facts land on the document, so CSS can use them without JavaScript:

```css
/* <html data-craft-window-controls="overlay"> */
.sidebar-header {
  /* the far edge of the real buttons, or 0 where they are not over the page */
  padding-left: var(--craft-window-controls-width, 0px);
}
```

`--craft-window-controls-height`, `--craft-window-controls-inset-x` and
`--craft-window-controls-inset-y` are published alongside it. All four are the
room to leave *inside the page*, so all four are zero whenever the buttons are
not over it — a window with its own titlebar, a window whose content starts
after a native sidebar, a fullscreen window whose titlebar has slid away.

The reserve spans the host's own chrome as well as the buttons: on a
web-material window Craft draws a sidebar toggle and two history arrows beside
them, and a page that cleared only the buttons put its content under real
`NSButton`s. A page that is *under* the buttons but clear of that row — a
narrow icon rail the row overhangs — wants the buttons alone, and gets them:

```css
.rail {
  /* the buttons' own bottom edge, not the far edge of everything up there */
  padding-top: calc(
    var(--craft-window-buttons-y, 0px) + var(--craft-window-buttons-height, 0px) + 8px
  );
}
```

`--craft-window-buttons-x` and `--craft-window-buttons-width` complete the
rectangle. Same coordinates and the same zero-when-not-over-the-page rule as
the reserve.

A UI shared between a Craft window and a browser — a component library, a page
that is also a marketing demo — often wants mock traffic lights in the browser
and must not draw them here. `--craft-window-controls-replicas` is the `display`
value a replica should take: `none` wherever the platform drew real buttons and
wherever there is no window to control at all, and *unset* in a frameless
window, where the page really does own its chrome. Written as a fallback, it
needs no JavaScript and cannot flash, because the host sets it before the
document is parsed:

```css
.traffic-lights {
  display: var(--craft-window-controls-replicas, flex);
}
```

For layout CSS cannot express — a canvas, a measured scroller — listen for the
change instead. It fires only when something really moved, never for the
initial state, which the seed already applied:

```javascript
window.addEventListener('craft:windowcontrols', (event) => {
  layout(event.detail.reserveWidth)
})
```

A frameless window is the one case where a page owns its window chrome, and it
gets `style: 'custom'` to say so — see below.

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
  <button onclick="window.craft.window.close()" style="-webkit-app-region: no-drag;">
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

### Vibrant Window (macOS)

A web UI can sit on a real `NSVisualEffectView` instead of on a flat fill, so
the window has the same translucent surface as Finder or System Settings — and
so the traffic lights, which AppKit draws over the page in a `titlebarHidden`
window, rest on something rather than floating on a white rectangle.

Two shapes, and they are two different Mac windows rather than two settings:

```typescript
// Finder: vibrancy under the leading strip, an opaque pane beside it.
await createWindow(url, {
  titlebarHidden: true,
  webSidebarMaterial: true,
  webSidebarWidth: 74,
  webSidebarMaterialOpacity: 0.25,
})

// System Settings: one material behind everything, nothing opaque anywhere.
await createWindow(url, {
  titlebarHidden: true,
  webWindowMaterial: true,
})
```

Craft says which one it drew, at document start, so CSS can lay itself out over
it on the first frame:

```css
/* <html data-craft-web-material="sidebar|window">, absent in a browser */
:root[data-craft-web-material] body { background: transparent; }

/* The window span has no opaque surface anywhere, so the page provides the
   wash — and the page is the only thing that knows whether it is light or
   dark, which is why this is not a native tint. */
:root[data-craft-web-material='window'] body {
  background: color-mix(in srgb, var(--app-bg) 62%, transparent);
}
```

`webSidebarMaterialOpacity` applies to the sidebar span only, for the same
reason: it tints a strip the page paints nothing over, and it is drawn light,
like the strip.

A window-span material is *not* pinned to light. It resolves against the
window's appearance, so `darkMode` and the Mac's own setting reach it — and so
does the page's `prefers-color-scheme`, which WebKit reads off the same place.
An app with its own light/dark control has to say which it picked:

```typescript
await window.setAppearance('dark')   // 'light' | 'dark' | 'system'
```

`'system'` is a real value rather than a synonym for light: it hands the window
back to the OS, so it follows a sunset switch again.

### Always on Top

```typescript
// Set always on top
await window.setAlwaysOnTop(true)

// Toggle
await window.setAlwaysOnTop(!(await window.isAlwaysOnTop()))
```

## Multi-Window

### Creating Multiple Windows

```typescript
import { createWindow, windowManager } from 'craft-native'

const mainWindow = windowManager.current
const inspector = await createWindow({
  id: 'inspector',
  html: inspectorHtml,
  title: 'Inspector',
  width: 520,
  height: 640,
})

await inspector.setPosition(900, 120)
await inspector.focus()

const stopWatching = inspector.on('resize', ({ width, height }) => {
  console.log(`Inspector is now ${width}×${height}`)
})
```

`executeJavaScript()` runs in the addressed window and returns its JSON value
to the page holding the handle, including when that page is a different
window. `undefined` resolves as `null`; a thrown JavaScript exception rejects
with `NATIVE_CALL_FAILED`. If the target navigates or closes before evaluation
finishes, the still-live caller receives `CANCELLED`. Calls made by a page
that itself navigates or closes are discarded with that page, so their old
replies cannot resolve a new page's promises.

```typescript
const title = await inspector.executeJavaScript<string>('document.title')
```

Every operation on `inspector` carries that stable ID to the host, so it still
targets the Inspector when called from the main page. Calling `createWindow`
again with `id: 'inspector'` brings the existing native window forward and
returns the existing SDK handle:

```typescript
const sameInspector = await createWindow({
  id: 'inspector',
  html: inspectorHtml,
})

console.log(sameInspector === inspector) // true
```

Inside any window's own page, `windowManager.current` is named `main`; that is
a local alias for the page's native window, not the process's first window.
Use the manager to inspect handles retained by the current page or resolve its
focused handle:

```typescript
for (const handle of windowManager.all) {
  console.log(handle.id)
}

const focused = await windowManager.getFocused()
console.log(focused?.id)
```

Native lifecycle events are scoped to their owners. The Inspector page sees
its own events through `windowManager.current` (`main` locally), and the page
that created it sees the same transitions through the `inspector` handle.
Other open windows do not receive them. Call the unsubscribe function returned
by `on`, such as `stopWatching()` above, when the listener is no longer needed.

On macOS, closing a window keeps its native page alive so reopening can
restore its DOM and JavaScript state. On Linux and Windows, closing releases
the native window and webview; reopening the same ID creates a fresh page
behind the same stable SDK handle. `destroy()` releases a named window's native
resources and detaches its SDK DOM listeners. A later `createWindow()` with the
same ID reuses the typed handle and reattaches those listeners. The unnamed
primary window cannot be force-destroyed through this API. CI exercises Linux
create/close/reopen under Xvfb and the equivalent Windows WebView2 path,
including concurrent child creation, scoped child events while unrelated pages
are open, and stale-handle cleanup. Installed PKG, DEB and MSI smokes also
create and close a child through the packaged runtime.
Parent-only modal semantics are part of the runtime-created-window contract.
See [Multi-window ownership](../architecture/multi-window-ownership.md) for the
implemented routing guarantees and remaining cross-platform work. App-wide
event delivery remains primary-page-only pending the separate policy and test
work in [#331](https://github.com/craft-native/craft/issues/331).

## Multi-Monitor

The typed `Window` handle can request screen coordinates with `setPosition()`
and read its actual bounds with `getBounds()`. The SDK does not currently expose
the `getMonitors()`, `getPrimaryMonitor()`, or `getCurrentMonitor()` methods that
older examples used. Avoid assuming a requested position is honored: a Linux
window manager may adjust it, and global positioning can be unavailable under
Wayland.

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

window.on('enter-fullscreen', () => {
  console.log('Entered fullscreen')
})

window.on('leave-fullscreen', () => {
  console.log('Left fullscreen')
})
```

`close` is a notification, not a cancellable request. The native close path is
already under way when the listener runs. For an explicit Close button, ask for
confirmation before calling `window.close()`. Do not call `preventDefault()`
on the `close` event.

## Window Title

### Dynamic Title

```typescript
// Set title
await window.setTitle('My App - Document.txt')

// Get title
const title = await window.getTitle()
```

### Title from Web Content

```html
<head>
  <title>Dynamic Title</title>
</head>
```

An HTML `<title>` sets the document title. To change native window chrome after
creation, call `await window.setTitle('Updated Title')` on the typed handle.

## Window Icon

The typed runtime-created `Window` handle does not have a `setIcon()` method,
and `WindowCreateOptions` does not accept `icon`. Set the application icon
through the packaging configuration instead.

## Best Practices

### Window State Persistence

```typescript
const state = await window.getState()
localStorage.setItem('window-bounds', JSON.stringify(state.bounds))
```

Enable `persistentStorage` for a window that needs its `localStorage` to
survive application restarts. Restore saved bounds by passing their `x`, `y`,
`width`, and `height` fields into `createWindow()` on the next launch. Save
from an explicit action or a debounced move/resize handler; an asynchronous
write started by a `close` listener may outlive the page on Linux or Windows.

## Next Steps

- [Webview Integration](/features/webview-integration) - Configure webview
- [IPC Communication](/features/ipc-communication) - Window-web communication
- [Native APIs](/features/native-apis) - System integration
