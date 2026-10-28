# Native STX on iOS and Android

Craft's experimental `native` mobile renderer runs a compiled STX route bundle
without a browser view. iOS evaluates the bundle with JavaScriptCore and creates
UIKit controls. Android evaluates the same bundle with JavaScriptSandbox and
creates Android views. Native mode never creates `WKWebView` or `WebView`, and it
fails visibly when its bundle or JavaScript runtime is unavailable.

The default renderer remains `web`. Opting into native mode does not change an
existing web-rendered application.

## Shared components and release boundaries

Author common UI, state and handlers as stx components and typed TypeScript
composables. stx performs template composition, native IR translation and reactive
bindings; Craft supplies the UIKit and Android controls and device capabilities.
Do not copy native host source into an application to compensate for an unsupported
translation. Fix the reusable behavior in stx or Craft and consume the package.

The same source and signals model make reuse possible; they do not automatically
merge an application's separately written browser and native screen files. Check
both targets with the same route and data, and review compiler diagnostics for
unsupported utilities, elements, styles and events. Browser screenshots cannot
verify native controls, navigation, permissions or background work.

Native screens, imported client helpers and the host ship in the installed app.
Code or capability changes need a new build and release. A website deployment
updates web-rendered pages and server behavior; it does not replace the native
bundle. A native app's configured site URL is its API and navigation origin,
not a remote source for its native UI.

## Build the same bundle for both platforms

Configure routes in `native.config.json`, then compile from the directory that
contains that file with the stx CLI:

```bash
stx native compile --format bundle --output ./native-screen.js

craft ios init MyApp --renderer native --output ./ios
craft ios build --output ./ios --native-bundle ./native-screen.js

craft android init MyApp --package com.example.myapp --renderer native --output ./android
craft android build --output ./android --native-bundle ./native-screen.js
```

Native mode does not accept a web distribution (`--html-path`) or a
development server (`--dev-server`). The bundle must be local at build time:
`--native-bundle`, or `nativeBundle` in the config, which `init` and every
`build` install as `dist/native-screen.js`. `devServerURL` in the config is
still allowed: in native mode it names the app's site (see below).

## Native script and lifecycle semantics

The native compiler runs each route's client script through the shared stx
signals runtime. Use `state`, `derived`, and `effect` in ordinary `<script>`
blocks; bindings update native controls through the mutation protocol. Native
scripts also receive the `globalThis.craft` route, navigation, storage, and
capability APIs from the host.

Native `View`, `Text`, `Button`, and `Link` props also accept `onClick` as a
DOM-compatible alias for `onPress`; `@click` lowers to the same native event.
Maps accept `standard`, `satellite`, or `hybrid` styles and keyed `polylines`
and `markers` arrays on both maintained hosts; child map overlays remain
supported.

Native screens do not run in a browser context. The host supplies the language
runtime, `globalThis.craft`, `fetch`, timers, and the enabled capability APIs,
but it does not provide browser URL or encoding globals. `URL`,
`URLSearchParams`, and `TextEncoder` are installed as named failures when they
are otherwise absent, so a shared helper fails with an actionable message
instead of an unrelated `ReferenceError` after a screen has already started
loading. Use an absolute URL or `encodeURIComponent` for request paths and
query strings, and use a native-supported encoding helper for byte conversion.
This behavior is identical on iOS JavaScriptCore and Android
JavaScriptSandbox; it is not a capability gate and does not change the web
renderer.

The maintained Mobile E2E workflow checks out one released STX compiler version
for both simulator hosts. The workflow-level `STX_COMPILER_VERSION` is the
single source of truth for every native checkout; update that one value when a
new STX release is qualified. The workflow contract test rejects compiler skew
between hosts. The current pin targets `v0.2.608`, which preserves authored reconciliation keys
and explicit grid row tracks in
static and reactive native styles, and keeps template indentation out of native
leaf button labels. Touchable primitives preserve authored accessibility roles
and let the hosts infer link or button semantics from their current destination.
Prepared hidden screens start unfocused before their mount hooks run; their
appearance guards run when the host actually shows them. Scripted component
clones receive independent setup, and retained keyed rows keep their handlers
and local state after reordering. The native fixtures qualify its compiled
properties and mutation metadata together with both native models. Application
releases consume the normally published compiler after qualification.

The host-neutral layout contract lives in Craft's Zig runtime at
`packages/zig/src/native_layout.zig`. It defines the shared row/column flex
and equal-track grid rules for basis, positive growth, negative shrink, gap,
per-edge margins, parent padding, min/max bounds, row/column gaps, justification,
and cross-axis alignment while leaving intrinsic measurement (especially text) to
the platform host. Wrapped tree lines honor per-child `alignSelf`, including
children that override the parent's cross-axis alignment. UIKit and Android
adapters must preserve these values when mounting the resulting frames;
non-finite or negative dimensions are sanitized at the shared boundary. Grid
`alignContent`, including grids with an auto-row minimum, is also resolved in
the shared core so leftover space between rows cannot drift between UIKit and
Android; platform-specific measurement must not fork the distribution rules.

The same module exposes the #334 tree-layout ABI: `LayoutNodeInput` carries a
preorder tree and `craft_native_layout_tree` returns a host-free flat frame list
for the complete tree. `craft_native_layout_tree_v2` is the versioned extension
for reverse main-axis flows; it adds a `reverse` flag without changing the v1
struct stride, so a host can probe the newer symbol and retain the v1 path on an
older runtime. `craft_native_layout_tree_v3` reuses that payload shape with a
separate symbol whose reverse bitmask also supports `wrap-reverse`, so a host
can probe each newer symbol and retain the older path on an older runtime.
The Android JNI table registers all three layout entry points (114 natives in the
current bridge), while each Kotlin wrapper still treats an unavailable symbol as
a normal compatibility fallback.
`Style` accepts host-measured intrinsic width and height as plain
numbers, so font and image measurement remain callbacks at the boundary rather
than becoming UIKit or Android dependencies in Zig. Each entry point rejects
malformed trees and undersized frame buffers without returning partial geometry,
allowing a host to keep its compatibility fallback while an older runtime is in
use. Both iOS and Android hosts now opt eligible definite-size
flex containers and equal-track grids into this complete-tree boundary for direct-
child and eligible nested placement. Each adapter recursively preserves a
nested container's direction, padding, gap, and grid columns with its own
content-box measurements, so parent placement cannot erase those values.
Wrapped flows use the same boundary when both axes use independent row/column gaps; percentage sizes
resolve against the parent content box before entering the shared ABI. Reverse
main-axis flows use the versioned v2 boundary when available, and wrap-reverse
flows use v3; grids with resolved `gridAutoRows` use v4, which appends the
resolved minimum without changing the older payloads. Grids with explicit
`gridTemplateRows` use v5, which appends the equal-track count while retaining
the v4 fields. Absolute children,
missing runtimes, and any malformed ABI result stay on the local compatibility
algorithms. Hosts still measure each grid child locally, but the shared core now
owns the final auto-row minimum and row placement. The iOS root also keeps
a
definite viewport frame for a `flex: 1` screen root, so an absolute sibling of
a `ScrollView` is anchored to the screen rather than to the scroll content.
Android flattens each measured flex line explicitly before serializing the tree,
so line metadata never becomes part of the shared ABI payload.
The iOS layout fixture also covers a plain `View` root with overflowing content;
after scrolling, the sibling's viewport-relative top and trailing edges must be
unchanged. The maintained navigation fixture checks the same invariant on both
hosts.
The Zig contract also exercises a nested preorder tree and checks absolute
descendant frames, so hosts cannot silently flatten a nested container or lose
its padding and gap offsets while applying the shared result. Wrap-reverse,
absolute overlays, missing runtimes, and malformed ABI results stay on the local
compatibility algorithms. The fallback is intentional, so
an SDK-only project never loses native layout. Baseline alignment follows the same
boundary: hosts provide the measured distance to a child's baseline, and Zig
only aligns those numeric metrics.

Use `onMount` and `onDestroy` for route-scoped lifecycle work. Craft disposes
the screen runtime before a native screen is removed or replaced, so effects,
capability requests, and registered cleanup callbacks do not leak into the
next route.

## Current component contract

| STX primitive | iOS | Android |
| --- | --- | --- |
| `View`, `SafeAreaView` | `CraftNativeFlowView` | `CraftNativeFlexLayout` (a `LinearLayout`) |
| `KeyboardAvoidingView` | `CraftNativeKeyboardAvoidingView` | `CraftNativeKeyboardAvoidingView` |
| `Text` | `UILabel` | `TextView` |
| `Button` | `UIButton` | `Button` |
| `Link` | underlined `UIButton` | underlined clickable `TextView` |
| `Pressable`, `TouchableOpacity`, `TouchableHighlight` | `CraftNativeFlowView` | `CraftNativeFlexLayout` |
| `TextInput` | `UITextField` | `EditText` |
| `Checkbox` | `UIButton` with system checkbox symbols | `CheckBox` |
| `Picker` | `UIPickerView` | `Spinner` |
| `DatePicker` | `UIDatePicker` | `DatePicker` / `TimePicker` |
| `Modal` | `CraftNativeModalView` | `CraftNativeModalView` (`FrameLayout`) |
| `Switch` | `UISwitch` | `Switch` |
| `Slider` | `UISlider` | `SeekBar` |
| `ActivityIndicator` | `UIActivityIndicatorView` | `ProgressBar` |
| `StatusBar` | screen status-bar style/visibility | screen status-bar style/visibility |
| `RefreshControl` | attached to its parent `ScrollView` | attached to its parent `ScrollView` |
| `Icon` | `CraftNativeIconView` (`UIImageView`) | `CraftNativeIconView` (`TextView`) |
| `Image` | `UIImageView` | `ImageView` |
| `ImageBackground` | `CraftNativeImageBackgroundView` | `CraftNativeImageBackgroundView` |
| `Video` | `CraftNativeVideoView` (`AVPlayerViewController`) | `CraftNativeVideoView` (`VideoView`) |
| `Map` | `CraftNativeMapView` (`MKMapView`) | `CraftNativeMapView` (native MapLibre or Google Maps) |
| `MapPolyline`, `MapMarker` | overlays inside `CraftNativeMapView` | overlays inside `CraftNativeMapView` |
| `Svg` | `CraftNativeSvgView` | `CraftNativeSvgView` |
| `G`, `SvgText` | drawn inside `CraftNativeSvgView` | drawn inside `CraftNativeSvgView` |
| `ScrollView` | `UIScrollView` | `ScrollView` or `HorizontalScrollView` |
| `SectionList` | `UIScrollView` (slot fallback) | `ScrollView` or `HorizontalScrollView` (slot fallback) |
| `FlatList` | `UICollectionView` | `RecyclerView` |

On iOS, `CraftNativeFlowView` remains a `UIStackView` subclass for source and
accessibility compatibility while supplying the shared wrapping and positioning
rules; Android keeps the corresponding `LinearLayout` compatibility surface.
Both native hosts follow the configured `appearance` (`system`, `light`, or
`dark`) and reapply theme-default controls when the system trait changes without
recreating the screen. When `appearance` is omitted, the legacy `darkMode`
boolean pins the host for compatibility. On Android, set `backgroundColorDark`
to let the generated Material DayNight theme swap the native background when
the system enters night mode; iOS resolves the same color dynamically.
Both generated hosts keep native content inside platform safe-area insets,
including Android system bars and display cutouts.
CI also checks the host-neutral component and fallback contract against both
generated renderers, so a platform can’t silently lose a native primitive.

`Switch` accepts the shared `trackColor` object (`false` and `true` states) and
`thumbColor`; iOS also honors `ios_backgroundColor` for the off-state track.
Use `value` for the controlled state. `checked` is a compatibility alias when
`value` is null, and `value` takes precedence when both are provided.
On iOS, opt in with `<Switch :ios_solid="true" :value="enabled" @value-change="changed($event)" />`
to use a solid native `UIControl` instead of UIKit's translucent switch animation.
The thumb stays opaque during taps and drags; taps settle immediately without
animation. Colors, disabled state, accessibility activation, keyboard activation,
RTL layout, and controlled/uncontrolled values remain supported. `thumbColor`
keeps its RGB color but its alpha is forced to 1. The default is still `UISwitch`;
Android ignores this iOS-only option. Choose the style when mounting: changing
`ios_solid` replaces the native control, so supply `value` when changing styles
to retain state. Ordinary value/color mutations retain the same control.
`Slider` accepts `minimumTrackTintColor`, `maximumTrackTintColor`, and
`thumbTintColor` on both hosts, with `step` snapping values before events are
delivered.
`Button.color` and `Link.color` set the native action-label color;
`style.color` remains the shared fallback when either prop is omitted.
`Pressable`, `TouchableOpacity`, and `TouchableHighlight` are native flow
containers with `onPress`/`onClick`, long-press, and disabled handling; disabled
containers block both press and long-press callbacks on both hosts. On
`TouchableHighlight`, `underlayColor` temporarily replaces the authored
background during a press and `onShowUnderlay`/`onHideUnderlay` follow the
same lifecycle on iOS and Android.
The shared `Pressable` contract intentionally omits platform-specific
`hitSlop`, ripple, retention-offset, and long-press-delay options until both
hosts implement them.
Pointer-event routing (`pointerEvents`, `box-none`, and `box-only`) is likewise
outside the maintained native contract; use explicit native layout and enabled
state props instead of relying on DOM hit-testing semantics.
Native `Text` accepts `selectable`. When true, iOS uses a non-editable
`UITextView` and Android uses a selectable `TextView`, so the system copy menu
and selection gestures remain native. The default is false and keeps the
lightweight label path on both hosts; changing the prop during reconciliation
replaces the leaf only when the native control kind must change.
`Picker` renders option children from `<select>`/`<option>` or the native
primitive, accepts an `items` array or child options plus `value`/`selectedValue`,
and sends the selected option's `value` plus `index` through `onValueChange` or
`onChange`. Numeric option values are normalized to strings consistently on
both hosts.
`DatePicker` keeps the mode, bounds, and minute interval shared across hosts;
its presentation style is platform-default rather than an iOS-only prop.
`Checkbox` accepts `checked`/`value`, `indeterminate`, and `disabled`; when both
controlled values are present, `checked` takes precedence. It delivers a
boolean `nativeEvent.value` through `onValueChange` or `onChange`.
An indeterminate checkbox is announced as `mixed` and becomes checked or
unchecked on the next user toggle.
`ImageBackground` uses the shared image source and load/error lifecycle while
mounting ordinary native children in a flex container over the image. Its
`resizeMode` follows the same `cover`, `contain`, `stretch`, and `center`
semantics as `Image`; native tiling (`repeat`) is intentionally not part of
the native contract. Image presentation is controlled by the shared container
style; there is no separate `imageStyle` prop in the native protocol.

`Map` is the deliberately small native trail-map primitive. Its children may
be `MapPolyline` or `MapMarker`; each overlay carries a flat latitude,
longitude `geometry` array, so a signal update changes the existing native map
without rebuilding the screen. `MapPolyline` also accepts `strokeColor` and a
positive `strokeWidth` in logical points, which are preserved by both map
hosts (the Android hosts convert points to the physical pixels expected by
their map renderers). `Map` accepts a
controlled `region` (with `center` and `span`), an `initialRegion` applied once,
or `fitToBounds`, which recenters only when its overlay geometry changes. Explicit regions use the
authored camera bounds on both hosts; only `fitToBounds` adds framing padding. A marker's `onPress` or
`onMarkerPress` receives `nativeEvent.id`; a marker's own handler wins, and the map-level handler is
used as a fallback when the marker has no non-empty handler.
`MapMarker.image` accepts an HTTPS avatar URL. `imageSize` defaults to 30 logical
points and is clamped to 16–96; `imageShape` is `circle` (default) or `square`.
Photos are center-cropped, drawn upright and centered on the coordinate, and keep
the marker's title and tap ID. Until loading succeeds, or when the URL is absent,
invalid or unavailable, the existing pin/direction marker remains visible.
Changing these props updates the existing annotation; removing a marker cancels
its pending photo. Kept media can supply the original HTTPS URL offline.
The hosts also accept `imagesize`/`imageshape` and `image-size`/`image-shape`,
which current STX template compilers may emit before these names are added to
their canonical prop list. STX's `MapMarkerProps`/`MapMarkerOverlay` TypeScript
interfaces need the corresponding upstream additions for typed programmatic use.
It is backed by MapKit on iOS and the configured native provider on Android.
Set the Craft Android config's `mapProvider` to `maplibre` for a key-free native
GL view; `google` preserves the existing Google Maps host. Only the selected
provider's SDK is included in the generated Android project. These STX map
components do not use the DOM-based `@craft-native/ts-maps` adapter.
`basemap` names a map and the host draws it as well as the platform can,
caches its tiles on the device and shows its credit: `standard` (Apple's
vector map with realistic terrain from iOS 16; OpenFreeMap's vector style on
Android), `outdoors` (topography with contours, drawn over a muted Apple map
so unloaded ground is never an empty grid), `satellite` and `hybrid`. Prefer
it to `mapType`, whose values are `standard`, `satellite`, and `hybrid`, and
to `tileOverlay`, which accepts an HTTPS raster URL template and its visible
provider attribution for a map of your own; `basemap` replaces both when set.
Android's terrain-only style is intentionally not part of the cross-platform
contract. `edgePadding` reserves logical
points around a fitted route for floating controls. `pitchEnabled` controls
tilt gestures; `cameraPitch` and `cameraHeading` set the camera explicitly.
Markers accept `pinColor` for trailheads and inspected profile positions, or
`bearing` for a route-direction chevron; chevrons that would overlap at the
current zoom are hidden by the map and return closer in. The portable system colors
`label` and `secondaryLabel` follow light/dark appearance changes and refresh
retained overlays without moving the camera. Clustering, turn-by-turn
directions, and offline tile downloads remain outside this view contract.
Set `showsUserLocation` to opt into the
platform location dot; the host only enables it when the app's existing
location permission is already granted, and never prompts from a renderer
pass. Android also forwards `MapView` start/stop lifecycle callbacks as map
screens attach and detach.
Coordinates must be finite and within latitude [-90, 90] and longitude
[-180, 180]; invalid overlay points are ignored. Region spans must be
positive, no wider than 360 degrees, no taller than 180 degrees, and must not
cross a pole, so malformed input cannot reach either platform map SDK.
`KeyboardAvoidingView` responds to the native keyboard/IME inset. Its
`behavior` may be `padding`, `position`, or `height`, and
`keyboardVerticalOffset` subtracts from the overlap on both hosts.
`DatePicker` accepts `mode` (`date`, `time`, `datetime`/`datetime-local`, or
`countdown`), `value`, `minimumDate`, `maximumDate`, `minuteInterval`, and
`disabled`. Its `onValueChange`/`onChange` event includes a local `value`, an
ISO timestamp, and the Unix `timestamp` in milliseconds on both native hosts.
Countdown values are durations: numeric values are seconds and text values use
`HH:mm` or `HH:mm:ss`; their event value is always `HH:mm:ss`, `iso` is an
ISO-8601 duration such as `PT5400S`, and `timestamp` is the duration in
milliseconds. Native countdown controls clamp values to `23:59:59`.
`Modal` is parent-scoped: `visible` controls a native layer around its
children, `transparent` removes the dimming scrim, and hidden modals do not
participate in layout or touch handling. `animationType` accepts `none`,
`fade`, or `slide`; `slide` enters from and exits toward the bottom edge on
both hosts. `onShow` and `onDismiss` fire on visibility transitions,
and `onRequestClose` fires when Android back or the modal blocker requests a
close. Set `nonModal` for a popup that leaves the screen interactive; it is
pass-through by default. Add `dismissOnOutsideTap` when the popup should
consume an outside tap and call `onRequestClose` on both hosts. The default
WebView renderer remains unchanged.
`Text` supports positive `numberOfLines` values and `ellipsizeMode` (`head`,
`middle`, `tail`, or `clip`) on both hosts; omitting the line count keeps the
label intrinsically multiline.
`ActivityIndicator` accepts `color`, `animating`, `hidesWhenStopped`, and
`size` (`small`, `large`, or a numeric point/unit value). The native host keeps
the indicator visible when animation is stopped only when `hidesWhenStopped` is
false; shared `display: 'none'` still takes precedence on both hosts.
`Image.alt` supplies the native accessibility label when an explicit
`accessibilityLabel` is not provided.

`Icon` is a native leaf with the shared `symbol`/`name` contract. iOS draws
SF Symbols through `UIImageView`; Android uses the maintained dependency-free
glyph map and renders an outlined circle for symbols it does not recognize.
Both hosts preserve the authored size, color, and accessibility metadata, and
neither creates a DOM or WebView fallback for an icon.

`Video` uses the platform player in native mode. Its `source` accepts a URI
string or `{ uri }`, while `autoplay`/`autoPlay`, `paused`, `loop`, `muted`,
`controls`, and `resizeMode` configure playback without creating a DOM video
element. The native player is stopped when its node is removed or replaced;
unsupported or empty sources remain inert instead of falling back to a WebView.
Both native hosts preserve a video paused from its native controls, or a
non-looping video that has ended, across reconciliation unless the
`autoplay`/`autoPlay` or `paused` play intent changes.
`@play`, `@pause`, `@timeupdate`, `@ended`, `@load` and `@error` reach the screen
on both platforms, from the system controls as well as from props; `@play` waits
for the native player to report active playback. A video with sound
plays mixed with the person's music (iOS: the playback session, shared with
speech and sounds; Android: no audio focus). With `pictureInPicture` it carries
on in a floating window when the person leaves the app while it plays, and
comes back into its place with the app; `onPictureInPictureStart` and
`onPictureInPictureStop` report those transitions on both hosts. iOS needs
`enableBackgroundAudio`.

A screen's next change can animate instead of cutting:
`craft.animation.next({ duration: 0.35, curve: 'spring' })`, then change the
state. Views that stay move and resize to their new places, new views fade in,
removed ones fade out where they were, and a label whose font size changed
scales into it. Two views with the same `transitionID` prop, one leaving and
one arriving, are one element that moves and scales between the two places.
The screen's `backgroundColor` and the bar's hiding animate with it, and the
status bar's style changes in step. With Reduce Motion the screen crossfades.
Android uses its framework transitions, matched by `transitionID`.

Native screens have Web Audio: the standard `AudioContext` API, so code
written for a page (synthesised music, breath tones, filtered noise) runs
unchanged. On iOS (`CraftWebAudio.swift`) that is `AudioContext`
(`currentTime`, `sampleRate`, `state`, `resume()`/`suspend()`/`close()`,
`statechange`), `AudioParam` (`value`, `setValueAtTime`,
`linearRampToValueAtTime`, `exponentialRampToValueAtTime`, `setTargetAtTime`,
`setValueCurveAtTime`, `cancelScheduledValues`, `cancelAndHoldAtTime`, and a
node connected into a param), `GainNode`, `OscillatorNode` (sine, square,
sawtooth, triangle, `frequency`, `detune`), `AudioBuffer` and
`AudioBufferSourceNode` (`loop`, `loopStart`/`loopEnd`, offset, duration,
`playbackRate`, `detune`), `BiquadFilterNode` (all eight types),
`DelayNode` (in a feedback cycle too), `DynamicsCompressorNode` and
`ConvolverNode` (with the spec's normalisation), `connect()`/`disconnect()`,
`start()`/`stop()` and `onended`.

The graph renders in 128-frame quanta, as the spec describes, inside one
`AVAudioSourceNode` per context on the screen's `AVAudioEngine`; a step
sequencer's short-lived nodes are freed once the script lets go of them
(`FinalizationRegistry`) and they can no longer sound. The convolver runs its
first 512 taps directly and the rest as partitioned FFT convolution, so it adds
no latency. Approximations, inaudible for synthesis: square and sawtooth are
PolyBLEP band-limited rather than wavetables, a biquad takes its coefficients
once per quantum, the compressor has no look-ahead, and a 4-channel impulse
response uses its first two channels. The session is `.ambient`, mixing with
other audio and muted by the silent switch, as a web view's Web Audio is.
`decodeAudioData` refuses: play a file with `craft.audio`. Android renders the
same native graph shape through `AudioTrack`, including uploaded stereo
`AudioBuffer` channel samples, buffer sources, and the
gain/filter/compressor/convolver chain
used by `useAmbientSound`; its effects are intentionally conservative and file
decoding remains outside the native runtime. Both hosts tear the graph down
with the screen.

Native screens run in JavaScriptCore (iOS) or JavaScriptSandbox (Android), not
in a DOM. To keep browser-safe SDK bridges usable, both hosts alias `globalThis.window`
to `globalThis` before installing the native bridge, so
`window.craft` resolves normally. The alias does not add `document` or DOM
rendering, and routes that do not opt into `native` continue using the WebView
renderer. Web APIs that the native capability contract does not advertise
retain their normal WebView fallback behavior on web routes.

`Svg` is DOM-free in native mode: the compiler emits geometry commands for
shape nodes, `G` inherits fill/stroke paint, and `SvgText` draws text in the
same viewBox. Both hosts preserve inherited opacity, fill/stroke colors, fill
rules, fill/stroke opacity, line caps, joins, miter limits, dash patterns, and
dash offsets; `SvgText` also accepts `dominantBaseline` values for centered or
edge-aligned labels. The iOS host applies those styles to each `CGPath` before
stroking. An SVG string that requires DOM APIs remains a WebView concern.

`key` is scoped to sibling nodes. `testID` is also accepted as an identity for
existing screens. Unkeyed children reconcile by position. A rerender updates an
existing native control when its identity and type are unchanged, preserving
input focus, selection, draft text, and scroll objects. Duplicate sibling keys
fall back to positional identity rather than attaching state to the wrong view.

## Incremental update protocol

Generated native hosts advertise `mutationProtocolVersion: 1` on
`globalThis.__stxNativeBridge`. A current `stx native compile` bundle uses `MUTATE`
batches when that value is present and continues to send the original
whole-document `RENDER` message to older hosts. If a host rejects a mutation
batch, the bundle resynchronizes with `RENDER`, so a bundle can run against
both generations of Craft.

Every batch has one protocol version, a non-empty identifier, consecutive
revisions, and at least one operation:

```json
{
  "type": "MUTATE",
  "payload": {
    "version": 1,
    "batchId": "screen-4",
    "baseRevision": 3,
    "revision": 4,
    "operations": [
      {
        "op": "updateNode",
        "id": "root/key:counter",
        "patch": { "children": ["Count: 4"] }
      }
    ]
  }
}
```

Version 1 supports these operations:

| Operation | Required fields | Effect |
| --- | --- | --- |
| `createNode` | `id`, `node`; optional `root` | Creates a detached node, or the document root when `root` is `true` |
| `updateNode` | `id`, `patch` | Replaces supplied `props`, `style`, `events`, or text `children` fields |
| `insertChild` | `parentId`, `childId`, `index` | Attaches a detached node to a container |
| `moveChild` | `parentId`, `childId`, `index` | Reorders a child within its current parent |
| `removeNode` | `id` | Removes the node and its descendants |

`View`, `SafeAreaView`, `ScrollView`, and `SectionList` are the container node types. Node
children in `createNode` and `updateNode` may contain text only; node
relationships use `insertChild`. Indexes are zero-based and may equal the
current child count when inserting or moving to the end.

`SafeAreaView` accepts an optional `edges` array containing any of `top`,
`right`, `bottom`, and `left`. It applies only those system insets to its
content; omitted `edges` means all four. The maintained iOS and Android hosts
keep a SafeAreaView screen root edge-to-edge so the selected edges are applied
by the node itself, while ordinary roots retain the host's full safe-area
padding. The maintained native-navigation fixture uses `top` and `bottom`
only, so both mobile E2E hosts exercise selective edges rather than just the
default all-edge case.

The host validates the complete batch against a copy of its retained tree. It
commits and advances the revision only if every operation succeeds, then sends:

```json
{
  "type": "MUTATION_ACK",
  "payload": { "version": 1, "batchId": "screen-4", "revision": 4 }
}
```

Malformed or stale batches leave both the native view tree and revision
unchanged. The reply is `MUTATION_ERROR` with `version`, `batchId`, `code`,
`message`, and, when an operation failed, its zero-based `operationIndex`.
Error codes are deterministic across iOS and Android: `INVALID_BATCH`,
`UNSUPPORTED_VERSION`, `REVISION_MISMATCH`, `INVALID_REVISION`,
`INVALID_OPERATION`, `UNKNOWN_OPERATION`, `INVALID_NODE`, `DUPLICATE_NODE`,
`ROOT_EXISTS`, `INVALID_PATCH`, `UNKNOWN_PARENT`, `UNKNOWN_NODE`,
`INVALID_PARENT`, `NODE_ATTACHED`, `CYCLE`, `INVALID_INDEX`, `NOT_A_CHILD`, and
`MISSING_ROOT`, and `INVALID_TREE`. A successful batch must leave every node
reachable from its single, unattached root.

Stable node IDs are derived from sibling-scoped `key` values, with `testID`
accepted for existing screens and position used as the fallback. Updating a
node keeps its native object, event bindings, accessibility metadata, input
focus and selection. Structural operations reconcile the affected parent
subtree and preserve unrelated controls and scroll views. Root replacement is
the only mutation path that intentionally performs a full native render.

The shared style subset is deliberately smaller than the public `ViewStyle`
type:

- numeric or percentage `width`, `height`, `minWidth`, `maxWidth`, `minHeight`,
  and `maxHeight` (percentages resolve against the parent's content box);
- `flexDirection` (`row`, `column`, and their reverse forms), `alignItems`,
  `alignSelf`, `justifyContent`, `flexWrap: 'wrap' | 'wrap-reverse'`, `gap`, `rowGap`, and
  `columnGap`;

- baseline alignment uses each text view's first baseline; non-text views use
  their bottom edge as the fallback;
- `flex`, `flexGrow`, `flexShrink`, and numeric or percentage `flexBasis` distribute
  remaining or overflowing main-axis space per flex line while preserving
  gaps and margins;
- wrapped containers support `alignContent` (`flex-start`, `center`,
  `flex-end`, `space-between`, `space-around`, `space-evenly`, and `stretch`)
  for cross-axis line distribution;
- `display: 'grid'` with equal tracks from numeric `gridTemplateColumns` and
  `gridTemplateRows` (or CSS-shaped `repeat(N, 1fr)` text), plus numeric
  `gridAutoRows`; grid children fill their track by default, pack in source
  order, and honor `alignSelf`, `columnGap`, and `rowGap`. Explicit row tracks
  divide a definite container height equally; implicit rows retain their
  measured intrinsic height.
- `position: 'relative'` (the default) and `position: 'absolute'` with numeric
  `top`, `right`, `bottom`, and `left` insets;
- `padding`, its four side properties, `paddingHorizontal`, and
  `paddingVertical`;
- `backgroundColor`, `opacity`, `borderWidth`, `borderColor`, `borderRadius`,
  per-edge `borderTop*`/`borderRight*`/`borderBottom*`/`borderLeft*` values,
  `borderStyle` (`solid`, `dashed`, or `dotted`), `overflow: 'hidden'`, and
  `display: 'none'`;
- linear gradients with `gradientDirection` (`to-t`, `to-tr`, `to-r`,
  `to-br`, `to-b`, `to-bl`, `to-l`, or `to-tl`), `gradientFrom`, optional
  `gradientVia`, and `gradientTo`; both hosts follow the same stops and
  direction while retaining authored corners and borders;
- for text: `color`, `fontFamily`, `fontSize`, `fontStyle`, `fontWeight`,
  `letterSpacing`, `lineHeight`, `textAlign`, `textDecorationLine`, and
  `textTransform`;
- for images: `resizeMode` (`contain`, `cover`, `stretch`, or `center`) and
  `tintColor` for template rendering.

`textTransform: 'capitalize'` uppercases the first character of each
space-delimited word while preserving the remaining characters on both hosts.
`fontWeight` accepts `normal`, `bold`, and numeric `100`–`900` values; both
hosts normalize those forms before selecting the closest native type weight.
`textAlign: 'justify'` uses UIKit justification on iOS and inter-word
justification on Android when the platform API supports it.
Explicit `null` image style values are treated as unset, so a prop-level
`resizeMode` remains effective during reconciliation.
Changing `resizeMode` during reconciliation recomputes image clipping from the
current mode and authored overflow/radius styles; a previous `cover` render does
not permanently clip a later `contain` render.

Colors use platform color syntax; hexadecimal colors are portable. Dimensions,
spacing, and font sizes are points on iOS and density-independent units on
Android. Both hosts use the same line-breaking, gap, min/max clamping, percentage
resolution, wrapped-line distribution, absolute inset, grid-track, and
stretch/center/flex-end rules; text and image intrinsic
sizes are measured by the host-native control, and `Button`/`Link` text uses the
same font, color, alignment, and decoration styles as `Text`. Generated hosts
pin the native screen root to the platform safe-area insets. View transforms
(`translateX/Y`, `scale`, `rotate`, and `skew`) and z-order (`zIndex`) are
applied by both hosts. View shadows use `shadowColor`, `shadowOpacity`,
`shadowRadius`, and `shadowOffset`; Android also maps `elevation` to its native
outline/elevation model. Every native component's `style` accepts a nested
`StyleValue` array, so conditional entries can be composed and flattened before
rendering; `null`, `false`, and `undefined` entries are ignored. Unsupported values are ignored rather than interpreted
as CSS. Explicit `null`
layout values, including `alignSelf` and `position`, clear the previous value
and restore the host default during reconciliation.

When the Craft Zig runtime is linked, the mobile hosts use its flat
`craft_native_flex_row` ABI for one-line main-axis distribution and
`craft_native_flex_line_breaks`/`craft_native_flex_line_distribution` for wrapped
lines, plus `craft_native_cross_axis_position` for each item's cross-axis
alignment. These ABIs carry only plain numeric data—never UIKit or Android
types—so an SDK-only project can keep the equivalent host fallback until a
runtime is installed.

The same host-neutral layout core models a complete tree's main-axis
`justifyContent` distribution (`flex-start`, center, `flex-end`,
`space-between`, `space-around`, and `space-evenly`) for deterministic parity
tests. Cross-axis `alignItems` and per-child `alignSelf` use the same
host-neutral rule, including the default stretch behavior. Intrinsic text and
image measurement remains a host responsibility; the shared rule consumes
those measurements as numeric bases. Wrapped flex trees form lines from the
same numeric bases, distribute free cross-axis space, and then recurse into
each child without importing a host view type. `alignContent` controls that
line distribution with the same start, center, end, between, around, and
stretch options used by the mobile hosts. Grid rows use the same cross-axis
alignment rule, so a shorter child is centered or end-aligned inside an
intrinsically measured row instead of being forced to its top edge.
`aspectRatio` derives a missing width or height from the other definite
dimension in both flex and grid trees; invalid, zero, or non-finite ratios are
ignored just like invalid host style values.
Flex and grid siblings also accept numeric `order`; lower values are laid out
first and equal values retain authored order on both maintained hosts.

The same runtime also exports `craft_native_grid` for equal-track grids. It
accepts intrinsic measurements and alignment as plain data, leaving platform
views responsible only for measurement and mounting; hosts may fall back to
their local grid path when no runtime is linked. Both bridges reject
non-finite widths, positions, and frames from a malformed runtime payload and
take that same local fallback, so one bad value cannot poison native layout.

Scroll content is measured with an unbounded scroll-axis constraint, so intrinsic
text and image sizes contribute to the content extent instead of collapsing to
zero when the viewport supplies an unspecified size.

Views also support `onLayout`. The host calls it after the first native layout
and again only when that view's frame changes (including safe-area, rotation, or
responsive-size changes). The callback receives
`{ layout: { x, y, width, height } }`, measured in the view's parent coordinate
space. Values are points on iOS and density-independent units on Android;
removing a node removes its pending layout callback as well.
On iOS, keyboard frame changes are folded into the controller's additional safe
area while a native input is focused, so the same measurement contract updates
as the keyboard animates and returns to the original inset when it hides.

Anchored overlays should remeasure their anchor after every `onLayout` callback
from the anchor or its screen root, and after `onScroll` from any scrolling
ancestor. These callbacks cover safe-area, rotation, responsive-size, and
scroll-offset changes; there is no second host-specific viewport transform to
apply. Recompute `View.measure` and clamp the resulting `left`/`top` against
`viewportWidth`/`viewportHeight` before updating a non-modal popup.

## Images and scrolling

Use either a URI string or `{ uri: value }` for an image source. Dimensions belong in the `Image`
style/layout rather than the source object. `headers` on an object source are
forwarded to HTTPS requests on both hosts. Data-image URIs and HTTPS URLs work on
both platforms. Local development may also use HTTP from loopback hosts
(`localhost`, `127.0.0.1`, `::1`, or Android's `10.0.2.2`); public HTTP, file
URLs, and other schemes are rejected. A source with no URI scheme resolves from
the iOS asset catalog or Android app assets, so the asset must be packaged
separately under the same name for a shared bundle.
Image sources are URI strings, data URLs, or packaged asset paths; numeric
bundled-image IDs are not part of the native contract. Invalid data, missing bundled images, failed HTTPS downloads, and unsupported
schemes clear stale pixels, log a diagnostic, and expose a short accessibility
error value. That value remains stable when the native node is reconciled again;
it is not appended repeatedly. `onLoadStart`, `onLoad`, and `onLoadEnd` report the image lifecycle;
`onError` receives `nativeEvent.error.message` for failures. Route teardown and
node removal cancel outstanding downloads.

Images also prefer the copy saved by `await craft.media.keep(url, { headers })`.
Keep the original HTTPS URL as the image source, not the returned filesystem path.
Both hosts decode the kept file off the UI thread before trying their image cache
or the network, so private photos can display offline without a second request.
Kept image bytes do not enter the public image cache. Clear kept media on sign-out
and unmount private screens; clearing the files does not erase pixels already displayed.
A corrupt kept image reports a load error rather than silently fetching it again.
This does not enable arbitrary file URLs or picker paths as image sources.

For an authenticated attachment, keep the response before assigning the original
URL to the screen's image signal:

```ts
await craft.media.keep(attachmentURL, { headers: { Authorization: `Bearer ${token}` } })
photoURL.set(attachmentURL) // <Image :source="{ uri: photoURL }" />
```

Do not assign `craft.media.path(attachmentURL)` or a `files.download`/`pickImage`
descriptor's path to `source`: the kept-media lookup is keyed by the authored
URL, not an arbitrary file path. Source changes still use the normal native
mutation protocol and must clear the previous image before displaying new bytes.

`ScrollView` uses `horizontal` (or a row flex direction) to choose its axis and
renders its children as native views. `scrollEnabled`, the platform scroll
indicators, and nested scrolling are native; Android forwards the nested-scroll
setting to its underlying platform scroller rather than shadowing the wrapper's
view API. `pagingEnabled` snaps `ScrollView` content to viewport-sized pages on
both hosts. `onScroll` reports
`contentOffset`, `contentSize`, and `layoutMeasurement`; `onScrollBeginDrag`
and `onScrollEndDrag` report the corresponding gesture boundaries.
`keyboardShouldPersistTaps` accepts `"never"` (the default), `"always"`, or
`"handled"`; it controls whether taps inside a scroll host dismiss the active
keyboard, preserving taps on native controls for the handled mode. The same
policy applies to `FlatList`, which inherits the scroll props.
`onMomentumScrollBegin` and `onMomentumScrollEnd` report the native deceleration
interval. `FlatList` forwards the same scroll, drag, and momentum callbacks from
its virtualized collection or recycler host, including the same
`contentOffset`, `contentSize`, and `layoutMeasurement` payload. `FlatList` now
accepts `onRefresh` and controlled
`refreshing`; pull-to-refresh is backed by UIKit's `UIRefreshControl` on iOS and
AndroidX `SwipeRefreshLayout` on Android. Use `ScrollView` for bounded content
and `FlatList` for keyed child rows that
need recycling. The maintained protocol is driven by the shared STX tree, not
by a serialized `data`/`renderItem` callback pair.
The versioned mutation ABI also accepts a `replaceChildren` operation for a
keyed list snapshot: it supplies the parent node and ordered protocol ids in
one atomic batch. Both hosts validate the snapshot before committing it,
discard rows that left the set, and reconcile the list once. STX currently emits
the equivalent keyed child mutations; this operation is reserved for a future
compiler optimization and keeps list updates host-neutral.
When `scrollEnabled={false}`, the list is measured to its full vertical content
height on both hosts, so it can be placed inside an outer native `ScrollView`
without clipping rows.

For a shared refresh configuration, `FlatList` also accepts the typed
`refreshControl` prop. Its `refreshing` state and `tintColor` are applied to the
same native control on both hosts; a top-level `onRefresh` remains the fallback
when the object does not provide an event binding.

`FlatList` also accepts `showsVerticalScrollIndicator`,
`showsHorizontalScrollIndicator`, `bounces`, `alwaysBounceVertical`, and
`alwaysBounceHorizontal`. Indicators default to visible. When the bounce-axis
props are omitted, the list's active axis follows `bounces` and the other axis
does not, so horizontal and vertical lists retain their native direction by
default.
`pagingEnabled` snaps virtualized rows to viewport pages on both hosts. A
`scrollTarget` string or `{ id, animated?, key? }` targets a row by its native
`testID`, `id`, or stable key; the `key` field retriggers the same target after
the data snapshot changes. `stickyHeaderIndices` remains a `ScrollView`-only
capability; list chrome should use the maintained `listRole` slots instead.

`RefreshControl` is a native utility node rather than a visible child: place it
inside a `ScrollView` when the screen wants the React Native-shaped form. Its
`refreshing`, `onRefresh`, and `tintColor` props control the platform refresh
control, and the node is removed from the scroll content so it cannot consume
layout space. Host-specific presentation props are intentionally not part of
the shared contract.
`StatusBar` likewise contributes no layout; its `barStyle` (`default`,
`light-content`, or `dark-content`) and `hidden` props apply to the active
screen while the app-level appearance remains the fallback.

`SectionList` currently follows the same native scroll host as
`ScrollView` for ordinary `.stx` slot children; grouped, virtualized section
data should use `FlatList` until the section-data protocol is added. Section
data props (`sections`, `renderItem`, and `keyExtractor`) and section headers
therefore are not part of the native `SectionList` contract yet.

## Recycling lists

`FlatList` compiles keyed child rows into retained native rows. iOS uses a
diffable `UICollectionView` data source; Android uses `RecyclerView`, stable
IDs, and `DiffUtil`. Inserts, updates, moves, and removals reuse unaffected rows
instead of rebuilding the list. Visible text inputs retain their draft, focus,
accessibility metadata, and event handlers, and keyed updates retain the
viewport anchor. The simulator and emulator suites exercise this contract with
10,000 keyed rows without rebuilding unaffected rows.

```stx
<script>
let people = [{ id: 'ada', name: 'Ada' }, { id: 'grace', name: 'Grace' }]

function loadMore() {
  // Guard duplicate requests while an asynchronous load is in flight.
}
</script>

<FlatList numColumns={2} onEndReached={loadMore} onEndReachedThreshold={0.2}>
  <Text listRole="header">People</Text>
  <View listRole="item" :for="person, index in people" :key="person.id" :accessibilityLabel="person.name">
    <Text>{{ index }}: {{ person.name }}</Text>
  </View>
  <View listRole="separator" style="height: 1" />
  <Text listRole="empty">Nobody here</Text>
  <Text listRole="footer">End of people</Text>
</FlatList>
```

The `listRole="item"` child is expanded by the ordinary STX `:for` binding and
can reference its loop value and zero-based index. Its `:key` must be stable and
unique; moving a row with the same key keeps its native row state. `horizontal`, `inverted`, and
`numColumns` select the native layout. `numColumns` applies to vertical lists;
header, separator, empty, and footer content span every column. Empty content
is shown only when the keyed row set has no items. Separator content is inserted
between item rows, never before the first or after the last.
List chrome belongs in child slots marked with `listRole`; component props such
as `ListHeaderComponent`, `ItemSeparatorComponent`, `renderItem`, and
render-window tuning are intentionally outside the maintained native protocol.

`onEndReachedThreshold` is the fraction of keyed rows allowed to remain when
`onEndReached` fires. Header, separator, empty, and footer nodes do not count
toward the threshold and a chrome-only list does not fire it. A given child-tree
signature fires at most once; keyed inserts or moves create a new signature and
may fire again if the viewport is still within the threshold. Handlers should
therefore guard concurrent pagination requests.

Item rows participate in the same layout contract as ordinary views. Put an
`onLayout` handler on the `listRole="item"` root to receive measurements for
each materialized row; the callback runs when a row is laid out or its frame
changes after recycling, safe-area, orientation, or responsive-size updates.
Rows that are not materialized do not produce layout events until they become
visible, and recycled rows keep their keyed handler association.

For backward compatibility, a `FlatList` without a `listRole="item"` template
keeps its existing static children. Older compiled bundles also continue to
use whole-document `RENDER`; the native host accepts both that path and the
incremental mutation protocol.

When a keyed node changes its native type during reconciliation, the host
creates a control of the new type instead of reusing an incompatible view. This
keeps a `Button` changed to a `Link` (or another component class) from retaining
the old control's traits, listeners, or accessibility behavior.

When a virtualized Android row leaves the viewport or is removed, its native
interaction listeners are detached before the view can be reused for another
identity. Handler cleanup therefore cannot leak the previous row's closure or
event target into a recycled row.

Native row descendants are scoped by their keyed parent on both hosts, including
rows rendered in an ordinary `ScrollView`. Two rows can therefore use the same
child `testID` or local key without sharing uncontrolled input drafts or retained
native state.

Android scroll hosts also invalidate their callback generation when released, so
queued momentum polling and touch callbacks cannot report events through a
previous screen after the host is recycled.

Video teardown releases its event bridge and picture-in-picture callback on both
hosts as playback stops, so a removed native video cannot retain its screen or
deliver media events after recycling.

Android also clears `VideoView`'s prepared, completion, and error listeners
during that stop, preventing a late platform callback from reaching a released
native node.

Map teardown follows the same rule: iOS releases MapKit delegates, callbacks,
markers, polylines, and tile overlays before a map leaves a row, then restores
the delegate when that native view is adopted by a new row.

Android date pickers clear their value-change bridge during teardown as well, so
the platform picker cannot retain a screen callback after its native view is
released.

The Android refreshable `FlatList` wrapper clears its refresh closure before
the inner recycler is released, keeping a keyed reconciliation from retaining
the previous screen through the outer swipe host.

Android also detaches control-specific listeners from released checkboxes,
switches, sliders, and pickers so a retained native control cannot dispatch the
previous identity's callback during reuse.

Text-input watchers are detached too. A released Android `EditText` therefore
cannot retain the old screen's draft and change handler through a closure after
its row or screen has been recycled; screen disposal also sweeps any watcher
that was not reachable through the retained view tree.

When an iOS screen is popped or replaced, its rendered tree is torn down before
the JavaScript runtime closes. That includes rows kept in a `FlatList` recycle
pool, so UIKit delegates, control targets, media, and map callbacks cannot keep
the old screen alive after navigation.

## Events, accessibility, and navigation

`defaultValue` initializes an uncontrolled `TextInput` once; controlled
`value` continues to win on later renders without replacing the user's draft
when it is omitted. `onPress` and `onClick` deliver an empty `nativeEvent` from buttons and other
pressable native views. `onLongPress` fires once after the native long-press
gesture begins and also delivers an empty `nativeEvent`; removing the handler
releases the platform gesture recognizer. `TextInput` accepts `onChange` or `onChangeText` and
delivers `nativeEvent.text`; `onFocus`, `onBlur`, `onEndEditing`, and
`onSubmitEditing` are also native events and include the current text when
the event applies to a `TextInput`. `keyboardType`, `returnKeyType`,
`autoCapitalize`, `autoCorrect`, `secureTextEntry`, `editable`, and `autoFocus`
map to the platform input control. `placeholderTextColor`, `selectionColor`,
positive `maxLength`, `multiline`, and `numberOfLines` values are applied on
both hosts, including keyboard and return-key traits on multiline inputs. Shared
keyboard types are limited to values both hosts implement; iOS-only keyboard
variants and `passwordRules` are intentionally not part of the shared contract.
Shared text styles (`color`, `fontSize`, `fontFamily`, `fontWeight`,
`fontStyle`, `textAlign`, `letterSpacing`, and `lineHeight`) also apply to
native text inputs. When `fontSize` is omitted, text uses the shared 16-point
default on both hosts. Configuration changes are applied only when
their values change, so state reconciliation preserves the focused field and
its keyboard; UIKit text inputs retain their dynamic accessibility value unless
an explicit `accessibilityValue` prop overrides it, and removing that prop
restores UIKit's live value. The host also restores the first responder around synchronous
native event callbacks and after a native tree reconciliation on the main UI
thread. The host keeps a weak anchor to the last focused field so a control
callback restores focus after dispatch and schedules a short delayed main-queue
handoff after UIKit finishes the touch, even if UIKit temporarily clears first
responder status while dispatching the event. `FlatList` supports `onEndReached`.
`ScrollView` and `FlatList` emit the scroll callbacks described above, accept
`bounces`, `alwaysBounceVertical`, and `alwaysBounceHorizontal` to control the
platform overscroll effect, and accept
`keyboardDismissMode="on-drag"` or `"interactive"`; omitting it keeps the
keyboard open while scrolling.

Removing `placeholderTextColor` or `selectionColor` from a reused `TextInput`
restores the platform theme default on both hosts instead of retaining the
previous native color. Removing `accessibilityState.disabled` likewise restores
interaction for retained links and generic pressable containers.

Changing a keyed `TextInput` between single-line and `multiline` mode recreates
the platform control when its native class or mode is incompatible, while the
reconciler carries forward the current draft value.

Android handles `uiMode` changes in place: the active native document is
reconciled against the new DayNight resources, so theme-default text colors,
safe-area insets, and focused input state survive a light/dark transition.
On iOS, `traitCollectionDidChange` performs the same reconciliation so system
label/tint colors and native accessibility traits follow the new appearance.

`accessibilityLabel`, `accessibilityHint`, `accessibilityValue`,
`accessibilityState`, and `accessibilityRole` map to native accessibility
metadata and traits. The portable roles include `button`, `image`, `header`,
`link`, `search`, `none`, `adjustable`, `checkbox`, `combobox`, `menu`,
`menuitem`, `progressbar`, `radio`, `radiogroup`, `scrollbar`, `spinbutton`,
`switch`, `tab`, `tablist`, `timer`, `toolbar`, `list`, `menubar`, `summary`,
and `alert`; unknown roles retain the platform control's native class.
`accessibilityState` supports `disabled`, `selected`, and `checked`.

These fields are part of the exported `BaseProps`/`TextInputProps` types, so a
shared screen can keep its accessibility and keyboard contract type-safe before
it is compiled for either native host.

`craft.navigation.push`, `replace`, and `back` use the platform navigation
stack. A pushed route receives `craft.route.params`; `craft.navigation.open`
also accepts an optional second `props` object for a structured handoff. The
host keeps it in `craft.route.props`, separate from path/query params, so a
prop named `id` cannot overwrite a route parameter. Props are delivered with
the initial route and replaced when an existing route is opened again; they
are dropped with that route. Returning to an earlier
route reveals its existing native tree and JavaScript state. Native events are
delivered only to the top route, and route teardown removes its subscriptions
and cancels its in-flight requests. On iOS, a back-swipe that starts on a
horizontal `ScrollView` that can still scroll back (a pager past its first
page, a scrolled carousel or chart) is that scroll view's, from the edge too:
the pager goes back a page. At its first page there is nothing to scroll back
to, and the swipe goes back as usual. A custom horizontal gesture can opt out
of iOS 26's content-wide back-swipe with
`craft.navigation.setOptions({ contentSwipeBack: false })`; the edge-only back
gesture remains available. `swipeBack: false` turns off both, for a screen
whose own Back steps through it (a tour's questions). A screen that should
keep back navigation but own the tab gesture can independently set
`craft.navigation.setOptions({ tabSwipeEnabled: false })`.

`rightButtons` may contain SF Symbol, title, account, and badge buttons. On
iOS, account-style buttons are independent 44-point custom bar items with
their own circular material surface; they opt out of iOS 26's shared bar-item
platter so adjacent buttons cannot merge into one oversized background.

A screen can update one tab without replacing the bar or its navigation stacks.
The iOS and Android shells accept a live `title`, `iconTint`, and `iconPulse`:

```js
craft.navigation.setOptions({
  tabItem: {
    id: '/health',
    title: '123 bpm',
    iconText: null,
    iconTint: '#ff3b30',
    iconPulse: true,
    accessibilityLabel: 'Health, live heart rate, 123 bpm',
  },
})
```

The tab keeps its stable test identifier, `craft-tab-` followed by its id, even
when its caption or accessibility label changes. The configured symbol stays
in place. `iconText` is a separate optional icon
replacement; clear it when showing the symbol. A null `title` restores the
configured caption, a null `iconTint` restores the normal selected/unselected
color, and `iconPulse: false` stops the effect. Pulsing is subtle, stops while
the app is inactive, and honors Reduce Motion on iOS and disabled system
animations on Android. iOS 16 shows a static icon; iOS 17 and later use the
system symbol pulse. Changing the caption does not restart the animation.

Native and hybrid iOS route shells use `UITabBarController`. UIKit owns tab
selection, badge sizing, accessibility and scroll-edge presentation. Tabs stay
expanded while scrolling. On iOS 26, the standard action uses `UITabAccessory`
above the bar. Older iOS versions keep the action above the system tab bar.
Titles, selected symbols, icon tints, text icons and account photos remain
supported. Repeating `iconPulse`/`selectedIconPulse` and custom
`tabBar.selection` shapes/colors do not override this system control; they
still apply to the legacy web-only chrome and Android where supported.
The system indicator follows committed selection rather than Craft's
fractional swipe preview. Native route stacks and swipe cancellation are
retained. This migration does not change the web-only shell.

`tabAccessory` adds one destination button beside the tab pill without adding
it to any tab stack or to the tab-swipe order. Give it an app-local path,
title, and symbol; an optional badge and accessibility label are shared across
the iOS, Android, and browser hosts:

```js
craft.navigation.setOptions({
  tabAccessory: {
    path: '/messages',
    title: 'Messages',
    symbol: 'message',
    badge: '3',
  },
})
// Remove it when the destination is no longer relevant.
craft.navigation.setOptions({ tabAccessory: null })
```

On the iOS native/hybrid route shell, add `iconOnly: true` for a 48-point
circular trailing action with an overlaid badge. Its title and badge remain
available to VoiceOver. This compact presentation bypasses `UITabAccessory`,
including on iOS 26, and floats above the bar without increasing the native
bottom safe area or the hybrid page's `--craft-tab-bar-height`. Avoid placing
important controls under its trailing footprint; add local padding if needed.
Omitting `iconOnly` retains the standard accessory presentation and spacing.
The `@stacksjs/stx/native` navigation/chrome types carry the same `iconOnly`
option; no separate compiler or compact-accessory prop is needed.

Paths must begin with one `/` and are handled by the app's native route
resolver. The button is cleared when a pushed screen goes away, so a
destination cannot remain over another route. The browser native renderer
uses the same shape and navigates through its platform adapter.

Both maintained native hosts expose the same tab-swipe contract. In a hybrid
app, the iOS shell's gesture also covers the WebView. Pass
`swipeEnabled: false` to `craft.tabBar.set` when the page owns a horizontal
gesture of its own; native screens can still opt out independently with
`tabSwipeEnabled`.

Both native hosts also accept `backgroundColor` in
`craft.navigation.setOptions`. It paints the screen behind its native content;
passing `null` or omitting the option follows the app's light/dark background
resource, while an explicit colour remains the screen's requested fill.

On Android 15 and newer, three-button navigation keeps a system-themed
background only inside its tappable inset so every native button remains
readable, including over a black timer screen. This follows the device's
appearance even when the app chooses a different local theme. The screen and
status inset keep the requested fill; gesture navigation remains edge to edge.

On iOS, a native screen can opt into an opaque navigation bar that uses its
screen background, including the light/dark variant from `craft.config.json`:

```js
craft.navigation.setOptions({ navigationBarSolid: true })
```

This applies to both standard and large-title bars, and remains in place while
the screen is pushed, popped, or revealed by a tab swipe. The default remains
UIKit's translucent material; pass `navigationBarSolid: false` to restore it.
The host reapplies the dynamic app background when the system switches between
Light and Dark mode, so the bar does not need to be set again.

A screen's content stays inside the safe area. To colour the strips under the
status bar and the home indicator too, such as a black full-screen timer with
the bar hidden, set `craft.navigation.setOptions({ hidden: true,
backgroundColor: '#000000' })`; `backgroundColor: null` gives the app's colour
back. A screen whose first view is its `ScrollView` runs edge to edge under the
bar, as a large-title screen does: its content scrolls up under the bar
behind iOS's scroll edge effect, and on down under the floating tab bar.

## An all-native iOS app: paths, tabs and an app script

On its own, `renderer: "native"` is one screen and the stack it pushes. Add
`nativeScreens` (and, optionally, `tabs`) and the app gets the same shell a
hybrid app has (tab stacks, path routing, deep links) with no web view at
all: no `WKWebView` is ever created.

```json
{
  "renderer": "native",
  "devServerURL": "https://hq.training/m",
  "nativeScreens": {
    "/m": "Today",
    "/m/calendar": "Calendar",
    "/m/workout/:id": "Workout"
  },
  "tabs": [
    { "id": "/m", "title": "Today", "symbol": "sun.max" },
    { "id": "/m/calendar", "title": "Calendar", "symbol": "calendar" }
  ],
  "nativeBundle": "./native-screen.js",
  "nativeApp": "__app"
}
```

- `devServerURL` is the app's site. Its path is the path the app starts on
  (`/` without one), and the bundle reads it as `__stxNativeBridge.appURL`.
- Every tab id and the start path must be drawn by a native screen; `init` and
  `build` refuse the config otherwise, because there is no web view to fall
  back to.
- `craft.navigation.open(path, props?)` opens a tab (switching to it), a native screen
  (pushed onto the visible tab, or popped back to if it is already in the
  stack), or, for a path no screen draws, the in-app browser
  (`SFSafariViewController`) at that path on the site's origin. A full `http(s)`
  address on the site's host is treated as its path; one on any other host
  opens in the in-app browser. With no `devServerURL`, a path no screen draws
  is logged and ignored.
- A deep link to a native path opens its screen in the tab that owns it. A
  universal link to the site's host that no screen draws opens in the in-app
  browser. Anything else reaches the screens as `DEEP_LINK`. A link that
  launched the app waits for the shell.
- Tab taps and completed left/right swipes switch stacks natively. In a hybrid
  app the gesture works over both native screens and the WebView; the page can
  disable it with `craft.tabBar.set(tabs, { swipeEnabled: false })`. A swipe
  switches tabs only on a tab's first screen (deeper, a swipe to the right is
  Back) and not while a screen has put the tab bar away (`tabBarHidden`). Swipes
  yield to a horizontal native scroll view or a screen that sets
  `contentSwipeBack: false` or `tabSwipeEnabled: false`; the tab bar provides selection feedback when a
  swipe changes tabs. A screen that throws before its first frame
  keeps its own error, since there is no page to stand in for it.
- GPS (fixes, watches, the background route recorder and its relaunch
  restore) and Apple Music work here too: the app holds the web view's service
  coordinator without a web view, so `geolocation` and `music` are among the
  capabilities whenever `enableGeolocation` / `enableAppleMusic` are set. The
  single-screen native app (no `nativeScreens`) gets them as well.

### Generated project customization

Generated native sources are owned by Craft and may be replaced on the next
build. Use typed configuration for common chrome changes, and declare a hook
only for app-owned source changes that Craft does not model yet:

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

The `tabBar.selection` option is shared by the iOS and Android builders. Its
`cornerRadius` is in points on iOS and dp on Android; `color` is `#RRGGBB`.
It styles Android and the legacy web-only iOS chrome. Native and hybrid iOS
route shells use the system tab indicator and do not override its shape or
fill. Omitted values preserve each host's default selection appearance.

`postGenerate` runs after `craft ios build` or `craft android build` generates
the native project. The command runs with the generated project as its working
directory and is launched directly from `command` plus `args` (no shell
interpolation). Craft provides `CRAFT_PROJECT_ROOT`, `CRAFT_PLATFORM`, and
`CRAFT_GENERATE_PHASE=build`. Missing executables, malformed options, and
non-zero exits fail the build and include the hook's stderr, so a source patch
cannot silently stop applying after a template change.

### iOS home-screen quick actions

Native iOS screens and the `nativeApp` script expose `craft.shortcuts.set(items)`
and `craft.shortcuts.clear()` through the `shortcuts` capability. They update
the app-wide UIKit long-press menu without a WebView. `set` replaces the entire
dynamic menu and resolves `{ count }`; `clear` removes it and resolves `true`.

```ts
await craft.shortcuts.set([
  { type: 'saved', title: 'Saved trails', iconName: 'heart.fill' },
  { type: 'record', title: 'Record a trail', subtitle: 'Start recording' },
])
```

Provide at most four items, each with a unique, non-empty `type` and non-empty
`title`. Optional `subtitle` and `iconName` must be strings. Optional `userInfo`
is an object containing property-list-compatible JSON values (strings, finite
numbers, booleans, arrays and nested objects; no `null`). Invalid input rejects
with `INVALID_ARGUMENT` before changing the previous menu. UIKit decides how
many actions it displays. A disposed screen's queued request cannot replace
another screen's menu; once applied, actions outlive the registering screen.

Configured `appShortcuts` still seed the menu at launch and generate App Intents;
dynamic `set`/`clear` does not add or remove Siri/Spotlight intents. A later cold
launch reapplies configured shortcuts. Registration is best owned by `nativeApp`
when it depends on the signed-in account.

Activation uses the existing `craftShortcut` app event with `{ type }`, including
taps queued before the app script is ready. Handle it in the app script and run
the usual sign-in/authorization checks before navigating. Registration does not
automatically navigate, and `userInfo` is not added to the activation payload.
The page's `onShortcut` helper is not a new native-screen event subscription.

This capability is implemented by the iOS native host; it does not claim an
Android native implementation. Cross-platform callers should check the host's
advertised capabilities and report unsupported on hosts without `shortcuts`.

### The app script (`nativeApp`)

`nativeApp` names a bundle route that has no screen (Stacks names it `__app`).
It runs once for the app's whole life, in its own JavaScriptCore context,
beside the screens, in a hybrid app or a native one. It is loaded after the
first screen's first frame is committed, so it never delays it. If background
work (a silent push or a background refresh) is waiting for it, it is loaded
at once instead, because a launch in the background draws no frame. Otherwise
it is loaded 1.5 seconds after launch at the latest.

- It gets every `APP_STATE`, not only while on top of a stack, and no
  `DEEP_LINK`.
- The app's events go to it instead of to the page, as the bridge message
  `CRAFT_EVENT { event, detail }`, which the stx runtime dispatches as a
  `CustomEvent` on the script's global: `craftNotificationResponse`,
  `craftNotificationReceived`, `craftSilentPush`, `craftBackgroundRefresh`,
  `craftShortcut` and `craftSiriShortcut`. Events that arrive before it has run
  its bundle (a notification tap that launched the app) are held and delivered
  in order once it has. Without an app script they go to the page as before;
  an all-native app with neither logs and drops them, and answers any
  background work at once.
- `craft.navigation.open(path, props?)` opens in the shell as above, so
  `craft.navigation.open('/m/workout/5', { workout })` opens that screen in the
  visible tab and makes the structured value available as `craft.route.props`.
  and a tab path switches tabs. Opens made before the shell exists are held
  for it. `push`, `replace`, `back`, `popToRoot`, `setOptions` and
  `tabBarHidden` do nothing: it has no stack and no bar.
- A failure while loading is logged; nothing falls back.
- It answers background work with `craft.background.complete(ok, id?)`: the
  `Background.complete` capability with args `[ok, id?]` (no id finishes
  everything pending). The `background` capability is present when
  `backgroundRefresh.enabled` or `enablePushNotifications` is set. The `id`
  comes in the `craftSilentPush` / `craftBackgroundRefresh` detail; iOS is
  answered by itself after 25 seconds.

```js
addEventListener('craftNotificationResponse', (event) => {
  if (event.detail.path) craft.navigation.open(event.detail.path)
})
addEventListener('craftSilentPush', async (event) => {
  const ok = await sync().then(() => true, () => false)
  craft.background.complete(ok, event.detail.id)
})
```

### What every screen knows of the app

`__stxNativeBridge` carries `appURL` (the `devServerURL`, or `""`),
`appVersion` (`CFBundleShortVersionString`), `appBuild`
(`CFBundleVersion`) and `sessionTokenKey` (the config's, or `auth.token`),
beside `platform`, `capabilities`, `initialAppState` and `colorScheme`.

### The signed-in account

`craft.session.token()` (sync) reads the sign-in token under `sessionTokenKey`;
`craft.session.onChange((token, previous) => ...)` hears each change of it,
whoever made it: this screen, another screen, the app script, a sign-out's
`secureStorage.clear()`, or the page's own sign-in through a `shareStorage`
key. Each change also reaches every screen as
`SESSION_CHANGED { key, token, previous }`, after secure storage holds the new
token. Like the snapshot functions, the host's `craft.session` survives the
runtime assigning its own. See the [Session API](../api/mobile/session.md).

```js
let account = craft.session.token()
craft.session.onChange((token) => {
  if (token === account) return
  account = token
  resetScreen()
})
```

### Snapshots

`craft.snapshots.get(name)` (sync) and `craft.snapshots.set(name, value)` (a
promise) read and write `Application Support/craft-snapshots/<name>.json`, the
same files a hybrid page's snapshots use. `craft.snapshots.clear(keep?)` (a
promise) deletes every snapshot except the names in the optional `keep` array,
for a sign-out: `await craft.snapshots.clear(['app'])`. Every removal reaches
every screen as `SNAPSHOT_CHANGED`. The host functions survive the runtime
assigning its own `craft.snapshots` object; a key the runtime defines itself
wins.

## Capability bridge

The generated iOS and Android hosts advertise a versioned capability bridge on
`globalThis.__stxNativeBridge`:

```ts
globalThis.craft.platform // 'ios' or 'android'
globalThis.craft.capabilityProtocolVersion // 1
globalThis.craft.capabilities.storage // true when enabled
globalThis.craft.capabilities.secureStorage // true when enabled
globalThis.craft.capabilities.biometric // true when enabled
```

The shared asynchronous surface is:

```ts
await craft.storage.set('profile', { name: 'Ada' })
const profile = await craft.storage.get('profile')
await craft.db.execute('CREATE TABLE IF NOT EXISTS notes (text TEXT)')
const notes = await craft.db.query('SELECT text FROM notes')
await craft.db.beginTransaction()
await craft.db.commit() // or await craft.db.rollback()

const stopState = craft.lifecycle.onStateChange((state) => console.log(state))
const state = craft.lifecycle.getState() // synchronous current state
const initial = await craft.deepLinks.getInitialURL()
const stopLinks = craft.deepLinks.onLink((link) => console.log(link.url))
const id = await craft.notifications.schedule({ title: 'Reminder', delay: 60_000 })
await craft.notifications.cancel(id)

const photo = await craft.files.pickImage({ source: 'library' })
const attachments = await craft.files.pickFile({
  contentTypes: ['application/pdf', 'csv', 'gpx', 'fit'],
  maxSelections: 4,
  maxBytes: 20 * 1024 * 1024,
}) // [{ path, name, type, size }], or [] when dismissed
const form = new FormData()
form.append('photo', photo)
const upload = await fetch('https://api.example.com/upload', {
  method: 'POST',
  body: form,
})
const exportFile = await craft.files.write('route.csv', 'name,distance\nLoop,5', { type: 'text/csv' })
await craft.files.remove(exportFile.path)

await craft.secureStorage.set('session-token', 'secret')
const token = await craft.secureStorage.get('session-token')
await craft.secureStorage.delete('session-token')
const available = await craft.biometrics.isAvailable()
const biometricType = await craft.biometrics.getBiometricType()
if (available) await craft.biometrics.authenticate('Unlock WildLoop')

#### Mounted-view operations

Shared overlays use the screen-owned `View` capability rather than reaching
into a DOM. The STX adapter sends an `API_REQUEST` with `module: 'View'` and
one of these argument shapes:

```ts
await nativeCall('View', 'focus', [{ nodeId, mode: 'keyboard' }])
await nativeCall('View', 'focus', [{ nodeId, mode: 'accessibility' }])
const box = await nativeCall('View', 'measure', [{ nodeId }])
const offset = await nativeCall('View', 'scrollTo', [{ nodeId, x: 0, y: 240, animated: true }])
```

`focus` resolves to `true`. Keyboard focus is supported for mounted text
inputs; accessibility focus posts the platform's layout-change notification
for the mounted node. When a modal becomes visible, its host captures the
currently focused opener before modal content can autofocus; closing it
restores that opener only if it is still mounted. `measure` resolves to `{ x, y, width, height,
viewportWidth, viewportHeight, unit, coordinateSpace }`. The coordinate space
is the native screen viewport, with an origin at its top-left and values in
logical units (`points` on iOS and density-independent `dp` on Android).
Coordinates therefore move as a scroll view moves, include the screen's safe
area and exclude any window chrome outside the native screen root. Calls made
after reconciliation but before layout settle on the host's main/UI thread.
An anchored popup must treat the anchor's `onLayout`, the screen root's
`onLayout`, and each ancestor `onScroll` event as placement invalidations; the
next `measure` response is the authoritative position in `screenViewport`.

`scrollTo` targets a mounted native `ScrollView`. Its `x` and `y` values are
optional logical offsets (`points` on iOS and density-independent `dp` on
Android); omitted axes retain their current offset. The host clamps requested
offsets to the scrollable content range and resolves to the resulting
`{ x, y, unit }`. `animated` defaults to `false`.

Unknown or removed node ids reject with `VIEW_NOT_FOUND`; detached nodes reject
with `VIEW_NOT_MOUNTED`; unsupported focus targets reject with
`UNSUPPORTED_TARGET`. `scrollTo` rejects non-scroll-view targets with the same
code and rejects non-finite coordinates with `INVALID_ARGUMENT`. The
`viewFocus`, `viewMeasure`, and `viewScroll` capability flags are advertised
independently so shared components can gate these operations on older Craft
hosts. Hosts that support the viewport-owned, non-blocking popup contract also
advertise `viewNonModalPresentation`. Gate `Modal` usage with
`nonModal: true` and `dismissOnOutsideTap: true` on that capability; an older
host may only understand the blocking modal behavior. The flag covers viewport
promotion, outside-tap dismissal, and nested overlay teardown together.

// Native iOS passkeys (capability `passkeys`). The server still creates and
// verifies the WebAuthn challenge; Craft presents Apple's credential sheet and
// returns the standard WebAuthn response fields. `rpId` must be one of the
// app's `webcredentials:` associated domains.
if (craft.capabilities.passkeys && await craft.passkeys.isAvailable()) {
  const credential = await craft.passkeys.get({
    rpId: 'login.example.com',
    challenge: authenticationOptions.challenge,
    allowCredentials: authenticationOptions.allowCredentials,
  })
  await verifyOnServer(credential)
}

// iOS app-icon badge (the capability is advertised only on iOS).
if (craft.capabilities.badge) {
  await craft.badge.set(3)
  await craft.badge.clear()
}
```

Storage is JSON-serializable and survives process termination. A queued native
Storage operation cancelled before it starts leaves the saved value unchanged
and sends no completion. Cancelling an operation that has already started cannot
undo its atomic commit. Android host disposal also stops queued storage work and
pending completions; new calls to that closed host reject with `HOST_CLOSED`.
iOS screen disposal cancels pending requests before controller deallocation and
rejects later requests from that closed runtime. Flush a final checkpoint before
disposing its screen or host.
Individual storage operations are atomic. A sequence of reads and writes is not
a transaction: use `setIfAbsent` or `compareAndSet` when sessions can compete for
the same checkpoint, and handle a `false` result as a conflict.

SQLite is stored
in the app's persistent data directory and supports typed string, number,
boolean, and null parameters. `execute` resolves to `{ rowsAffected,
lastInsertId }`; transaction methods resolve to `true` on success. Local
notification schedules are persisted by the OS on iOS and through
`AlarmManager` on Android, so they do not depend on a running JavaScript
process. The Android receiver is registered only for native-renderer projects.

`enableLocalDatabase`, `enableLocalNotifications`, and `enableDeepLinks` are
explicit configuration gates. `enableSecureStorage` and `enableBiometric` gate
the corresponding secure-storage and biometric methods. Secure storage accepts
string values and persists them in the iOS Keychain or Android encrypted
preferences. The `badge` capability is iOS-only and does not request notification
authorization; `craft.badge.set(count)` and `craft.badge.clear()` update the app
icon without requiring local notifications.
On Android, `enableHealthConnect` keeps the HealthKit-shaped workout methods on
the foreground Health Connect lifecycle and writes the finished session back
through Health Connect. Native apps that need live sensors can additionally set
`enableHealthServices: true`. Craft retains `ExerciseClient` in a foreground
service, checks device capabilities before starting, and sends the same typed
`craftHealthWorkout` events as iOS, including `heartRateBpm`,
`activeEnergyCalories`, and `distanceMeters` metrics. The adapter supports
running, walking, hiking, and cycling. Pair it with `enableHealthConnect` when
the finished session should be written as an `ExerciseSessionRecord` with its
distance and active-energy totals; without Health Connect the native session
still ends and returns the typed result. Unsupported devices and exercise
types produce an `error` event rather than silently upgrading the fallback.

On iOS, `health.discardWorkout()` (native protocol: `Health.discardWorkout`)
ends the current live session without saving a workout. `endWorkout()` still
ends **and saves** it. Use `health.supports('discardWorkout')` before offering
discard on older hosts or Android; never fall back to `endWorkout()` when the
intent is not to save. Discard resolves to `true`, rejects with `NO_WORKOUT`
when no live session exists, and rejects with `WORKOUT_ENDING` if a save is
already in progress. It does not delete existing HealthKit samples or promise
to undo activity-ring contributions. For a mindful session, discard the live
workout first, then explicitly save the intended `saveMindfulSession` record.
This option does not change authorization or device requirements for starting
a live workout or guarantee Apple Watch sample timing.

A native passkey screen requires both `enablePasskeys: true` and at least one
`webcredentials:<host>` entry in `associatedDomains`; otherwise the host does
not advertise `passkeys`. `craft.passkeys.isAvailable()` is a configuration
and OS-version check and does not display a sheet. `create(options)` expects a
base64url `challenge`, `user.name`, and base64url `user.id`; `get(options)`
expects a base64url `challenge` and optional `allowCredentials`. Both accept an
explicit `rpId` (or `rp.id`) only when it exactly matches a configured
`webcredentials:` host, preventing a native screen from presenting credentials
for another relying party. Results contain `id`, `rawId`, `type: 'public-key'`,
and the standard registration or assertion `response` fields, all base64url
encoded. The sheet is presented on the main thread and is cancelled with the
screen's capability request token when the route is torn down.
A missing key resolves to `null`. Biometric availability is a
device check, so an enabled simulator or emulator may still report `false`.
A disabled or unavailable capability rejects with
`CAPABILITY_DISABLED` or `NOT_SUPPORTED`; malformed keys, SQL, or notification
arguments reject with `INVALID_ARGUMENT`. Every request has a 30-second native
deadline. A timeout rejects with `TIMEOUT`, sends `API_CANCEL`, and native route
teardown cancels any remaining work. Unsupported protocol versions reject with
`UNSUPPORTED_VERSION`.

`deepLinks.getInitialURL()` claims the launch URL once for the native app
process. It can be called from any route, but later routes receive `null`; a
URL delivered through `deepLinks.onLink` is marked `initial: true`. URLs received
through a resumed activity or scene are marked `initial: false` and remain
available to subscribers even after the launch URL has been claimed. Android
persists the launch claim across activity recreation, so rotation and process
handoff do not replay a stale intent.

The old flat notification methods (`scheduleNotification`,
`cancelNotification`, `cancelAllNotifications`, and `getPendingNotifications`)
remain available as aliases. Existing device info, clipboard, haptics,
mutation, and legacy web-renderer behavior are unchanged. To migrate a web
screen, keep the existing `craft-native/mobile` calls and use the nested
capability methods only where persistence or native lifecycle behavior is
needed; browser-rendered apps continue using their existing web fallbacks.

The `files` capability keeps picked, downloaded, and generated files in an
app-owned temporary directory that survives Activity recreation; stale entries
are swept after a day. `craft.files.remove` rejects paths outside that
directory. When the host advertises `files`, its `FormData`
implementation accepts text fields and those file descriptors;
`Network.fetch` assembles the multipart body natively, so file bytes do not
pass through JavaScriptCore as base64. Without that capability, native
`FormData` is not installed and the text-only fetch contract below remains
unchanged. `craft.files.download` resolves a non-2xx response as
`{ ok: false, status, body }`; transport failures still reject with the native
network error codes.

Both maintained native hosts implement `craft.files.pickFile`. Android maps the
shared MIME, UTI, and common extension filters to `ACTION_OPEN_DOCUMENT`, copies
each selected document into the same app-owned directory, and enforces the
shared 512 MiB default/per-file limit before publishing a descriptor. A
dismissed picker resolves with an empty array; a canceled or oversized copy
never leaves a partial file behind. The same cancellation cleanup applies while
Android is decoding a picked image or copying a video, so a request canceled
after the picker closes cannot publish or leak an app-owned file. Use this for
GPX, TCX, FIT, PDF, or other documents that are not photos or videos. On iOS,
failed photo JPEG creation or finalization also removes its staging directory,
so a rejected image import does not accumulate orphaned temporary files.
If an iOS or Android file picker, write, or download finishes after its request is
cancelled (including screen teardown), the delivery boundary removes its
undelivered app-owned files and their staging directories. Already delivered
files and the persistent `media.keep` cache are not removed by this cleanup.
Android checks screen closure during document/video copying even after request
cancellation bookkeeping has been cleared. A denied document read rolls back
the entire selection, including earlier successful copies, and a denied image
read settles with `READ_ERROR` instead of leaving a pending request. The Android
capability instrumentation covers these paths with a debug-only content provider
and real file streams; it does not automate the system picker's permission UI.

`craft.audio` playback is screen-owned on both hosts. Android requests audio
focus before preparing a player, reports a denied request as `AUDIO_FOCUS_DENIED`,
pauses on a transient interruption and resumes on focus gain, ducks during a
duckable interruption, and releases focus when the last sound ends or the
screen closes. Android keeps ducking
active through volume changes and fades, restoring the current requested volume
on focus gain. Explicit `resume()` returns `false` during transient focus loss;
a user-paused sound remains paused when focus returns. iOS observes
`AVAudioSession` interruptions and resumes sounds
only when the system grants the `shouldResume` option. A permanent Android
focus loss releases every player and sends each sound's error event; replacement,
decode failure, cancellation, interruption, and teardown also release their
player resources.
On iOS and Android, stopping, replacing, or closing a sound while it is still
loading rejects that pending play request with `CANCELLED` exactly once.
A late readiness callback cannot report success for a removed sound or affect
another sound that reuses its id; decode failures retain `AUDIO_ERROR`.
Control calls resolve `false` when their sound id is not owned by the screen,
matching the browser host instead of reporting a false success.

Checkpoint names use the same bounded filename contract on both native hosts:
letters, digits, `.`, `_`, and `-`, up to 128 characters, without a leading
dot. Non-JSON values and invalid names are rejected before a write is posted;
the previous confirmed checkpoint remains available after a failed or
interrupted replacement. If a screen closes while a checkpoint is still being
written, its promise rejects instead of hanging; the host's later worker
completion cannot publish a second result for that request. iOS also reports a
failed result when its writer completes after the screen runtime is disposed or
has already been deallocated.
On iOS, a retained context cannot start new snapshot reads, writes, deletions,
or clears after its screen closes: those calls fail with `SCREEN_CLOSED`
before touching the shared checkpoint cache or disk. The genuine synchronous
unmount callback retains its storage-cleanup allowance; work queued after it
does not. Writes already admitted before close may still finish on disk, so a
rejected completion is not a rollback guarantee. Await the final checkpoint
before leaving the screen when persistence must be confirmed.

The `media` capability (iOS) keeps video and audio on the phone for offline,
in Application Support rather than the temporary directory, left out of
iCloud backups. `craft.media.keep(url, { headers })` downloads the file once
and resolves `{ ok: true, url, path, size }` (a copy already there answers at
once, and two calls for one address share a download); a non-2xx answer
resolves `{ ok: false, url, status }` and keeps nothing.
`craft.media.path(url)` is the kept copy's path or `null`,
`craft.media.prune(urls)` removes every copy not in `urls` and resolves how
many went, and `craft.media.usage()` is `{ files, bytes }`. A native `Video`
given an address with a kept copy plays the copy, so a screen keeps its
videos and passes the same URLs as before. A `Video` whose source has no
scheme (`/videos/a.mp4`) cannot load on a native screen and fires `onError`.

On iOS the downloads run on the app's background URL session, so a video
being kept carries on while the app is suspended or closed, and iOS
relaunches the app in the background to store it. `{ cellular: false }` keeps
a download off cellular, hotspots and Low Data Mode. When the phone cannot
fetch the file now (no connection, or only a metered one for a Wi-Fi-only
keep), `keep` resolves at once with `{ ok: false, url, reason: 'offline' |
'cellular', queued: true }` and the transfer stays queued with iOS: it
finishes when it can, and the next `keep` of that address answers from the
copy. `prune` stops the transfers for addresses it does not keep, and
`clear` (sign-out) stops them all, so none lands afterwards.

Android does the same with WorkManager: each download is a job named by its
address, run when its network is there (an unmetered one for `{ cellular:
false }`), so it carries on after Android stops the app. A partly downloaded
file is resumed with a Range request on the next attempt, and the queued
answer has the same shape as on iOS.

```ts
await craft.media.keep('https://example.com/videos/squat.mp4')
await craft.media.prune(['https://example.com/videos/squat.mp4'])
```

### Network requests and timers

JavaScriptCore has no `fetch` and no timers. The iOS host supplies both, and
advertises `fetch` in `__stxNativeBridge.capabilities`; a current `stx native compile`
bundle then installs a global `fetch` with the familiar subset:

```ts
const response = await fetch('https://api.example.com/today', {
  method: 'POST', // default GET
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ days: 7 }), // a string, or omitted
})
if (response.ok) today = await response.json() // or await response.text()
response.status // also statusText, url, redirected, headers.get(name)
```

Each call is one `Network.fetch` capability request served by a `URLSession`
data task, so it shares the 30-second deadline, `API_CANCEL`, and route
teardown cancellation of the other capabilities: a closed screen cancels its
transfers. Only absolute `http` and `https` URLs are accepted (plain HTTP still
needs an App Transport Security exception, as the template has for
`localhost`); bodies are UTF-8 text both ways, a `GET` or `HEAD` with a body is
rejected, and a response larger than 8 MB rejects with `RESPONSE_TOO_LARGE`.
Transport failures reject with a `TypeError` whose `code` is `NETWORK_ERROR` or
`TIMEOUT`; HTTP error statuses resolve normally with `ok: false`. Streaming
bodies, `AbortSignal`, and arbitrary binary bodies are not part of the subset.
`FormData` is supported only when the host advertises `files`; it is limited
to text fields and files created by `craft.files`. Cookies use the app's
shared `HTTPCookieStorage`.

`setTimeout` and `clearTimeout` are installed when the context lacks them. The
callbacks stay in JavaScript, the deadline runs on the main queue, and route
teardown cancels every pending timer.

## Controlled text edits

TextInput change events carry a per-control `nativeEvent.eventCount`. A runtime
that controls `value` echoes that count in `mostRecentEventCount` in the same
update as the value. Both native hosts reject an update acknowledging an older
edit, so delayed bridge delivery cannot erase later characters. A reset or
formatted value acknowledging the current edit still applies. stx handles this
handshake automatically; application inputs do not maintain counters.

Older runtimes without acknowledgements keep the bounded pending-value fallback
on either script thread. UIKit also retains its composition and selection
protection, and removed controls release their counters with their handlers.

## Verification

The repository exercises the same compiled multi-route fixture on both
platforms:

```bash
bun packages/ios/scripts/test-native-render.ts
bun packages/ios/scripts/test-native-navigation.ts
bun packages/android/scripts/test-native-navigation.ts
cd benchmarks && bun run bench:native-mutations
```

The iOS commands require macOS and a bootable simulator. The native-render
runner keeps XCTest output visible so interaction failures include their
assertion messages and source lines in CI. The Android command requires
`ANDROID_HOME`, `adb`, Gradle, and a running emulator. CI is the source
of truth when those platform prerequisites are unavailable locally. The
host-neutral benchmark includes 100, 1,000, and 10,000-node full renders and
single-node mutations; the platform suites separately verify native recycling,
capability persistence across relaunch, and notification cancellation.

When a style or color prop is removed during reconciliation, reused native
controls reset that value to the platform default instead of retaining stale
state. Detaching a retained iOS child also clears its cached layout style and
invalidates the parent measurement cache before the next responsive pass.

## The browser service host

Use `craft-native/browser` with stx’s `compileBrowserScreen` or
`renderBrowserScreen` to run the same portable screen in a browser. The entrypoint
exports `createBrowserPlatform(options)` and contains no desktop packaging APIs.

Options include `namespace`, `tokenKey`, `locale` and application `urlSchemes`.
The configured token key can match an existing website session. Snapshots and
ordinary storage are scoped by a SHA-256 account identifier; an account change
clears the previous account’s retained data, files and media. Cross-tab account
changes reload the screen so old controllers cannot continue under a new login.
Browser storage retains browser security semantics; it does not become Keychain
or Android encrypted storage.

The adapter provides real HTML dialogs, file pickers, multipart-capable File
objects, downloads, image/file sharing and saving, clipboard, speech, wake locks,
audio with fades, and account-scoped CacheStorage media where available. File
descriptors cross the stx JSON protocol and materialize back into File objects
before they reach application FormData. Disposal aborts service work and releases
object URLs, media and listeners.

Capabilities describe actual browser support. Health stores, push registration,
Bluetooth services and background recording are not advertised by this adapter.
Wi-Fi-only media downloads wait when the browser cannot identify its network;
applications may let the account explicitly allow other networks. Website
updates replace the browser bundle; installed native bundles still require an
app release.
