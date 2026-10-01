# Multi-window ownership

This document records Craft's current multi-window ownership contract. It is
both a map of the implemented desktop behavior and a boundary around the choices
that are still open. A process-global Zig object is not automatically a
single-window bug: the important question is whether it is a shared service or
whether it stores a window-specific target.

## Current status

| Area | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Runtime creation from `createWindow()` | Implemented | Implemented; GUI smoke in CI | Implemented; WebView2 GUI smoke in CI |
| Stable named handles | Implemented | Implemented | Implemented |
| Sender-authenticated local actions | Implemented | Implemented through WebKitGTK | Implemented through WebView2 |
| Named cross-window actions | Implemented | Implemented for core controls | Implemented for core controls |
| `executeJavaScript()` result and error replies | Implemented | Implemented with WebKitGTK | Implemented with WebView2 result API |
| Per-window lifecycle events | Implemented | Implemented | Implemented |
| Named-window always-on-top control | Implemented | Implemented as a window-manager request | Implemented |
| Named-window relative movement | Implemented | Implemented as a window-manager request | Implemented |
| Named-window size-limit short aliases (`setMinSize`, `setMaxSize`) | Implemented | Implemented | Implemented |
| Named-window attention request (`flashFrame`) | App-level Dock attention; request IDs retained per handle for cancellation and destroy; installed-app smoke | Per-window GTK urgency hint; desktop may ignore; installed-app smoke | Per-window caption/taskbar flash; installed-app smoke |
| Addressed `getState()` reads | Implemented | Implemented with GTK/GDK state | Implemented with Win32 state |
| Named-window `toggle()` visibility | Implemented | Implemented; GUI smoke in CI | Implemented; WebView2 GUI smoke in CI |
| Permanent destroy and cleanup | Implemented for named windows | Implemented on close/destroy | Implemented on close/destroy |
| Modal and parent relationships | Parent-scoped sheets and attached child windows; installed-app smoke in CI | Transient child windows with parent-only input blocking and prior sensitivity restored; Openbox-backed focus and native X11 ownership/stacking checks in GUI smoke, plus installed-app smoke in CI | Owned child windows with parent-only input blocking and prior enabled state restored; GUI and installed-app smokes plus process-scoped Win32 owner/enabled-state probe in CI |

The runtime-creation, stable-handle, reply-routing, and event-scoping contract
from issue #67 is covered here. Parent/modal behavior follows the approved
[contract](./multi-window-parent-modal-proposal.md); all three desktop
backends now apply it. The Windows release archive stages an app-local WebView2 loader;
users still need the Microsoft WebView2 Runtime.

Linux and Windows keep their live native window/webview pairs in
`desktop_window_registry.zig`. Page messages are authenticated by the sending
WebKitGTK view or the per-WebView2 event subscription; names select a target
only after that native source is known.

Linux reports the requested always-on-top setting because GTK delegates actual
stacking to the window manager, which may ignore that request. `getState()`
reports that same requested setting on Linux; its other flags and bounds come
from the live GTK/GDK window. Windows reads visibility, minimization,
maximization, focus and topmost status from Win32; its fullscreen flag comes
from Craft's borderless-fullscreen state.

The typed SDK contains some methods beyond this portable core. The host
dispatchers define their current support, not the existence of a TypeScript
method:

| Action group | macOS | Linux and Windows |
| --- | --- | --- |
| `setMovable`, `startDrag`, `isMovable`, `setOpacity`, `getOpacity`, `setBackgroundColor`, `setHasShadow`, `setWindowLevel` | AppKit window bridge | `PlatformNotSupported` |
| `setAppearance`, `setVibrancy` | AppKit-specific | `PlatformNotSupported` |
| `setBackgroundMaterial`, `setOverlayIcon` | No window action handler | No window action handler |

`flashFrame` is implemented on all three desktops, with platform-specific
attention behavior described above. Do not present the reserved Windows
material/overlay methods as working APIs until a native handler and installed
app test exist. A missing handler rejects; it does not silently succeed.

Replies go back to the requesting view, and lifecycle events go to the changed
window plus its named handle's creator. The Linux and Windows GUI smokes resize
a child while two unrelated child pages are live, requiring the changed page's
local event and the creator's named event without broadcasting to those pages.
The GUI and installed-app smokes also watch every supported lifecycle channel
on child pages, rejecting events for windows that page neither hosts nor owns.
They also verify that an unparented child opened by another child page survives
that creator's destruction: a different live page cannot steal its handle
beforehand, but can adopt the orphaned name afterward and receive subsequent
named events while the surviving child still receives local events.

Linux must register its `GtkApplication` before constructing the first
`GtkApplicationWindow`, because the CLI creates that window before entering
`g_application_run()`. It seeds each window's initial geometry before the page
loads so the first page-requested resize emits a lifecycle event instead of
silently setting a baseline. On Windows, the controller
passed to the asynchronous WebView2 completion callback is borrowed. Each live
window retains its own controller reference until native destruction; otherwise
WebView2 can close before the page bridge registers or navigation begins.
WebView2 also forbids entering a nested message loop from its message callback.
Windows therefore queues page-requested child creation onto the UI message
queue, preserving the authenticated owner and reply ID until that callback
returns. Concurrent opens are drained serially and abandoned if their creator
window is destroyed before dispatch.

`executeJavaScript()` evaluates in the addressed live window, but resolves or
rejects the promise in the page that requested it. The result is a JSON value;
JavaScript `undefined` resolves as `null`, while a JavaScript exception rejects
with `NATIVE_CALL_FAILED`. Each in-flight operation retains a distinct request
ID and monotonic native ticket, so concurrent calls cannot swap replies. A
target navigation or close cancels its pending calls; a still-live requesting
page receives `CANCELLED`. If the requesting page itself navigates or closes,
its old promises are discarded rather than delivered into the replacement
document. Closing and reopening a named window cannot inherit a stale result.

## Per-window state

The following state belongs to one native window and must never silently fall
back to whichever window was created most recently:

- `window_registry.zig` owns the stable name, native handle and creator-webview
  relationship for every macOS window. Names are decoded from JSON before
  registration and lookup, so escaped identifiers compare and emit as the
  same bytes the TypeScript handle owns.
- `main` is reserved as each page's local-window alias and can never be used
  as a runtime-created window name; otherwise the creator would return its
  existing local wrapper for a different native window.
- `window_context.zig` carries the authenticated `WKScriptMessage` sender while
  a bridge call is dispatched. The host, not the JSON payload, establishes the
  caller's local window and webview.
- `request_context.zig` carries reply correlation so asynchronous
  `executeJavaScript()` results return to the requesting page even when the
  execution target is another window.
- Window chrome, material configuration, retained HTML content, recovery state
  and swipe-gesture accumulation use bounded slots keyed by native window or
  webview. Lossless stores are sized to the window registry's full capacity;
  they do not evict one live window to make room for another.
- `NativeUIBridge.WindowState` owns sidebars, file browsers, split views,
  controller state, context-menu delegates and space switchers for one window.
- The older whole-window native-sidebar constructors keep their config arena,
  material settings, controls and event webview in a slot keyed by `NSWindow`.
- Window event delivery resolves the event notification's own `NSWindow`, then
  emits to that page and, for a named child, its creator page. Unrelated pages
  receive nothing. If that creator is permanently destroyed while the child is
  retained, the child drops the stale route and the next page to open its name
  becomes its handle owner. While the creator remains live, another page is
  refused rather than receiving a handle whose events it cannot own.
- The local scroll monitor is installed once, but reads the event's `NSWindow`,
  advances only that window's accumulator and emits only to its webview.

On macOS, `close()` preserves these resources and the SDK's native-event
subscriptions so the same page can reopen with its DOM and JavaScript state
intact, including when the primary window is reopened by the Dock rather than
`createWindow()`.
`destroy()` removes the named registry entry, Native UI graph, gesture and
material slots, recovery state, event ownership and retained AppKit objects
before releasing the window and detaching the SDK's DOM listeners.

## Process-global services

The bridge instances in `macos.zig` are process-global dispatch services. They
are safe to share because page-driven operations resolve their target through
`window_context` or through an explicit named handle. Their stored primary
window/webview is only a fallback for calls without a page sender.

Tray and menu behavior is also deliberately primary-window scoped. A child
window does not replace the target used to show or toggle the application, and
tray/menu events continue to reach the primary page.

Quick Look is application-scoped because `QLPreviewPanel` is an AppKit shared
panel. Showing it from another window replaces the shared panel's contents;
Craft does not pretend each window owns a separate panel.

Touch Bar is also a legacy application-scoped service today. One global
`TouchBarBridge` owns the item definitions, and rebuilding it installs the bar
on AppKit's `mainWindow`; a delayed callback has no sending-page context and
therefore uses the primary-page evaluator. A child-page call mutates that same
main-window bar rather than creating per-window Touch Bar state.

## Primary-page event sinks

Some asynchronous native sources have no authenticated sender by the time they
emit. They currently deliver to the primary page through `getGlobalWebView()`:

| Source | Current delivery |
| --- | --- |
| Theme changes (`macos_theme.zig`) | Primary page |
| Screen configuration changes (`bridge_screen.zig`) | Primary page |
| Deep links (`macos_deep_link.zig`) | Primary page |
| Location updates (`bridge_location.zig`) | Primary page |
| In-app purchase updates (`bridge_iap.zig`) | Primary page |
| Local-server requests (`bridge_local_server.zig`) | Primary page |
| Screen-sharing changes (`bridge_screen_sharing.zig`) | Primary page |
| Tray and application-menu actions | Primary page |

This is an explicit compatibility contract, not per-window subscription
behavior. Before changing one of these sources, choose and document whether it
should remain primary-only, broadcast to every page, or track individual
subscribers and their owning webviews. Opening a child must never implicitly
make it the new sink.

## Remaining decisions

The parent/child and parent-only modal contract is implemented and covered by
the desktop GUI and installed-app smokes. The remaining product choices are:

1. Choose primary-only, broadcast or per-subscriber delivery for each
   application-level asynchronous source above.
2. Decide whether Touch Bar should stay primary-window scoped or follow the
   key window with separately owned item definitions and callbacks.
3. Decide the portability contract for advanced actions beyond bounds,
   centering, resizability, size limits and fullscreen. Closing still differs:
   macOS retains a closed page, while Linux and Windows release it.
4. Expand platform-native integration beyond named-window lifecycle and core
   geometry/control smokes. CI runs Linux WebKitGTK under Xvfb with Openbox and Windows
   WebView2 on a native runner. Installed PKG, DEB and MSI smoke tests now
   launch a sample app through the SDK and compare escaped clipboard text
   through the page bridge with the host OS clipboard. Each installed app also
   opens a child page, reads its addressed title, resizes it, requires both the
   child's local and creator's named resize events without changing the main
   window size, reads addressed native state from the main and child, then
   closes the child with a named close event. Each installed app additionally
   opens an unparented grandchild from that child page, rejects
   a second page's attempt to steal its live handle, tears down its creator,
   and requires the surviving grandchild's local and newly adopted named
   resize events and addressed native state. macOS explicitly destroys the
   retained creator after close;
   Linux and Windows release it on close. The macOS job also
   dispatches a registered URL scheme into the installed app. Its notification
   check queries Notification Center for the delivered ID when permission is
   granted, and reports a denied permission separately. If macOS rejects the
   authorization request, the smoke queries the actual status: only a confirmed
   denial skips delivery, while an undetermined or inconsistent state fails.
   The Linux job verifies
   a unique notification reached a desktop daemon over D-Bus. The Windows job
   checks its MSI-installed toast identity and Start-menu shortcut, then looks
   for the notification in Action Center. Signed/notarized release artifacts
   remain outside this smoke.

## Review checklist

For every new bridge or callback that touches a window, verify:

- A page-driven call uses `window_context`, not a mutable process-global target.
- An explicit window ID is resolved through the registry and unknown IDs fail.
- An asynchronous reply retains both its target and its requesting webview.
- A delayed control callback stores its owner on the control/delegate instance.
- On macOS, ordinary close retains the page and permanent destroy forgets it
  exactly once. On Linux and Windows, close and destroy both release the native
  window/webview; a later open of the same name creates a fresh native page.
- A process-global event sink is documented as primary, broadcast or
  subscriber-owned rather than inheriting accidental last-window behavior.
