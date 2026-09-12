# Multi-window ownership

This document records Craft's current multi-window ownership contract. It is
both a map of the implemented macOS behavior and a boundary around the choices
that are still open. A process-global Zig object is not automatically a
single-window bug: the important question is whether it is a shared service or
whether it stores a window-specific target.

## Current status

| Area | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Runtime creation from `createWindow()` | Implemented | Not wired to the SDK handle contract | Not wired to the SDK handle contract |
| Stable named handles | Implemented | Not implemented | Not implemented |
| Sender-authenticated local actions | Implemented | Not implemented | Not implemented |
| Named cross-window actions | Implemented | Not implemented | Not implemented |
| Per-window lifecycle events | Implemented | Not implemented | Not implemented |
| Permanent destroy and cleanup | Implemented for named windows | Not implemented | Not implemented |
| Modal and parent relationships | Unspecified | Unspecified | Unspecified |

Issue #67 therefore remains open. Its macOS core is substantially implemented,
but closing it would imply cross-platform and modal/parent semantics that Craft
does not yet provide.

## Per-window state

The following state belongs to one native window and must never silently fall
back to whichever window was created most recently:

- `window_registry.zig` owns the stable name, native handle and creator-webview
  relationship for every macOS window.
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
  becomes its handle owner; a live owner is never silently replaced.
- The local scroll monitor is installed once, but reads the event's `NSWindow`,
  advances only that window's accumulator and emits only to its webview.

`close()` preserves these resources so the same page can reopen with its DOM
and JavaScript state intact. `destroy()` removes the named registry entry,
Native UI graph, gesture and material slots, recovery state, event ownership
and retained AppKit objects before releasing the window.

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
3. Bring Linux and Windows runtime creation, stable handles, sender routing,
   lifecycle events and destroy semantics up to the macOS contract. Their
   platform backends can create native windows today, but the TypeScript bridge
   deliberately reports runtime creation as unsupported outside macOS.
4. Add platform-native integration coverage. Source conformance and pure state
   tests defend macOS invariants without requiring a GUI runner, but they do
   not substitute for real Windows WebView2 and Linux WebKitGTK lifecycle tests.

## Review checklist

For every new bridge or callback that touches a window, verify:

- A page-driven call uses `window_context`, not a mutable process-global target.
- An explicit window ID is resolved through the registry and unknown IDs fail.
- An asynchronous reply retains both its target and its requesting webview.
- A delayed control callback stores its owner on the control/delegate instance.
- Ordinary close preserves state; permanent destroy forgets it exactly once.
- A process-global event sink is documented as primary, broadcast or
  subscriber-owned rather than inheriting accidental last-window behavior.
