# WebView-free native navigation fixture

The three `.stx` screens and `stx-native.config.json` exercise a native push with parameters, an in-app back action, UIKit's back button and edge-swipe, and replace. Home owns a `TextInput` and counter; returning to it must reveal the same values, not a freshly compiled screen. The simulator test also checks that the app exposes no WebView.

From the Craft repository, with the sibling stx checkout at or after
`fa5b1e1673`:

```bash
bun packages/ios/scripts/test-native-navigation.ts
```

The script verifies that the compiler emitted mutation-protocol support,
generates a temporary iOS app, boots an available simulator, and runs
`NativeNavigationUITests.swift`. CI pins the stx-native compiler commit and
runs the same script on iOS and Android.
