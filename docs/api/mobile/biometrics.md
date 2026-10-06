# Biometrics API

Authenticate users with Face ID, Touch ID, or fingerprint through Craft's
typed mobile bridge.

## Import

```typescript
import { biometrics } from 'craft-native'
```

Native STX screens can call the same capability through `craft.biometrics`.
Enable it in the generated app with `enableBiometric: true`. Availability can
still be false when the device has no enrolled biometric hardware, including
the default simulator/emulator state.

## Methods

### `biometrics.isAvailable()`

Returns whether biometric authentication is currently available.

```typescript
if (await biometrics.isAvailable()) {
  await biometrics.authenticate('Unlock your account')
}
```

Returns `Promise<boolean>`. The web fallback returns `false`.

### `biometrics.getBiometricType()`

Returns the native biometric type, or `null` when the bridge is unavailable.
Native bridges return `'none'` when the capability is enabled but no enrolled
biometric is available.

```typescript
const type = await biometrics.getBiometricType()

switch (type) {
  case 'faceId':
    showMessage('Use Face ID')
    break
  case 'touchId':
    showMessage('Use Touch ID')
    break
  case 'fingerprint':
    showMessage('Use your fingerprint')
    break
  case 'none':
  case null:
    showPasswordLogin()
    break
}
```

Returns `Promise<'faceId' | 'touchId' | 'fingerprint' | 'none' | null>`.

### `biometrics.authenticate(reason)`

Shows the platform authentication prompt with the supplied reason.

```typescript
try {
  const authenticated = await biometrics.authenticate('Confirm this purchase')
  if (authenticated) processPurchase()
}
catch (error) {
  // The native bridge rejects on cancellation or authentication failure.
  handleAuthenticationFailure(error)
}
```

Returns `Promise<boolean>`. The promise resolves `true` after successful
authentication and rejects with the native failure/cancellation error. There
is no web fallback because silently replacing biometric authentication with a
less secure mechanism would be unsafe.

## Capability and lifecycle behavior

- The generated bridge rejects calls with `CAPABILITY_DISABLED` when
  `enableBiometric` is false.
- Every request has a cancellation token; cancelling a pending request settles
  it once and dismisses the platform prompt.
- iOS uses LocalAuthentication; Android uses BiometricPrompt.
- The legacy web renderer remains unchanged and receives no biometric API
  unless a native bridge is present.

## Example

```typescript
import { biometrics, secureStorage } from 'craft-native'

export async function unlock() {
  if (!await biometrics.isAvailable()) return false
  if (!await biometrics.authenticate('Sign in to Wildloop')) return false

  const token = await secureStorage.get('auth_token')
  return token !== null
}
```
