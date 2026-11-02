# Timed native input receiver

`packages/ios/scripts/compile-templates.ts` builds this independent SwiftUI app
and dispatches all 24 taps in one native HID stream: starts 80 ms apart, each held
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

For #432, the original missing One/Two callbacks remain unexplained. Correcting
the separately reproduced timing compression does not establish that the
intermittent callback loss is fixed.

## Compare intended and delivered timing

Export attachments with `xcrun xcresulttool export attachments --path
TimedInputDriver.xcresult --output-path evidence`. In `evidence/manifest.json`,
select the `timed-input-<uptime>` schedule and `timed-input-receiver-values`
attachment **from the same device, configuration and repetition**. Pass their
`exportedFileName` paths (not the human-readable names):

```sh
bun packages/ios/scripts/analyze-timed-input.ts evidence/SCHEDULE.txt evidence/VALUES.txt
```

This diagnostic exits nonzero for missing/malformed evidence, lost
phases/callbacks, inconsistent state, or native offsets outside 50 ms of the
canonical schedule. The tolerance allows frame quantization; it does not allow
cumulative timing drift. It normalizes `UITouch.timestamp` to the first down
and reports delivery lag separately, so a delayed main thread is not confused
with an incorrectly scheduled event. It cannot measure absolute first-touch
latency, which requires a cross-process dispatch receipt. Callback-count CI
passing alone does not establish timing acceptance. The template compilation
job now exports the attachments and applies this same analyzer before accepting
a successful XCTest result. It requires exactly one schedule and receipt from
the same device, configuration and repetition; missing, duplicated, mixed or
compressed evidence fails the job. The original result bundle is retained
before analysis, including when analysis fails. This does not close #432.

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

## Stationary tap playback

For non-overlapping stationary paths beginning at offset zero,
`CraftTimedInput` constructs one `RCPSyntheticEventStream` and submits it to an
owned `RCPInlinePlayer` in the test runner. Both are native APIs from the same
Recap framework used by the simulator's XCTest touch translator. Explicit
`advanceTime:` calls represent the hold and idle intervals; these construct
event timestamps rather than sleeping between individual tap submissions.
The observed XCTest translator omits idle intervals, while using stationary
moves to represent holds rounds each 25 ms hold to roughly 33 ms.

The native player prepares its delivery service without emitting touches,
disables its optional initial/completion delays, and tears down its own
resources on completion. Runtime selectors are checked before submission;
unavailable native playback and timeouts fail rather than falling back to
compressed input. These private APIs live only in the generated XCTest target,
never in a shipped application. Moving, overlapping, or initially delayed paths
retain the existing XCTest path implementation; their timing is not qualified
by this stationary-tap fixture.

Local iOS 26.5 execution with the owned player and no initial delay delivered
24 began phases, 24 ended phases, zero cancellations and all 24 callbacks, over
the requested 1.865 s. The original compressed CI receipt remains a required
negative regression. Hosted acceptance on the changed source is still required.
