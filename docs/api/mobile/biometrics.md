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
readable by any code in the app, with or without that answer. To make a
secret depend on the face or finger, keep it where only they can release it.

### When it fits, and when a passkey does

A Face ID credential guards something the app already holds, on this device.
It fits when the app keeps a long-lived secret between launches and wants the
person present before using it:

- locking the app until Face ID when it opens, with the session token kept
  behind Face ID instead of in `secureStorage`;
- asking again before a sensitive action, such as showing an account number;
- unlocking data the app encrypted locally.

It cannot sign anyone in on its own. The value is only as good as the server's
willingness to accept it, so a token the server revokes at sign-out is gone
exactly when the credential would be needed, and keeping it past sign-out
would hand back a token that no longer works. For "Sign in with Face ID"
against your server, use [passkeys](../../guides/native-stx.md)
(`enablePasskeys`, `craft.passkeys.get()`): the system sheet also asks for
Face ID, the server verifies the result, and iCloud carries the passkey to
the person's other devices.

### `biometrics.storeCredential(key, value)`

```typescript
await biometrics.storeCredential('session', sessionToken)
```

Writes a Keychain item behind the faces or fingers enrolled right now, on
this device only and only while it has a passcode. On Android the value is
sealed with an AES-256-GCM key, and that key is wrapped with an RSA key pair
of its own in the AndroidKeyStore. The private half decrypts only after
`BiometricPrompt` passes a strong biometric, and enrolling another one
invalidates it. Writing does not prompt on either. Rejects with
`BIOMETRICS_UNAVAILABLE` when nothing is enrolled or there is no passcode or
screen lock, so the app never keeps a token no one could open.

### `biometrics.getCredential(key, reason?)`

```typescript
const token = await biometrics.getCredential('session', 'Unlock your account')
```

The system shows Face ID or Touch ID (on Android, the biometric prompt) with
`reason`, and the value is released only if the person passes. Resolves to `null` when there is none,
including a credential invalidated because another face or finger was
enrolled. That is deliberate, and the app should ask for the password again.
Rejects with `AUTHENTICATION_CANCELLED` or `AUTHENTICATION_FAILED`. The read
waits on the person, so it is never timed out by the bridge.

### `biometrics.hasCredential(key)`

Whether a credential is kept under `key`, answered without any prompt. An
app uses it on launch to decide whether to show its lock screen.

### `biometrics.deleteCredential(key)`

Forgets the credential without a prompt, for example when signing out.

These credentials are kept apart from `secureStorage`: never cached in memory,
never shared with a web page, and not removed by `secureStorage.clear()`.
Both hosts carry them, for native screens and hybrid pages alike. A host
without the store (a browser) rejects `storeCredential` and `getCredential`
with `UNSUPPORTED` and resolves `hasCredential` to `false`.

## Capability and lifecycle behavior

- The generated bridge rejects calls with `CAPABILITY_DISABLED` when
  `enableBiometric` is false.
- Every request has a cancellation token; cancelling a pending request settles
  it once and dismisses the platform prompt.
- iOS uses LocalAuthentication; Android uses BiometricPrompt.
- The legacy web renderer remains unchanged and receives no biometric API
  unless a native bridge is present.

## Example

The app locks until Face ID when it opens. The session token the server
issued at sign-in lives behind Face ID instead of in `secureStorage`, and
signing out removes it.

```typescript
import { biometrics } from 'craft-native'

const KEY = 'session'

// After sign-in, keep the session behind Face ID when the device can.
export async function keepSession(sessionToken: string): Promise<boolean> {
  if (!await biometrics.isAvailable()) return false
  await biometrics.storeCredential(KEY, sessionToken)
  return true
}

// On launch. Resolves null when there is nothing to unlock, including
// after the enrolled faces changed: show the sign-in screen. Rejects with
// AUTHENTICATION_CANCELLED when Face ID was dismissed: stay on the lock
// screen and offer it again.
export async function unlockSession(): Promise<string | null> {
  if (!await biometrics.hasCredential(KEY)) return null
  return biometrics.getCredential(KEY, 'Unlock your account')
}

// After the server has revoked the token.
export async function signOut() {
  await biometrics.deleteCredential(KEY)
}
```
