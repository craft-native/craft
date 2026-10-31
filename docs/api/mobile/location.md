# Location recording API

Record a route natively, screen locked or app in the background, and read it
back when the effort is over. This page covers the power modes; ownership,
recovery and acknowledgement are described in the
[TypeScript package README](../../../packages/typescript/README.md#recording-ownership-and-recovery).

## Import

```typescript
import { location } from 'craft-native/mobile'
```

## Power modes

`startRecording({ powerMode })` chooses how hard the recording works the GPS.

| Mode | Behaviour |
| --- | --- |
| `'default'` | A fix about every second, at the best accuracy. |
| `'saver'` | For a long effort (an ultra). Fixes come at least 5 m apart instead of every second. While the pace holds steady iOS asks for ten-metre accuracy rather than the best, and goes back to the best as soon as the pace or the signal changes. Android asks for the same spacing and batches delivery up to 20 s. Fixes stay under 30 s apart at any speed that counts as moving, so distance and moving time come out as at the default rate. |
| `'auto'` | `'saver'` while the device is saving power, `'default'` otherwise. The device is saving power when iOS Low Power Mode or Android Battery Saver is on, or the battery is under 20% and not charging. |

`'auto'` is re-evaluated whenever the platform reports a change
(`NSProcessInfoPowerStateDidChange` and the battery notifications on iOS,
`ACTION_POWER_SAVE_MODE_CHANGED` and `ACTION_BATTERY_CHANGED` on Android), and
only while a recording is running in that mode. The location manager or request
is only touched when the answer changed.

The state returned by every recording call reports both:

```typescript
const state = await location.startRecording({ powerMode: 'auto' })

state.powerMode           // 'auto': what was asked for. 'default' on a host that predates power modes.
state.effectivePowerMode  // 'saver' | 'default': what the recorder is using now.
```

`powerMode` stays what the caller asked for, so existing code that starts with
`'default'` or `'saver'` reads the same value back. `effectivePowerMode` is
`'default'` once the recording has stopped.

## Changing the mode while recording

```typescript
const { id } = await location.startRecording()

// Nothing on screen but a countdown: spend less on the GPS.
await location.setRecordingPowerMode({ expectedId: id!, powerMode: 'saver' })

// Back to normal when the athlete leaves it.
await location.setRecordingPowerMode({ expectedId: id!, powerMode: 'default' })
```

`setRecordingPowerMode({ expectedId, powerMode })` resolves with the recording's
state. `expectedId` is required and fences the call to the recording you started,
exactly as it does for `pauseRecording`, `resumeRecording` and `stopRecording`.

| Rejection | When |
| --- | --- |
| `INVALID_ARGUMENT` | `expectedId` is missing or empty, or `powerMode` is not `'default'`, `'saver'` or `'auto'`. |
| `RECORDING_CONFLICT` | `expectedId` is not the recording that is running. |
| `NO_ACTIVE_RECORDING` | Nothing is recording. |
| `RECORDING_STORAGE_ERROR` | The new mode could not be saved. The previous mode stays in force. |
| `RECORDING_POWER_MODE_UNSUPPORTED` | The host was built before power modes could change. |

The mode is saved with the recording. A recording that survives the app being
killed comes back in the mode it was last given, and a pause followed by a
resume starts the steady-pace history over rather than trusting speeds seen
before the pause.

## Feature detection

```typescript
if (location.supportsRecordingPowerMode()) {
  await location.startRecording({ powerMode: 'auto' })
}
```

`supportsRecordingPowerMode()` is true when the host advertises the
`locationRecordingPowerMode` capability and provides `setRecordingPowerMode`.
`startRecording({ powerMode: 'auto' })` and `setRecordingPowerMode` reject with
`RECORDING_POWER_MODE_UNSUPPORTED` on a host without it; `'default'` and
`'saver'` keep working on every host that had them.

A build that links the optional Zig runtime on iOS hands the recorder to that
runtime, which has no power modes: it does not advertise the capability.

## In the browser

Without a native host the recording runs on the browser's geolocation. Power
modes are recorded and reported, but the browser has no power-saving signal, so
`'auto'` is kept as asked and runs as `'default'`, and `'saver'` only changes the
reported `effectivePowerMode`.
