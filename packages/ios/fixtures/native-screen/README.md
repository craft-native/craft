# WebView-free iOS smoke screen

This `.stx` screen exercises the UIKit + JavaScriptCore host without creating a `WKWebView`. It covers a button update, text input, device info, clipboard read/write, an invalid argument, and haptics.

From the Craft repository, with `@stacksjs/stx`'s `stx` CLI available:

```bash
stx native compile packages/ios/fixtures/native-screen/Screen.stx --format bundle --output /tmp/craft-native-screen.js
craft ios init NativeSmoke --renderer native --output /tmp/craft-native-smoke
craft ios build --output /tmp/craft-native-smoke --native-bundle /tmp/craft-native-screen.js
craft ios run --output /tmp/craft-native-smoke --simulator
```

When testing an unreleased sibling checkout, set `STX_CLI=../stx/packages/stx/bin/cli.ts`
for Craft's fixture scripts. Native support is part of `@stacksjs/stx`; do not
install or invoke the historical `stx-native` package or compiler.

For the enabled run, set `enableHaptics` and `enableClipboard` to `true` in `/tmp/craft-native-smoke/craft.config.json` before building. Type a name, write it to the clipboard, and read it back. “Write invalid value” should show `INVALID_ARGUMENT`; “Play haptic” should show `Haptic accepted` (the simulator cannot physically vibrate). For the disabled run, set both flags to `false`, rebuild and reinstall. Clipboard and haptic taps should show `CAPABILITY_DISABLED`, while device info should still show `iPhone`.

The native mode is opt-in. The generated `Sources/CraftNativeScreen.swift` creates UIKit controls directly; `Sources/NativeSmokeApp.swift` selects that host when `renderer` is `native`. The existing WebView path remains the default for other apps. The unit suite also checks that malformed native `fetch` options (relative URLs, GET bodies, non-string bodies, and non-string headers) are rejected before any network request, matching the Android host.

## Renderer regression tests

Run `bun packages/ios/scripts/test-native-render.ts` from the Craft repository on a Mac with XcodeGen and an iOS simulator. It generates a temporary native app and runs simulator-hosted XCTest: a unit test checks that keyed UIKit controls keep their object identity through property changes and moves, while a UI test types through repeated label and button updates without losing the keyboard. The test bundle is deliberately plain JavaScriptCore input so CI does not need a sibling stx checkout. The `.stx` fixture above remains the compiler integration smoke screen.

To select a case, use the full XCTest target/class/method identifier, for example
`CRAFT_ONLY_TESTING=NativeRenderUITests/NativeRenderUITests/testTypingAndButtonUpdatesDoNotDropTheKeyboard`.
The runner checks the result bundle and rejects zero tests or skipped cases,
including Xcode's successful exit for an unmatched selection.

Picker interruption tests first assert that the actual document/photo/video
picker is visible. XCTest then backgrounds the app, whose fixture receives the
public `APP_STATE` event and sends `API_CANCEL` or `NAVIGATE_REPLACE` once. On
return, the test verifies dismissal, callback counts and a working retry. This
handshake replaces an eight-second timer that could close the picker before a
loaded CI accessibility server observed it. No cancellation implementation is
injected into the native host, and the existing dismissal deadlines remain.
For document cancellation the observed element is the Files navigation bar;
the Cancel action can remain an accessibility placeholder during cold startup.
The subsequent user-cancel retry still requires and taps the real Cancel button.

`HeartRateUnitTests.swift` decodes Heart Rate Measurement (0x2A37) payloads (uint8 and uint16 rates, sensor contact, energy, RR intervals, truncated payloads), checks that the simulator's stand-in strap gives RR intervals that vary with the breath and agree with its rate, and checks that the `HeartRate` module answers only in an app built with `enableHeartRate`.

`FilesUnitTests.swift` covers `craft.files`' disk side: file names with no path in them, only files made in tmp/craft-files counted as the app's own, a photo written as an upright JPEG no larger than asked, a FormData sent as multipart with its file's bytes (and an arbitrary path refused), a download kept under the server's name or, refused, answered with its status and body, and what a screen made written as text or base64 bytes.

`NativeLayoutUnitTests.swift` covers the flex layout (`flex-1`, text that truncates inside its parent, `rounded-full`, text padding, stretched buttons, a non-scrolling FlatList inside a ScrollView, in-place style updates, inserted children), keyboard-driven additional safe-area changes, and the host functions a screen calls before its first render (`craft.storage.getSync`, `craft.snapshots`, `craft.secureStorage.getSync`, `console`, `craft.navigation.setOptions`). Set `CRAFT_NATIVE_RENDER_SIMULATOR` to a booted simulator's UDID to run on a simulator nothing else is using, so another app coming to the front cannot interrupt the UI test.

The same XCTest fixture covers FlatList paging and row `scrollTarget` reconciliation,
including a target that arrives while the diffable snapshot is still applying
or queued behind it, and a last-row target among tall self-sizing rows, which
must land at the true end of the content rather than at an estimate.

`NativeAudioUnitTests.swift` renders Web Audio graphs offline (`CraftWebAudio(live: false)`, no engine): oscillator shapes and pitch, the AudioParam timeline (ramps, targets, curves), sample-accurate start/stop and `onended`, buffer sources (offset, loop, duration), a biquad, a delay in a feedback cycle, the convolver's latency-free partitioned convolution and its spec normalisation, the compressor, a node driving a param, suspend/close, and a minute of an ambient music bed (the shape stx's `useAmbientSound` builds) whose released nodes are freed.

To run the same UI test against the actual compiler output, compile `Screen.stx` as shown above and set `CRAFT_NATIVE_RENDER_BUNDLE` to the absolute bundle path when invoking `test-native-render.ts`.

Within one parent, use a unique `key` on children whose identity must survive reordering. The current compiler emits it as `props.key`; the native host also accepts a top-level IR `key` and uses `testID` for existing screens. Unkeyed children are matched by position. Duplicate sibling keys fall back to position, so they cannot promise identity through moves.
