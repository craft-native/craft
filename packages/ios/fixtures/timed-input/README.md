# Timed native input receiver

`packages/ios/scripts/compile-templates.ts` builds this independent SwiftUI app
and dispatches all 24 taps in one native record: starts 80 ms apart, each held
for 25 ms. No Craft renderer is involved. The original `received-taps` assertion
must still observe every name in order, followed by the selection and scroll
checks. Do not use warm-up taps, drop initial events, or retry away a failure.

The test-host-only `InputReceipt` observes `UIWindow.sendEvent` and forwards each
event to UIKit exactly once. It records native began/ended/cancelled phases,
event timestamps, delivery uptime, coordinates, target view class, key-window
and application state. Button callbacks independently record their names and
the SwiftUI array before/after the append. Recording does not render UI or write
to disk; the first 256 observations are retained in memory.

After synthesis, the driver attaches `timed-input-receiver.txt` **before**
asserting 24 began phases, 24 ended phases, zero cancellations, the 24 callback
names, and the original SwiftUI label. Its companion
`timed-input-receiver-values.json` attachment includes the complete
`native-input-journal-N` values. Sort by numeric suffix and concatenate to
recover the JSON journal; each chunk stays below XCTest’s 512-character value
limit (the text tree truncates further). The scheduled `timed-input-*.json` attachment
and receiver journal distinguish planned input from delivered input and state
observation. Both remain in the retained `TimedInputDriver.xcresult` artifact.

For #432, an unchanged local pass does not explain the original missing One/Two
callbacks. These additional assertions and receipts preserve that investigation;
they are not evidence that the intermittent loss has been fixed.
