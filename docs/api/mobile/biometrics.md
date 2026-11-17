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

## Credentials only a face or finger can release

`authenticate()` answers whether the person passed. It does not protect
anything by itself: a token read afterwards with `secureStorage.get()` is
readable by any code in the app, with or without that answer. For "Sign in
with Face ID", keep the token where only the face or finger can release it.

### `biometrics.storeCredential(key, value)`

```typescript
await biometrics.storeCredential('session', refreshToken)
```

Writes a Keychain item behind the faces or fingers enrolled right now, on
this device only and only while it has a passcode. Writing does not prompt.
Rejects with `BIOMETRICS_UNAVAILABLE` when nothing is enrolled or there is no
passcode, so the app never keeps a token no one could open.

### `biometrics.getCredential(key, reason?)`

```typescript
const token = await biometrics.getCredential('session', 'Sign in to HQ')
```

The system shows Face ID or Touch ID with `reason`, and the Keychain releases
the value only if the person passes. Resolves to `null` when there is none,
including a credential invalidated because another face or finger was
enrolled. That is deliberate, and the app should ask for the password again.
Rejects with `AUTHENTICATION_CANCELLED` or `AUTHENTICATION_FAILED`. The read
waits on the person, so it is never timed out by the bridge.

### `biometrics.hasCredential(key)`

Whether a credential is kept under `key`, answered without any prompt. A
sign-in screen uses it to decide whether to offer "Sign in with Face ID".

### `biometrics.deleteCredential(key)`

Forgets the credential without a prompt, for example when signing out.

These credentials are kept apart from `secureStorage`: never cached in memory,
never shared with a web page, and not removed by `secureStorage.clear()`.
iOS only for now. On Android, `storeCredential` and `getCredential` reject
with `UNSUPPORTED` and `hasCredential` resolves `false`.

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
import { biometrics } from 'craft-native'

const KEY = 'session'

// After a password sign-in, offer Face ID for next time.
export async function rememberWithFaceId(refreshToken: string) {
  if (!await biometrics.isAvailable()) return
  await biometrics.storeCredential(KEY, refreshToken)
}

// On the sign-in screen.
export async function signInWithFaceId(): Promise<string | null> {
  if (!await biometrics.hasCredential(KEY)) return null
  try {
    // null: the enrolled faces changed. Ask for the password again.
    return await biometrics.getCredential(KEY, 'Sign in to HQ')
  }
  catch (error: any) {
    if (error.code === 'AUTHENTICATION_CANCELLED') return null
    throw error
  }
}

export async function signOut() {
  await biometrics.deleteCredential(KEY)
}
```
