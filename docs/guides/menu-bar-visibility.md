# Native menu bar visibility

Craft exposes two explicitly selected macOS grouping backends. A normal tray app
creates no grouping control. The `nativeVisibility` backend requires macOS 27,
a direct, non-sandboxed build and Accessibility access. It uses the private
MenuBarClientCore assessment-mode visibility API researched in
[Hidden Bar](https://github.com/dwarvesf/hidden). Apple can change this API;
unavailability never selects the legacy width-based backend automatically.

```ts
const native = useNativeDesktop()
native.onReady(async ({ menubar }) => {
  await menubar?.init({ backend: 'nativeVisibility' })
  const state = await menubar?.getState()
  // Offer a user-initiated permission action when available && !authorized.
  // await menubar?.requestPermission()
})
```

The backend adds one compact status button. Command-drag icons to its left
(right in a right-to-left interface) to include their applications in the hidden
group. Click the button or call `toggle()` to hide/reveal it. `collapse()` reads
the unrestricted arrangement asynchronously, then activates a visibility
assertion; `busy` describes this in-flight work. `collapsed` becomes true only
when macOS confirms activation. No status item is widened.

Hiding applies per app, so a visible sibling keeps every icon from that app
visible. System controls and the owning app are protected by default. Missing or incomplete
Accessibility geometry stays visible. Apps launched during a collapsed session
may remain hidden until the next reveal, when the unrestricted layout is read
again. Native system overflow remains under macOS control when revealed icons
exceed the available space; this API cannot pin app menus above system overflow.

`init({ backend: 'nativeVisibility', preserveSystemItems: false })` explicitly
accepts the private API's suppression of Apple modules, including Focus, Now
Playing and camera/microphone activity indicators. This matches Hidden Bar's
native behavior. Unselected application icons remain protected: if one disappears
after activation, Craft releases the assertion and reports `visibilityMismatch`.
Reveal restores suppressed modules. The default `preserveSystemItems: true`
also restores the bar when an Apple module disappears. `getState()` reports the
configured policy. Reinitializing reveals the group before applying a new policy.

`getState()` and `onStateChange` expose availability, authorization, busy state,
errors and the actual hidden-app count. Permission loss and activation failure
restore icons. Generation tokens prevent late activation callbacks from winning
after reveal, disable or quit. A 20-second deadline releases stalled activations.
`expand()` cancels pending work and releases the assertion; `destroy()` also
removes the control. Process exit releases the OS-owned assertion.

The positional backend, `init({ backend: 'legacy' })`, hides individual icons
to the left of `›` by reserving native status-bar space. Its `‹` remains the
reveal control even when the app's own cup or other icons are on the left.
`busy` remains true until the native layout settles. The arrow stays at 20 points.
On macOS 27, a chain of blank status items immediately to its left reserves the hidden space;
each item stays below half the narrowest display's width, while their combined
reservation covers the widest connected display. This avoids a single long
spacer being refused on a MacBook before it can hide icons on an external display.
Older status bars retain a single spacer whose width is reduced until the system
accepts it without displacing the compact reveal control.

Native saved positions can be clamped, so each spacer stays compact while its
requested position is adjusted. On macOS 27, Craft verifies one spacer beside
the arrow at a time and hides it before positioning the next. This keeps a
compact chain from overflowing beside a notch after the arrow is moved left.
Only then does Craft restore the complete wide reservation. Unsafe placement
restores the visible group. Later clicks reuse the verified layout immediately
until native reordering or changed display geometry requires calibration.
Replacement spacers receive fresh internal saved identities so macOS cannot park
them in an obsolete overflow slot. Their preference keys are removed on disposal;
the user's arrow retains its stable saved identity.
While revealed, macOS 27 hides the blank
items so even their native padding stops occupying the bar; older status bars
keep their width at zero. Disabling grouping removes the complete
chain and the arrow. The verified compact layout anchors widening, so delayed
layout updates after reveal do not undo the next collapse.

The compact arrow uses its own stable saved identity rather than inheriting the
retired widening separator's native overflow placement. That migration places
it in a visible native slot; subsequent native Command-drags persist normally.
This backend does not activate an assessment-mode restriction or require
Accessibility authorization.

Command-drag uses the standard native status button. Craft leaves its geometry
alone while the mouse is held. Reordering a collapsed group reveals it after
the drop; clicking `›` then hides the icons to the left of the new boundary.
Command-clicks and the mouse-up that finishes a drag do not toggle the group.
Only a gesture that starts in the menu bar and moves counts as reordering;
Command-clicks and drags in other windows leave a collapsed group unchanged.

The default `init()` remains the legacy backend for existing consumers. Select
native visibility explicitly; do not combine both controllers. Private visibility
must not be used in App Store submissions. The native tests exercise lifecycle
failure paths with controlled replies and the real bridge with the packaged
runtime, without granting Accessibility access.

For live acceptance on macOS 27, with Accessibility already authorized, run:

```sh
CRAFT_NATIVE_TEST_BIN="$PWD/packages/zig/zig-out/bin/craft" CRAFT_NATIVE_VISIBILITY_E2E=1 bun test packages/typescript/src/__tests__/menubar-visibility.native.test.ts
```

This creates isolated signed controller/target app bundles, creates a real target
status item, waits for the real macOS activation reply, then checks
reveal and destroy. The test never requests a permission grant. Test apps and
their assertions are released in cleanup; ordinary CI skips this opt-in case.

To verify positional reordering with real Command-drags and mouse clicks, run
the following on a Mac where the automation process already has Accessibility
and input-event permission:

```sh
CRAFT_NATIVE_TEST_BIN="$PWD/packages/zig/zig-out/bin/craft" CRAFT_MENUBAR_DRAG_E2E=1 bun test packages/typescript/src/__tests__/menubar-drag.native.test.ts
```

This packages an isolated native app and compiles a temporary input driver. It
moves the arrow to either side of a test icon, checks that right-side items stay
visible and left-side items disappear, reveals them again, and exercises cached
toggles and dragging while collapsed. Controls are found by their owning process,
not by a chevron shared with the system overflow UI. The test never requests or
grants permissions and cleans up its app and preference profile.
