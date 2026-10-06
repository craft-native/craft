# Biometrics API

Authenticate users using Face ID, Touch ID, or fingerprint.

## Import

```typescript
import { biometrics } from 'craft-native'
```

Native STX screens use the same capability through the global bridge:
`await craft.biometrics.isAvailable()`, `getBiometricType()`, and
`authenticate(reason)`. Enable it in the generated app with
`enableBiometric: true`; availability can still be false on a simulator or
emulator without enrolled hardware.

## Methods

### biometrics.isAvailable()

Check if biometric authentication is available.

```typescript
const available = await biometrics.isAvailable()

if (available) {
  console.log('Biometrics supported')
}
```

**Returns:** `Promise<boolean>`

---

### biometrics.getBiometricType()

Get the type of biometrics available on the device.

```typescript
const type = await biometrics.getBiometricType()

switch (type) {
  case 'faceId':
    console.log('Face ID available')
    break
  case 'touchId':
    console.log('Touch ID available')
    break
  case 'fingerprint':
    console.log('Fingerprint available')
    break
  case null:
    console.log('No biometrics available')
    break
}
```

**Returns:** `Promise<'faceId' | 'touchId' | 'fingerprint' | null>`

---

### biometrics.authenticate(options?)

Prompt the user to authenticate with biometrics.

```typescript
try {
  const result = await biometrics.authenticate({
    reason: 'Authenticate to access your account',
    fallbackLabel: 'Use Passcode',
    cancelLabel: 'Cancel'
  })

  if (result.success) {
    console.log('Authentication successful')
    grantAccess()
  }
} catch (error) {
  if (error.code === 'user_cancel') {
    console.log('User cancelled')
  } else if (error.code === 'lockout') {
    console.log('Too many failed attempts')
  } else {
    console.error('Authentication failed:', error.message)
  }
}
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| options.reason | `string` | Reason shown to user (required on iOS) |
| options.fallbackLabel | `string` | Label for fallback button (iOS) |
| options.cancelLabel | `string` | Label for cancel button |
| options.allowDeviceCredential | `boolean` | Allow passcode/PIN as fallback |

**Returns:** `Promise<AuthResult>`

---

### biometrics.canAuthenticate()

Check if authentication is currently possible (enrolled biometrics exist).

```typescript
const canAuth = await biometrics.canAuthenticate()

if (canAuth.available) {
  showBiometricOption()
} else {
  console.log('Cannot authenticate:', canAuth.reason)
  // Reasons: 'not_enrolled', 'not_available', 'lockout', 'passcode_not_set'
}
```

**Returns:** `Promise<CanAuthenticateResult>`

## Example Usage

```typescript
import { biometrics, secureStorage } from 'craft-native'

// Login flow with biometrics
async function handleLogin() {
  const available = await biometrics.isAvailable()

  if (available) {
    try {
      const result = await biometrics.authenticate({
        reason: 'Sign in to MyApp',
        allowDeviceCredential: true
      })

      if (result.success) {
        // Retrieve stored credentials
        const token = await secureStorage.get('auth_token')
        await loginWithToken(token)
      }
    } catch (error) {
      handleBiometricError(error)
    }
  } else {
    // Fall back to password login
    showPasswordLogin()
  }
}

// Protect sensitive action
async function confirmPurchase(amount: number) {
  const result = await biometrics.authenticate({
    reason: `Confirm purchase of $${amount.toFixed(2)}`,
    cancelLabel: 'Cancel Purchase'
  })

  if (result.success) {
    await processPurchase(amount)
    showSuccessMessage()
  }
}

// Setup biometric login
async function enableBiometricLogin() {
  const canAuth = await biometrics.canAuthenticate()

  if (!canAuth.available) {
    if (canAuth.reason === 'not_enrolled') {
      showMessage('Please set up Face ID/Touch ID in device settings')
    } else {
      showMessage('Biometric login is not available on this device')
    }
    return false
  }

  // Test authentication before enabling
  const result = await biometrics.authenticate({
    reason: 'Enable biometric login'
  })

  if (result.success) {
    await secureStorage.set('biometric_enabled', 'true')
    showMessage('Biometric login enabled!')
    return true
  }

  return false
}

// Show appropriate icon/label
async function getBiometricLabel(): Promise<string> {
  const type = await biometrics.getBiometricType()

  switch (type) {
    case 'faceId':
      return 'Sign in with Face ID'
    case 'touchId':
      return 'Sign in with Touch ID'
    case 'fingerprint':
      return 'Sign in with Fingerprint'
    default:
      return 'Sign in'
  }
}

// Handle errors appropriately
function handleBiometricError(error: BiometricError) {
  switch (error.code) {
    case 'user_cancel':
      // User tapped cancel - do nothing
      break
    case 'lockout':
      showMessage('Too many failed attempts. Please try again later.')
      break
    case 'biometry_not_available':
      showMessage('Biometrics not available')
      disableBiometricLogin()
      break
    case 'biometry_not_enrolled':
      showMessage('Please set up biometrics in device settings')
      break
    default:
      showMessage('Authentication failed. Please try again.')
  }
}
```

## Types

```typescript
interface AuthOptions {
  reason?: string
  fallbackLabel?: string
  cancelLabel?: string
  allowDeviceCredential?: boolean
}

interface AuthResult {
  success: boolean
}

interface CanAuthenticateResult {
  available: boolean
  reason?: 'not_enrolled' | 'not_available' | 'lockout' | 'passcode_not_set'
}

interface BiometricError extends Error {
  code:
    | 'user_cancel'
    | 'user_fallback'
    | 'lockout'
    | 'biometry_not_available'
    | 'biometry_not_enrolled'
    | 'passcode_not_set'
    | 'authentication_failed'
    | 'unknown'
}
```

## Platform Differences

| Feature | iOS | Android |
|---------|-----|---------|
| Face ID | Yes | Via BiometricPrompt |
| Touch ID | Yes | N/A |
| Fingerprint | N/A | Yes |
| Device credential fallback | Yes | Yes (Android 10+) |
| Custom UI | No (system UI only) | No (system UI only) |
| Lockout duration | ~30 seconds | Varies by device |

## Security Considerations

1. **Always verify server-side** - Biometric success doesn't guarantee identity
2. **Store tokens securely** - Use `secureStorage` for credentials
3. **Handle lockouts gracefully** - Provide alternative authentication methods
4. **Clear credentials on logout** - Remove tokens from secure storage
5. **Re-authenticate for sensitive actions** - Don't rely solely on session state
