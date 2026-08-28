# Android Development

Making Android a Zig-native platform: Zig reaches Android's Java APIs through JNI, the way
`packages/zig/src/macos.zig` reaches AppKit through `objc_msgSend`.

This document is the working plan. It is meant to be checked off, and the phase gates are
meant to be run.

---

## Where Android actually stands

**`zig build build-android` exits 0 and ships nothing.**

```console
$ ls -l zig-out/lib/libcraft-android-arm64.a
-rw-r--r--  2990 bytes

$ ar t zig-out/lib/libcraft-android-arm64.a
/                    ← symbol table (empty)
//                   ← string table
/0                   ← one .o with no exported symbols

$ nm zig-out/lib/libcraft-android-arm64.a | grep -c ' T '
0
```

An empty archive is a legal archive, so the build is green.

**Root cause:** `build.zig:1807-1819` builds a static library rooted at `src/android.zig`,
which has **zero `export fn`**. Zig only emits code reachable from an export — `pub` is
visibility, not linkage.

Because nothing is reachable, `mobile.zig` is never analysed at all, so its `comptime`
`@export` block at `mobile.zig:165-170` never runs, silently dropping the only two `Java_*`
symbols in the codebase. And even if they had survived, they bind to
`app.craft.CraftValueCallback` and `app.craft.CraftActivity` — **classes that exist nowhere
in this repo and that no template could generate.**

Compare iOS, which gets this right: `src/ios_main.zig` has 8 `export fn craft_ios_*` and
`build.zig:1590` roots the library there, not at `ios.zig`. **Android has no equivalent
`android_main.zig`.**

### What does ship

`packages/android/templates/CraftBridge.kt.template` — 3,880 lines of Kotlin with **103**
`@JavascriptInterface` methods — plus a genuinely functional builder
(`packages/android/src/index.ts`, 599 lines) that runs `gradle wrapper`, `./gradlew`,
`adb install -r`, and `adb shell am start -n`.

Good news for the JNI plan: the Kotlin has **no coroutines and no Compose**
(`suspend fun` count: 0). Everything it does is plain Java-API work that JNI can reach.

### The bridge never connects

Three verified mismatches:

| | TypeScript expects | Native provides |
|---|---|---|
| interface name | `window.CraftBridge` | `addJavascriptInterface(craftBridge, "CraftAndroid")` |
| envelope | `{method, params, callbackId}` | 103 typed methods, no `postMessage` at all |
| ready event | `craft:ready` | `craftReady` |

So `window.CraftBridge.postMessage(...)` is a `TypeError` on every call.

---

## Four blockers to clear before anything works

### 1. Android currently links GTK

`bridge.zig:7` switches on `builtin.os.tag`. Android's target is
`.os_tag = .linux, .abi = .android` (`build.zig:1801-1804`), so the `.linux` arm catches it
and routes `evalJS` into `linux.zig` — which holds **44** `extern "c"` GTK/WebKit2GTK
declarations.

Undefined symbols cost nothing in a *static archive*, which is precisely why this has never
surfaced. **The moment we emit a `.so`, the linker demands `gtk_init` and 43 friends.**

The `.linux` arm needs an `.abi == .android` guard, landed **in the same commit** as the
linkage change. `build.zig:1940-1942`'s `linkPlatformLibraries` has the same landmine —
its `.linux` arm links `gtk+-3.0` and `webkit2gtk-4.1`, and the Android libs must never
start calling it without the same guard.

### 2. `{{PACKAGE_NAME}}` makes mangled `Java_*` symbols impossible

`MainActivity.kt.template:1` is `package {{PACKAGE_NAME}}`, substituted with the user's
chosen id. JNI symbol mangling embeds the package, so a fixed export name cannot exist.

**Fix, in two parts:**

1. **Put the native-binding class in a package Craft owns.** A new
   `CraftNative.kt.template` declaring `package app.craft.runtime` — no substitution at all.
   Gradle compiles multiple packages in one module without complaint, and
   `applicationId`/`namespace` are unaffected. Now every native-facing class name is a
   compile-time constant on the Zig side.

2. **Bind via `JNI_OnLoad` + `RegisterNatives`, exporting zero `Java_*` symbols.**

Why `RegisterNatives` rather than mangled names, now that the package is fixed:

- **It fails loudly at load.** A missing binding throws `UnsatisfiedLinkError` during
  `onCreate`, naming the method. Mangled-name binding fails at the first call of that one
  method, months later.
- **The table is enumerable Zig data**, so a conformance test can assert bijection with the
  Kotlin `external fun` declarations. Mangled names give you no artifact to check.
- **It survives R8.** `build.gradle.kts.app.template:22-28` sets `isMinifyEnabled = true`
  for release and `proguard-rules.pro.template` is 9 lines with no keep rule. Add
  `-keep class app.craft.runtime.CraftNative { *; }`.

### 3. The JNI vtable in the tree is mis-ordered

`mobile.zig:25-40` declares `JNINativeInterface` with `reserved0..3`, then jumps straight to
`GetVersion, FindClass, GetMethodID, …` with a literal comment at line 31:

```zig
// ... many more function pointers ...
```

The real vtable has ~230 slots in a fixed ABI order: `FindClass` is index 6,
`GetObjectClass` is 31, `NewStringUTF` is 167. **Every function pointer read from this
struct reads the wrong slot.** Even if it linked, every call would jump to a garbage
address.

There is also a *second*, incompatible `jni` namespace at `android.zig:20-30` — opaque
aliases with no vtable at all.

### 4. Nothing here has ever been compiled

`mobile.zig:11` reads `const jni = if (target.os.tag == .linux) struct {...} else struct {};`
so on a macOS host `jni` is an **empty struct** and `jni.JNIEnv` does not exist.

Proof that no function body has ever been analysed: `mobile.zig:1292` has
`if (callback) |cb|` where the parameter is the non-optional `*const fn (bool) void` — an
unconditional compile error that has never fired.

Other never-executed bugs in the same region: `requestPermission` (`:1275-1298`) resolves
the **static** `ActivityCompat.requestPermissions` via `GetMethodID` and passes 2 varargs
where the signature demands 3 with a `jobjectArray`; `createWebView` (`:1103-1106`) and
`evaluateJavaScript` (`:1198-1206`) invoke constructors through `CallObjectMethod` where
`NewObject` is required.

---

## Architecture

```
page  ──  craft.getPlatform()
            │  craft-mobile.js  →  _req('device', 'getPlatform', d)
            ▼
      window.CraftBridge.postMessage(JSON.stringify({t, a, d, i}))
            │                                   [JavaBridge thread]
            ▼
      CraftNative.postMessage  →  nativeHandleMessage  (RegisterNatives)
            │
            ▼
      android_dispatch.zig  ──  routes on `t`
            │
            ├── Zig arm   →  android_jni.zig  →  Java APIs
            └── host arm  →  CraftNative.callHost(...)   (Phase A6 escape hatch)
            │
            ▼
      format reply ON the JavaBridge thread   ← request_context is threadlocal
            │
            ▼
      CraftNative.evaluateOnUi(script)  →  webView.post { evaluateJavascript }
```

### The threading constraint iOS doesn't have

`@JavascriptInterface` methods run on the WebView's **JavaBridge** thread.
`WebView.evaluateJavascript` **must** be called on the UI thread or it throws.

And `request_context.zig` is `threadlocal` — a frame pushed on JavaBridge is invisible from
the UI thread.

**Therefore: format the reply on the JavaBridge thread, where the context frame lives, then
hand the finished string across.** Three lines of Kotlin:

```kotlin
fun evaluateOnUi(script: String) = webView.post {
    webView.evaluateJavascript(script, null)
}
```

Do not reply from the UI thread. This removes an entire crash class and is worth the Kotlin.

---

## Decision: `@cImport` the NDK's `jni.h`

**Do not hand-write the vtable. Do not vendor a copy of `jni.h`.**

- **A wrong slot index compiles, links, and jumps to garbage at runtime.** `mobile.zig:25-40`
  is the existence proof. There is no compiler check for "is `FindClass` the 7th field?",
  the failure is silent, and it is silent *on a phone*. A 230-slot transcription is 230
  chances to make that mistake, and reviewing it is unreviewable.
- **Cross-compiling from macOS is already solved here.** `build.zig:9` takes `-Dmacos-sdk`
  and `applySdkPaths` (`:1963-1976`) feeds it through `addSystemIncludePath`. Its docstring
  is directly on point about avoiding `--sysroot` because it breaks `@cImport`. Mirror it
  exactly as `-Dandroid-ndk`. `jni.h` is pure C — `stdarg.h` + `stdint.h` — with no Bionic
  dependency, so translate-c reads it on a macOS host.
- **Reproducibility comes from pinning the NDK**, which CI already does
  (`mobile-e2e.yml:164-166` pins `ndk;26.1.10909125`). Pin it in `deps.yaml`/`pantry.jsonc`
  beside the Zig pin.

### Use only the `*A` call forms

`jni.h` declares ~60 slots three times: `CallVoidMethod(...)` (C varargs),
`CallVoidMethodV(va_list)`, and `CallVoidMethodA(const jvalue*)`.

**Use `*A` exclusively.** They are non-variadic and ABI-exact, which sidesteps the pinned
Zig version's one real hazard with variadic function-pointer fields. As a bonus, they
structurally kill the constructor bug class: `NewObjectA` cannot be spelled as
`CallObjectMethodA`.

### The facade earns its keep

`src/android_jni.zig` wraps the `@cImport` and exposes `callVoid(env, obj, mid, args)`-style
helpers that:

1. always use `*A`,
2. call `ExceptionCheck`/`ExceptionDescribe`/`ExceptionClear` after **every** call — a
   pending JNI exception makes the *next* JNI call abort the process, and nothing in the
   current code checks even once,
3. confine `@cImport` to one file, so nothing else becomes un-host-testable and a future
   NDK change touches exactly one place.

### The ABI test the hand-rolled version could never have

Gated on `-Dandroid-ndk` being present:

```zig
@offsetOf(c.JNINativeInterface, "FindClass")       / @sizeOf(usize) == 6
@offsetOf(c.JNINativeInterface, "GetObjectClass")  / @sizeOf(usize) == 31
@offsetOf(c.JNINativeInterface, "NewStringUTF")    / @sizeOf(usize) == 167
@offsetOf(c.JNINativeInterface, "RegisterNatives") / @sizeOf(usize) == 215
@sizeOf(c.JNINativeInterface) / @sizeOf(usize) >= 229    // non-vacuity floor
```

That last line matters: without it, a truncated or empty import passes. Same idiom as
`capabilities_test.zig:92`.

---

## Phase A0 — Demolition

Delete rather than fix. Every one of these is unreachable or actively misleading, and
leaving them means the next reader can't tell new code from fossil.

| Target | Lines | Why |
|---|---:|---|
| `src/android_template.zig` | 553 | Zero importers; a second Gradle/Kotlin generator superseded by `packages/android/templates/` |
| `src/js_bridge.zig` | 635 | Zero importers (the 13 grep hits are struct *field* names, not imports) |
| `test/android_test.zig` | 373 | Not wired into `build.zig` at all; uses the removed pre-0.15 `ArrayList.init(allocator)` at `:323`, so it wouldn't compile if it were |
| `mobile.zig:11-110` — the `jni` namespace | 100 | Mis-ordered vtable; not fixable in place |
| `mobile.zig:162-206` — `@export` block + both `Java_*_impl` | 45 | Bind to classes that don't exist |
| `mobile.zig:1028-1377` — `pub const Android` | 350 | Every call reads the broken vtable; contains the static-method, constructor, and non-optional-callback bugs |
| `mobile.zig:115-160` — `AndroidCallbackStorage` | 46 | A fixed 16-slot `% 16` table that silently aliases the 17th concurrent callback onto the 1st |
| `android.zig:20-30` — the second `jni` namespace | 11 | Opaque aliases, no vtable |
| `android.zig:333-412` — nine "handlers" | 80 | `handleShowToast` extracts the message, discards it, and replies `{"success":true}`. Worse than a missing handler |
| `android.zig:419-493` — `AndroidFeatures` | 75 | Ten stubs; `isNetworkConnected()` hardcodes `true` |
| `android.zig:260-295` — substring JSON | 36 | Breaks on any escaped quote; `std.json` is the house pattern |
| `examples/android/main.zig` + its `build.zig` step | ~40 | Builds a *desktop* Cocoa/GTK executable and calls it the Android demo |

**Keep:** `android.zig`'s `StringHashMap(Handler)` dispatcher shape (`:202-258`) as the seed
for `android_dispatch.zig`, and `packages/android/templates/test-bridges.html` as the
Phase A1 fixture page.

**Gate:** `zig build && zig build test` green; `git grep -c 'jni\.' packages/zig/src` = 0.

---

## Phase A1 — Vertical slice: `device.getPlatform` on an emulator

### Why this action

It **cannot be faked past its own assertion**. CI compares the value the *page* printed
against `adb shell getprop ro.build.version.sdk` and `ro.product.model`. The current stub at
`android.zig:336` returns a hardcoded `{"os":"android","version":"14"}` and would fail.

It also exercises the full vtable surface in one call — `FindClass("android/os/Build$VERSION")`
→ `GetStaticFieldID` → `GetStaticIntField`, plus `GetStringUTFChars`/`ReleaseStringUTFChars`.
If the imported slots were wrong, this crashes rather than lying.

`showToast` was the obvious alternative and is the wrong choice: asserting a Toast from CI
means OCR on a screenshot.

### What lands

**New Zig files:**

| File | Contents |
|---|---|
| `src/android_jni.zig` | `@cImport` of `jni.h`, `*A`-only wrappers, `ExceptionCheck` on every path, `JavaVM*` cache, `attachCurrentThread()` |
| `src/android_main.zig` | **The export root.** `JNI_OnLoad`, the `JNINativeMethod` table, `nativeOnCreate`, `nativeHandleMessage`, `nativeOnDestroy` |
| `src/android_dispatch.zig` | `std.json` parse of `{t,a,d,i}`, `request_context` push/pop, route on `t`, reply via `bridge_error.sendResultToJS` |
| `src/android_log.zig` | `__android_log_write` wrapper + a `std.log` `logFn` override so existing sites land in logcat |
| `src/android_device.zig` | The `device` namespace with one action |

**Zig edits:**

- `bridge.zig:6-21` — an `.android` arm **before** `.linux`, guarded on
  `builtin.abi == .android`. Without this, the `.so` link fails on GTK.
- `build.zig:1807-1848` — root at `android_main.zig`; `.linkage = .dynamic`; name
  `craft_android`; add `-Dandroid-ndk` and `applyAndroidNdkPaths` modelled on
  `applySdkPaths`; `linkSystemLibrary("log")`; `-z max-page-size=16384`.
- `src/js/craft-bridge.js:161-175` — `_post` gains a transport switch:
  `webkit.messageHandlers.craft` → `window.CraftBridge` → warn. **Shared with iOS.**

**Kotlin:**

- New `CraftNative.kt.template` in `package app.craft.runtime`: `System.loadLibrary("craft_android")`,
  `@JavascriptInterface fun postMessage(json: String)`, `fun evaluateOnUi(script: String)`,
  and the `external fun` declarations.
- `MainActivity.kt.template:100` — `"CraftAndroid"` → `"CraftBridge"`, fixing the name
  mismatch against `core.ts:723`.
- Install the bridge script via `WebViewCompat.addDocumentStartJavaScript`
  (`androidx.webkit:webkit:1.12.1` is already a dependency, and `minSdk` is 26) rather than
  at `onPageFinished` (`:70-73`), which any page calling `craft.*` at parse time loses today.
  Dispatch **`craft:ready`**; emit the legacy `craftReady` alongside it for one release.

`CraftBridge.kt` is **still generated and still registered** in Phase A1. The slice must not
regress any existing app.

**TypeScript / packaging:**

- `index.ts` — `init()` writes `app/src/main/java/app/craft/runtime/CraftNative.kt`; a new
  `syncNativeLibs()` copies the `.so` into `jniLibs/{arm64-v8a,x86_64}/`; **`init()` (not
  `build()`) materializes the Gradle wrapper** — today `:341` writes
  `gradle-wrapper.properties` but never `gradlew` itself.
- `build.gradle.kts.app.template` — `ndk { abiFilters += listOf("arm64-v8a", "x86_64") }`.
- `proguard-rules.pro.template` — the keep rule.

### Gate

```bash
zig build build-android-x86 -Dandroid-ndk=$ANDROID_NDK_HOME
llvm-nm -D --defined-only  …/libcraft_android.so | grep -q ' T JNI_OnLoad'
llvm-nm -D --undefined-only …/libcraft_android.so | grep -c 'gtk_\|webkit_'   # must be 0
llvm-readelf -l …/libcraft_android.so | grep LOAD | grep -q 0x4000            # 16KiB, Android 15+
craft android init E2E --output /tmp/e2e && craft android build --output /tmp/e2e
unzip -l …/app-debug.apk | grep -q 'lib/x86_64/libcraft_android.so'
adb install -r … && adb shell am start -n …/.MainActivity
adb logcat -d | grep CRAFT_RT > out
test "$(jq -r .sdkInt <out)" = "$(adb shell getprop ro.build.version.sdk)"
test "$(jq -r .model  <out)" = "$(adb shell getprop ro.product.model)"
```

`WebChromeClient` is already set (`MainActivity.kt.template:97`) and forwards `console.log`
to logcat.

### Deferred

102 of the 103 Kotlin methods (Kotlin keeps serving them); permissions; `onActivityResult`;
event emission; arm64 exercise (builds, not tested); release/R8 builds;
`AttachCurrentThread`; `PushLocalFrame`; the capability gate (A2).

### Risks

| Risk | Detection | Mitigation |
|---|---|---|
| **GTK link failure** — the likeliest blocker | Fires at the first `.so` link | Land the `bridge.zig` guard *before* flipping linkage; assert 0 undefined `gtk_` symbols |
| `FindClass` returns null in `JNI_OnLoad` | `UnsatisfiedLinkError` at load | Fall back to one mangled `Java_app_craft_runtime_CraftNative_nativeBoot` called from Kotlin's static init, receiving `jclass` directly |
| Replying off the UI thread | Silent dropped reply | The `evaluateOnUi` shim; detect via zero `E/chromium` lines |
| 16 KiB page alignment | `.so` refuses to load on Android 15+ | `llvm-readelf -l` assertion above |
| ABI directory naming | Zig emits `x86_64`/`aarch64`; jniLibs wants `x86_64`/`arm64-v8a`. A mismatch silently ships an APK with no native lib | The `unzip -l` assertion |

---

## Phases A2–A6

| Phase | Scope | Gate |
|---|---|---|
| **A2** | Extract `macos.zig:4564-4645` into a shared `mobile_dispatch.zig` (iOS gets it free). Generalize `capabilities_test.zig`, which hardcodes desktop `@embedFile`s. Add the `RegisterNatives` ↔ Kotlin `external fun` parity test | `zig build test` fails on any drift |
| **A3** | **Tier 0** (~20): pure JNI, no permissions, no async — `getDeviceInfo`, `getNetworkStatus`, `log`, `openURL`, `share`, `clipboard*`, `vibrate`, `haptic`, `setBadge`, `setKeepAwake`, `lockOrientation`, `setFlashlight` | `adb shell` ground truth per action (`cmd clipboard`, `dumpsys deviceidle`) |
| **A4** | **Tier 1** (~25): state, storage, callbacks. First background threads → `AttachCurrentThread`. **`dbExecute`/`dbQuery` use the vendored SQLite** already compiled into every other target (`build.zig:1953-1959`), not JNI to `SQLiteDatabase` | Round-trip through the bridge + `dumpsys jobscheduler` |
| **A5** | **Tier 2** (~30): permissions and Activity results | `pm grant`/`revoke`; **the denied path must reply with an error, not hang** |
| **A6** | **Tier 3** (~28): Play Billing, ML Kit, Firebase, Health Connect, ARCore, Wear | Kotlin `@JavascriptInterface` ratchet reaches its floor |

**A3 adds `PushLocalFrame`/`PopLocalFrame`** per handler, before `Intent`/`Uri` construction
turns into a reference leak nobody can find.

**A5 lands the two mechanisms as their own sub-phase before any action uses them.** Two new
`RegisterNatives` entries (`nativeOnPermissionResult`, `nativeOnActivityResult`) fed from
`MainActivity.kt.template:220-224`'s existing hook. Correlation needs a real
`AutoHashMap(i32, PendingRequest)`, not a `% 16` array.

`ActivityCompat.requestPermissions` is **static** (`GetStaticMethodID`,
`CallStaticVoidMethodA`) and takes **three** args with a `jobjectArray` built by
`NewObjectArray` + `SetObjectArrayElement`. `mobile.zig:1275-1298` gets both wrong and is
the best worked example of what not to do.

### A6: one declared escape hatch, not a JNI slog

BillingClient, ML Kit, Play Review, Firebase, Health Connect, and ARCore are listener-heavy,
generic-heavy builder APIs. Reaching them from JNI means hand-writing anonymous inner
classes, which JNI cannot do at all without a Java shim. There is no Zig-purity win
available; there is only a large, fragile, unreviewable surface.

Instead: Zig calls `CraftNative.callHost(namespace, action, dataJson, requestId)`, and
Kotlin answers through the **same** `nativeDeliverResult(requestId, json)` every other path
uses. Zig still owns dispatch, correlation, capability truth, and the wire format. Kotlin
becomes a leaf.

Add `host_delegated` as a fifth `NamespaceStatus` beside `declared`, `undeclared`,
`unavailable`, and `unrouted` (`capabilities.zig:64-73`), so `craft.capabilities()` tells
apps honestly which surfaces are native-Zig and which are host-delegated. That is the same
ethos as the existing "a namespace craft hasn't audited says so", extended one step.

Only then delete the superseded Kotlin — expected residue 25–30 methods, down from 103.

---

## The conformance gate

`max_undeclared = 0` for Android, **permanently**. Desktop's ratchet sits at 45
(`capabilities_test.zig:57`) only because it inherited 52 unaudited namespaces. Android
starts from an empty tree and has nothing to grandfather, so there is no reason to ever
permit an undeclared Android namespace. This is the cheapest place to hold the line, and it
is only cheap *now*.

Three gates:

1. **`test/capabilities_android_test.zig`** — every declared action dispatches; every
   dispatched action is declared; a declared namespace contains no raw literal action
   comparison. With a non-vacuity floor so a regex matching nothing fails.
2. **`RegisterNatives` ↔ `CraftNative.kt` parity** — embed the template, scan `external fun`,
   assert bijection with the Zig table including JNI signature strings. This is what makes
   `RegisterNatives` worth choosing over mangled names.
3. **Kotlin-surface ratchet** — embed `CraftBridge.kt.template`, count `@JavascriptInterface`
   (103 today), assert `<= max_kotlin_javascript_interface`, and lower the constant each
   phase. The spec becomes a countdown with a build-enforced direction.

---

## CI

### `ci.yml` — every PR, no emulator, ~2 min

After `zig build test` on the Linux leg:

```bash
sdkmanager --install "ndk;26.1.10909125"
zig build build-android-all -Dandroid-ndk=$ANDROID_NDK_HOME -Doptimize=ReleaseSafe
llvm-nm -D --defined-only  …/libcraft_android.so | grep -q ' T JNI_OnLoad'
llvm-nm -D --undefined-only …/libcraft_android.so | grep -c 'gtk_\|webkit_' | grep -q '^0$'
llvm-readelf -l …/libcraft_android.so | grep LOAD | grep -q 0x4000
test "$(stat -c%s …/libcraft_android.so)" -gt 100000
```

**That size floor is the direct answer to the 2,990-byte archive: an empty artifact must
fail the build.** The `gtk_` check is the standing guard on the `bridge.zig` regression.

### `mobile-e2e.yml` — currently proves nothing

The Android job boots an AVD, takes a screenshot, and asserts nothing, because its only test
step is behind `if [ -x "packages/android/gradlew" ]` — a path that **can never exist**,
since projects are generated into a user-chosen `--output` directory.

- Restore `pull_request` triggers on `packages/zig/src/android_*.zig`, `packages/android/**`, `build.zig`
- Delete the `gradlew` guard
- Replace the emulator script with the Phase A1 chain
- Keep screenshots as **artifacts**, not tests

`release.yml` is not touched.

### `packages/android/src/index.ts`

1. `init()` materializes the Gradle wrapper and fails loudly there — a project is either
   complete or absent
2. `syncNativeLibs()` copies the `.so` per ABI
3. Writes `CraftNative.kt` with **no** `{{PACKAGE_NAME}}` substitution
4. `build()` fails when the `.so` is missing, rather than producing an APK that
   `UnsatisfiedLinkError`s at launch
5. `index.test.ts` asserts `jniLibs/`, `gradlew`, `CraftNative.kt`, and the `"CraftBridge"`
   registration

Per `CLAUDE.md`'s distribution rule, the `.so` resolution lives here in the Android builder
— a legitimate dev-loop override — not in `binary-resolver.ts`.

---

## Prerequisites

| | Needed | Status |
|---|---|---|
| Phase A0 | pinned Zig only | ✅ works today |
| Phase A1+ | Android SDK, NDK (pinned `26.1.10909125`), `adb`, `gradle` | ❌ none present |

Zig is pinned at `0.17.0-dev.1509+bb296ab9b`.

---

## Honest accounting

Android is further from working than iOS: iOS has nine concrete compile errors, while
Android has no JNI layer at all. But Android has one advantage — everything it needs to
reach is plain Java API, with no Kotlin-only surface in the way.

The `host_delegated` escape hatch in A6 exists so the last 28 actions don't become an
open-ended JNI slog. And `CraftBridge.kt` keeps serving every action Zig hasn't taken over,
so no phase ships a broken app.
