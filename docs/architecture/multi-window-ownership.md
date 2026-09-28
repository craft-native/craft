# Multi-window ownership

This document records Craft's current multi-window ownership contract. It is
both a map of the implemented desktop behavior and a boundary around the choices
that are still open. A process-global Zig object is not automatically a
single-window bug: the important question is whether it is a shared service or
whether it stores a window-specific target.

## Current status

| Area | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Runtime creation from `createWindow()` | Implemented | Implemented; GUI smoke in CI | Implemented; WebView2 GUI smoke under validation in CI |
| Stable named handles | Implemented | Implemented | Implemented |
| Sender-authenticated local actions | Implemented | Implemented through WebKitGTK | Implemented through WebView2 |
| Named cross-window actions | Implemented | Implemented for core controls | Implemented for core controls |
| Per-window lifecycle events | Implemented | Implemented | Implemented |
| Permanent destroy and cleanup | Implemented for named windows | Implemented on close/destroy | Implemented on close/destroy |
| Modal and parent relationships | Unspecified | Unspecified | Unspecified |

Issue #67 remains open while the Windows runtime smoke and the still-unspecified
modal/parent semantics are reviewed. The Windows release archive now stages an
app-local WebView2 loader; users still need the Microsoft WebView2 Runtime.

Linux and Windows keep their live native window/webview pairs in
`desktop_window_registry.zig`. Page messages are authenticated by the sending
WebKitGTK view or the per-WebView2 event subscription; names select a target
only after that native source is known.
Replies go back to the requesting view, and lifecycle events go to the changed
window plus its named handle's creator. Linux must register its `GtkApplication`
before constructing the first `GtkApplicationWindow`, because the CLI creates
that window before entering `g_application_run()`. On Windows, the controller
passed to the asynchronous WebView2 completion callback is borrowed. Each live
window retains its own controller reference until native destruction; otherwise
WebView2 can close before the page bridge registers or navigation begins.
WebView2 also forbids entering a nested message loop from its message callback.
Windows therefore queues page-requested child creation onto the UI message
queue, preserving the authenticated owner and reply ID until that callback
returns. Concurrent opens are drained serially and abandoned if their creator
window is destroyed before dispatch.

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

`close()` preserves these resources and the SDK's native-event subscriptions
so the same page can reopen with its DOM and JavaScript state intact, including
when the primary window is reopened by the Dock rather than `createWindow()`.
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

The next multi-window milestone needs product decisions in addition to code:

1. Define parent/child and modal behavior, including focus, close propagation,
   sheets, always-on-top interaction and ownership after the creator is
   destroyed.
2. Choose primary-only, broadcast or per-subscriber delivery for each
   application-level asynchronous source above.
3. Decide whether Touch Bar should stay primary-window scoped or follow the
   key window with separately owned item definitions and callbacks.
4. Finish advanced Linux/Windows window actions and clarify which are portable
   versus platform-specific, without conflating close semantics: macOS retains
   a closed page, while Linux and Windows release it.
5. Complete platform-native integration coverage. Linux WebKitGTK runs under
   Xvfb in CI; Windows currently has a cross-build but still needs a real
   WebView2 lifecycle smoke on a capable Windows runner.

## Review checklist

For every new bridge or callback that touches a window, verify:

- A page-driven call uses `window_context`, not a mutable process-global target.
- An explicit window ID is resolved through the registry and unknown IDs fail.
- An asynchronous reply retains both its target and its requesting webview.
- A delayed control callback stores its owner on the control/delegate instance.
- Ordinary close preserves state; permanent destroy forgets it exactly once.
- A process-global event sink is documented as primary, broadcast or
  subscriber-owned rather than inheriting accidental last-window behavior.
