# Native STX on iOS and Android

Craft's experimental `native` mobile renderer runs a compiled STX route bundle
without a browser view. iOS evaluates the bundle with JavaScriptCore and creates
UIKit controls. Android evaluates the same bundle with JavaScriptSandbox and
creates Android views. Native mode never creates `WKWebView` or `WebView`, and it
fails visibly when its bundle or JavaScript runtime is unavailable.

The default renderer remains `web`. Opting into native mode does not change an
existing web-rendered application.

## Build the same bundle for both platforms

Configure routes in `stx-native.config.json`, then compile the directory that
contains that file:

```bash
stx-native compile --format bundle --output ./native-screen.js

craft ios init MyApp --renderer native --output ./ios
craft ios build --output ./ios --native-bundle ./native-screen.js

craft android init MyApp --package com.example.myapp --renderer native --output ./android
craft android build --output ./android --native-bundle ./native-screen.js
```

Native mode does not accept a web distribution or development-server URL. The
bundle must be local at build time.

## Current component contract

| STX primitive | iOS | Android |
| --- | --- | --- |
| `View`, `SafeAreaView` | `UIStackView` | `LinearLayout` |
| `Text` | `UILabel` | `TextView` |
| `Button` | `UIButton` | `Button` |
| `TextInput` | `UITextField` | `EditText` |
| `Image` | `UIImageView` | `ImageView` |
| `ScrollView` | `UIScrollView` | `ScrollView` or `HorizontalScrollView` |

`key` is scoped to sibling nodes. `testID` is also accepted as an identity for
existing screens. Unkeyed children reconcile by position. A rerender updates an
existing native control when its identity and type are unchanged, preserving
input focus, selection, draft text, and scroll objects. Duplicate sibling keys
fall back to positional identity rather than attaching state to the wrong view.

The shared style subset is deliberately smaller than the public `ViewStyle`
type:

- numeric `width` and `height`;
- `flexDirection` (`row`, `column`, and their reverse forms), `alignItems`,
  `justifyContent`, `gap`, `rowGap`, and `columnGap`;
- `padding`, its four side properties, `paddingHorizontal`, and
  `paddingVertical`;
- `backgroundColor`, `opacity`, `borderWidth`, `borderColor`, `borderRadius`,
  `overflow: 'hidden'`, and `display: 'none'`;
- for text: `color`, `fontFamily`, `fontSize`, `fontStyle`, `fontWeight`,
  `letterSpacing`, `lineHeight`, `textAlign`, `textDecorationLine`, and
  `textTransform`;
- for images: `resizeMode` (`contain`, `cover`, `stretch`, or `center`).

Colors use platform color syntax; hexadecimal colors are portable. Dimensions,
spacing, and font sizes are points on iOS and density-independent units on
Android. Percentage dimensions, flex wrapping, absolute positioning, min/max
constraints, transforms, and shadows are not in the native renderer contract
yet. Unsupported values are ignored rather than interpreted as CSS.

## Images and scrolling

Use `{ uri: value }` for an image source. Data-image URIs and HTTPS URLs work on
both platforms. A source with no URI scheme resolves from the iOS asset catalog
or Android app assets, so the asset must be packaged separately under the same
name for a shared bundle. Plain HTTP, file URLs, and other schemes are rejected.
Invalid data, missing bundled images, failed HTTPS downloads, and unsupported
schemes clear stale pixels, log a diagnostic, and expose a short accessibility
error value. Route teardown and node removal cancel outstanding downloads.

`ScrollView` uses `horizontal` (or a row flex direction) to choose its axis and
renders its children as native views. Scroll indicators, paging, refresh
controls, scroll callbacks, and virtualized lists are not implemented. Use
`ScrollView` only for bounded content until a recycling list primitive lands.

## Events, accessibility, and navigation

`onPress` and `onClick` deliver an empty `nativeEvent` from buttons and other
pressable native views. `TextInput` accepts `onChange` or `onChangeText` and
delivers `nativeEvent.text`. Image-load and scroll events are not implemented.

`accessibilityLabel`, `accessibilityHint`, and `accessibilityRole` map to native
accessibility metadata. The portable roles are `button`, `image`, `header`,
`link`, and `search`; unknown roles retain the platform control's native class.

`craft.navigation.push`, `replace`, and `back` use the platform navigation
stack. A pushed route receives `craft.route.params`; returning to an earlier
route reveals its existing native tree and JavaScript state. The initial native
API bridge currently supports device info, clipboard read/write, and haptic
impact. Other Craft device APIs remain browser-renderer only until they receive
native adapters.

## Verification

The repository exercises the same compiled multi-route fixture on both
platforms:

```bash
bun packages/ios/scripts/test-native-render.ts
bun packages/ios/scripts/test-native-navigation.ts
bun packages/android/scripts/test-native-navigation.ts
```

The iOS commands require macOS and a bootable simulator. The Android command
requires `ANDROID_HOME`, `adb`, Gradle, and a running emulator. CI is the source
of truth when those platform prerequisites are unavailable locally.
