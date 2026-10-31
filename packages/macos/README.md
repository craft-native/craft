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
It never links the system JavaScriptCore, and links WebKit only when built with `webkit: true` (see below).
The build enforces the first half: after linking, it fails if the host imports any
JavaScriptCore function or links `JavaScriptCore.framework`, since a WebKit build sits one
framework away from it and zig-js exports the same C names (`assertZigJsEngine`).

```ts
import { buildMacOSNative } from 'craft-native/macos'

// The pinned toolchain is resolved for you: Zig is installed by Pantry and
// zig-js is fetched at its pinned revision and built once, into
// ~/.cache/craft/toolchain (CRAFT_TOOLCHAIN_DIR moves it, CRAFT_ZIG overrides
// the compiler). `resolveMacOSToolchain()` returns what it resolved.
await buildMacOSNative({ outdir: 'dist/native', nativeBundle: 'dist/native-screen.js' })

// Or hand it a toolchain you manage yourself:
await buildMacOSNative({
  outdir: 'dist/native',
  nativeBundle: 'dist/native-screen.js',
  zig: '/toolchain/zig',
  zigJS: { source: '/sources/zig-js', library: '/sources/zig-js/zig-out/lib/libzig-js.a' },
})
```

## Web pages: `<WebView>` and `craft.web`

A browser or help viewer can show web pages beside its native screens. Build
with `webkit: true` and the host links WebKit, advertises the `web` capability,
and renders `<WebView tab="...">` as that tab's `WKWebView`. Without the flag
none of it is compiled, the host links no WebKit, and `WebView` is reported as
an unsupported control.

```ts
await buildMacOSNative({ outdir: 'dist/native', nativeBundle: 'dist/native-screen.js', webkit: true })
```

Tabs are owned by the host, not by the view that shows them, so a page survives
re-renders, split panes and off-screen time. The screen creates and drives them
through `craft.web`, and decides where each appears with `<WebView tab>`:

| Method | Answers |
|---|---|
| `create({ id?, url?, profile?, private?, inspectable? })` | the tab's state |
| `navigate(id, url)`, `back(id)`, `forward(id)`, `reload(id, { ignoreCache? })`, `stop(id)`, `close(id)` | `true` (`back`/`forward`: whether there was history) |
| `state(id)`, `list()` | state |
| `evaluate(id, script, { isolated? })` | the script's JSON value; `isolated` runs it where the page's scripts cannot see it |
| `find(id, text, { backwards?, caseSensitive?, wraps? })` | `{ found }` |
| `setZoom(id, zoom)`, `focus(id)`, `setInspectable(id, on)` | |
| `snapshot(id, { width? })` | a JPEG data URL (tab previews, sleeping tabs) |
| `print(id)` | `true`, once the print sheet is up |
| `setContentRules(identifier, { version, json? })` | `{ cached }`, or `{ missing: true }` when that version was never compiled and no `json` came with it |
| `removeContentRules(identifier)`, `allowContent(hosts)` | |
| `setUserScripts([{ id, hosts, css?, js?, world?, at?, allFrames? }])` | |
| `answerPermission(request, 'grant' \| 'deny' \| 'prompt')` | whether the request was still waiting |
| `clearData({ profile, private?, host?, types? })` | `{ cleared }`; `types` from `cookies`, `storage`, `cache` |
| `cancelDownload(id)`, `revealDownload(path)`, `openDownload(path)` | |

**Content blockers** (an ad blocker) are WebKit content-rule lists. WebKit
compiles each once and keeps it on disk under its identifier and version, so a
screen first asks for a version without `json` and sends the rules only when the
answer is `missing`. Every tab has its own content controller: a site listed in
`allowContent` (a host covers its subdomains) loads with no list applied, in
that tab only. **User scripts** (Boosts, an ad blocker's page scripts) run on
the hosts they name (none, or `*`, is every site), in an isolated world the
page's scripts cannot see unless `world: 'page'`; CSS lands at document start,
JS at document end unless `at: 'start'`, and pages pick a new set up on their
next load. **Downloads** can
only be revealed or opened inside ~/Downloads, and an app or script is revealed
in Finder rather than run.

Each profile has its own website data store (cookies, storage, cache), found
again on every launch by a UUID derived from its name (macOS 14+; `default` is
WebKit's default store). `private: true` keeps nothing on disk. Pages get
desktop Safari's user-agent suffix.

Events arrive as `CRAFT_EVENT` `craftWebView` with `{ tab, type, ... }`:
`state` (title, url, progress, loading, canGoBack, canGoForward, secure, zoom,
themeColor, camera, microphone; coalesced to one per run-loop turn),
`navigationStart`, `navigationFinish`, `navigationError`, `favicon`, `open`
(`target=_blank` and `window.open` arrive with a ready `child` tab id;
⌘-click arrives with only a `url` and `background`), `close`, `crashed`
(the page's process died and was reloaded), `permission` (a site asks for the
camera or microphone: `{ request, kind, origin }`; answer it with
`answerPermission`, or it is denied after two minutes) and `download` (`started`,
`progress` at most every 250ms, `finished`, `failed`, saved to ~/Downloads
under a name that never overwrites). Links to other apps' schemes (`mailto:`,
`facetime:`) open those apps. JavaScript alerts, confirms, prompts and file
inputs use native sheets on the tab's window. A window that closes closes the
tabs it owns.

## Hosted-API apps

An app with its own local agent (Attic) is launched with `--api-url` and gets its
session cookie from `/native/session`. An app that talks to a hosted API passes
`--no-session` instead: there is no handshake, and `--api-url` is only the origin
relative `fetch` calls resolve against (`craft.app.url`).

`craft.secureStorage` is the macOS Keychain (one generic password per key, service
`<bundle id>.secure`). A signed Mac App Store build uses the data-protection
keychain; an unsigned or ad-hoc build uses the login keychain. `craft.session`
follows the `auth.token` item and sends `SESSION_CHANGED` to every window.
`craft.storage` has synchronous `getSync` and `setSync` over UserDefaults.

A single-line `TextInput` fires `onSubmitEditing` on Return and `onBlur` /
`onEndEditing` on leaving; a multi-line one fires `onBlur` too. A multi-line
`TextInput` with `ghostText` draws an inline completion after the caret and Tab
fires `onAcceptCompletion`; any edit removes it. `Text` honors `line-through` and
`underline`. Menus passed to `craft.desktop.setMenus` land between Edit and Window,
and one titled `File` goes first after the app menu. A screen with a
`craft.desktop.onQuit` handler holds the quit until its promise settles (a final
save), for 3 seconds at most; an app without one quits at once.

Launch the executable with `--api-url`, `--native-bundle`, `--title`, and an
optional `--route`. The HTTP agent's `/native/session` endpoint must establish
the session cookie. URLSession owns that cookie and shares it between windows.

Use `--titlebar-style transparent` to hide the window title on a transparent
title bar. The default keeps the standard AppKit title bar. `--width`,
`--height`, `--min-width` and `--min-height` configure the main window in points.
Additional windows accept `titlebarStyle: 'standard' | 'transparent'` with the
same size options through `craft.desktop.openWindow`, and `floating: true` keeps
one above other windows.

Links and files other apps open with this one arrive as `CRAFT_EVENT`
`craftDesktopOpenURL` `{ urls }`; ones that came before a screen was listening
wait for `craft.desktop.takeOpenedURLs()`. `isDefaultBrowser()` and
`setDefaultBrowser()` (macOS asks the person to confirm) cover a browser that
declares http and https. `craft-app.json` `dockMenu: [{ title, action }]` fills
the Dock icon's menu; each item arrives as a desktop command.

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
Drop `action-<n>.json` files into the directory and each gets a `result-<n>.json`:
`{ "action": "command", "id" }`, `appearance` (`value`: light or dark), `resize`,
`screenshot`, `close`, `quit`, and, aimed at a control by its testID (`target`),
`press`, `type` (`text`), `submit`, `key` (`key`, `shift`) and `hover` (`value`).

## Text editing, sidebar and shadows

A multi-line `TextInput` reports the caret and selection with `onSelectionChange`
(`{ start, end }`, UTF-16 offsets) and takes a `selection` prop to move it. With the
`markdown` prop the text stays plain markdown, drawn as Notes would show it:
headings, bold, italic, code, quotes, bullets and checklists with finished items struck
through, restyled after every edit. `NativeSidebar` takes `rowHeight` and
`labelFontSize` (24 and 15 give a Things-like source list). `shadow-*` classes draw a
real layer shadow. With `--test-dir`, the driver's `key` action sends `return`, `tab`,
`escape`, `up`, `down` or `backspace` to a text control as a command, so submit and
accept-completion handlers can be exercised without a keyboard.

A Keychain read never waits on a permission prompt: with user interaction turned off an
item the app is not trusted for fails, and the app signs in again, instead of hanging
with no window behind a dialog.

Escape that reaches a window or a text control unhandled arrives in the screen as the
desktop command `escape` (`craft.desktop.onCommand`), unless a ghost completion is
showing. With `--titlebar-style transparent` the content runs under the title bar
(full-size content view): leave room for the traffic lights.
