# WebView-free iOS smoke screen

This `.stx` screen exercises the UIKit + JavaScriptCore host without creating a `WKWebView`. It covers a button update, text input, device info, clipboard read/write, an invalid argument, and haptics.

From the Craft repository, with a sibling stx checkout:

```bash
bun ../stx/packages/stx-native/src/cli/index.ts compile packages/ios/fixtures/native-screen/Screen.stx --format bundle --output /tmp/craft-native-screen.js
craft ios init NativeSmoke --renderer native --output /tmp/craft-native-smoke
craft ios build --output /tmp/craft-native-smoke --native-bundle /tmp/craft-native-screen.js
craft ios run --output /tmp/craft-native-smoke --simulator
```

For the enabled run, set `enableHaptics` and `enableClipboard` to `true` in `/tmp/craft-native-smoke/craft.config.json` before building. Type a name, write it to the clipboard, and read it back. “Write invalid value” should show `INVALID_ARGUMENT`; “Play haptic” should show `Haptic accepted` (the simulator cannot physically vibrate). For the disabled run, set both flags to `false`, rebuild and reinstall. Clipboard and haptic taps should show `CAPABILITY_DISABLED`, while device info should still show `iPhone`.

The native mode is opt-in. The generated `Sources/CraftNativeScreen.swift` creates UIKit controls directly; `Sources/NativeSmokeApp.swift` selects that host when `renderer` is `native`. The existing WebView path remains the default for other apps.

## Renderer regression tests

Run `bun packages/ios/scripts/test-native-render.ts` from the Craft repository on a Mac with XcodeGen and an iOS simulator. It generates a temporary native app and runs simulator-hosted XCTest: a unit test checks that keyed UIKit controls keep their object identity through property changes and moves, while a UI test types through repeated label and button updates without losing the keyboard. The test bundle is deliberately plain JavaScriptCore input so CI does not need a sibling stx checkout. The `.stx` fixture above remains the compiler integration smoke screen.

Within one parent, use a unique `key` on children whose identity must survive reordering. The current compiler emits it as `props.key`; the native host also accepts a top-level IR `key` and uses `testID` for existing screens. Unkeyed children are matched by position. Duplicate sibling keys fall back to position, so they cannot promise identity through moves.
