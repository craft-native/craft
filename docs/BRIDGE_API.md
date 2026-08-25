# Craft JavaScript Bridge API

The Craft JavaScript Bridge provides a seamless interface for your web application to control native features like the system tray, window management, and application behavior.

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
- [System Tray API](#system-tray-api)
- [Application Menu (macOS)](#application-menu-macos)
- [Global Shortcuts (macOS)](#global-shortcuts-macos)
- [Window API](#window-api)
- [App API](#app-api)
- [TypeScript Support](#typescript-support)
- [Examples](#examples)

## Overview

The bridge is automatically injected into your WebView at document start. No additional setup is required - simply use `window.craft` in your JavaScript code.

```javascript
// Wait for bridge to be ready
window.addEventListener('craft:ready', () => {
  console.log('Craft bridge is ready!');
  // Your code here
});

// Or check if already available
if (window.craft) {
  // Bridge is ready
}
```

## Getting Started

### Basic Usage

```javascript
// Update system tray
await window.craft.tray.setTitle('🍅 25:00');

// Toggle window visibility
await window.craft.window.toggle();

// Hide dock icon (menubar-only mode)
await window.craft.app.hideDockIcon();
```

### CLI Integration

Enable system tray from the command line:

```bash
craft http://localhost:3000 --system-tray --hide-dock-icon
```

### TypeScript Integration

```typescript
import { createApp } from 'craft-native'

const app = createApp({
  url: 'http://localhost:3000',
  window: {
    systemTray: true,
    hideDockIcon: true,
    width: 400,
    height: 600
  }
})

await app.show()
```

## System Tray API

Control the system tray icon from your web application.

### `window.craft.tray.setTitle(title: string): Promise<void>`

Update the system tray title/text.

```javascript
// Show a Pomodoro timer
await window.craft.tray.setTitle('🍅 25:00');

// Show app status
await window.craft.tray.setTitle('✓ Ready');
```

**Note:** On macOS, titles are limited to ~20 characters to avoid menubar overflow.

### `window.craft.tray.setTooltip(tooltip: string): Promise<void>`

Set tooltip text that appears on hover.

```javascript
await window.craft.tray.setTooltip('Pomodoro Timer - Click to toggle');
```

### `window.craft.tray.onClick(callback: Function): Function`

Register a click handler for the tray icon.

```javascript
const unregister = window.craft.tray.onClick((event) => {
  console.log('Tray clicked!', event);
  // event.button: 'left' | 'right' | 'middle'
  // event.timestamp: number
  // event.modifiers: { command?, shift?, option?, control? }
});

// Later: unregister the handler
unregister();
```

### `window.craft.tray.onClickToggleWindow(): Function`

Convenience method: toggle window visibility on tray click.

```javascript
const unregister = window.craft.tray.onClickToggleWindow();
```

### `window.craft.tray.setMenu(items: MenuItem[]): Promise<void>`

Set a context menu for the tray icon.

```javascript
await window.craft.tray.setMenu([
  { label: 'Show Window', action: 'show' },
  { type: 'separator' },
  { label: 'Start Timer', action: 'start-timer' },
  { label: 'Pause Timer', action: 'pause-timer' },
  { type: 'separator' },
  { label: 'Quit', action: 'quit' }
]);

// Listen for custom menu actions
window.addEventListener('craft:tray:menu', (event) => {
  if (event.detail.action === 'start-timer') {
    startTimer();
  }
});
```

**MenuItem Interface:**

```typescript
interface MenuItem {
  id?: string
  label?: string
  type?: 'normal' | 'separator' | 'checkbox' | 'radio'
  checked?: boolean
  enabled?: boolean
  action?: 'show' | 'hide' | 'toggle' | 'quit' | string
  shortcut?: string
  submenu?: MenuItem[]
}
```

## Application Menu (macOS)

The menu bar across the top of the screen, distinct from the tray menu above.
macOS only — on Linux and Windows these calls are accepted and ignored.

Craft installs a default bar at startup, so an app that never touches this API
still gets the standard shortcuts. Calling `set()` replaces that bar
**entirely** — if your app has text input anywhere, declare an Edit menu
yourself, or Cmd+X/C/V stop reaching it.

### `window.craft.menu.set(options: { menus: MenuDefinition[] }): Promise<void>`

Replace the whole bar.

```javascript
await window.craft.menu.set({
  menus: [
    {
      label: 'File',
      items: [
        { id: 'new', label: 'New', shortcut: 'cmd+n' },
        { id: 'open', label: 'Open...', shortcut: 'cmd+o' },
        { separator: true },
        { role: 'close', label: 'Close Window', shortcut: 'cmd+w' },
      ],
    },
    {
      label: 'Edit',
      items: [
        { role: 'undo', label: 'Undo', shortcut: 'cmd+z' },
        { role: 'redo', label: 'Redo', shortcut: 'cmd+shift+z' },
        { separator: true },
        { role: 'cut', label: 'Cut', shortcut: 'cmd+x' },
        { role: 'copy', label: 'Copy', shortcut: 'cmd+c' },
        { role: 'paste', label: 'Paste', shortcut: 'cmd+v' },
        { role: 'selectAll', label: 'Select All', shortcut: 'cmd+a' },
      ],
    },
  ],
});
```

The returned promise resolves once the message has been posted, not once the
menu exists — native acknowledges nothing on success. A failure arrives on the
console rather than as a rejection.

### `window.craft.menu.onAction(handler: (event: { id: string }) => void): () => void`

Menu clicks arrive here. Without it there is no way to respond to a menu at all.
Returns an unsubscribe function.

```javascript
const off = window.craft.menu.onAction(({ id }) => {
  if (id === 'new') createDocument();
  if (id === 'open') openDocument();
});
```

Only items with an `id` fire this. Role items are performed by the system and
never reach your handler.

### Items and roles

```typescript
interface MenuDefinition {
  label: string
  items: MenuItemDefinition[]
}

interface MenuItemDefinition {
  /** Echoed back by `onAction` when this item is clicked. */
  id?: string
  label?: string
  /** Accelerator, e.g. `cmd+n`, `cmd+shift+r`. */
  shortcut?: string
  /** Icon name (SF Symbol, resolved through Craft's cross-platform icon table). */
  icon?: string
  /** Renders a divider; every other field is ignored when this is set. */
  separator?: boolean
  /** A standard behavior the system performs — see the table below. */
  role?: string
}
```

This is the whole of it. The native decoder parses exactly these fields and
ignores anything else, so extra keys are dropped in silence rather than
rejected. Two consequences worth knowing:

- a separator is `{ separator: true }`, not `{ type: 'separator' }`
- there are no nested submenus yet; the bar is one level deep

Checkmarks and enablement are set after the fact, with `checkItem()` /
`enableItem()`, not with a field here.

**Roles.** A role item is wired to an AppKit selector through the responder
chain, exactly as a hand-built Mac menu would be. Use one wherever the system
already knows how to do the job:

| role | performs | role | performs |
|---|---|---|---|
| `about` | About panel | `selectAll` | select all |
| `hide` | hide app | `close` | close window |
| `hideOthers` | hide other apps | `minimize` | minimize |
| `showAll` | unhide all | `zoom` | zoom |
| `quit` | quit | `front` | bring all to front |
| `undo` / `redo` | undo, redo | `fullscreen` | toggle full screen |
| `cut` / `copy` / `paste` | clipboard | `reload` | reload the webview |
| `delete` | delete selection | `forceReload` | reload ignoring cache |

Cut, copy and paste **must** be roles. A round trip through JavaScript cannot
reach the field editor inside a text field or the WKWebView's own clipboard
handling, so an `id` item named "Copy" will not copy anything.

An unrecognized role degrades to an ordinary `id` item, which fires `onAction` —
a newer bridge surface therefore fails soft on an older binary.

### The rest of the surface

| method | effect |
|---|---|
| `setDock({ items })` | replace the Dock menu (right-click the Dock icon) |
| `clearDock()` | remove it |
| `addItem(menuId, item)` | append one item to an existing menu; `menuId` is the menu's **label**, e.g. `'File'`. Pass `index` on the item to insert instead of append |
| `removeItem(itemId)` | remove by id |
| `enableItem(itemId)` / `disableItem(itemId)` | greyed out or not |
| `checkItem(itemId)` / `uncheckItem(itemId)` | checkmark |
| `setItemLabel(itemId, label)` | rename in place |

## Global Shortcuts (macOS)

System-wide hotkeys: they fire whether or not your app is frontmost. macOS only
— on Linux and Windows every registration is refused, because craft has no
implementation there and a shortcut that can never fire is worse than one that
was never accepted.

Craft registers these through Carbon's `RegisterEventHotKey`, which needs no
Accessibility or Input Monitoring permission and only ever calls back for the
exact combinations you asked for. Your app never sees any other keystroke.

### `window.craft.shortcuts.register(id, accelerator): Promise<void>`

Reserve a combination. `id` is yours to choose and is what comes back when the
key is pressed. Registering an id twice replaces the first binding.

```javascript
await window.craft.shortcuts.register('summon', 'Cmd+Shift+H');

window.craft.shortcuts.on(({ id, accelerator }) => {
  if (id === 'summon') window.craft.window.toggle();
});
```

Accelerators are `+`-separated and case-insensitive. The last component is the
key; everything before it is a modifier:

| Modifier | Accepted as |
|---|---|
| Command | `Cmd`, `Command`, `Meta`, `Super`, `⌘` |
| Control | `Ctrl`, `Control`, `⌃` |
| Option | `Alt`, `Option`, `Opt`, `⌥` |
| Shift | `Shift`, `⇧` |
| Either | `CmdOrCtrl`, `CommandOrControl`, `Mod` — command on macOS, control elsewhere |

Keys are named by position on the keyboard, not by the character they produce,
so a shortcut survives the user switching layout. Letters, digits, punctuation,
`Space`, `Tab`, `Return`, `Escape`, `Delete`, the arrows, `Home`/`End`/`PageUp`/
`PageDown`, `F1`–`F20` and the keypad (`Keypad0`–`Keypad9`, `KeypadEnter`, …)
are all bindable. Web and Electron spellings — `Backspace`, `Esc`, `Enter`,
`ArrowLeft`, `Plus` — resolve to the same keys.

**At least one of Command, Control or Option is required**, except on the
function keys. A bare global hotkey on `H` would mean no application on the
system — including yours — ever saw the user type an h again; failing the
registration is recoverable, and that is not. Shift alone does not count, since
Shift+H is how you type a capital H.

### `window.craft.shortcuts.onError(handler): () => void`

Where a failed call arrives: `{ id, code, message }`. Every verb here except
`isRegistered` and `list` is fire-and-forget — the promise resolves as soon as
the message is posted, not when the key is reserved — so this is how you learn
that a combination belongs to another app or to the system, or that `enable()`
could not take a released key back.

```javascript
window.craft.shortcuts.onError(({ id, message }) => {
  showToast(`Could not bind ${id}: ${message}`);
});
```

### `window.craft.shortcuts.on(handler): () => void`

Fires on every press of a registered, enabled shortcut, with `{ id, accelerator }`.
The accelerator is craft's canonical spelling — `Cmd+Delete`, whatever you
originally wrote — so it round-trips back through `register()`. Returns an
unsubscribe function.

### The rest

| Call | What it does |
|---|---|
| `unregister(id)` | give the key back to the system and forget the shortcut |
| `unregisterAll()` | the same, for every shortcut this app holds |
| `disable(id)` | stop firing **and release the key**, so other apps can use it again; the shortcut stays listed |
| `enable(id)` | take it back — this can fail if something else claimed it in the meantime, and reports on `onError` |
| `isRegistered(id): Promise<boolean>` | whether the id is known, enabled or not |
| `list(): Promise<Shortcut[]>` | `{ id, accelerator, key, enabled }` for each |

## Window API

Control the application window from JavaScript.

### `window.craft.window.show(): Promise<void>`

Show the window.

```javascript
await window.craft.window.show();
```

### `window.craft.window.hide(): Promise<void>`

Hide the window.

```javascript
await window.craft.window.hide();
```

### `window.craft.window.toggle(): Promise<void>`

Toggle window visibility.

```javascript
await window.craft.window.toggle();
```

### `window.craft.window.minimize(): Promise<void>`

Minimize the window.

```javascript
await window.craft.window.minimize();
```

### `window.craft.window.close(): Promise<void>`

Close the window (and quit the app if it's the last window).

```javascript
await window.craft.window.close();
```

## App API

Application-level controls.

### `window.craft.app.hideDockIcon(): Promise<void>`

Hide the dock icon (macOS only). Creates a menubar-only application.

```javascript
await window.craft.app.hideDockIcon();
```

**Note:** Best used with `--system-tray` to ensure the app remains accessible.

### `window.craft.app.showDockIcon(): Promise<void>`

Show the dock icon (macOS only).

```javascript
await window.craft.app.showDockIcon();
```

### `window.craft.app.quit(): Promise<void>`

Quit the application.

```javascript
await window.craft.app.quit();
```

### `window.craft.app.getInfo(): Promise<AppInfo>`

Get application information.

```javascript
const info = await window.craft.app.getInfo();
console.log(info);
// { name: 'MyApp', version: '1.0.0', platform: 'macos' }
```

## TypeScript Support

Full TypeScript definitions are included:

```typescript
declare global {
  interface Window {
    craft: {
      tray: {
        setTitle(title: string): Promise<void>
        setTooltip(tooltip: string): Promise<void>
        onClick(callback: (event: TrayClickEvent) => void): () => void
        onClickToggleWindow(): () => void
        setMenu(items: MenuItem[]): Promise<void>
      }
      window: {
        show(): Promise<void>
        hide(): Promise<void>
        toggle(): Promise<void>
        minimize(): Promise<void>
        close(): Promise<void>
      }
      app: {
        hideDockIcon(): Promise<void>
        showDockIcon(): Promise<void>
        quit(): Promise<void>
        getInfo(): Promise<AppInfo>
      }
    }
  }
}
```

Import types:

```typescript
import type { CraftBridgeAPI, TrayClickEvent, MenuItem } from 'craft-native'
```

## Examples

### Pomodoro Timer

See the complete example in `packages/typescript/examples/pomodoro-timer.html`

Key features:

- Updates tray title with countdown
- Click tray to toggle window
- Shows window when timer completes
- Menubar-only mode (optional)

Run it:

```bash
# From the repository root
craft packages/typescript/examples/pomodoro-timer.html --system-tray

# Or with menubar-only mode
craft packages/typescript/examples/pomodoro-timer.html --system-tray --hide-dock-icon
```

### Music Player

```javascript
let isPlaying = false;

// Update tray based on playback state
function updateTray() {
  const icon = isPlaying ? '▶️' : '⏸️';
  const title = `${icon} ${currentTrack.title}`;
  window.craft.tray.setTitle(title);
}

// Set up tray menu
window.craft.tray.setMenu([
  { label: 'Play/Pause', action: 'toggle-playback' },
  { label: 'Next Track', action: 'next-track' },
  { label: 'Previous Track', action: 'prev-track' },
  { type: 'separator' },
  { label: 'Show Window', action: 'show' },
  { label: 'Quit', action: 'quit' }
]);

// Handle menu actions
window.addEventListener('craft:tray:menu', (event) => {
  switch (event.detail.action) {
    case 'toggle-playback':
      togglePlayback();
      break;
    case 'next-track':
      nextTrack();
      break;
    case 'prev-track':
      previousTrack();
      break;
  }
});
```

### System Monitor

```javascript
// Update tray with system stats
async function updateStats() {
  const cpu = await getCPUUsage();
  const mem = await getMemoryUsage();

  const title = `CPU: ${cpu}% | RAM: ${mem}%`;
  await window.craft.tray.setTitle(title);
}

// Update every 2 seconds
setInterval(updateStats, 2000);

// Click tray to show detailed view
window.craft.tray.onClick(() => {
  window.craft.window.show();
});
```

### Download Manager

```javascript
// Show progress in tray
function updateProgress(percent) {
  const bars = Math.floor(percent / 10);
  const progress = '▓'.repeat(bars) + '░'.repeat(10 - bars);
  window.craft.tray.setTitle(`⬇️ ${percent}%`);
  window.craft.tray.setTooltip(`Downloading: ${progress}`);
}

// Show window when complete
async function onComplete() {
  await window.craft.tray.setTitle('✓ Done');
  await window.craft.window.show();
}
```

## Platform Support

| Feature | macOS | Windows | Linux |
|---------|-------|---------|-------|
| Tray Title | ✅ | ✅ | ✅ |
| Tray Tooltip | ✅ | ✅ | ✅ |
| Tray Click | ✅ | 🚧 | 🚧 |
| Tray Menu | 🚧 | 🚧 | 🚧 |
| Window Control | ✅ | ✅ | ✅ |
| Hide Dock Icon | ✅ | ➖ | ➖ |
| Global Shortcuts | ✅ | 🚧 | 🚧 |

✅ Implemented | 🚧 In Progress | ➖ Not Applicable

## Best Practices

1. **Always check for bridge availability:**

   ```javascript
   if (window.craft) {
     // Safe to use
   }
   ```

2. **Handle errors gracefully:**

   ```javascript
   try {
     await window.craft.tray.setTitle('Title');
   } catch (err) {
     console.warn('Failed to update tray:', err);
   }
   ```

3. **Keep tray titles short:**
   - Max 20 characters on macOS
   - Use emoji for visual indicators: 🍅 ✓ ⏸️ ▶️

4. **Unregister event listeners:**

   ```javascript
   const unregister = window.craft.tray.onClick(handler);
   // When done:
   unregister();
   ```

5. **Combine with system tray:**
   - Always use `--system-tray` when using tray API
   - Consider `--hide-dock-icon` for menubar-only apps

## Troubleshooting

### Bridge not available

If `window.craft` is undefined:

1. Ensure you're using Craft 1.3.0 or later
2. Wait for the `craft:ready` event
3. Check the browser console for injection errors

### Tray not updating

Common issues:

1. Tray not created: Use `--system-tray` flag
2. Title too long: Keep under 20 characters
3. Invalid emoji: Some emoji may not render properly

### TypeScript errors

Ensure you have the latest type definitions:

```bash
bun add craft-native@latest
```

Or manually import types:

```typescript
/// <reference types="craft-native" />
```

## Contributing

Found a bug or have a feature request? Please open an issue on [GitHub](https://github.com/home-lang/craft/issues).

## License

MIT License - see [LICENSE](../LICENSE) for details.
