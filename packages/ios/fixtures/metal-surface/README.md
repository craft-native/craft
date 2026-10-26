# Native Metal display fixtures

This fixture compiles `metal_surface.zig` with Craft's pinned compiler and calls
its public `Surface` interface through a test-only C boundary. A native UIKit
application displays the result without a WebView or JavaScript renderer.

```sh
CRAFT_ZIG=/absolute/path/to/pinned/zig bun packages/ios/scripts/test-metal-surface.ts \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-2 \
  --xcodegen /absolute/path/to/managed/xcodegen \
  --output artifacts/native-metal-ios
```

The runtime must already be installed. The runner creates its own simulator,
retains logs and an XCTest result bundle under a fresh evidence directory, and
deletes only that simulator and its temporary project. It verifies simulator
deletion by reading the simulator's own UUID back. Command and test budgets are
bounded; missing tools, failed assertions, empty selections and skips fail.

Each command has its own POSIX process group. Completion, timeout and
cancellation dispose that group before the project is removed. A command that
ignores termination is killed after 250 ms; disappearance must be confirmed
within another second. Failure to confirm disposal fails the run. SIGINT,
SIGTERM and SIGHUP request the same ordered command, simulator and workspace
teardown. The execution, boot and test budgets remain unchanged. This owns
ordinary descendants; it is not a sandbox for processes that deliberately
escape their group, or a guarantee of teardown after an uncatchable SIGKILL.

The unit test compares every pixel copied back from the actual Metal drawable
across 60 frames, a native resize and resume. It verifies the window's backing
scale, rejection from a background thread and removal of the owned layer.

The UI application presents 61 frames and then becomes idle for inspection.
The UI test requires completion of frame 60, samples all four displayed color
quadrants from a real screen capture, resizes, backgrounds and resumes the app,
and samples again. Its retained screenshots contain only first-party test colors.
No animation, accessibility or idle-detection gate is disabled.

`mobile-e2e.yml` requires this job in complete mobile runs and includes it in
the focused `ios-render` scope. It uses Xcode 26.2 and iOS 26.2. Local execution
on the available iOS 27 beta passed the unit case, but the UI runner timed out
before a UI case began. A later local attempt also timed out during simulator
data migration. These failures remain evidence, and neither establishes visual
acceptance. A later unchanged retry on the required Xcode 26.2 and iOS 26.2
toolchain passed both unit and UI cases with zero failures or skips. Its
[retained receipt](../../../../docs/receipts/metal-surface-ios.json) verifies
the original artifact digest and records all three inspected screen captures.
That focused execution predates the command ownership correction; complete
release acceptance and consumer adoption remain separate gates.

## macOS display acceptance

```sh
CRAFT_ZIG=/absolute/path/to/pinned/zig bun scripts/test-metal-surface-macos.ts \
  --xcodegen /absolute/path/to/managed/xcodegen \
  --output artifacts/native-metal-macos
```

The AppKit application uses the same test-only C boundary and public Metal
surface. A native UI test captures only the owned view, compares its four
displayed color quadrants, resizes it, hides and resumes the application, then
verifies layer disposal. The existing macOS Zig tests independently compare
drawable pixels and backing scale. Screen capture and GPU readback are distinct
checks; neither substitutes for the other.

The runner checks the host's existing UI automation admission policy before
compiling. It never changes authentication or privacy settings. The standard
GitHub macOS image provisions unattended UI testing, and the macOS `zig-core`
job requires this display test. Missing admission, skipped tests, wrong pixels
and incomplete disposal fail acceptance. LaunchServices applications are checked
and disposed by executable paths beneath the unique generated project. If that
disposal cannot be confirmed, the project is retained for diagnosis.

Local AppKit and XCTest compilation passed, but this machine requires user
authentication for UI automation. The original XCTest attempt timed out before
any UI test began; the subsequent admission check refuses that host immediately.
These are retained failed executions, not proof of displayed macOS pixels.
Hosted execution and a qualified package release remain required.
