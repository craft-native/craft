# Craft native macOS

`buildMacOSNative` compiles an AppKit host for the stx native mutation protocol.
It renders controls directly using NSView, NSTextField, NSTextView, NSButton,
NSPopUpButton, NSOutlineView, NSScrollView, NSImageView, and AVPlayerView.
Windows, sheets, menus, file dialogs, previews, clipboard operations, and QR
codes use macOS APIs. The layout ABI and atomic mutation validator are shared
with Craft's mobile hosts.

The script engine is zig-js. Pass its checkout and built public static archive
as `zigJS: { source, library }`, and the pinned Zig compiler as `zig`.
The host imports zig-js's `ZigJS` module and owns its Objective-C bridge objects.
It never links the system JavaScriptCore or WebKit frameworks.

```ts
import { buildMacOSNative } from 'craft-native/macos'

await buildMacOSNative({
  outdir: 'dist/native',
  nativeBundle: 'dist/native-screen.js',
  zig: '/toolchain/zig',
  zigJS: { source: '/sources/zig-js', library: '/sources/zig-js/zig-out/lib/libzig-js.a' },
})
```

Launch the executable with `--api-url`, `--native-bundle`, `--title`, and an
optional `--route`. The HTTP agent's `/native/session` endpoint must establish
the session cookie. URLSession owns that cookie and shares it between windows.

Use `--titlebar-style transparent` to hide the window title on a transparent
title bar. The default keeps the standard AppKit title bar. `--width`,
`--height`, `--min-width` and `--min-height` configure the main window in points.
Additional windows accept `titlebarStyle: 'standard' | 'transparent'` with the
same size options through `craft.desktop.openWindow`.

This is a native control vocabulary, not an HTML renderer. Unsupported controls
produce a diagnostic and an explicit visible error. The native `Sidebar` accepts
sections of `{ id, header?, items: [{ id, label, icon?, badge? }] }` and sends an
`onValueChange` event. Desktop capabilities are exposed through `craft.desktop`.

## WebView pointer lock

The macOS WebView renderer does not support `Element.requestPointerLock()`. WebKit
reports `pointerlockerror` even when the request comes from a trusted click because
its public `WKUIDelegate` has no pointer-lock permission callback. Craft does not
use private WebKit APIs for Store builds. Element fullscreen remains available, so
canvas and game code should detect pointer-lock failure and provide a drag or
fullscreen control fallback. The AppKit native renderer has no DOM pointer-lock
surface and is unaffected by this WebView limitation.

An explicit `--test-dir` enables local file-based AppKit control automation.
It records actual control classes, frames, values, script errors, and view trees.
It is absent during normal launches. Tests should always use isolated data.
