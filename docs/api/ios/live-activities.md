# Live Activities API

Craft exposes Live Activities through the browser-safe `craft-native/mobile`
entrypoint. Enable `enableLiveActivities` in the iOS app configuration before
using this API.

## Start and retain a handle

`start` returns a handle bound to the ActivityKit activity that was created.
Its `update` and `end` methods cannot affect another activity.

```ts
import { liveActivities } from 'craft-native/mobile'

const recordingActivity = await liveActivities.start({
  activityId: recording.id,
  title: 'WildLoop',
  status: 'Recording',
  distanceMeters: 0,
  durationSeconds: 0,
})

await recordingActivity.update({
  distanceMeters: 1609,
  durationSeconds: 480,
})

await recordingActivity.end({ status: 'Saved' })
```

Persist `recordingActivity.id` when the app must restore the association after
a background transition. The same activity can then be addressed explicitly:

```ts
await liveActivities.update(savedActivityId, { distanceMeters: 2400 })
await liveActivities.end(savedActivityId, { status: 'Saved' })
```

Several handles may be active at once. Each handle and explicit ID call targets
only its matching ActivityKit activity.

## Migrating singleton calls

The former singleton forms remain available for one release, but are
deprecated:

```ts
await liveActivities.update({ progress: 0.5 })
await liveActivities.end()
```

Keep the handle returned from `start`, or persist its `id`, and migrate to one
of the scoped forms above. Singleton calls select the first active activity and
cannot safely be used when more than one activity exists.
