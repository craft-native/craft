# Permissions API

Check and request native permissions without coupling permission state to the
device operation that uses it.

## Import

```typescript
import { permissions } from 'craft-native/mobile'
```

## Status Values

Every check or request resolves to one of these values:

| Status | Meaning |
| --- | --- |
| `granted` | The app has usable access. |
| `denied` | The platform currently denies access. |
| `undetermined` | The user has not decided, the permission is unknown, or the web fallback cannot query it. |
| `restricted` | The platform prevents access through a policy the user cannot change directly. |

## Check a Permission

```typescript
const status = await permissions.check('location')

if (status === 'granted') {
  // Permission state is ready; requesting a coordinate is a separate call.
}
```

`check` never asks the user for access.

## Request a Permission

```typescript
const status = await permissions.request('camera')

if (status !== 'granted') {
  showPermissionRecovery()
}
```

If access is already granted, the native bridge resolves immediately without
showing another system prompt.

## Check or Request Several Permissions

```typescript
const current = await permissions.checkMultiple(['camera', 'microphone'])
const requested = await permissions.requestMultiple(['camera', 'microphone'])
```

The result is keyed by permission name. Requests are performed in input order
so the platform does not display several unrelated prompts at once.

## Open App Settings

```typescript
await permissions.openSettings()
```

Use this as recovery after a denied permission when the platform no longer
shows an in-app prompt.

## Permission Types

```typescript
type PermissionType =
  | 'camera'
  | 'microphone'
  | 'photos'
  | 'location'
  | 'locationAlways'
  | 'notifications'
  | 'contacts'
  | 'calendar'
  | 'reminders'
  | 'bluetooth'
  | 'motion'
  | 'health'
```

Support varies by platform and generated app capabilities. An unknown or
unsupported permission resolves `undetermined` rather than fabricating access.

## Android Location Semantics

Android can grant either precise (`ACCESS_FINE_LOCATION`) or approximate
(`ACCESS_COARSE_LOCATION`) foreground access. Craft reports `location` as
`granted` when either permission is granted. A mixed Android request result—fine
denied and coarse granted—is therefore also `granted`. Foreground fixes,
watches, and location recording accept either grant; Android limits the
resulting accuracy when the user selects approximate access.

`locationAlways` additionally requires background location on Android versions
that expose it. Permission status does not imply that GPS, Google Play Services,
or a fresh coordinate is currently available.

The Android manifest must declare the requested capability. The Craft Android
generator adds location declarations when `enableGeolocation` or
`enableBackgroundLocation` is enabled.
