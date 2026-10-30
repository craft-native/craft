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

## Compare intended and delivered timing

Export attachments with `xcrun xcresulttool export attachments --path
TimedInputDriver.xcresult --output-path evidence`. In `evidence/manifest.json`,
select the `timed-input-<uptime>` schedule and `timed-input-receiver-values`
attachment **from the same device, configuration and repetition**. Pass their
`exportedFileName` paths (not the human-readable names):

```sh
bun packages/ios/scripts/analyze-timed-input.ts evidence/SCHEDULE.txt evidence/VALUES.txt
```

This offline diagnostic exits nonzero for missing/malformed evidence, lost
phases/callbacks, inconsistent state, or native offsets outside 50 ms of the
canonical schedule. The tolerance allows frame quantization; it does not allow
cumulative timing drift. It normalizes `UITouch.timestamp` to the first down
and reports delivery lag separately, so a delayed main thread is not confused
with an incorrectly scheduled event. It cannot measure absolute first-touch
latency, which requires a cross-process dispatch receipt. Callback-count CI
passing alone does not establish timing acceptance. This diagnostic does not
change the current CI gate or claim that #432 is resolved.

Investigation on Xcode 26.6 / iOS 26.5 found ten unchanged relaunch attempts
with all 24 callbacks, but delivered down events about 33 ms apart: about
0.8 s to the last up, versus the requested 1.865 s. A separate native record
attachment retained the correct 80 ms offsets before dispatch. Removing the
stationary move and using the device event synthesizer did not restore timing.
Putting all taps in one path delivered only one touch; reusing a pointer index
timed out during synthesis.
Those experimental driver changes were confined to disposable projects.
These results identify timing compression on this toolchain; they do not
explain the original CI run's missing One/Two callbacks.

The same compression is present in the passing native receiver from
[CI 41095420626](https://github.com/craft-native/craft/actions/runs/41095420626),
artifact `12998581446`. `compressed-ci-receipt.json` preserves that attempt’s
exported schedule and values with their provenance. The analyzer’s regression
test requires detecting the 0.800 s native span despite all 24 callbacks being
present. No retries are combined, and no experimental driver is used in this
fixture.
