# Android native navigation fixture

This uses the same three `.stx` screens as the iOS navigation test in
`packages/ios/fixtures/native-navigation`. The compiler produces one route
bundle, and the generated Android app hosts it in native views with a
JavaScriptSandbox isolate per screen.

With a sibling `stx` checkout and an Android SDK/emulator available:

```bash
bun packages/android/scripts/test-native-navigation.ts
```

The instrumentation test checks native control classes, including the `Spinner`
rendered for the `Picker`, rendered route
parameters, push/replace/back (including Android's Back key), retained input
identity and value, text-input submission, and the absence of any `WebView` in
the activity view tree. Scroll callbacks are attached to the underlying Android
scroller rather than the native wrapper, so nested scroll offsets come from the
platform control that actually moves. The FlatList assertion also requires row
layout events to increase after recycled rows are materialized, rather than
assuming a fixed callback count.

The navigation section also verifies the shared runtime lifecycle: a pushed
details screen gets fresh state, `onDestroy` runs after the Android Back path,
and replacement disposes the outgoing screen before the new route is opened.
The native form coverage also keeps a keyed input's draft while changing its
single-line/multiline mode, recreating the incompatible platform control, and
the iOS fixture runs the same mode-transition and recycled-row assertions.
The shared name field is controlled, so its value and caret remain stable
while the native renderer applies each change on both hosts.
Test identities stay in Android view tags, leaving visible text available to
accessibility services unless a label or value is explicitly supplied.
Returning to a retained route reapplies native theme defaults before it becomes
visible, so a dark-mode change while another route is open cannot leave stale
colors behind.
CI uses the stx compiler (`stx native compile`) pinned at `6151b9e73c`. Its
external checkout uses `bun install --no-save` because Pantry's Bun 1.3.14
cannot frozen-install the pinned lockfile; the compiler installs an initial
tree atomically before sending incremental keyed mutations.

`--prepare-only` compiles the `.stx` bundle and generates the Android fixture
without needing an emulator. Set `CRAFT_KEEP_ANDROID_NATIVE_PROJECT=1` to keep
the generated project for inspection. On an emulator failure, the test prints
the activity's native view tree and the harness dumps `CraftNativeAndroid`
errors from logcat.
