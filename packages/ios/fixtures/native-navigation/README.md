# WebView-free native navigation fixture

The three `.stx` screens and `stx-native.config.json` exercise a native push with parameters, an in-app back action, UIKit's back button and edge-swipe, and replace. Home owns a keyboard-configured `TextInput`, `Picker`, submit counter, counter, and keyed `FlatList`; the list covers two-column recycling, header/footer/empty content, row moves, focused-input retention, `onEndReached`, and controlled pull-to-refresh. The native list unit fixture also verifies scroll, drag, momentum, and refresh-control callback forwarding. Returning home must reveal the same values, not a freshly compiled screen. The simulator test also checks that the app exposes no WebView.

Keyed row replacement releases the previous native root before the new row type
is hosted, so old event, image, and pull-to-refresh handlers cannot leak across
reuse.
Returning to a retained route also reapplies native theme defaults before the
controller appears, keeping dark-mode colors current after navigation.
Keyboard frame changes update the controller's additional safe area, keeping the
focused form controls and their `onLayout` measurements responsive.
The form path carries a keyed draft across a single-line/multiline input mode
change even though UIKit must replace the underlying control class. Keyed
FlatList inputs retain their drafts when rows recycle off-screen and return.

From the Craft repository, with the sibling stx checkout at or after
`6c1603f742`:

```bash
bun packages/ios/scripts/test-native-navigation.ts
```

The script verifies that the compiler emitted mutation-protocol support,
generates a temporary iOS app, boots an available simulator, and runs
`NativeNavigationUITests.swift`. CI pins the stx-native compiler commit and
runs the same script on iOS and Android. The pinned compiler sends the initial
tree as one atomic render, then uses keyed mutations for later updates.

`--prepare-only` compiles the `.stx` bundle and generates the Xcode fixture
without requiring an installed or bootable simulator. Set
`CRAFT_KEEP_NATIVE_NAVIGATION_PROJECT=1` to keep the generated project for
inspection; the normal command remains the CI simulator gate.
