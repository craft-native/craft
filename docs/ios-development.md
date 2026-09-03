# iOS Development

Making iOS a Zig-native platform: Zig drives UIKit through `objc_msgSend`, exactly as
`packages/zig/src/macos.zig` drives AppKit today.

This document is the working plan. It is meant to be checked off, and the phase gates are
meant to be run.

---

## Where iOS actually stands

Three facts, each verified, that together explain why "iOS is broken" has been true for
months without anyone being able to point at a single cause.

**1. The Zig iOS sources have not compiled since 2026-05-07.** The Zig 0.17 migration
(`1b6f285`) broke them; on 2026-08-18 the mobile E2E workflow was made
`workflow_dispatch`-only (`e1bc449`) rather than repaired. `zig build build-ios-simulator`
fails with 9 errors.

**2. Nothing links the Zig library anyway.** There are no references to `craft_ios_*`,
`@_silgen_name`, or `libcraft` anywhere in `packages/ios/`. The XcodeGen spec
(`templates/project.yml.template`) sets no `LIBRARY_SEARCH_PATHS` and names no `.a`. Even a
green Zig build would be dead weight.

**3. What actually ships is Swift.** `packages/ios/templates/CraftApp.swift` is 5,169 lines
with **106** dispatcher actions and a properly registered `WKScriptMessageHandler`. It
works. `craft ios init/build/open/run` shells out to `xcodegen`, `xcodebuild`, and `simctl`,
and those work too.

So the goal is not "repair the Zig build." It is to move the native layer from Swift to Zig
without ever having a non-working app in between.

### The spec has already drifted inside one file

`CraftApp.swift`'s injected JavaScript calls five `ota*` actions — `otaConfigure`,
`otaCheckForUpdate`, `otaDownloadUpdate`, `otaApplyUpdate`, `otaRollback` — that its own
`switch` handles **zero** times. Those promises never settle; they don't even time out,
because the OTA methods bypass the `_createCallback` path that owns the timeout.

A further 33 handled actions are unreachable from the injected JS.

That is one file disagreeing with itself. The conformance gate in Phase 2 exists to make
this class of bug impossible rather than merely fixed.

---

## Counting actions correctly

The dispatcher region (`CraftApp.swift:516-1078`) holds exactly **106** distinct actions.

A naive `grep 'case "'` over the whole file returns **139**, because sub-switches use string
cases for haptic styles, permission names, orientations, health types, and AR primitives.

**Any scanner must bound itself to the dispatcher region**, or it will fail forever on
`case "box"`.

---

## Architecture

```text
page  ──  craft.getDeviceInfo()
            │  craft-mobile.js  →  _req('mobile', 'getDeviceInfo', d)
            ▼
      window.webkit.messageHandlers.craft.postMessage({t, a, d, i})
            │
            ▼
      WKScriptMessageHandler  (Zig, registered at runtime)
            │
            ▼
      ios_dispatch.zig  ──  routes on `t`
            │
            ├── Zig arm    →  bridge_*.zig  →  sendResultToJS
            └── Swift arm  →  CraftSwiftShim  (shrinks each phase)
```

### One envelope: `{t, a, d, i}`

There are currently **five** incompatible bridge envelopes in the repo. iOS adopts the
desktop one.

Reply correlation is the hardest part of a bridge, and the desktop implementation is
already written and tested — dual pending tables, per-call timeout, and a `_forget` so a
late reply cannot settle someone else's call (`craft-bridge.js:203-233`), with
`formatResultJS` stamping the request id from `request_context`
(`bridge_error.zig:221-241`).

Adopting Swift's envelope instead would mean rewriting all of that, including its reply
escaping at `CraftApp.swift:2447`, which replaces only `'` — so any payload containing a
backslash or a newline breaks out of the JS string literal. `bridge_error.escapeJsonString`
already handles this correctly.

Compatibility for page code written against `window.craft.getDeviceInfo()` comes from a JS
shim, **not** from a second wire protocol. Shipping a second reply protocol "temporarily"
is exactly how five accumulated.

### What we get for free

- `objc_runtime.zig` is already iOS-ready — its gate is
  `is_darwin = .macos or .ios or .tvos or .watchos` (`objc_runtime.zig:6`).
- `macos.zig:5071` `setupScriptMessageHandler` and `macos.zig:5017` `didReceiveScriptMessage`
  use only the ObjC runtime, Foundation, and WebKit — **zero AppKit** — and register under
  the name `"craft"`, which is what the page already posts to.
- `craft-bridge.js:161-166` already builds `{t,a,d,i}` and posts to
  `webkit.messageHandlers.craft`. iOS *is* WKWebView, so **the page side needs no change**.
- Adding a `.ios` arm to `bridge.evalJS` (`bridge.zig:6-22`, currently
  `error.UnsupportedPlatform`) lights up every existing `bridge_*.zig` reply path. Six lines.
- ~20 of the 25 frameworks `CraftApp.swift` imports are Objective-C and reachable via
  `objc_msgSend`.

---

## Phase 0 — Amputate, then gate

**Needs no Xcode.** All of it works on Command Line Tools.

Most of the nine reported errors live in code that should not exist, so deletion comes
before repair.

### Delete

| Target | Lines | Why |
|---|---:|---|
| `src/js_bridge.zig` | 635 | Zero importers |
| `src/ios_template.zig` | 633 | Zero importers; superseded by `packages/ios/templates/` |
| `src/hotreload_mobile.zig` | 271 | Zero importers; won't compile under 0.17 |
| `packages/typescript/src/bridge/ios.ts` | 1,004 | A fourth envelope, zero importers, not exported |
| `ios.zig:556-846` — the `JSBridge` struct | ~290 | Substring JSON parsing (`extractJsonObject`'s unguarded `depth -= 1` underflows a `usize`); nine handlers calling four functions that don't exist; `handleMessage` has no caller anywhere |
| `ios.zig:479-489` — `runMainLoop` | 11 | `UIApplicationMain` owns the run loop |
| `ios.zig:199-263` — `injectBridgeScript` | 65 | Third envelope; injected before the navigation that wipes it; its fallback resolves `{success:true, browser:true}`, making "works" and "no bridge" indistinguishable |
| `mobile.zig:972-1024` — `showAlert` | 53 | Uses `keyWindow`, nil in any scene-based app; computes a delay and discards it |
| `mobile.zig:797-884` — `requestPermission` | 88 | `_ = callback;` at `:803` — discards the caller's callback and passes `null` for every completion handler |
| `mobile.zig:667-795` — `checkPermissionStatus` + mappers | 129 | Only caller is the deleted `JSBridge` |
| `ios_main.zig:211-223` — the export test block | 13 | The source of errors 1–3; asserts nothing a compiler wouldn't |

**~3,200 lines**, removing six of the nine errors and three of the five `??*anyopaque`
sites without writing a replacement.

### Then fix what remains

- `objc_runtime.zig:182,193` — `target.isDarwin()` → `target.os.tag.isDarwin()` (pre-0.17 API)
- `objc_runtime.zig` — add `pub fn alloc(class: Class) !id` beside `allocInit`. `ios.zig:283`
  needs the alloc half only, because `:284-286` sends `initWithFrame:` itself
- `ios.zig:438` — `?objc.id` → `objc.id` in `LoadHTMLFn`
- `mobile.zig:475-477` — `trackObject` takes `*anyopaque`; unwrap or skip when null
- `mobile.zig:484` — `@ptrCast` cannot discard optionality; add the null check

### The gate

New `packages/zig/test/ios_surface_test.zig`, wired into `test_step` like `mobile_tests`:

```zig
test "every iOS decl compiles" {
    std.testing.refAllDeclsRecursive(@import("../src/ios.zig"));
    std.testing.refAllDeclsRecursive(@import("../src/mobile.zig").iOS);
}
```

This builds for the **host** in seconds. `mobile_test.zig` is green today only because it
touches enums and structs and Zig analyses function bodies lazily — this forces analysis,
and every one of the nine errors plus the five latent ones becomes a host-visible compile
error. Cross-compiling stays the source of truth; this is the loop to iterate in.

**Gate:** `zig build test` passes, and passes *only after* the fixes — verify by reverting
one and watching it fail. `zig build build-ios-simulator` and `zig build build-ios` both
compile.

---

## Phase 1 — Vertical slice: `getDeviceInfo` on a simulator

**Needs Xcode.**

One action, round-tripped end to end, observed from inside the Zig process.

### Why this action

- It is a **real spec action** (`CraftApp.swift:647`), so nothing is thrown away later.
- It reads UIKit through `objc_msgSend` — `[[UIDevice currentDevice] systemName]`,
  `[[UIScreen mainScreen] bounds]` — proving the runtime is alive in-process.
- Its result is **unforgeable**: `"systemName":"iOS"` and `"isSimulator":true` cannot come
  from a fallback path. Compare `ios.zig:239-244`, whose fallback returns `{success:true}`
  and looks exactly like success.

Rejected, and worth recording why: `haptic` is fire-and-forget *and* a silent no-op on the
simulator, so it would pass while doing nothing. `clipboardRead` triggers iOS 16+'s "Allow
Paste?" prompt — a flake generator in CI. `showAlert` needs someone to dismiss it.

### What lands

1. **`UIApplicationMain` restructure.** `run()` shrinks to: register a `CraftAppDelegate`
   class at runtime, then call `UIApplicationMain` — which never returns, so `run()` becomes
   `noreturn`. Everything currently at `ios.zig:145-172` moves into
   `export fn didFinishLaunching(...) callconv(.c) bool`, added under
   `application:didFinishLaunchingWithOptions:` with type encoding `"B@:@@"`.

   This is forced, not stylistic: `[UIScreen mainScreen]` returns nil before UIKit is
   initialised, so `createWindow`'s `initWithFrame:` currently receives a garbage `CGRect`,
   and `makeKeyAndVisible` traps with no `UIApplication` instance.

2. **A real `WKScriptMessageHandler`** — port `macos.zig:5071-5122` and `:5017-5066`
   structurally unchanged, including the `NSJSONSerialization` step. Do not write an ObjC
   object walker; do not resurrect substring parsing.

3. **User script at `atDocumentStart`** — port `macos.zig:4037-4049`.

   **The order inverts.** `addScriptMessageHandler:name:` and `addUserScript:` both go on
   the `WKUserContentController`, which must be attached to the `WKWebViewConfiguration`
   *before* the webview is constructed. Today `ios.zig:154` injects before `:157` navigates,
   so the navigation wipes the script.

4. **`.ios` arm on `bridge.evalJS`**, plus `ios.evalJS` mirroring `macos.zig:4485-4496`.

5. **A correct completion block.** `mobile.zig:555-646` is wrong four ways: `??*anyopaque`
   parameters; a `Block.callback` signature mismatch against the function's own parameter;
   a **stack-allocated** block handed to an asynchronous API; and a function-local
   descriptor that dangles even if the block were copied, since `_Block_copy` copies the
   block body but keeps the descriptor *pointer*.

   Rewrite to `bridge_permissions.zig:131-164`'s shape: module-level `const` block and
   descriptor, plain `objc.id` parameters, `extern var _NSConcreteStackBlock` with `&`.

6. **`src/bridge_mobile.zig`** with exactly one action, plus a `t == "mobile"` arm in a new
   `ios_dispatch.zig`.

7. **`packages/ios/fixtures/zig-slice/`** — checked in. `main.m` is a three-line shim so
   `_main` lives in the app target rather than the static archive.

### Gate

A **closed** loop, not a half loop: page posts → Zig serves → Zig replies → **Zig then
evaluates `window.__craftSliceAck` through the block from step 5** and prints
`CRAFT_SLICE_ACK <json>` to stderr. That final hop is what forces the block to be correct
in Phase 1, where it belongs, since Phases 4–6 are built on it.

`packages/ios/src/slice.test.ts` reuses the existing `pickSimulator` and `bootSimulator`
(`index.ts:632,665`) and asserts `"systemName":"iOS"` and `"isSimulator":true` within 90s.
It **skips rather than fails** when `xcode-select -p` reports Command Line Tools, so the
repo stays green on machines without Xcode.

Belt and braces: also write the ack into the app container and poll
`simctl get_app_container`, since `--console-pipe` can drop stderr on a cold boot.

### Deferred

`craft-bridge.js` injection; the Swift shim; error replies; main-thread marshalling; config
plumbing (`AppConfig.orientations`, `status_bar_style` stay inert fields); and the other 105
actions — `ios_dispatch` answers `UNKNOWN_ACTION` for all of them, in one place.

### Risks

| Risk | Detection | Mitigation |
|---|---|---|
| Dead-strip removes `craft_ios_main` | Link error | It's referenced from `main.m`; else `-force_load` |
| Zig `bool` ≠ ObjC `BOOL` on arm64 | App launches to black, no crash | `BOOL` is `signed char`; if it fails, return `i8` `1` |
| `_NSConcreteStackBlock` unresolved | Link error | In libSystem; proven on macOS by `bridge_permissions.zig` |
| `--console-pipe` drops stderr | Timeout, no output | The app-container fallback above |

---

## Phase 2 — Dispatcher, JS surface, and the hand-off

`ios_dispatch.zig` becomes a real dispatcher: namespace routing, `sendErrorToJS` for unknown
actions, `request_context` push/pop around every dispatch. Note `macos.zig:4646-4665` — the
desktop bug where `handleMessage` discarded `d`. Do not repeat it.

**The hand-off table is what makes everything after this incremental.** On an action it does
not serve, `ios_dispatch` looks up `objc_getClass("CraftSwiftShim")` and sends
`handleAction:payload:callbackId:`. One app, one message handler, one page-visible surface.
Each later phase moves actions from the Swift arm to the Zig arm and the page notices
nothing.

`src/js/craft-mobile.js` — deliberately **not** `craft-bridge.js`, which defines
`craft.window.*`, `craft.tray.*`, and `craft.menu.*` that iOS has no business exposing (a
page calling `craft.tray.create()` on iOS should get a clear error, not silence). Extract
the shared transport into `craft-bridge-core.js` and `@embedFile` it into both, so there is
one transport rather than two.

Also here: the Swift shim's reply helpers get rewritten to call `__craftBridgeResult`,
which incidentally fixes the `'`-only escaping at `CraftApp.swift:2447`.

---

## Phases 3–9

| Phase | Adds | Gate |
|---|---|---|
| **3** | +24 — no permission, no UI, no delegate: `log`, `clipboardRead/Write`, `haptic`, `openURL`, `setBadge`, `getSafeArea`, `setKeepAwake`… | A driver calling all 24, asserting 24/24 **and a floor** so a driver that finds nothing fails |
| **4** | +10 — permissions and Keychain | **Two concurrent** permission requests resolve to the *right* promises |
| **5** | +12 — presented UI, on a shared `ios_delegate.zig` class factory | XCUITest cancels each presenter; the rejection must reach JS |
| **6** | +19 — long-lived subscriptions, `craft:*` events | `simctl location set 37.33,-122.03` → `craft:locationUpdate` with those coordinates |
| **7** | +15 — contacts, calendar, notifications, health, db | Needs the SQLite fix below; watch `binary-size.yml` |
| **8** | Swift 5,169 → ~600 lines | Conformance intersection empty |
| **9** | +3 Vision. **AR stays Swift**, declared with a `reason` | Registry declares the boundary honestly |

**Phase 3 fixes `getSafeArea`**, which currently queries the *window* (`ios.zig:498`) and
therefore returns zeros. It needs the root view's `safeAreaInsets`.

**Phase 3 also fixes `HapticType`.** `mobile.zig:887` has the seven real tags
(`selection`, `impact_*`, `notification_*`); `ios.zig:756-761`'s six names were fiction.

**Phase 4 is the highest-risk phase after Phase 1**, because it is the first time a reply is
produced *outside* the dispatch that requested it. `request_context.current()` is a
per-dispatch stack, so by the time an `AVCaptureDevice` completion block fires it is empty,
`formatResultJS` stamps `null`, and correlation silently falls back to action name — which
hands caller B's answer to caller A whenever two are in flight.

This phase must land a **pending-request table** keyed by the `i` captured at dispatch. Do
Keychain first (`SecItemAdd` is plain C with no blocks) to keep the two risks separate.

**Phase 7 requires a build change.** `linkPlatformLibraries` adds `vendor/sqlite/sqlite3.c`
(`build.zig:1955`) but is never called for any iOS target — the calls are at
`:84,128,150,328,798,1519,1543,1566`, and the iOS targets are `:1586-1648`. `dbExecute` and
`dbQuery` cannot work until SQLite is linked in.

**Phase 9 recommendation: keep ARKit and SceneKit in Swift permanently.** `CraftApp.swift:4996-5054`
is SceneKit node-graph manipulation; through `objc_msgSend` it would be miserable and
low-value. Zig-native is a means, not an end, and five actions of SceneKit glue is where it
stops paying. Declare the boundary in `capability_registry.zig` with a `reason`.

### What stays Swift, permanently

Thirteen actions have no usable Objective-C surface:

- **StoreKit 2** — `getProducts`, `purchase`, `restorePurchases` (`Product.PurchaseResult` is Swift-only)
- **ActivityKit** — `startLiveActivity`, `updateLiveActivity`, `endLiveActivity`
- **WidgetKit** — `updateWidget`, `reloadWidgets`
- **App Intents** — `registerSiriShortcut`, `removeSiriShortcut`
- **WatchConnectivity** — `sendToWatch`, `updateWatchContext`, `isWatchReachable` (`WCSession`
  *is* ObjC, but it is only useful paired with the Watch app template, so it stays with its peer)

---

## The conformance gate

`packages/zig/test/ios_conformance_test.zig`, wired like `capability_conformance_tests`
(`build.zig:786-819`). It embeds four sources and asserts four directions:

| Assertion | Catches |
|---|---|
| **spec ⊆ (zig ∪ shim ∪ not_yet)** | An action silently dropped in migration. `not_yet` is explicit, with a **ratchet that may only go down** — like `max_undeclared` at `capabilities_test.zig:57`. Starts at 105 after Phase 1 |
| **zig ∩ shim = ∅** | Two servers for one action, where the page gets whichever raced |
| **js ⊆ (zig ∪ shim)**, no allow-list | The `ota*` class — a JS method whose promise nothing can settle. `CraftApp.swift` fails this **five times today** |
| **(zig ∪ shim) ⊆ js** modulo `internal_only` | The 33 actions reachable only by hand-writing `postMessage` |

Use `window_lifecycle_test.zig:52-65`'s `callsFunction` helper so a commented-out
`// case "haptic":` doesn't count as an implementation — that is exactly the failure mode a
substring scan invites.

Bound the spec scan to the dispatcher region, and assert a floor, so a refactor that renames
the function makes the scan find zero and **fail** rather than pass.

### Extend it to TypeScript

`api/mobile.ts:169` calls `craft.device.getInfo()` — a `craft.<ns>.<method>` shape no native
side has ever provided. `packages/react/src/index.ts:6` declares `os_version` where Swift
returns `systemVersion`.

A bun test asserting every `craft.*` method the TS types promise actually exists in
`craft-mobile.js` closes the third leg. Without it, Zig↔Swift is pinned and the TypeScript
contract drifts on its own — which is how this happened in the first place.

---

## CI

`mobile-e2e.yml` today boots a simulator and asserts nothing: both meaningful steps are
gated on `hashFiles('packages/ios/TestApp/TestApp.xcodeproj')`, which has never matched.

- Restore `pull_request` triggers for `packages/zig/src/ios*.zig`, `packages/zig/src/mobile.zig`,
  `packages/ios/**`
- Fix the two path filters the header comment flags as pointing at directories that don't exist
- Replace the `hashFiles` guards with the checked-in fixture
- Keep screenshots as **artifacts**, not tests

`release.yml` is not touched. The Apple signing gate stays exactly as it is.

---

## Prerequisites

| | Needed | Status |
|---|---|---|
| Phase 0 | nothing beyond the pinned Zig | ✅ works today on Command Line Tools |
| Phase 1+ | full Xcode — SDK, simulator runtime | ❌ install required |

Zig is pinned at `0.17.0-dev.1963+e00c6c439`. Clear `.zig-cache` between heavy rounds.

---

## Honest accounting

This replaces working Swift with Zig. The payoff — one implementation instead of three,
enforced by a compiler and a conformance test rather than by convention — does not arrive
until Phase 8.

The hand-off table exists so that every phase before then ships a **working app**, not a
half-migrated one. If this effort stalls at any point, the app still runs: Swift keeps
serving everything Zig hasn't taken over yet.
