# WebView-free native navigation fixture

The three `.stx` screens and `native.config.json` exercise a native push with parameters, an in-app back action, UIKit's back button and edge-swipe, and replace. Home owns a keyboard-configured `TextInput`, `Picker`, `Checkbox`, date/time/countdown pickers, submit counter, counter, keyed `ScrollView`, a horizontal carousel whose swipe must take precedence over the tab shell, a network-free native `Video` mount (empty URI), a host-native `Icon`, and a DOM-free `svg` containing a grouped path and text node; the details list covers row moves, focused-input retention, insertion, empty content, and controlled pull-to-refresh. The native list unit fixture separately verifies virtualized `FlatList` scroll, drag, momentum, recycling, and refresh-control forwarding. Returning home must reveal the same values, not a freshly compiled screen. The simulator test also checks that the app exposes no WebView and that Icon/Video/SVG accessibility survives native mounting.

`testSharedRuntimePushBackReplaceLifecycleAndStateIsolation` is the focused
navigation gate. It uses the shared runtime's state and lifecycle APIs to verify
route parameters, retained home state, fresh state for every pushed details screen,
explicit and UIKit back behavior, replace stack semantics, and `onDestroy`
cleanup after both pop and replace. The shared runtime provides `craft`,
signals, and lifecycle hooks to ordinary client scripts; mutable values use
`state()` so bindings and route parameters observe the same live values.
The cleanup marker uses the native host's existing synchronous storage method.
An asynchronous request made by `onDestroy` still belongs to that screen and
is cancelled when its bridge disposes. A checkpoint requiring acknowledged
completion must finish before the application intentionally closes its context.
The synchronous marker tests callback delivery, while the capability suite
separately verifies that cancelled queued writes never mutate storage.
Run only that acceptance path with:

```bash
CRAFT_NATIVE_NAVIGATION_TEST=testSharedRuntimePushBackReplaceLifecycleAndStateIsolation bun packages/ios/scripts/test-native-navigation.ts
```

`testNativeBackSwipeKeepsTheSelectedTabAndHomeState` verifies UIKit's edge-back
gesture while the tab gestures are installed. `testNativeLinkOpensRoute` uses a
non-tab route alias so it exercises a native push and pop rather than selecting
the Details tab. It locates the compiled anchor by its accessibility identifier;
stx compiles anchors as touchable native controls. An unrelated home-state update precedes the link tap.
A hosted UIKit regression also retains exactly one link recognizer across updates
and removes it while disabled, so reconciliation cannot silently make a native
link stop responding.

Keyed row replacement releases the previous native root before the new row type
is hosted, so old event, image, and pull-to-refresh handlers cannot leak across
reuse. Both native hosts attach the details screen's `ScrollView` refresh
handler to the platform refresh control.
Returning to a retained route also reapplies native theme defaults before the
controller appears, keeping dark-mode colors current after navigation.
Keyboard frame changes update the controller's additional safe area, keeping the
focused form controls and their `onLayout` measurements responsive.
The fixture also exercises parent-relative percentage sizing and keeps wrapped
line distribution, including `space-evenly`, available through the shared
`alignContent` contract. The iOS host maps `space-evenly` to the shared code
before falling back locally, so the maintained fixture covers both paths.
The form path carries a keyed draft across a single-line/multiline input mode
change even though UIKit must replace the underlying control class. Keyed
ScrollView rows retain their drafts while the collection is reordered.
The UI gate locates the keyed row input relative to its row label and scrolls
controls into the root viewport before interacting, so unrelated fields and
screen-height changes cannot silently change which native control is tested.

Home also sets two right navigation buttons (`fixture-messages` and
`fixture-account`) with independent accent/account variants and badges. The
UI gate checks that both remain separate, non-overlapping 36–52 point
controls inside the window, covering the iOS 26 shared-platter regression
without relying on a screenshot.

From the Craft repository, with `@stacksjs/stx` available as `stx` (the
maintained CI checkout is pinned to
`0d85afbab4b569ac2f09113a6c9a5d11d926145f` / stx `0.2.573`):

```bash
bun packages/ios/scripts/test-native-navigation.ts
```

The script invokes `stx native compile` from the shared `@stacksjs/stx`
repository and verifies that it emitted mutation-protocol support,
generates a temporary iOS app, boots an available simulator, and runs
`NativeNavigationUITests.swift`. CI pins the stx compiler commit and
runs the same script on iOS and Android. For an unreleased sibling checkout,
set `STX_CLI=../stx/packages/stx/bin/cli.ts`; native support is part of
`@stacksjs/stx`, so do not install the historical `stx-native` package or
compiler. The pinned compiler sends the initial tree as one atomic render,
then uses keyed mutations for later updates.

`--prepare-only` compiles the `.stx` bundle and generates the Xcode fixture
without requiring an installed or bootable simulator. Set
`CRAFT_KEEP_NATIVE_NAVIGATION_PROJECT=1` to keep the generated project for
inspection; the normal command remains the CI simulator gate.

## Interactive native tab transitions

The iOS fixture has five native tabs. `NativeNavigationUnitTests` drives the real
UIKit gesture handler and checks stack geometry during the drag, past halfway,
and after completion, cancellation and reversal. It requires a native Core Animation
position interpolation with the expected start, destination and 220ms duration,
and samples the presentation layer while settling. It waits for display frames
and restored stacks rather than assuming a loaded simulator services a timer on time.
Async XCTest fulfillment keeps the main actor free for scene startup and native
animation callbacks; synchronous waits here can block the work being tested.
Restored frame checks allow half a point of UIKit rounding and report every
stack's frame and animation keys if settling times out.
Mid-drag screenshots are retained in the Xcode result bundle.
Tab taps interrupt a settling swipe immediately; a stale animation completion
must neither override that selection nor interfere with the next gesture.

`testTabSwipeSwitchesNativeRootsAndReturns`,
`testSwipesAcrossAllFiveNativeTabsAndBack`,
`testShortTabSwipeCancelsAndTheNextSwipeStillWorks` and
`testHorizontalCarouselKeepsItsSwipe` exercise actual simulator touches through
the compiled stx screens. The normal CI navigation command runs both targets.
To use a dedicated simulator, set `CRAFT_NATIVE_NAVIGATION_SIMULATOR=<udid>`.
To run only the geometry checks, set
`CRAFT_ONLY_TESTING=NativeNavigationUnitTests`. This variable also accepts
comma-separated XCTest selectors to run geometry and selected UI journeys in
one session. `CRAFT_NATIVE_NAVIGATION_TEST` continues to select a single UI test
by method name. The runner builds for testing first, then starts a separate
test session to avoid Xcode stalling between compilation and test launch.
