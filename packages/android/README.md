# @craft-native/android

Build native Android apps with web technologies using Craft.

`appLinks` path rules use the website association wildcards: `*` matches zero
or more characters, `?` matches one, and `?*` matches one or more. The first
matching rule decides whether a link opens in the app or browser. For example,
`/gyms/*/?*` excludes a nonempty subpath without excluding `/gyms/trifit/`.
The `?` and `?*` wildcards require Craft 0.0.204 or later.

## Features

### Core

- **WebView or native STX** - Choose the browser renderer or Android views driven by a compiled STX bundle
- **Dark Mode** - Native dark/light theme support

### Input & Feedback

- **Native Speech Recognition** - Android SpeechRecognizer
- **Haptic Feedback** - Vibration patterns for different feedback types
- **Audio Recording** - MediaRecorder with compressed output
- **Video Recording** - Camera video capture

### Device Access

- **Camera & Gallery** - Take photos or pick from gallery
- **Barcode/QR Scanner** - ML Kit barcode scanning
- **File Picker** - Document picker for any file type
- **File Download** - DownloadManager integration

### Sensors & Location

- **Geolocation** - GPS and network location via FusedLocationProvider
- **Motion Sensors** - Accelerometer & gyroscope via SensorManager
- **NFC** - Read NFC tags via NfcAdapter

### Communication

- **Share Sheet** - Native Android sharing
- **Clipboard** - Read and write to system clipboard
- **Push Notifications** - Firebase Cloud Messaging ready

### Security & Auth

- **Biometric Auth** - Fingerprint / Face unlock
- **Social Auth** - Google Sign In
- **Secure Storage** - EncryptedSharedPreferences

### Data & Storage

- **Local Database** - SQLite with full SQL support
- **Bluetooth LE** - BluetoothLeScanner

### System

- **Device Info** - Device model, OS version, screen info
- **Network Status** - Connection type monitoring (WiFi/Cellular)
- **Capability Reporting** - Unsupported app badges are reported honestly
- **App State** - Foreground/background detection
- **Flashlight** - Camera flash control
- **Open URL** - External browser launch
- **Vibration Pattern** - Custom vibration sequences
- **App Review** - Google Play In-App Review prompt
- **Screen Capture** - Take screenshots programmatically
- **Health/Fitness** - Health Connect integration

## Installation

The Android support is built into the main `craft` CLI:

```bash
bun add craft-native
```

## Quick Start

For CI device tests, `@craft-native/android` also exports
`createAndroidEmulator()`. Provision the pinned JDK and Android command-line
tools with the Pantry action, then pass absolute `sdkmanager` and `avdmanager`
paths, `sdkRoot`, `image`, `artifactsDirectory`, and an explicit `acceleration`
mode. The image ABI must match the host. For example:

```ts
import { createAndroidEmulator } from '@craft-native/android'

const device = await createAndroidEmulator({
  sdkRoot: '/ci/android-sdk',
  sdkmanager: '/ci/pantry/.bin/sdkmanager',
  avdmanager: '/ci/pantry/.bin/avdmanager',
  image: 'system-images;android-35;google_apis_playstore;x86_64',
  acceleration: 'hardware',
  memoryMb: 4096,
  artifactsDirectory: '/ci/artifacts/android',
  acceptLicenses: true,
})
try {
  // Use device.adb, device.serial and device.env for the app's acceptance tests.
}
finally {
  await device.dispose()
}
```

`hardware` requires a successful emulator acceleration probe. `software` uses
the Android emulator's explicit `-accel off` mode on x86_64 hosts. Android
[documents that CPU emulation mode as unsupported](https://developer.android.com/studio/run/emulator-commandline#startup-options);
it is available for explicit diagnostics and does not provide release acceptance.
Software graphics (`-gpu software`) are independent of CPU acceleration. The public
helper defaults to a ten-minute boot budget, and hardware mode cannot exceed
it. Software callers may explicitly set `bootTimeoutMs` up to twenty minutes.
`memoryMb` selects the requested guest RAM, defaulting to 2048 MB. It accepts
the emulator's documented [1536–8192 MB range](https://developer.android.com/studio/run/emulator-commandline#startup-options).
`virtualCpus` selects the guest CPU count, defaulting to 2 and accepting values
from 1 through 8. The stock Play acceptance verifier requests two guest CPUs.
Receipts retain the actual host model and guest allocation. Reaching launcher
focus after a platform ANR does not establish a healthy cold boot.
The stock Play verifier requests 4096 MB after retained cold boots
showed low-memory/process-death churn and a SystemUI ANR. The image and complete
readiness checks remain the same.
The stock Play CI verifier provisions runner access to KVM and tests a cold
boot of the unmodified API 35 Play image through the public SDK. The hardware
budget remains ten minutes. A separate TCG diagnostic retains its twenty-minute
budget and exact-image check. The API 35 image took 943,520 ms in the retained diagnostic run
[39113277828](https://github.com/craft-native/craft/actions/runs/39113277828).
This is OS provisioning before app installation; app and performance budgets
are unchanged. Both modes require a complete event-history read and reject
recorded platform ANR or crash events, including faults before launcher focus
recovers. SettingsProvider,
the package manager and System UI to be ready, with HOME resolved beyond the
automatic Android SDK setup activity and its launcher package owning the current
input-focus window. Logs record the budget, actual
boot duration, host CPU interval, selected image, acceleration
probe, process identity and boot result. Disposal reaps only the owned process
and deletes only its disposable AVD; the managed SDK and other devices remain
available.

### 1. Initialize Project

```bash
craft android init MyApp --package com.example.myapp
cd android
```

### 2. Add Your Web Content

Replace `app/src/main/assets/index.html` with your web app, or point to a dev server:

```bash
craft android build --html-path ../dist/index.html
# or
craft android build --dev-server http://10.0.2.2:3456
```

For a WebView-free app, initialize with `--renderer native` and give the build
the same route bundle that `stx native compile` produces for iOS:

```bash
craft android init MyApp --package com.example.myapp --renderer native
cd android
stx native compile --config ../screens/native.config.json --format bundle --output ../native-screen.js
craft android build --native-bundle ../native-screen.js
```

Native mode maps STX `View`, `SafeAreaView`, `KeyboardAvoidingView`, `StatusBar`,
`RefreshControl`, `Text`, `Button`, `Link`, `Icon`,
`Pressable`, `TouchableOpacity`, `TouchableHighlight`, `Checkbox`, `TextInput`, `Picker`, `SegmentedControl`, `DatePicker`, `Modal`, `Switch`, `Slider`, `ActivityIndicator`, `Image`, `ImageBackground`, `Video`, `Svg`, `G`, `SvgText`, `ScrollView`,
`Map`, `SectionList`, and `FlatList` to Android views. `Map` uses the configured
native map provider for trail polylines and marker taps; its overlays carry flat
latitude/longitude `geometry` arrays, `strokeWidth` is expressed in logical
points, and the camera supports controlled `region`, one-time `initialRegion`,
and `fitToBounds`. Select `mapProvider: 'maplibre'` for the key-free native
MapLibre renderer. It uses native GL views and needs neither a Google map SDK
dependency nor a Google map key. `mapProvider: 'google'` retains the existing
Google Maps host and uses `mapsApiKey` for its SDK manifest key; Google remains
the default for compatibility with existing projects.

Reactive `StatusBar` props update the visible window during targeted native
mutations, including light/dark icon contrast and visibility. Retained screens
keep their own values; unchanged props leave the current window appearance alone.

Coordinates must be JSON numbers (numeric strings are not coerced), are
range-checked at the native boundary, and invalid points or pole-crossing
regions are ignored. `fitToBounds` waits for the map viewport to
be measured before caching a successful camera fit, so an early map callback
does not lose the initial route framing.
The shared controls include `showsCompass`, `showsScale`, `pitchEnabled`,
`cameraPitch`, `cameraHeading`, and floating-control `edgePadding`. Markers
accept `pinColor` and route-direction `bearing`. The builder's
`nativeMapProviders` export advertises the providers it actually implements,
so a build orchestrator can refuse an unsupported explicit choice.

`SectionList` uses the same
native scroll host for ordinary `.stx` slot children; grouped section data
should use `FlatList` until the section-data protocol is available. The
generated host routes both list names through `CraftNativeScrollView` for this
slot-based contract. `ScrollView` also supports `stickyHeaderIndices` and
`scrollTarget` for vertical native content. `Picker` renders `<select>`/`<option>` values
with `onValueChange` or `onChange`. `DatePicker` uses the platform `DatePicker`
and `TimePicker` controls for date, time, datetime, and countdown modes and
emits local `value`, ISO, and millisecond `timestamp` fields. `Modal` is parent-scoped and supports
`visible`, `transparent`, `nonModal`, `dismissOnOutsideTap`, `animationType`, `onShow`,
`onDismiss`, and `onRequestClose` for Android back handling. Non-modal popups remain
pass-through unless outside-tap dismissal is explicitly enabled. System Back dismisses
the top modal before it pops the native route. `Switch` supports state-aware `trackColor`
and `thumbColor`, while `Slider` supports track/thumb tint props and `step`
snapping without collapsing stepped ranges to a fixed pixel-like precision.
`View.measure` and non-modal absolute `left`/`top` placement use the same
`screenViewport` origin; safe-area offsets are not added implicitly. Re-run
measurement after the anchor or screen root emits `onLayout`, and after every
`onScroll` from an ancestor; those are the host-neutral invalidation signals for
repositioning an anchored popup.
`ActivityIndicator` keeps a visible stopped indicator genuinely
non-animated when `animating={false}` and `hidesWhenStopped={false}`. `Image`
reports load lifecycle events and structured failures. Native image sources
accept HTTPS everywhere and loopback HTTP for local development (`localhost`,
`127.0.0.1`, `10.0.2.2`, `::1`, and `*.localhost`); public HTTP and unsupported
schemes are rejected. `Video` uses the native
`VideoView` for URI playback with autoplay, pause, looping, mute, controls, and
resize-mode props.
`ImageBackground` loads an image behind ordinary native children while
preserving the shared flex layout contract. `Svg` is a DOM-free drawing
surface; grouped `G` and `SvgText` nodes are painted inside it.
Grid tracks retain fractional widths and row distribution until Android lays
out the final pixel frames, matching the shared native layout contract.
`Icon` uses the shared symbol/name contract with a dependency-free Android
glyph map; unknown symbols render a hollow-circle fallback instead of an empty
native node.
`KeyboardAvoidingView` responds to Android IME insets with `padding`,
`position`, or `height` behavior and accepts `keyboardVerticalOffset`.
`Checkbox` accepts controlled `checked`/`value` and `indeterminate`; mixed
controls expose an Android accessibility state description of `mixed` and
become checked on their first user toggle.
`FlatList` uses
`RecyclerView`, stable IDs, and `DiffUtil` for keyed `:for` child-row
recycling, grids, horizontal and inverted layouts, list chrome, and end-reached
pagination; the maintained native protocol does not serialize `data`/`renderItem`
callbacks.
Flex items support `flex`, `flexGrow`, `flexShrink`, and numeric or percentage
`flexBasis` for main-axis space distribution while preserving gaps and margins.
The screen's document root fills its viewport unless it declares a height,
matching iOS. This also applies after reactive style updates remove an explicit
height. Ordinary child containers keep their authored flex and intrinsic sizing.
Shared transforms, z-order, view shadows, text shadows, per-edge border
styles, and linear gradients are applied with the same style keys as the iOS
renderer. Android `elevation` remains an additional native shadow input.
`gap`, `rowGap`, and `columnGap` retain fractional density-independent values
through line distribution and round only the final native frames.
Numeric lengths and percentage widths/heights resolve against the native parent
content box, keeping responsive sizing aligned with the iOS renderer.
When `flexShrink` is omitted, horizontal text labels and scroll hosts use the
same shrink defaults as the iOS renderer; buttons and editable fields retain
their intrinsic width unless explicitly configured.
An exact horizontal scroll viewport still measures its content unbounded and
retains that measured child width for the platform's second pass, so a wider
carousel keeps its overflow and receives the horizontal gesture before the tab
shell.
Wrapped containers also honor `alignContent` (`center`, `flex-end`,
`space-between`, `space-around`, `space-evenly`, and `stretch`) consistently
across hosts.
The Android local fallback keeps fractional line and grid spacing until each
child frame is rounded, matching the shared layout ABI when an older runtime
does not expose its optional alignment symbols.
Its flex main-axis fallback applies the same fractional treatment to
`space-around` and `space-evenly` before rounding positions.
Wrapped `alignContent` fallback spacing keeps fractional cross-axis offsets
until each child frame is rounded as well.
The `stretch` fallback also carries fractional per-line expansion into the
child cross-axis frames before rounding.
Reverse flex directions preserve wrapped line order on the cross axis while
reversing each line's main-axis children, matching the iOS host.
Shared wrapped-line IDs are accepted only when they are complete and monotonic;
invalid bridge data falls back to the host layout implementation.
Eligible definite-size flex containers, including reverse and wrap-reverse direct
flows, also serialize their measured children through the host-neutral
`craft_native_layout_tree` ABI. Missing runtimes, unsupported styles, or malformed
frame results retain the local Kotlin layout, so older SDK-only projects keep the
same behavior.
Push, replace, and back preserve the
previous screen's views and JavaScript state; Android's system back button pops
the route. Native mode accepts neither `--html-path` nor `--dev-server`. Its
native bridge supports device info, clipboard read/write, haptic impact,
persistent JSON storage, SQLite queries and transactions, lifecycle and deep-link
events, and local notifications. Storage and SQLite survive process relaunch;
notifications use `AlarmManager`, so delivery does not require a running
JavaScriptSandbox process. Enable `enableLocalDatabase`,
`enableLocalNotifications`, and `enableDeepLinks` explicitly. Disabled or
malformed calls reject with stable capability/error codes, and in-flight calls
have a deadline and cancellation path. The broader browser bridge remains
specific to WebView mode. JavaScriptSandbox has no DOM `window`; Craft aliases
`globalThis.window` to `globalThis` before installing the native bridge so
browser-safe SDK calls such as `window.craft.dialog.actionSheet()` reach the
native capability host. This does not add `document` or DOM rendering; routes
that do not opt into `native` continue using the WebView renderer. Native
`TextInput` applies `placeholderTextColor`,
`selectionColor`, positive `maxLength`, `multiline`, and `numberOfLines` values.
Native views include
`ActivityIndicator` and expose
`onLayout` callbacks with density-independent frame measurements that refresh
after inset or orientation changes. The shared component, capability, list, style,
image-source, event, accessibility, and reconciliation contract is documented in the
[Native STX guide](../../docs/guides/native-stx.md).

Native screens also expose `craft.files` when the host advertises the
`files` capability. `pickImage` returns an app-owned file descriptor,
`download` and `write` keep bytes on disk, and `remove` accepts only files
created by that capability. `FormData` is available on this path; `fetch`
builds its multipart body natively from text fields and those owned files, so
image bytes do not cross the Android JavaScript bridge as base64. The browser
renderer keeps using the ordinary web `File`/`FormData` implementations. Owned
files survive Activity recreation and stale cache entries are swept after a day.
Voice capture uses a separate temporary namespace. With `enableAudioRecording`,
`craft.audioRecording` produces an owned M4A descriptor for multipart uploads.
Cancellation and backgrounding erase both active and stopped captures. The next
native launch removes files left by an interrupted process, including the earlier
recorder's M4A files, without clearing picked files or downloads. Preparing another
screen in the same process preserves the current screen's recording.

`files.download` resolves a non-2xx response as `{ ok: false, status, body }`
instead of turning the server's response into a transport error.

`FlatList` item roots receive the same `onLayout` callback as ordinary native
views when rows are materialized or recycled.

Current bundles negotiate the versioned native mutation protocol and update
only the changed Android views. Older bundles remain compatible through the
whole-document `RENDER` path. Batches are atomic and revision-checked; the
guide documents their wire format and deterministic cross-platform errors.

The native runtime requires Android's JavaScriptSandbox. It prefers message
ports with promise-return support and uses the sandbox's console callback
when those features are unavailable. If neither bridge is supported, the app
displays a clear unsupported-device error; it never silently opens a WebView.
The native-navigation emulator fixture also relaunches the generated app and
reads back storage and SQLite data through the compiled STX bundle.
Support depends on the installed WebView provider, so validate on each device
class you plan to ship. The [Android JavaScriptEngine guide](https://developer.android.com/develop/ui/views/layout/webapps/jsengine)
documents the sandbox and device-support check.

### A whole app of native screens

With `nativeScreens` (paths to the screens that draw them), `tabs` and
`nativeApp` in craft.config.json, the same keys as the iOS builder, the
native renderer is a whole app rather than one bundle route:

`craft android init` and `craft android build` validate every tab and the
configured start path against `nativeScreens`; invalid native route tables are
rejected before a project is generated.

- a tab bar and a navigation bar (`craft.navigation.setOptions`: title, large
  title, right buttons with badges, `tabAccessory`, `tabBarHidden`), a stack per tab, Android's
  Back key popping it; completed left/right swipes switch between tab roots
  interactively, yield to a horizontal scroll view, and can be disabled per
  screen with `craft.navigation.setOptions({ tabSwipeEnabled: false })`;
  each screen may also set `backgroundColor`; omitting it or passing `null`
  follows the app's light/dark background resource, and the navigation bar and
  large title use the same resolved color;
- `craft.navigation.open(path)` matched in the iOS shell's order (fixed segments
  before parameters), a tab's path selecting its tab, a path no screen draws
  opening the site in a Custom Tab; deep links and tapped notifications route
  the same way;
- `craft.navigation.replace('/m/claim?kind=club&slug=rappid')` finishes a flow
  atomically: the host resolves the path and query, closes the current screen,
  and opens or reuses the destination. Android and iOS also keep supporting
  `replace(screenName, params)` for screens without URL routes. A closing isolate
  cannot send a second navigation message, so use this operation when completing
  sign-in instead of sending `popToRoot()` followed by `open(path)`;
- the app script (`nativeApp`) in its own isolate for the app's life, and in a
  WorkManager job for `backgroundRefresh` and silent pushes
  (`craftBackgroundRefresh`, `craftSilentPush`, answered with
  `craft.background.complete`);
  the app script may open a matched path through `craft.navigation.open`, but
  has no native stack of its own, so `push`, `replace`, `back`, and
  `popToRoot` are no-ops;

- `craft.storage.getSync`, `craft.secureStorage.getSync` and `craft.snapshots`:
  JavaScriptSandbox cannot call the host synchronously, so every isolate starts
  with a copy of these stores and the host keeps each copy current. Timers and
  `requestAnimationFrame` (vsync, for the screen on display) are the host's;
  long messages on the console bridge travel in pieces;
- the services the iOS host answers by the same module names: Dialog, Browser
  (Custom Tabs, `mode: 'auth'` callbacks), Linking, Share, Push (FCM),
  Location (with a foreground-service route recording), Media (videos kept
  for offline, played in place of their address), KeepAwake, Brightness,
  StatusBar, Speech and Health;
- `iconsPath` (a `{ viewBox, strokeWidth, icons }` table of SVG bodies keyed by
  icon name and SF Symbol) gives `<Icon>`, tabs and bar buttons the app's own
  vectors in place of Android's glyphs.

Health is Health Connect with the HealthKit contract (`getWorkouts`,
`getDailyStatistics`, `getHeartRateSamples`, `getSamples`, `getSleepIntervals`,
`saveWorkout`, `saveMindfulSession`...), plus `availability`, `grantedTypes`
and `openSettings` (`healthAvailability`). `healthConnect: { read, write,
background, history }` lists the types the manifest declares; Play reviews
each one. `startWorkout`, `pauseWorkout`, `resumeWorkout`, and `endWorkout`
currently provide a foreground lifecycle contract and write the completed
session back through Health Connect. Native apps can additionally set
`enableHealthServices: true` to retain `ExerciseClient` in a foreground
service, check device capabilities, and emit the shared `craftHealthWorkout`
event with live heart-rate, active-energy and distance metrics. The adapter
supports running, walking, hiking and cycling. When `enableHealthConnect` is
also enabled, ending the live session writes its `ExerciseSessionRecord`,
distance, and active-energy totals through the existing Health Connect writer;
without that flag the session still ends natively and returns its typed result.
Unsupported devices or types emit a typed `error` event and leave the Health
Connect fallback untouched.
`bun scripts/test-native-health.ts` runs the Health Connect contract against
an Android 14+ emulator.

`getSamples('bloodGlucose' | 'dietaryCarbohydrates', { startDate, endDate, limit })`
reads Health Connect's `BloodGlucoseRecord` (mg/dL, with the meal relation and
specimen) and nutrition carbs one record at a time, each with its record id.
Health Connect has no insulin record: `insulinDelivery` is accepted and answers
an empty list, and requesting it adds no permission. List `bloodGlucose` under
`healthConnect.read` so the manifest declares `READ_BLOOD_GLUCOSE`.

### Google Wallet

Set `enableWallet: true` to expose `craft.wallet` to native screens. Android
accepts an HTTPS Google Wallet save link, or a signed pass JWT through
`craft.wallet.add({ jwt })`; the latter uses Google's `PayClient` SDK and
returns the result of the native save sheet. `craft.wallet.isAvailable()` asks
the SDK whether the JWT save API is available on this device. `has()` remains
unsupported on Android because Google Wallet does not expose local pass lookup
through this API. Pass signing and updates stay server-side.

### 3. Open in Android Studio

```bash
craft android open
```

### 4. Run on Device

```bash
craft android run
# or specify device
craft android run --device emulator-5554
```

## Configuration

Edit `craft.config.json` in your Android project:

```json
{
  "appName": "MyApp",
  "packageName": "com.example.myapp",
  "version": "1.0.0",
  "versionCode": 1,
  "darkMode": true,
  "appearance": "system",
  "backgroundColor": "#1a1a2e",
  "enableSpeechRecognition": true,
  "enableHaptics": true,
  "enableShare": true,
  "enableCamera": true,
  "enableBiometric": true,
  "enablePushNotifications": false,
  "enableSecureStorage": true,
  "enableGeolocation": true,
  "enableBackgroundLocation": false,
  "enableHealthConnect": false,
  "enableHealthServices": false,
  "enableHeartRate": false,
  "enableWallet": false,
  "enableKeepAwake": true,
  "enableDeepLinks": true,
  "urlSchemes": ["myapp"],
  "trustedOrigins": ["https://app.example.com"],
  "minSdk": 26,
  "compileSdk": 36,
  "targetSdk": 35
}
```

Every `enable*` flag is enforced, not only reported. A call whose capability is
off rejects with `CAPABILITY_DISABLED`, as it does on iOS, and
`window.craft.capabilities` reports the same answer, so a page that
feature-detects and a page that just calls behave the same. Calls that answer
nothing yet, such as `haptic` and `vibrate`, do nothing and say so on the
console. Every flag defaults to off, so an app that shipped without setting one
and relied on Android serving it anyway has to turn it on.

Only the fields shown above are generator options. Enabling background location
also enables foreground geolocation. Push notifications require a regular
`googleServicesFile` whose JSON contains a client matching the generated
Android package. Deep links require at least one valid URI scheme; scheme names
are normalized to lowercase.
The generated runtime supports Android 8.0 / API 26 and newer, exported as
`ANDROID_MIN_SDK`. `minSdk` defaults to that floor; lower values are rejected
before project files are written, including when Health Connect is enabled.
Health Connect normalizes `compileSdk` to at least 36.
Opting into Health Services selects `minSdk: 30` (Android 11) when omitted,
matching its AndroidX library requirement. Explicit minimums below 30 are
rejected before writing the project; higher supported minimums are retained.
The same effective `minSdk` is written to Gradle and both configuration files.
A custom `appIconPath` must be a regular PNG, WebP, JPG, or GIF file; its supported
extension is preserved in the generated drawable resource.

`appearance` accepts `"system"`, `"light"`, or `"dark"`. System follows the
device's DayNight setting and refreshes native controls when that setting
changes; the other two values pin the generated host. If it is omitted,
`darkMode` remains the compatibility switch (`false` pins light, `true` pins
dark).

Native tab-bar selection styling is opt-in and lives in the generated config,
so the generated Kotlin never needs to be patched:

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

`cornerRadius` is measured in dp and `color` is `#RRGGBB`; omit either to keep
its host default. `postGenerate` runs from the generated project root during
`craft android build`, before Gradle compiles the app. Craft passes
`command` and `args` directly without a shell, and supplies
`CRAFT_PROJECT_ROOT`, `CRAFT_PLATFORM=android`, and
`CRAFT_GENERATE_PHASE=build`. An invalid command or non-zero exit fails the
build and includes the hook's stderr in the diagnostic.

Remote app and trusted-origin URLs must use HTTPS. Local development may use
HTTP with `localhost`, `127.0.0.1`, or the Android emulator host `10.0.2.2`.
Origins are normalized before they are stored, and a configured development
server is trusted automatically.

## JavaScript Bridge

Once Craft is initialized, the `window.craft` object is available:

```javascript
// Wait for Craft to be ready
window.addEventListener('craftReady', (e) => {
  console.log('Platform:', e.detail.platform); // 'android'
  console.log('Capabilities:', e.detail.capabilities);
});

// Haptic feedback
window.craft.haptic('light');   // light, medium, heavy
window.craft.haptic('success'); // success, warning, error
window.craft.haptic('selection');

// Speech recognition
window.craft.startListening();
window.craft.stopListening();

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

// Barcode/QR Scanner (ML Kit)
const scannedCode = await window.craft.scanQRCode();
console.log(scannedCode); // "https://example.com"

// File Picker
const file = await window.craft.pickFile(['image/*', 'application/pdf']);
console.log(file.name, file.data); // base64 encoded

// File Download
await window.craft.downloadFile('https://example.com/file.pdf', 'document.pdf');
await window.craft.saveFile(base64Data, 'image.png', 'image/png');

// Social Auth (Google Sign In)
const user = await window.craft.signInWithGoogle();
console.log(user.userId, user.email, user.displayName, user.idToken);

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

// Bluetooth LE Scanning. Rejects when the device has no adapter, Bluetooth is
// switched off, permission is denied, or the platform scanner cannot start.
await window.craft.bluetooth.startScan();
window.addEventListener('craftBluetoothDevice', (e) => {
  console.log(e.detail.name, e.detail.address, e.detail.rssi);
});
window.craft.bluetooth.stopScan();

// Heart rate (enableHeartRate): a Bluetooth strap, or a watch broadcasting its
// heart rate, through the standard Heart Rate Service (0x180D) and its Heart
// Rate Measurement (0x2A37): bpm, sensor contact, energy and RR intervals. The
// same API, answers and events as iOS (CraftHeartRate.kt). Scanning and
// connecting ask for Nearby devices on Android 12+ (location before), or call
// requestAuthorization() from a tap to ask first. A strap's id is its address.
window.addEventListener('craftHeartRate', (event) => {
  // { type: 'device', device: { id, name, rssi } }      a scan found a strap
  // { type: 'reading', bpm, rrIntervals, contact, energyExpended, timestamp, deviceId }
  // { type: 'state', connection, bluetooth, device, lastDevice, bpm, ... }
});
await window.craft.heartRate.scan({ timeout: 15 });
const strap = (await window.craft.heartRate.getDevices())[0]; // strongest signal first
await window.craft.heartRate.connect(strap.id);  // remembered; rejects TIMEOUT after 15 s while still asking
await window.craft.heartRate.reconnect();        // next time: the remembered strap, no scan
// A strap that drops out is asked for again (connection 'reconnecting') with
// an automatic GATT connection until disconnect({ forget }) lets it go.
await window.craft.heartRate.startRecording();   // every reading kept natively, app closed or not
const { samples } = await window.craft.heartRate.stopRecording(); // [{ timestamp, bpm, rr? }]
// While a recording runs a connectedDevice foreground service (and its
// notification) keeps the process reading with the screen locked. Native
// screens call the same service as the HeartRate module (capability
// `heartRate`) and hear the same events. On an emulator,
// `adb shell run-as <package> touch files/CraftFakeHeartRateMonitor` stands in
// a strap ("Simulated HRM", id 00000000-0000-4000-8000-00000000180D) whose
// readings take the 0x2A37 path, as the iOS simulator's does.

// NFC Tag Reading
const nfcData = await window.craft.scanNFC();
console.log(nfcData); // Tag content

// Health/Fitness (Health Connect)
await window.craft.requestFitnessAuthorization();
const steps = await window.craft.getFitnessData('steps', startDate, endDate);

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

// Secure storage (encrypted)
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
console.log(device.model, device.manufacturer, device.systemVersion);

// App badges have no portable Android API, so this is always false.
if (window.craft.capabilities.appBadge) {
  window.craft.setBadge(5);
}

// Network Status
const network = window.craft.getNetworkStatus();
console.log(network.isConnected, network.type); // true, 'wifi'

// Network change listener
window.craft.onNetworkChange((status) => {
  console.log('Network changed:', status);
});
window.craft.offNetworkChange();

// App Review (Google Play In-App Review)
await window.craft.requestReview();

// Flashlight
window.craft.setFlashlight(true);  // turn on
window.craft.setFlashlight(false); // turn off
window.craft.toggleFlashlight();   // toggle

// Open URL (external browser)
window.craft.openURL('https://example.com');

// Vibration Pattern (custom durations in ms)
window.craft.vibrate([100, 50, 100, 50, 200]); // [on, off, on, off, on]

// App State
const state = window.craft.getAppState(); // 'active', 'inactive', 'background'

// App state change listener
window.craft.onAppStateChange((state) => {
  console.log('App state:', state);
});
window.craft.offAppStateChange();

// Logging (appears in Logcat)
window.craft.log('Debug message');

// ==================== High Value Bridges ====================

// Contacts
const contacts = await window.craft.getContacts();
console.log(contacts); // [{id, displayName, phoneNumbers, emailAddresses}]

const newContactId = await window.craft.addContact({
  displayName: 'John Doe',
  phone: '+1234567890',
  email: 'john@example.com'
});

// Calendar Events
const events = await window.craft.getCalendarEvents(startDateMs, endDateMs);
console.log(events); // [{id, title, description, startDate, endDate, location, isAllDay}]

const newEventId = await window.craft.createCalendarEvent({
  title: 'Meeting',
  description: 'Discuss project',
  location: 'Office',
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
  timestamp: Date.now() + 60000, // 1 minute from now
  // or use delay: 60000 // delay in ms
});

await window.craft.cancelNotification('reminder-1');
await window.craft.cancelAllNotifications();

// In-App Purchase (Google Play Billing)
const products = await window.craft.getProducts(['product*id*1', 'product*id*2']);
console.log(products); // [{productId, title, description, price}]

const purchaseResult = await window.craft.purchase('product*id*1');
console.log(purchaseResult); // {purchaseToken, productId, ...}

await window.craft.restorePurchases();

// Keep Screen Awake
window.craft.setKeepAwake(true);  // Prevent screen dimming
window.craft.setKeepAwake(false); // Allow screen dimming

// Screen brightness, 0 to 1: always available (no config flag, no permission).
// A window-level override, so it ends with the window; resetBrightness hands the
// screen back to the system, auto-brightness included. `brightness` from
// 'craft-native/mobile' wraps all three.
const level = await window.craft.getBrightness();
await window.craft.setBrightness(0.1);
await window.craft.resetBrightness();

// Speech: short spoken cues through TextToSpeech, with transient may-duck audio
// focus so the person's music dips instead of stopping. Always available (no
// config flag). A device with no TTS engine resolves false.
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

// Background Tasks are not implemented on Android. These methods reject
// instead of reporting that work was scheduled when no worker can run.
try {
  await window.craft.backgroundTask.schedule('sync-data', {
    delay: 900,
    requiresNetwork: true,
    requiresCharging: false
  });
} catch (error) {
  console.error(error);
}

// PDF Viewer (opens in external PDF app)
await window.craft.openPDF('https://example.com/document.pdf');
await window.craft.openPDF(base64PdfData, 5); // Open at page 5
await window.craft.closePDF();

// Contacts Picker (shows native picker UI)
const contact = await window.craft.pickContact();
console.log(contact); // {id, displayName, phoneNumbers, emailAddresses}

const contacts = await window.craft.pickContact({multiple: true}); // Select multiple

// App Shortcuts (Android 7.1+, long press)
await window.craft.shortcuts.set([
  {type: 'new-message', title: 'New Message', subtitle: 'Start composing'},
  {type: 'search', title: 'Search'}
]);
window.craft.shortcuts.onShortcut((shortcut) => {
  console.log('Shortcut activated:', shortcut.type);
});
await window.craft.shortcuts.clear();

// Shared Preferences (cross-app data with named groups)
await window.craft.sharedKeychain.set('user*token', 'abc123', 'mygroup'); // group optional
const result = await window.craft.sharedKeychain.get('user*token', 'mygroup');
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

// AR (ARCore) - Note: Full ARCore requires native Activity integration
// Use Sceneform or AR Fragment for complete AR functionality
// The bridge API is consistent with iOS for cross-platform code:
await window.craft.ar.start({planeDetection: true});
// Returns error on Android: "ARCore requires native Activity integration"

// ML (ML Kit) - Full support for ML operations
// First capture an image
const image = await window.craft.openCamera();

// Image Classification (Labeling) - Identify what's in the image
const labels = await window.craft.ml.classifyImage(image);
console.log(labels); // [{label: 'Food', confidence: 0.95, index: 1}, ...]

// Object Detection - Detect and locate objects
const objects = await window.craft.ml.detectObjects(image);
console.log(objects); // [{labels: [...], boundingBox: {x, y, width, height}, trackingId: 1}]

// Text Recognition (OCR) - Extract text from image
const textResults = await window.craft.ml.recognizeText(image);
console.log(textResults); // [{text: 'Hello World', confidence: 0.98, boundingBox: {...}}]

// ==================== Widgets (AppWidgetProvider) ====================

// Update widget data - displayed on home screen widget
await window.craft.widget.update({
  title: 'My App',
  subtitle: 'Latest update',
  value: '42',
  icon: 'ic*star' // Android drawable name
});

// Reload all widgets
await window.craft.widget.reload();

// ==================== Google Assistant (App Actions) ====================

// App Actions are declared statically in app/src/main/res/xml/shortcuts.xml.
// Listen for incoming Google Assistant intents forwarded by the bridge.
window.addEventListener('craftVoiceAction', (event) => {
  console.log('Voice action:', event.detail.action);
});

// ==================== Wear OS Connectivity ====================

// Note: Full Wear OS support requires a companion watch app
// This provides the JavaScript API for future integration

// Check if watch is reachable
const status = await window.craft.watch.isReachable();
console.log(status.reachable); // true/false

// Send message to watch (requires companion app)
const reply = await window.craft.watch.send({
  action: 'ping',
  data: { timestamp: Date.now() }
});

// Update application context
await window.craft.watch.updateContext({
  lastUpdate: Date.now(),
  status: 'active'
});

// Listen for messages from watch
window.craft.watch.onMessage((message) => {
  console.log('Watch message:', message);
});
```

## CLI Reference

```bash
craft android init <name>       # Initialize new Android project
craft android build             # Build APK
craft android build --release   # Build release APK
craft android build --watch     # Watch for changes and rebuild
craft android open              # Open in Android Studio
craft android run               # Run on connected device/emulator

Options:
  --package <name>        Package name (e.g., com.example.app)
  --html-path <path>      Path to HTML file
  -d, --dev-server <url>  Development server URL
  -o, --output <dir>      Output directory (default: ./android)
  --release               Build release APK
  -w, --watch             Watch mode
  -d, --device <id>       Target device ID
```

## Requirements

- Android Studio with Android SDK
- JDK 17+
- Gradle 8.11.1 (the generator creates a wrapper pinned to this version)
- ADB (for device deployment)

## Permissions

The generator adds manifest permissions from enabled capabilities:

| Option | Android permissions |
| --- | --- |
| `enableSpeechRecognition` | `RECORD_AUDIO` |
| `enableCamera` | `CAMERA` |
| `enableHaptics` | `VIBRATE` |
| `enableBiometric` | `USE_BIOMETRIC` |
| `enableGeolocation` | `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` |
| `enableBackgroundLocation` | foreground location plus `ACCESS_BACKGROUND_LOCATION` and foreground-service permissions |
| `enablePushNotifications` | `POST_NOTIFICATIONS` |
| `enableKeepAwake` | `WAKE_LOCK` |
| `enableHealthConnect` | the configured Health Connect read/write permissions |
| `enableHealthServices` | foreground/background body-sensor and health permissions, `ACTIVITY_RECOGNITION`, location, `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_HEALTH`; adds `androidx.health:health-services-client` |
| `enableHeartRate` | `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`; `BLUETOOTH`, `BLUETOOTH_ADMIN` and `ACCESS_FINE_LOCATION` up to Android 11; `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE` for the recording's service |

Use `permissions.check('location')` and `permissions.request('location')` from
`craft-native/mobile` for runtime authorization. Android precise and
approximate access both count as a granted foreground location permission;
foreground fixes, watches, and recording accept either grant, with accuracy
controlled by Android. Obtaining a fix is still a separate operation. See the
[Permissions API](../../docs/api/mobile/permissions.md) for status semantics.

## Promise Lifecycle and Concurrency

Promise-based bridge calls have one active request slot per native callback
channel. A second request on the same channel rejects immediately with an
`already in progress` error, without replacing the first request's callbacks.
Calls on different channels can run concurrently. Some related methods share a
channel—for example, shortcut mutations serialize with other shortcut
mutations—so callers should await one before starting the next.

Native success, error, cancellation, and timeout callbacks settle a request at
most once. Synchronous JavaScript-interface failures are converted to Promise
rejections. Permission requests use request IDs and a 30-second timeout, while
one-shot location requests use a 15-second timeout. Destroying the bridge
rejects all pending work and any new request, while callbacks queued by the old
Activity lifecycle are ignored. Reinjecting the bridge rejects old work and
opens a fresh runtime.

## Template Validation

Android projects generated with the default and capability-heavy configurations
are assembled in CI, and their Kotlin permission tests are run. Contributors
with JDK 17, Android SDK 36, and Gradle 8.11.1 installed can run the same check:

```bash
cd packages/android
bun run test:templates
```

## Development Mode

For hot-reload during development:

```bash
# Terminal 1: Start your dev server
bun run dev  # e.g., http://localhost:3456

# Terminal 2: Build for an Android emulator
craft android build --dev-server http://10.0.2.2:3456

# Open in Android Studio and run on device
craft android open
```

The emulator resolves `10.0.2.2` to the host machine. For a physical device,
use an HTTPS development endpoint. The app will load from that server instead
of bundled HTML.

## Publishing

`build({ release: true, bundle: true })` runs `bundleRelease` and writes
`app/build/outputs/bundle/release/app-release.aab`, signed with the upload key
from `CRAFT_ANDROID_KEYSTORE` (the keystore's path), `CRAFT_ANDROID_KEYSTORE_PASSWORD`,
`CRAFT_ANDROID_KEY_ALIAS` and `CRAFT_ANDROID_KEY_PASSWORD` (the keystore password
when unset). Without them the release build is unsigned.

Build release APK/AAB:

```bash
craft publish --android
```

This will:

1. Build a release AAB (Android App Bundle)
2. Output path for manual upload to Play Console

For automated uploads, integrate with fastlane:

```bash
fastlane supply --aab ./android/app/build/outputs/bundle/release/app-release.aab
```

### Native crash symbols

`zig build build-android-all` strips the DWARF out of each release
`libcraft.so` before the generator copies it into `jniLibs`. With it, the
library was about 5.5 MB per ABI in every APK. The symbol table stays, so a
native crash tombstone still names functions. The DWARF goes to
`zig-out/android-symbols/<abi>/libcraft.so.debug`, linked from the library by
`.gnu_debuglink`.

To symbolicate a crash, point `ndk-stack -sym` at that directory. To have Play
Console symbolicate for you, upload the `.debug` files as the release's native
debug symbols. A `-Doptimize=Debug` build keeps the debug info in the library
itself.

## Kotlin fixture tests

`runKotlinFixture` compiles and runs a standalone Kotlin source file containing
`fun main()`. It requires Gradle and a JDK on PATH and resolves the Android
builder's Kotlin compiler and its transitive dependencies through Gradle.

```ts
import { runKotlinFixture } from 'craft-native/android'

await runKotlinFixture('fun main() { check(2 + 2 == 4) }')
```

Compilation failures and failed checks reject the promise. The temporary
project is removed after execution. This is also how Craft and consuming apps
execute the native input reconciler regressions, without assuming a particular
Gradle cache layout.

## Native image caching

Native `Image` keeps anonymous responses marked `public` with a positive
`Cache-Control: max-age` in a bounded disk cache, so photos remain available
after an offline app restart. The cache holds at most 32 MiB of encoded pixels
and 128 entries, with an 8 MiB limit per image. Freshness and pixels are written
atomically; failed cache writes do not fail a successful image download.

Requests with custom headers, cookie responses, `no-store`, `no-cache`, and
account-dependent variants are not persisted. Expired entries are fetched
again. Image pixels honor authored rounded corners without requiring a
container to hide overflow.

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
