# @craft-native/ios

Build native iOS apps with web technologies using Craft.

## Native celebration

Any native `View` may opt into a finite card entrance, light sweep and confetti
burst with `:celebration="{ replay: replayCount, enabled: true }"`. The numeric
`replay` value identifies the request: unrelated renders keep the current run;
increment it to replay. `enabled: false` displays an existing card quietly.
The effect takes three seconds, uses native animation frames, never captures
touches, and keeps the view's authored transform. iOS Reduce Motion and Android's
disabled animations show the complete content without movement or confetti.
Leaving the screen, detaching the view or backgrounding the app cancels the
decoration. Resuming does not replay it. Available on both native renderers.

## Features

### Core

- **WKWebView** - Native iOS WebView with full JavaScript support
- **Safe Areas** - Automatic handling of notch and home indicator
- **Dark Mode** - Native dark/light theme support

### Input & Feedback

- **Native Speech Recognition** - iOS SFSpeechRecognizer (works offline!)
- **Haptic Feedback** - UIImpactFeedbackGenerator, UINotificationFeedbackGenerator
- **Audio Recording** - AVAudioRecorder with compressed output
- **Video Recording** - UIImagePickerController video capture

### Native voice capture

With `enableAudioRecording`, the native renderer exposes
`craft.audioRecording.start(owner, { maxSeconds })`, `stop(owner)` and
`cancel(owner)`. Use a fresh UUID owner and at most 300 seconds. Stop returns
an owned temporary M4A descriptor with its MIME type, size and duration for
`craft.files` multipart uploads. Cancel and backgrounding erase the recording.

Permission is answered on the main thread. Recorder startup, stopping and
file inspection run on a serial audio queue. Startup has a 15-second deadline
after permission is granted; cancellation or timeout prevents a delayed encoder
from publishing a recording. A startup failure leaves the interface responsive.

### Device Access

- **Camera & Gallery** - Take photos or pick from gallery
- **Barcode/QR Scanner** - VisionKit DataScanner (iOS 16+)
- **File Picker** - UIDocumentPickerViewController
- **File Download** - Download and save files to device

### Sensors & Location

- **Geolocation** - GPS and network location via CLLocationManager
- **Motion Sensors** - Accelerometer & gyroscope via CoreMotion
- **NFC** - Read NFC tags via CoreNFC

### Communication

- **Share Sheet** - Native UIActivityViewController
- **Clipboard** - Read and write to system clipboard
- **Push Notifications** - APNs integration

### Security & Auth

- **Biometric Auth** - Face ID / Touch ID
- **Social Auth** - Apple Sign In
- **Secure Storage** - Keychain integration

### Data & Storage

- **Local Database** - SQLite with full SQL support
- **Bluetooth LE** - CoreBluetooth scanning

### System

- **Device Info** - Device model, OS version, screen info
- **Network Status** - Connection type monitoring (WiFi/Cellular)
- **App Badge** - Notification badge count
- **App State** - Foreground/background detection
- **Flashlight** - Camera flash control
- **Open URL** - External browser launch
- **Vibration** - Custom vibration patterns
- **App Review** - StoreKit review prompt
- **Screen Capture** - Take screenshots programmatically
- **Health/Fitness** - HealthKit integration

## Installation

The iOS support is built into the main `craft` CLI:

`Pressable`, `TouchableOpacity`, and `TouchableHighlight` render as native
pressable flow containers. `Modal` renders a parent-scoped native layer in native mode, with `visible`,
`transparent`, `nonModal`, `dismissOnOutsideTap`, `animationType`, `onShow`,
`onDismiss`, and `onRequestClose` support. Non-modal popups remain pass-through
unless outside-tap dismissal is explicitly enabled. `FlatList` item roots receive the same `onLayout` callback as ordinary native
views when rows are materialized or recycled.

`View.measure` and non-modal `left`/`top` placement use the same `screenViewport`
coordinate space. Safe-area and navigation-bar offsets are not added implicitly;
anchored callers must clamp against the measured viewport when needed. Re-run
measurement after the anchor or screen root emits `onLayout`, and after every
`onScroll` from an ancestor; those are the host-neutral invalidation signals for
repositioning an anchored popup.

```bash
bun add craft-native
```

## Native map input contract

Map coordinates are finite and range-checked at the native boundary; invalid
points and pole-crossing regions are ignored on iOS just as on Android.

## Quick Start

### 1. Initialize Project

```bash
craft ios init MyApp --bundle-id com.example.myapp
cd ios
```

### 2. Add Your Web Content

Replace `dist/index.html` with your web app, or point to a dev server:

```bash
craft ios build --html-path ../dist/index.html
# or
craft ios build --dev-server http://localhost:3456
```

### 3. Open in Xcode

```bash
craft ios open
```

### 4. Run on Device

In Xcode:

1. Select your Team in Signing & Capabilities
2. Connect your iPhone
3. Select your device
4. Click Run

## Configuration

### Experimental WebView-free screen

Native screens also support `ImageBackground`, which loads an image behind
ordinary native children while preserving the shared flex layout contract.
Native image sources accept HTTPS everywhere and loopback HTTP for local
development (`localhost`, `127.0.0.1`, `::1`, and `*.localhost`); public HTTP
and unsupported schemes are rejected.
`KeyboardAvoidingView` also responds to the native keyboard with `padding`,
`position`, or `height` behavior.

Native screens also expose the iOS-only `craft.badge` capability. `craft.badge.set(count)`
and `craft.badge.clear()` update the app icon without requesting notification
authorization or requiring local notifications to be enabled.

Keyboard frame changes update the native controller's additional safe area, so
focused inputs and responsive `onLayout` measurements move with the keyboard.

Shared view transforms, z-order, view/text shadows, per-edge border styles,
and linear gradients are applied by UIKit with the same style keys as Android;
`elevation` remains Android-specific. Gradient layers follow the native view's
bounds and corners through layout changes.

The opt-in `native` renderer hosts compiled `.stx` screens in JavaScriptCore and renders their `View`, `SafeAreaView`, `KeyboardAvoidingView`, `StatusBar`, `RefreshControl`, `Text`, `Button`, `Link`, `Checkbox`, `TextInput`, `Picker`, `SegmentedControl`, `DatePicker`, `Switch`, `Slider`, `ActivityIndicator`, `Icon`, `Image`, `ImageBackground`, `Video`, `Map`, `Svg`, `G`, `SvgText`, `ScrollView`, `SectionList`, and recycling `FlatList` nodes as UIKit controls. `StatusBar` and `RefreshControl` are screen/scroll utility nodes rather than visible children. `Map` uses MapKit for trail polylines and marker taps; its overlays carry flat latitude/longitude `geometry` arrays, `strokeWidth` is expressed in logical points, and the camera supports controlled `region`, one-time `initialRegion`, and `fitToBounds`. `Svg` is a DOM-free drawing surface; grouped `G` and `SvgText` nodes are painted inside it. `Icon` uses SF Symbols with the shared symbol/name contract and accessibility metadata. `SectionList` uses the same native scroll host for ordinary `.stx` slot children; grouped section data should use `FlatList` until the section-data protocol is available. `FlatList` uses `UICollectionView` with stable keyed rows, incremental diffs, grids, horizontal and inverted layouts, list chrome, and end-reached pagination. Native views support `onLayout` callbacks with point-based frame measurements that refresh after safe-area or orientation changes. Flex items support `flex`, `flexGrow`, `flexShrink`, and numeric `flexBasis` for main-axis space distribution. Native screens also expose the versioned capability bridge: JSON storage and SQLite survive relaunch, lifecycle and deep-link events are scoped to the top route, and local notifications use `UNUserNotificationCenter`. Enable each capability in `craft.config.json`; disabled calls preserve Craft's `CAPABILITY_DISABLED` rejection code and every request has deterministic timeout/cancellation behavior. The default remains `web`; existing iOS apps are unchanged. `Checkbox` supports controlled `checked`/`value`, indeterminate state, and boolean `onValueChange`; `Picker` renders `<select>`/`<option>` values with `onValueChange` or `onChange`; `DatePicker` emits local date/time values plus ISO and millisecond `timestamp` fields; `Switch` supports state-aware `trackColor`, `thumbColor`, and iOS `ios_backgroundColor`; `Slider` supports track/thumb tint props and `step` snapping; `Image` reports load lifecycle events and structured failures; `Video` uses an `AVPlayerViewController` attached to the native screen for URI playback, native controls, and route-safe teardown. `craft.navigation.setOptions` also accepts a `tabAccessory` destination beside the tab pill; it uses an app-local `path`, `title`, `symbol`, optional `badge`, and `accessibilityLabel`, and `null` clears it. The portable component, capability, list, style, image-source, event, accessibility, and reconciliation behavior is specified in the [Native STX guide](../../docs/guides/native-stx.md).

`FlatList` rows are authored as keyed `:for` child rows in native STX; the
maintained protocol does not serialize `data`/`renderItem` callbacks.

JavaScriptCore has no DOM `window`; Craft aliases `globalThis.window` to
`globalThis` before installing the native bridge so browser-safe SDK calls such
as `window.craft.dialog.actionSheet()` reach the native capability host. This
does not add `document` or DOM rendering; routes that do not opt into `native`
continue using the WebView renderer.

```bash
craft ios init NativeDemo --renderer native --output ./ios-native
stx native compile Screen.stx --format bundle --output ./screen.js
craft ios build --output ./ios-native --native-bundle ./screen.js
craft ios run --output ./ios-native --simulator
```

`stx native compile` is part of the [stx](https://github.com/stacksjs/stx) CLI (`@stacksjs/stx`); build tools can call `compileNativeBundle` from `@stacksjs/stx/native` instead. A runnable screen is in [`fixtures/native-screen/Screen.stx`](./fixtures/native-screen/Screen.stx). In native mode, the app never instantiates `WKWebView`; a missing `dist/native-screen.js` fails the build rather than silently opening the web placeholder.

Keep application repositories free of handwritten Swift with the built-in audit:

```bash
craft-ios audit-sources --app-root .
```

The command ignores Craft's generated `storage/framework/mobile` tree, build
output, and dependencies. It exits non-zero and lists the relative paths when
an app owns a `.swift` file; use the exported `assertNoApplicationSwiftSources`
function when the check belongs inside an existing TypeScript test.

Native screen updates use the versioned mutation protocol when the bundle
supports it and fall back to whole-document rendering for older bundles.
Updates reconcile the UIKit tree by sibling-scoped `key` (or `testID` for
existing screens); unkeyed children reuse their position. `TextInput` objects
therefore keep focus and selection while unrelated labels and buttons change.
Native `TextInput` also applies `placeholderTextColor`, `selectionColor`,
positive `maxLength`, `multiline`, and `numberOfLines` values while preserving
the WebView fallback for routes that do not opt into the renderer.
The protocol wire format, atomic validation, revisions, and error codes are in
the [Native STX guide](../../docs/guides/native-stx.md). On macOS,
`bun packages/ios/scripts/test-native-render.ts` runs the renderer's unit and
simulator UI tests.

`initSimulatorDriver` can also drive an installed release on a paired iPhone.
Pass `script: serializeSimulatorSteps(steps)` to bundle a journey in the test
target. `shot`, `tree` and `systemtree` then save native XCTest attachments;
checks appear in the Xcode test log. Generate the project with XcodeGen, sign
the test runner for your team and run it against the device. The installed app
under test is activated by its bundle identifier and is not rebuilt by the
driver. Export evidence with `xcrun xcresulttool export attachments --path
<result.xcresult> --output-path <evidence>`. Omitting `script` restores the
control-server protocol, required for the `net`, `delay` and `exec` hooks.
Journeys stop at the first failed check so later actions cannot operate on the
wrong screen. `systemtap` targets the system button around a Live Activity rather
than its remotely hosted text. The [Live Activity layout fixture](./fixtures/live-activity)
exercises long names and timer alignment using the production widget.

Use `universallink https://example.com/profile` to test an associated HTTPS
link after a fresh install. The driver host uses Apple's public
`universalLinksOnly` option and waits up to 60 seconds for iOS to accept the
association downloaded from Apple's CDN. A rejected association fails the
journey; it cannot fall back to Safari. This operation does not launch the app
under test directly, so a preceding `terminate` still tests a cold handoff.
Use `openurl` for browser fallback checks and custom URL schemes.

Use `drag 0.6 0.32 0.5 0.32` for a short horizontal drag that pauses before
release, so a tab swipe cancels instead of becoming a velocity-driven flick.
The four coordinates are relative to the app, between zero and one. The driver
uses public XCTest input, moves slowly and holds for 0.3 seconds before lifting.
Follow it with `selected` and content checks, then a full `swipe` to verify the
next gesture still works. Synchronized XCTest gestures do not replace separate
direct-input rapid-tap checks.

The iOS host uses the shared tree-layout ABI for eligible definite-size
containers, including reverse and wrap-reverse direct flows, and retains a
local fallback for older runtimes or unsupported styles. Both paths implement wrapped-line and grid
`alignContent`, including `space-evenly`, so a missing optional shared symbol
does not change placement semantics.
Reverse flex directions also retain wrapped line order on the cross axis while
reversing each line's main-axis children, matching Android's native host.

For rapid or interrupted input, `touches` submits multiple touch paths in one
native XCTest event record. Each point has `at` in seconds and either normalized
`x`/`y` coordinates or a `tab` name resolved to its native button center before
submission. For example, two taps 80 ms apart:

```ts
serializeSimulatorSteps([{ command: 'touches', paths: [
  [{ tab: 'Today', at: 0 }, { tab: 'Today', at: 0.025 }],
  [{ tab: 'Progress', at: 0.08 }, { tab: 'Progress', at: 0.105 }],
] }])
```

Unlike separate coordinate taps, the event record preserves timing between
paths without waiting for app quiescence. Save the scheduled paths and verify
the resulting selection and native content. Timing schedules are not FPS
measurements. The Objective-C bridge belongs only to the test target and uses
runtime-checked private XCTest event APIs; unsupported toolchains fail the
journey rather than silently switching to synchronized input. Nothing is linked
into the installed app. CI also delivers a 24-tap schedule to an independent
native receiver and verifies every callback and the final selection; source
serialization and successful compilation alone do not establish delivery. Native input semantics follow the [event-record API
used by XCTest automation](https://appium.github.io/appium-xcuitest-driver/latest/guides/input-events/).

For multiple native screens, configure named `.stx` routes and an initial screen in `native.config.json` (see [`fixtures/native-navigation`](./fixtures/native-navigation)). Compile without a positional file: `stx native compile --format bundle --output ./screen.js`. A screen can call `craft.navigation.push('details', { id: 7 })`, `.replace('home')`, or `.back()`; the destination reads `craft.route.params`. Craft uses a native navigation stack, so the back button and edge-swipe reveal the existing controller and retain its JavaScript and input state. `bun packages/ios/scripts/test-native-navigation.ts` compiles the fixture and runs its simulator test; the default WebView renderer is unchanged.

Hybrid web-to-web pushes use the same shared WebView across stack entries. The maintained [`fixtures/hybrid-navigation`](./fixtures/hybrid-navigation) fixture samples the outgoing page during the UIKit transition and is run by CI with:

```bash
bun packages/ios/scripts/test-hybrid-navigation.ts
```

Hybrid apps also get the shell's completed left/right tab swipe over the
WebView. Disable that page-wide gesture with
`craft.tabBar.set(tabs, { swipeEnabled: false })`; a native screen can still
use `craft.navigation.setOptions({ tabSwipeEnabled: false })` for its own
content.

Native screens can opt into an opaque navigation-bar fill that follows their
screen background (including light/dark trait changes) with
`craft.navigation.setOptions({ navigationBarSolid: true })`. The default stays
UIKit's translucent material; set it back to `false` when a screen no longer
needs a solid bar.

The `backgroundColor` navigation option is shared with the Android native host;
omitting it or passing `null` returns to the app's dynamic light/dark colour.

The optional Liquid Glass tab-bar styling is compiler-gated for Xcode 26/Swift 6.2 and later. Older SDKs compile the same tab bar with the material fallback, so generated projects remain buildable on Xcode 16.

The iOS host overlays `craft.config.json` on its defaults. Missing or `null` capability flags stay disabled; explicitly set a flag to `true` to enable it. Both the Swift host and Zig bridge reject malformed values and fall back to all capabilities disabled.

Native passkeys require both `enablePasskeys: true` and a matching
`webcredentials:<host>` entry in `associatedDomains`:

```json
{
  "renderer": "native",
  "enablePasskeys": true,
  "associatedDomains": ["webcredentials:login.example.com"]
}
```

The native STX screen calls `craft.passkeys.isAvailable()`, `create(options)`,
or `get(options)`. The host validates the relying-party id against those
associated domains before showing Apple's `ASAuthorization` sheet; a passkey
request for another host is rejected. The server remains responsible for
generating the challenge and verifying the returned WebAuthn response.

Edit `craft.config.json` in your iOS project:

```json
{
  "appName": "MyApp",
  "bundleId": "com.example.myapp",
  "version": "1.0.0",
  "buildNumber": "1",
  "darkMode": true,
  "backgroundColor": "#1a1a2e",
  "enableSpeechRecognition": true,
  "enableHaptics": true,
  "enableShare": true,
  "enableCamera": true,
  "enableBiometric": true,
  "enablePushNotifications": false,
  "enableSecureStorage": true,
  "enableGeolocation": true,
  "enableClipboard": true,
  "enableNetworkStatus": true,
  "enableAppReview": true,
  "enableFlashlight": true,
  "enableQRScanner": true,
  "enableFilePicker": true,
  "enableFileDownload": true,
  "enableSocialAuth": true,
  "enablePasskeys": true,
  "associatedDomains": ["webcredentials:login.example.com"],
  "enableAudioRecording": true,
  "enableVideoRecording": true,
  "enableMotionSensors": true,
  "enableLocalDatabase": true,
  "enableBluetooth": true,
  "enableNFC": true,
  "enableHealthKit": false,
  "enableWallet": true,
  "enableAppleMusic": false,
  "enableHeartRate": false,
  "enableBackgroundAudio": false,
  "enableScheduledWorkouts": false,
  "enableScreenCapture": true,
  "iosVersion": "15.0",
  "teamId": ""
}
```

The app name is shown as written (`"HQ.training"` is fine); the Xcode
project, target and Swift types use a PascalCase identifier made from it
(`HQTraining`). A key left out of the file keeps its default.

`enableBackgroundAudio` adds the `audio` background mode, so a soundscape or a
meditation's ambience (Web Audio, on the playback session) keeps playing with
the screen locked; a sleep timer then fades it out on the audio clock. Turn it
on only for an app that plays sound people listen to: App Review checks.

Purpose strings in your own words, by Info.plist key (each replaces Craft's
generic sentence; the keys for frameworks the shell links are always written,
since App Store Connect checks the binary):

```json
{
  "usageDescriptions": {
    "NSAppleMusicUsageDescription": "Shows the song playing during a workout and lets you pause or skip it."
  }
}
```

Appearance and navigation:

```json
{
  "appearance": "system",
  "backgroundColor": "#f8fafc",
  "backgroundColorDark": "#020617",
  "swipeNavigation": true
}
```

- `appearance`: `"system"` follows the phone's Light/Dark setting (and the
  page's `prefers-color-scheme`), with a status bar that reads on either;
  `"light"` and `"dark"` pin one. Without it, `darkMode` decides as before.
- `backgroundColorDark`: the launch screen and webview background in Dark Mode.
- `swipeNavigation`: an edge swipe goes back and forward through the page's
  history, pushState entries included.

Native tab-bar selection styling is opt-in and lives in the generated config,
so the generated Swift never needs to be patched:

```json
{
  "tabBar": {
    "selection": { "cornerRadius": 8, "color": "#123456" }
  },
  "postGenerate": {
    "command": "bun",
    "args": ["run", "scripts/customize-native.ts"]
  }
}
```

`cornerRadius` is measured in points and `color` is `#RRGGBB`; omit either to
keep its host default. `postGenerate` runs after `craft ios build` has written
the Xcode project, with the generated project as its working directory. Craft
does not invoke a shell: `command` and `args` are passed directly. The hook
receives `CRAFT_PROJECT_ROOT`, `CRAFT_PLATFORM=ios`, and
`CRAFT_GENERATE_PHASE=build`. A missing executable, non-zero exit, or invalid
configuration fails the build with the hook's stderr in the diagnostic.

Debug builds let Safari's Develop menu inspect the webview, and relay the
page's console, uncaught errors, rejected promises and failed script loads to
the device log as `[craft page] …`, so a page that only breaks inside the app
can be read with `xcrun simctl spawn booted log show --predicate 'process ==
"YourApp"'`. Release builds do neither.

When push notifications are enabled, generated Debug builds use the APNs
development environment and Release builds use the production environment.
The generated entitlements select the correct value from the active Xcode
build configuration automatically.

### Launch, offline and the feel of the web view

```json
{
  "splashMaxSeconds": 3,
  "requestTimeoutSeconds": 10,
  "allowsLinkPreview": false,
  "keyboardAccessory": false,
  "disableZoom": true,
  "associatedDomains": ["hq.training"],
  "backgroundRefresh": { "enabled": true, "minimumIntervalMinutes": 30 }
}
```

- `splashMaxSeconds` (default 3): the splash stays until the page calls
  `splash.hide()` or its first contentful paint is on screen, and never longer
  than this.
- `requestTimeoutSeconds` (default 10): how long the app's own page may take
  before the load counts as unreachable and the bundled page stands in.
- The bundled page `init` writes (`dist/index.html`, until your web assets
  replace it) is an offline page in the app's colours, light and dark, whose
  Retry loads the remote page again. An app whose page has a service worker
  normally opens from it offline; this shows on a first launch without one or
  after a hard failure. With `appBoundDomains` it is loaded as a page of the
  remote origin, because WebKit refuses to navigate from an app-bound domain
  to `craft://app`.
- `allowsLinkPreview` (default false): Safari's press-and-hold link previews.
- `keyboardAccessory` (default false): WebKit's previous/next/Done bar above
  the keyboard. Change it at runtime with `craft.chrome.setKeyboardAccessory`.
- `disableZoom` (default true): no pinch or double-tap zoom, and the page's
  viewport pinned at scale 1.
- `associatedDomains`: universal links. A bare host is signed as
  `applinks:<host>`; a universal link reaches the page as `craftDeepLink`, like
  a custom-scheme link.
- `backgroundRefresh`: a BGAppRefreshTask (`<bundleId>.refresh` unless
  `identifier` is set), declared in `BGTaskSchedulerPermittedIdentifiers` with
  the `fetch` background mode, scheduled no sooner than
  `minimumIntervalMinutes` (default 15). It fires `craftBackgroundRefresh`.

The web view also: shows `alert`, `confirm` and `prompt` as system alerts;
opens `target=_blank` and `window.open` for the app's own origins in place and
anything else in `SFSafariViewController`; grants `getUserMedia` to the app's
own origin without WebKit's extra prompt; dismisses the keyboard with a drag;
allows picture in picture; ends its user agent with the builder package's
resolved `Craft/<version>
<AppName>/<version>`; brings a page whose content process died back under the
splash, on the page it was showing, at most three times a minute before
showing the offline page; and saves its `interactionState` when the app goes to
the background, so a launch after iOS ended the app returns to the same screen
(same build only).

## JavaScript Bridge

Once Craft is initialized, the `window.craft` object is available:

```javascript
// window.craft is installed at document start, before the page's own scripts,
// so it can be used at once. craftReady still fires, once, when the document
// has been parsed, for pages that wait for it.
window.addEventListener('craftReady', (e) => {
  console.log('Platform:', e.detail.platform); // 'ios'
  console.log('Capabilities:', e.detail.capabilities);
});

// Haptic feedback. Resolves true, and rejects with CAPABILITY_DISABLED when
// enableHaptics is off.
await window.craft.haptic('light');   // light, medium, heavy
await window.craft.haptic('success'); // success, warning, error
await window.craft.haptic('selection');

// Speech recognition. startListening resolves true once the request is
// taken; whether listening actually began arrives as the events below
// (craftSpeechError for a declined prompt or no recognizer).
await window.craft.startListening();
await window.craft.stopListening();

// Listen for speech events
window.addEventListener('craftSpeechStart', () => { /* recording started */ });
window.addEventListener('craftSpeechResult', (e) => {
  console.log(e.detail.transcript);  // "hello world"
  console.log(e.detail.isFinal);     // true/false
});
window.addEventListener('craftSpeechEnd', () => { /* recording stopped */ });
window.addEventListener('craftSpeechError', (e) => {
  console.error(e.detail.error);
});

// Share
window.craft.share('Check out this app!', 'My App');

// Camera & Gallery
const imageBase64 = await window.craft.openCamera();
const selectedImage = await window.craft.pickImage();

// Barcode/QR Scanner (iOS 16+)
const scannedCode = await window.craft.scanQRCode();
console.log(scannedCode); // "https://example.com"

// File Picker
const file = await window.craft.pickFile(['public.image', 'application/pdf']);
console.log(file.name, file.data); // base64 encoded

// File Download
await window.craft.downloadFile('https://example.com/file.pdf', 'document.pdf');
await window.craft.saveFile('data:text/plain;base64,SGVsbG8=', 'hello.txt', 'text/plain');

// Social Auth (Apple Sign In). Needs `enableSocialAuth`, which also adds the
// Sign in with Apple entitlement. Pass the SHA-256 of a one-time nonce and
// send `authorizationCode` (with the raw nonce) to your server to redeem.
const user = await window.craft.signInWithApple({ nonce: sha256Hex(rawNonce) });
console.log(user.userId, user.email, user.name, user.identityToken, user.authorizationCode);

// Audio Recording
await window.craft.startAudioRecording();
const audioBase64 = await window.craft.stopAudioRecording();

// Video Recording
const videoBase64 = await window.craft.startVideoRecording();

// Motion Sensors
window.craft.startMotionUpdates();
window.addEventListener('craftMotionUpdate', (e) => {
  console.log('Accelerometer:', e.detail.accelerometer); // {x, y, z}
  console.log('Gyroscope:', e.detail.gyroscope);         // {x, y, z}
});
window.craft.stopMotionUpdates();

// Local Database (SQLite)
await window.craft.db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
await window.craft.db.execute('INSERT INTO users (name) VALUES (?)', ['Alice']);
const users = await window.craft.db.query('SELECT * FROM users');

// Bluetooth LE Scanning
window.craft.startBluetoothScan();
window.addEventListener('craftBluetoothDevice', (e) => {
  console.log(e.detail.name, e.detail.uuid, e.detail.rssi);
});
window.craft.stopBluetoothScan();

// NFC Tag Reading
const nfcData = await window.craft.scanNFC();
console.log(nfcData); // Tag content

// Health/Fitness (requires HealthKit entitlement)
await window.craft.requestHealthAuthorization(['stepCount', 'heartRate']);
const steps = await window.craft.getHealthData('stepCount', startDate, endDate);

// Through craft-native/mobile's `health` service:
import { health } from 'craft-native/mobile'
// Read only: the sheet asks for access, not "access and update".
await health.requestAuthorization(['workouts', 'heartRate', 'sleep'], { write: false })
// Apple Health workouts (the watch's and every app's), newest first.
const workouts = await health.getWorkouts({ startDate: Date.now() - 30 * 86400000 })
// One value per local day: sums, averages, the latest weight, hours asleep.
const hrv = await health.getDailyStatistics('heartRateVariability', { startDate: Date.now() - 30 * 86400000 })
// What a food log wrote (MyFitnessPal, Lose It!...): kcal, then grams of protein, carbohydrate and fat, summed per day.
const eaten = await health.getDailyStatistics('dietaryEnergy', { startDate: Date.now() - 7 * 86400000 })
// Food logs can write a quantity too; request write access first. The result
// contains HealthKit's sample id, and the date range defaults to this instant.
await health.requestAuthorization(['dietaryEnergy', 'dietaryProtein'], { write: true })
const sample = await health.saveData('dietaryProtein', 28, { startDate: mealStart, endDate: mealEnd })
// Every heart-rate reading in a range (bpm, start/end, source and device), oldest first.
const readings = await health.getHeartRateSamples({ startDate: Date.now() - 86400000 })
// The night as Apple Health recorded it: in bed, awake, and each asleep stage.
const nights = await health.getSleepIntervals({ startDate: Date.now() - 86400000 })
// An app built before these reads existed has neither; check first.
if (health.supports('getHeartRateSamples')) { /* ... */ }
// Diabetes: glucose (mg/dL), insulin (IU, each marked basal or bolus) and carbs (g),
// one sample at a time with its UUID, oldest first. Ask for them read only.
await health.requestAuthorization(['bloodGlucose', 'insulinDelivery', 'dietaryCarbohydrates'], { write: false })
const glucose = await health.getSamples('bloodGlucose', { startDate: Date.now() - 86400000 })
const doses = await health.getSamples('insulinDelivery', { startDate: Date.now() - 86400000 })
// Mindful minutes: ask for 'mindful' (with writing allowed), then save a
// meditation or breathing session. The id is kept as the sample's external
// UUID, so saving it again keeps the first sample ({ existing: true }).
await health.requestAuthorization(['mindful'], { write: true })
await health.saveMindfulSession({ id: 'session-42', startDate: started, endDate: Date.now() })
// Every app's mindful sessions, oldest first; ownApp marks the ones this app wrote.
const mindful = await health.getMindfulSessions({ startDate: Date.now() - 7 * 86400000 })
// Heart rate as Apple Health receives it, instead of polling getHeartRateSamples:
// the samples since `since` (two minutes ago by default) first, then each new
// batch, oldest first and each sample once, in getHeartRateSamples' shape.
// Needs the 'heartRate' grant; one stream at a time.
const stopListening = health.onHeartRate(samples => show(samples[samples.length - 1].bpm))
await health.startHeartRateUpdates({ since: Date.now() - 60000 })
// ...
await health.stopHeartRateUpdates()
stopListening()
// HealthKit only has what the watch has synced. During a workout or a
// Mindfulness session on the Apple Watch that is a reading every few seconds;
// otherwise the watch measures every few minutes, and so do these. On a page
// the batches are `craftHealthHeartRate` events ({ samples }); native screens
// hear them too. In the simulator, the CraftFakeHealthHeartRate default
// (`xcrun simctl spawn booted defaults write <bundle id> CraftFakeHealthHeartRate -bool YES`)
// sends a made-up watch reading every 5 s instead: someone settling into slow
// breathing, from about 72 toward 60 bpm.

// Live workout sessions (iOS 26+, requires enableHealthKit: true). The OS
// keeps the session alive while the app is backgrounded; samples arrive as
// typed craftHealthWorkout events. Ask for the workout/heart-rate grants before
// starting a session.
await health.requestAuthorization(['workouts', 'heartRate', 'activeEnergy', 'distance'], { write: true })
const stopWorkout = health.onWorkout(event => {
  if (event.event === 'metrics') showMetrics(event.heartRateBpm, event.activeEnergyCalories, event.distanceMeters)
  if (event.event === 'state') showWorkoutState(event.state)
  if (event.event === 'error') showWorkoutError(event.message)
})
const live = await health.startWorkout({ type: 'running', location: 'outdoor' })
await health.pauseWorkout()
await health.resumeWorkout()
const saved = await health.endWorkout() // { id, workoutId, endDate, durationSeconds }
stopWorkout()

`startWorkout`, `pauseWorkout`, `resumeWorkout`, and `endWorkout` reject with
`Live workouts are unavailable` when the build does not include HealthKit or
when the OS is older than iOS 26. `onWorkout` receives lifecycle events plus
live `heartRateBpm`, `activeEnergyCalories`, and `distanceMeters` metrics; the
existing post-hoc `saveWorkout` API remains separate.

// Screen Capture
const screenshotBase64 = await window.craft.takeScreenshot();

// Biometric authentication
try {
  const authenticated = await window.craft.authenticate('Confirm your identity');
  if (authenticated) {
    console.log('User authenticated!');
  }
} catch (error) {
  console.log('Authentication failed:', error.message);
}

// Push notifications
const token = await window.craft.registerPush();
console.log('Push token:', token);

// Secure storage (Keychain)
await window.craft.secureStore.set('api*key', 'secret123');
const apiKey = await window.craft.secureStore.get('api*key');
await window.craft.secureStore.remove('api*key');

// Geolocation
const position = await window.craft.getCurrentPosition();
console.log(position.latitude, position.longitude);

// Watch position (continuous updates)
const watchId = window.craft.watchPosition((position) => {
  console.log('New position:', position);
});
window.craft.clearWatch(watchId);

// Clipboard
await window.craft.clipboard.write('Hello World');
const text = await window.craft.clipboard.read();

// Device Info
const device = window.craft.getDeviceInfo();
console.log(device.model, device.systemVersion, device.screenWidth);

// App Badge
window.craft.setBadge(5);
window.craft.clearBadge();

// Network Status
const network = window.craft.getNetworkStatus();
console.log(network.isConnected, network.type); // true, 'wifi'

// Network change listener
window.craft.onNetworkChange((status) => {
  console.log('Network changed:', status);
});
window.craft.offNetworkChange();

// App Review (StoreKit)
await window.craft.requestReview();

// Flashlight
window.craft.setFlashlight(true);  // turn on
window.craft.setFlashlight(false); // turn off
window.craft.toggleFlashlight();   // toggle

// Open URL (external browser)
window.craft.openURL('https://example.com');

// Vibration Pattern (custom durations in ms)
window.craft.vibrate([100, 50, 100, 50, 200]);

// App State
const state = window.craft.getAppState(); // 'active', 'inactive', 'background'

// App state change listener
window.craft.onAppStateChange((state) => {
  console.log('App state:', state);
});
window.craft.offAppStateChange();

// Logging (appears in Xcode console)
window.craft.log('Debug message');

// ==================== High Value Bridges ====================

// Contacts
const contacts = await window.craft.getContacts();
console.log(contacts); // [{id, givenName, familyName, displayName, phoneNumbers, emailAddresses}]

const newContactId = await window.craft.addContact({
  givenName: 'John',
  familyName: 'Doe',
  phone: '+1234567890',
  email: 'john@example.com'
});

// Calendar Events
const events = await window.craft.getCalendarEvents(startDateMs, endDateMs);
console.log(events); // [{id, title, location, notes, startDate, endDate, isAllDay}]

const newEventId = await window.craft.createCalendarEvent({
  title: 'Meeting',
  location: 'Office',
  notes: 'Discuss project',
  startDate: Date.now(),
  endDate: Date.now() + 3600000,
  isAllDay: false
});

await window.craft.deleteCalendarEvent(eventId);

// Local Notifications
const notificationId = await window.craft.scheduleNotification({
  id: 'reminder-1',
  title: 'Reminder',
  body: 'Don\'t forget!',
  badge: 1,
  timestamp: Date.now() + 60000, // 1 minute from now
  // or use delay: 60000 // delay in ms
});

await window.craft.cancelNotification('reminder-1');
await window.craft.cancelAllNotifications();
const pending = await window.craft.getPendingNotifications();

// In-App Purchase
const products = await window.craft.getProducts(['product*id*1', 'product*id*2']);
console.log(products); // [{id, title, description, price, priceLocale}]

const purchaseResult = await window.craft.purchase('product*id*1');
console.log(purchaseResult); // {transactionId, productId, ...}

await window.craft.restorePurchases();

// Keep Screen Awake
window.craft.setKeepAwake(true);  // Prevent screen dimming
window.craft.setKeepAwake(false); // Allow screen dimming

// Screen brightness, 0 to 1: always available (no config flag). It is the
// device's backlight, so put it back: `brightness` from 'craft-native/mobile'
// remembers the person's level, restores it, and releases it while the app is
// in the background.
const level = await window.craft.getBrightness();   // 0.62
await window.craft.setBrightness(0.1);              // resolves with what the screen reports

// Apple Music (enableAppleMusic): what the Music app is playing, and its
// transport, through MPMusicPlayerController.systemMusicPlayer. Only Apple
// Music: iOS gives no app another player's controls, so while Spotify or a
// podcast app plays, the song fields are null and otherAudioPlaying is true.
// Nothing is read until the person allows media library access, which only
// requestAuthorization() asks for (call it from their tap, never at launch).
// Word the prompt with usageDescriptions.NSAppleMusicUsageDescription.
await window.craft.music.requestAuthorization(); // 'authorized' | 'denied' | 'restricted' | 'notDetermined'
const now = await window.craft.music.getNowPlaying();
// { available, authorization, source: 'appleMusic', playbackState: 'playing', isPlaying,
//   itemId, title, artist, album, duration, position, timestamp,
//   artworkDataURL: 'data:image/jpeg;base64,…' (120 px, or null), otherAudioPlaying }
await window.craft.music.togglePlayPause(); // play() / pause() too; each resolves with the snapshot
await window.craft.music.skipToNext();
await window.craft.music.skipToPrevious({ restartAfter: 3 }); // like Music's own button; 0 = always previous
await window.craft.music.observe(true); // then every change arrives as craftMusicChange
window.addEventListener('craftMusicChange', (event) => render(event.detail));
// Or `import { music } from 'craft-native/mobile'`: music.onChange(callback)
// observes while anyone listens, and off a phone every call answers
// { available: false } without doing anything.
// The simulator's Music app has nothing to play: launch with
// `-CraftFakeMusicPlayer YES` (or `simctl spawn <device> defaults write <bundle id>
// CraftFakeMusicPlayer -bool YES`) for three made-up songs that play (counting as other audio) and skip.
// Simulator builds only; a device always talks to the Music app.

// Heart rate (enableHeartRate): a Bluetooth strap, or a watch broadcasting
// its heart rate, through the standard Heart Rate Service (0x180D) and its
// Heart Rate Measurement (0x2A37): bpm, sensor contact, energy and RR
// intervals. The app gets the `bluetooth-central` background mode, so
// readings keep coming during a workout with the screen locked. iOS asks
// for Bluetooth on the first scan or connect (or requestAuthorization()); word
// it with usageDescriptions.NSBluetoothAlwaysUsageDescription.
window.addEventListener('craftHeartRate', (event) => {
  // { type: 'device', device: { id, name, rssi } }      a scan found a strap
  // { type: 'reading', bpm, rrIntervals, contact, energyExpended, timestamp, deviceId }
  // { type: 'state', connection, bluetooth, device, lastDevice, bpm, ... }
});
await window.craft.heartRate.scan({ timeout: 15 });     // straps nearby, and one already connected
const strap = (await window.craft.heartRate.getDevices())[0]; // strongest signal first
await window.craft.heartRate.connect(strap.id);  // remembered; rejects TIMEOUT after 15 s while still asking
await window.craft.heartRate.reconnect();        // next time: the remembered strap, no scan
// A strap that drops out is asked for again (connection 'reconnecting')
// until disconnect({ forget }) lets it go.
await window.craft.heartRate.startRecording();   // every reading kept natively, app closed or not
await window.craft.heartRate.pauseRecording();   // resumeRecording() / getRecordingState()
const { samples } = await window.craft.heartRate.stopRecording(); // [{ timestamp, bpm, rr? }]
// Native screens call the same service as the HeartRate module (capability
// `heartRate`), and hear the same craftHeartRate events. Or use `heartRate`
// from 'craft-native/mobile' (onReading, onDevice, onState); off a phone it
// answers { available: false }.
// The simulator has no Bluetooth: `simctl spawn <device> defaults write
// <bundle id> CraftFakeHeartRateMonitor -bool YES` stands in a strap ("Simulated
// HRM") whose readings are encoded and decoded as 0x2A37 payloads, their RR
// intervals varying beat to beat with a ten-second breath as a heart's do, so a
// heart-rate variability worked out from them means something. Simulator builds only.

// Apple Watch workouts (enableScheduledWorkouts, iOS 17+): WorkoutKit's
// WorkoutScheduler puts a structured workout in the paired watch's Workout
// app on its day. Only an app with the flag compiles in and links WorkoutKit
// (the CRAFT_SCHEDULED_WORKOUTS build condition); below iOS 17 it is weak-linked
// and isSupported() answers false. A plan is plain JSON in SI units.
if (await window.craft.scheduledWorkouts.isSupported()) {
  await window.craft.scheduledWorkouts.requestAuthorization(); // iOS's prompt once; waits on the person
  await window.craft.scheduledWorkouts.schedule({
    id: '6f1c2b8e-5a7d-4c3e-9b1a-2d4e6f8a0b1c', // a UUID: WorkoutPlan's id
    date: '2026-10-20', hour: 6, minute: 30,    // local; 07:00 without a time
    workout: {
      activity: 'running',                      // an HKWorkoutActivityType case name
      location: 'outdoor',                      // indoor | outdoor | unknown
      displayName: '4 x 1 km',
      warmup: { goal: { type: 'time', seconds: 600 } },
      blocks: [{ iterations: 4, steps: [
        { purpose: 'work', step: { goal: { type: 'distance', meters: 1000 },
          alert: { type: 'speed', min: 4.1, max: 4.4 }, displayName: '1 km hard' } }, // step names: iOS 18
        { purpose: 'recovery', step: { goal: { type: 'time', seconds: 120 } } },
      ] }],
      cooldown: { goal: { type: 'open' } },
    },
  }); // { id, droppedAlerts? }
  await window.craft.scheduledWorkouts.list();      // [{ id, date, hour, minute, complete }], ids lowercase
  await window.craft.scheduledWorkouts.remove(id);  // every day it is on; true when there was one
  await window.craft.scheduledWorkouts.removeAll(); // how many there were
}
// Goals: open, time (seconds), distance (meters), energy (kilocalories).
// Alerts: heartRate / power / speed (m/s) / cadence { min, max }, heartRateZone /
// powerZone { zone }. An activity or goal WorkoutKit refuses rejects, naming it
// (UNSUPPORTED_GOAL, INVALID_ARGUMENT); a refused alert is dropped and named in
// droppedAlerts. LIMIT_REACHED past WorkoutScheduler.maxAllowedScheduledWorkoutCount;
// NOT_SCHEDULED when nothing kept the plan (no paired watch); NOT_AUTHORIZED
// before access. Swimming: CustomWorkout has no swimming location or pool
// length, so with location 'unknown' a 'pool' swim is indoor, 'openWater' outdoor.
// Native screens call the same service as the ScheduledWorkouts module
// (capability `scheduledWorkouts`); or use `scheduledWorkouts` from 'craft-native/mobile'.
// A simulator never has a watch: `simctl spawn <device> defaults write <bundle id>
// CraftFakeWorkoutScheduler -bool YES` keeps plans in the app instead (WorkoutKit
// still builds and checks them). Simulator builds only.

// Files on a native screen (capability `files`, always there): a photo from
// the library (PHPickerViewController, no permission asked) or the camera
// (`source: 'camera'`, capability `camera`, needs enableCamera), saved as an
// upright JPEG with no metadata, no longer than maxPixels (default 2048).
// Null when the picker was closed. The bytes stay on disk: post the file in a
// FormData through fetch, or hand its path to the share sheet.
const photo = await craft.files.pickImage({ maxPixels: 2048, quality: 0.85 });
// { path, name: 'IMG_1234.jpg', type: 'image/jpeg', size, width, height }
// General documents use the same owned-file path and can be selected more
// than one at a time. Filters are MIME types, UTIs, or filename extensions.
const attachments = await craft.files.pickFile({
  contentTypes: ['application/pdf', 'csv', 'gpx', 'fit'],
  maxSelections: 4,
  maxBytes: 20 * 1024 * 1024,
});
// [{ path, name, type, size }], or [] when the picker is dismissed.
const form = new FormData();
form.append('photo', photo);                      // multipart, built natively
await fetch('https://example.com/upload', { method: 'POST', body: form });
// A file for the share sheet (Save to Files, AirDrop, another app), fetched
// straight to disk with your headers. Not 2xx: { ok: false, status, body }.
const gpx = await craft.files.download('https://example.com/route.gpx', { headers: { Authorization: 'Bearer …' } });
if (gpx.ok) await craft.share({ files: [gpx] });   // a file, or its path
await craft.files.remove(gpx.path);               // or leave it: tmp, swept after a day
// Something the screen made itself (a CSV export): text crosses the bridge
// once, as it is; bytes go as base64 ({ encoding: 'base64' }).
const csv = await craft.files.write('health-data.csv', 'date,steps\n…', { type: 'text/csv' });
await craft.share({ files: [csv] });

// Speech: short spoken cues that duck the person's music instead of stopping
// it, and play with the silent switch on. Always available (no config flag).
// Resolves when the utterance ends: true if spoken, false if stopped or
// interrupted. Rejects with INVALID_ARGUMENT for empty text.
const spoken = await window.craft.speech.speak('Rest, 15 seconds. Up next: Dead Bug', {
  rate: 1,          // 0.5 to 2, 1 = normal
  language: 'en-US', // BCP-47; defaults to the device's language
  interrupt: true   // default: stop what is being said first; false queues
});
await window.craft.speech.stop(); // pending speak() calls resolve false
// Or `import { speech } from 'craft-native/mobile'`: the same calls, falling
// back to the Web Speech API in a browser and resolving false where neither
// exists. speech.isAvailable() says which.

// Orientation Lock
window.craft.lockOrientation('portrait');   // Lock to portrait
window.craft.lockOrientation('landscape');  // Lock to landscape
window.craft.unlockOrientation();           // Allow all orientations

// ==================== Medium Value Bridges ====================

// Background Tasks (iOS 13+)
await window.craft.backgroundTask.register('sync-data');
await window.craft.backgroundTask.schedule('sync-data', {
  delay: 900,              // 15 minutes minimum
  requiresNetwork: true,
  requiresCharging: false
});
await window.craft.backgroundTask.cancel('sync-data');
await window.craft.backgroundTask.cancelAll();

// PDF Viewer
await window.craft.openPDF('https://example.com/document.pdf');
await window.craft.openPDF(base64PdfData, 5); // Open at page 5
await window.craft.closePDF();

// Contacts Picker (shows native picker UI)
const contact = await window.craft.pickContact();
console.log(contact); // {id, givenName, familyName, displayName, phoneNumbers, emailAddresses}

const contacts = await window.craft.pickContact({multiple: true}); // Select multiple

// App Shortcuts (3D Touch / long press)
await window.craft.shortcuts.set([
  {type: 'new-message', title: 'New Message', subtitle: 'Start composing', iconName: 'square.and.pencil'},
  {type: 'search', title: 'Search', iconName: 'magnifyingglass'}
]);
window.craft.shortcuts.onShortcut((shortcut) => {
  console.log('Shortcut activated:', shortcut.type);
});
await window.craft.shortcuts.clear();

// Keychain Sharing (cross-app data with access groups)
await window.craft.sharedKeychain.set('user*token', 'abc123', 'com.example.shared'); // group optional
const result = await window.craft.sharedKeychain.get('user*token', 'com.example.shared');
console.log(result.value); // 'abc123'
await window.craft.sharedKeychain.remove('user*token');

// Local Auth Persistence (skip re-auth for a duration)
await window.craft.authPersistence.enable(300); // 5 minutes
const status = await window.craft.authPersistence.check();
if (status.isValid) {
  console.log('Session valid for', status.remainingSeconds, 'more seconds');
}
await window.craft.authPersistence.clear();

// ==================== Nice to Have Bridges ====================

// AR (ARKit) - Requires iOS device with A9+ chip
await window.craft.ar.start({planeDetection: true});
window.craft.ar.onPlaneDetected((plane) => {
  console.log('Plane detected:', plane.id, plane.alignment);
});

// Place 3D objects (built-in shapes or .usdz/.scn files)
const obj = await window.craft.ar.placeObject('box', {x: 0, y: 0, z: -0.5});
console.log('Object placed:', obj.objectId);
// Built-in shapes: 'box', 'sphere', 'cylinder', 'cone'
// Or provide URL to .usdz or .scn file

// Get detected planes
const planes = await window.craft.ar.getPlanes();
console.log(planes); // [{id, alignment, center, extent}]

// Remove object
await window.craft.ar.removeObject(obj.objectId);

// Stop AR session
await window.craft.ar.stop();

// ML (Vision Framework)
// First capture an image
const image = await window.craft.openCamera();

// Image Classification - Identify what's in the image
const labels = await window.craft.ml.classifyImage(image);
console.log(labels); // [{label: 'cat', confidence: 0.95}, ...]

// Object Detection - Detect and locate objects
const objects = await window.craft.ml.detectObjects(image);
console.log(objects); // [{labels: [...], boundingBox: {x, y, width, height}}]

// Text Recognition (OCR) - Extract text from image
const textResults = await window.craft.ml.recognizeText(image);
console.log(textResults); // [{text: 'Hello World', confidence: 0.98, boundingBox: {...}}]

// ==================== Widgets (WidgetKit) ====================

// Update widget data - displayed on home screen widget
await window.craft.widget.update({
  title: 'My App',
  subtitle: 'Latest update',
  value: '42',
  icon: 'star.fill' // SF Symbol name
});

// Reload all widgets
await window.craft.widget.reload();

// ==================== Siri Shortcuts ====================

// Register a Siri shortcut
await window.craft.siri.register('Open my app', 'open*app');

// Remove a Siri shortcut
await window.craft.siri.remove('open*app');

// Listen for Siri shortcut invocations
window.craft.siri.onInvoke((detail) => {
  console.log('Siri invoked:', detail.action);
});

// ==================== Watch Connectivity ====================

// Check if watch is reachable
const status = await window.craft.watch.isReachable();
console.log(status.reachable); // true/false

// Send message to watch
const reply = await window.craft.watch.send({
  action: 'ping',
  data: { timestamp: Date.now() }
});

// Update application context (synced to watch)
await window.craft.watch.updateContext({
  lastUpdate: Date.now(),
  status: 'active'
});

// A planned workout is delivered through application context, so the latest
// plan replaces an older one while the watch is offline and is replayed when
// the companion launches. The watch persists its current plan and metrics in
// its own UserDefaults store, then publishes a `watch-state` context back.
await window.craft.watch.updateContext({
  type: 'planned-session',
  plan: {
    id: 'morning-run',
    activity: 'running',
    startDate: Date.now() + 60 * 60 * 1000,
    targetDistanceMeters: 5000,
  },
});

// Watch controls include a protocol version and requestId. Use requestId for
// idempotency when a queued command arrives after a reconnect. The watch's
// `watch-state` context includes a monotonically increasing stateVersion; use
// the highest version when a queued command and a reconnect snapshot cross.
await window.craft.watch.send({ type: 'recording-control', action: 'start' });

// Listen for messages from watch
window.craft.watch.onMessage((message) => {
  console.log('Watch message:', message);
});

// Listen for watch reachability changes
window.craft.watch.onReachabilityChange((status) => {
  console.log('Watch reachable:', status.reachable);
});
```

### Native UI, appearance and background (iOS)

Every call below returns a promise that settles and never throws: a failure
answers with what "nothing happened" means for it. `craft-native/mobile`
exports the same calls typed (`dialog`, `contextMenu`, `browser`, `symbols`,
`statusBar`, `chrome`, `refresh`, `background`, `appearance`), resolving
outside the shell too.

```javascript
// Haptics by kind, each on UIKit's own generator, kept warm.
await craft.haptics.impact('rigid');          // light, medium, heavy, soft, rigid
await craft.haptics.notification('success');  // success, warning, error
await craft.haptics.selection();
await craft.haptics.prepare('selection');     // before a gesture that will play one

// System dialogs. An anchor is a rect in CSS pixels or an element.
await craft.dialog.alert({ title: 'Saved' });
const ok = await craft.dialog.confirm({ title: 'Delete workout?', confirmLabel: 'Delete', destructive: true });
const choice = await craft.dialog.actionSheet({
  title: 'Workout',
  anchor: button,
  actions: [{ id: 'edit', title: 'Edit' }, { id: 'delete', title: 'Delete', style: 'destructive' }],
}); // the id, or null when dismissed

// The system context menu (iOS 17.4+; the edit menu, then an action sheet, before).
const picked = await craft.contextMenu.show({
  anchor: row,
  items: [{ id: 'duplicate', title: 'Duplicate', symbol: 'plus.square.on.square' }, { id: 'delete', title: 'Delete', symbol: 'trash', destructive: true }],
});

// SFSafariViewController, or the system web sign-in sheet.
await craft.browser.open('https://example.com');
const { url, cancelled } = await craft.browser.open(authorizeURL, { mode: 'auth', callbackScheme: 'hqtraining' });

// An SF Symbol as a PNG data URL.
img.src = await craft.symbols.image('heart.fill', { pointSize: 22, weight: 'semibold', color: '#e11d48' });

// Chrome around the page.
await craft.statusBar.setStyle('light');           // default, light, dark
await craft.chrome.setUnderPageColor('#020617');    // shown past the page's edges
await craft.chrome.setKeyboardAccessory(true);

// Native pull to refresh.
await craft.refresh.enable({ tintColor: '#22c55e' });
craft.refresh.onRefresh(async () => { await reload(); craft.refresh.end(); });
```

Events on `window`:

| Event | Detail | When |
| --- | --- | --- |
| `craftAppearance` | `{ contentSizeCategory, fontScale, reduceMotion, reduceTransparency, colorScheme }` | with `craftReady`, and whenever Dynamic Type, Reduce Motion, Reduce Transparency or Light/Dark changes. The root element also carries `--craft-font-scale`, `data-craft-reduce-motion`, `data-craft-reduce-transparency` and `data-craft-content-size` from the first byte; `craft.appearance` reads the current values. |
| `craftResume` | `{ backgroundedMs }` | the app returned to the foreground |
| `craftMemoryWarning` | `{}` | iOS is short of memory |
| `craftSilentPush` | `{ id, payload }` | a `content-available` push; answer with `craft.background.complete(ok, id)` within 25 s |
| `craftBackgroundRefresh` | `{ id }` | the scheduled refresh ran; answer the same way |
| `craftRefresh` | `{}` | the native pull-to-refresh was pulled |

## CLI Reference

```bash
craft ios init <name>           # Initialize new iOS project
craft ios build                 # Build and generate Xcode project
craft ios open                  # Open Xcode project
craft ios run --simulator       # Run on iOS Simulator

Options:
  --bundle-id <id>          Bundle identifier
  --team-id <id>            Apple Developer Team ID
  --html-path <path>        Path to HTML file
  -d, --dev-server <url>    Development server URL
  -o, --output <dir>        Output directory (default: ./ios)
  -s, --simulator           Run on simulator
```

Simulator selection uses the active Xcode's iOS Simulator SDK. Runtimes newer
than that SDK are excluded, including already booted devices. Select a matching
Xcode or install a compatible runtime when none is available.

## Requirements

- macOS with Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Apple Developer account (free or paid)
- iPhone running iOS 15+ (for device deployment)

## Permissions

Add to your Info.plist as needed:

```xml
<!-- Speech Recognition -->
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition for voice commands.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access for speech recognition.</string>

<!-- Camera -->
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to take photos.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs photo library access.</string>

<!-- Location -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs your location.</string>

<!-- Face ID -->
<key>NSFaceIDUsageDescription</key>
<string>This app uses Face ID for authentication.</string>

<!-- NFC -->
<key>NFCReaderUsageDescription</key>
<string>This app reads NFC tags.</string>

<!-- Bluetooth -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth.</string>

<!-- Health -->
<key>NSHealthShareUsageDescription</key>
<string>This app reads health data.</string>
<key>NSHealthUpdateUsageDescription</key>
<string>This app writes health data.</string>

<!-- Contacts -->
<key>NSContactsUsageDescription</key>
<string>This app accesses your contacts.</string>

<!-- Calendar -->
<key>NSCalendarsUsageDescription</key>
<string>This app accesses your calendar.</string>
```

## Runtime Validation

The Zig-native bridge rejects malformed values and overlapping interactive
requests that the legacy Swift dispatcher could silently truncate, coerce, or
abandon. See the
[mobile runtime compatibility guide](../../docs/api/mobile/runtime-compatibility.md)
for the affected input classes and migration guidance.

## Development Mode

For hot-reload during development:

```bash
# Terminal 1: Start your dev server
bun run dev  # e.g., http://localhost:3456

# Terminal 2: Build iOS with dev server
craft ios build --dev-server http://localhost:3456
craft ios open
```

The app will load from your dev server instead of bundled HTML.

## Template compiler gate

On macOS with Xcode and XcodeGen installed, run `bun run test:templates` from
`packages/ios`. It generates a minimal app, a capability-heavy iOS app, and the
same capability-heavy app with a Watch companion. It builds iOS, Live Activity,
Watch extension, and Watch app targets against device SDKs with code signing
disabled.

The Watch-enabled app is also built the way Xcode builds it for a person, with
the Watch app embedded. The script checks that the bundle carries
`Watch/<App>Watch.app` with `WKWatchKitApp` and its WatchKit extension, then
installs the app on an iOS simulator. That needs a watchOS simulator runtime
matching the selected Xcode (`xcodebuild -downloadPlatform watchOS`), and the
script fails without one rather than skipping.

Finally, a push-enabled app is built for the simulator in Debug and Release with
ad-hoc signing. The script reads the `aps-environment` Xcode actually signed
into each: `development` for Debug, `production` for Release.

This checks the actual generated Swift and Xcode projects; `bun test` checks the
builder's behavior separately.
Temporary projects are removed after the run. Pass `--keep` to retain them for
debugging.

## Publishing

Build for App Store:

```bash
craft publish --ios
```

This will:

1. Build a release archive
2. Output path for manual upload to App Store Connect

## License

MIT

### Custom native fonts

Set `nativeFonts` to bundle TTF/OTF files and their licenses. Keys are the font's
PostScript name (for example `Allura-Regular`); use that same name in a native
Text node's `fontFamily` style. Paths are local files, resolved before packaging.

```ts
nativeFonts: {
  'Allura-Regular': { src: '/app/fonts/Allura-Regular.ttf', license: '/app/fonts/OFL.txt' },
}
```

The iOS project registers the files through `UIAppFonts`. Android loads bundled
typefaces from assets. Both work offline; a missing file fails the build.

### Platform selection, clear fields and sheets

`SegmentedControl` takes `items: [{value, label, disabled?}]` and a controlled
`value`, and emits `onValueChange` with `{value, index}`. iOS uses UIKit's
`UISegmentedControl`; Android uses a horizontal native `RadioGroup` with
selected segments. Reconciliation does not emit a user selection.

`TextInput.clearButtonMode` is `never`, `while-editing`, `unless-editing` or
`always`. The native clear affordance emits a single text edit carrying
`{text: '', clear: true}`; Android also exposes a TalkBack clear action.

`Modal` accepts `presentationStyle: 'pageSheet' | 'formSheet'` with
`sheetDetents: ['medium', 'large']`, `selectedDetent` and `grabberVisible`.
iOS presents a real `UISheetPresentationController`, including system pan
and detents; Android sizes its native bottom panel to the selected detent
without an extra dependency. Omitting presentationStyle keeps the existing
full-screen overlay. A native sheet's close request still belongs to its
owner, which sets visible to false.


### Controlled native paging and font families

A horizontal `ScrollView` with `pagingEnabled: true` and a numeric `pageIndex`
uses viewport-sized direct children. The host advertises `nativePager` and emits
`onPageSelected` with `{ index, count }` after initial layout, count changes and
settled user selection. Updates to `pageIndex` select a page; removed pages clamp
the index and resizing preserves it. Offscreen pages stay mounted but are hidden
from native accessibility. `scrollEnabled: false` locks swiping while retaining
controls in the selected page. Without `pageIndex`, scroll content keeps its
ordinary intrinsic layout; this is an opt-in contract for a shared Pager.

Text `fontFamily` accepts a CSS fallback list. Bundled/custom fonts take priority
when available. `monospace`/`ui-monospace`, `serif`/`ui-serif` and
`sans-serif`/`ui-sans-serif`/`system-ui` select platform fonts, retaining requested
weight, italic style and system text scaling. A missing custom face falls through
to the next family rather than silently replacing a requested mono font with sans.
