# Secure Storage API

Store sensitive data in the device's secure enclave (iOS Keychain / Android Keystore).

## Import

```typescript
import { secureStorage } from 'craft-native'
```

Native STX screens can call `craft.secureStorage.set/get/delete/clear` directly
over the typed JavaScriptCore or JavaScriptSandbox bridge. Set
`enableSecureStorage: true` in the generated app. Native STX values are strings
and are persisted in the iOS Keychain or Android encrypted preferences; a
missing key resolves to `null`.

## Methods

### secureStorage.set(key, value, options?)

Store a value securely.

```typescript
// Store a string
await secureStorage.set('auth_token', 'eyJhbGciOiJIUzI1NiIs...')

// Store with accessibility options (iOS)
await secureStorage.set('api_key', 'secret123', {
  accessibility: 'afterFirstUnlock'
})

// Store with biometric protection
await secureStorage.set('encryption_key', 'key123', {
  requireBiometrics: true
})
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| key | `string` | Unique identifier for the value |
| value | `string` | Value to store |
| options.accessibility | `AccessibilityLevel` | When the data is accessible (iOS) |
| options.requireBiometrics | `boolean` | Require biometric auth to access |

**Returns:** `Promise<void>`

---

### secureStorage.get(key, options?)

Retrieve a securely stored value.

```typescript
const token = await secureStorage.get('auth_token')

if (token) {
  console.log('Retrieved token:', token)
} else {
  console.log('No token found')
}

// With biometric authentication
const key = await secureStorage.get('encryption_key', {
  authenticationPrompt: 'Authenticate to access your data'
})
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| key | `string` | Key to retrieve |
| options.authenticationPrompt | `string` | Biometric prompt message |

**Returns:** `Promise<string | null>`

---

### secureStorage.remove(key)

Remove a value from secure storage.

```typescript
await secureStorage.remove('auth_token')
```

`secureStorage.delete(key)` is the equivalent modern spelling. Both methods
are supported so screens can share code with older native bridge versions.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| key | `string` | Key to remove |

**Returns:** `Promise<void>`

---

### secureStorage.has(key)

Check if a key exists in secure storage.

```typescript
const hasToken = await secureStorage.has('auth_token')

if (hasToken) {
  attemptAutoLogin()
}
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| key | `string` | Key to check |

**Returns:** `Promise<boolean>`

---

### secureStorage.clear()

Remove all values from secure storage for this app.

```typescript
// Clear all secure data (e.g., on logout)
await secureStorage.clear()
```

**Returns:** `Promise<void>`

## Example Usage

```typescript
import { secureStorage, biometrics } from 'craft-native'

// Authentication token management
class AuthStorage {
  private static TOKEN_KEY = 'auth_token'
  private static REFRESH_KEY = 'refresh_token'

  static async saveTokens(accessToken: string, refreshToken: string) {
    await Promise.all([
      secureStorage.set(this.TOKEN_KEY, accessToken, {
        accessibility: 'afterFirstUnlock'
      }),
      secureStorage.set(this.REFRESH_KEY, refreshToken, {
        accessibility: 'afterFirstUnlock'
      })
    ])
  }

  static async getAccessToken(): Promise<string | null> {
    return secureStorage.get(this.TOKEN_KEY)
  }

  static async getRefreshToken(): Promise<string | null> {
    return secureStorage.get(this.REFRESH_KEY)
  }

  static async clearTokens() {
    await Promise.all([
      secureStorage.remove(this.TOKEN_KEY),
      secureStorage.remove(this.REFRESH_KEY)
    ])
  }

  static async hasTokens(): Promise<boolean> {
    return secureStorage.has(this.TOKEN_KEY)
  }
}

// Biometric-protected encryption key
class SecureVault {
  private static KEY = 'vault_encryption_key'

  static async setup(encryptionKey: string) {
    // Store with biometric protection
    await secureStorage.set(this.KEY, encryptionKey, {
      requireBiometrics: true,
      accessibility: 'whenUnlockedThisDeviceOnly'
    })
  }

  static async getKey(): Promise<string | null> {
    return secureStorage.get(this.KEY, {
      authenticationPrompt: 'Authenticate to unlock your vault'
    })
  }

  static async isSetup(): Promise<boolean> {
    return secureStorage.has(this.KEY)
  }
}

// Secure API key storage
async function setupAPIKeys() {
  // Check if we need to fetch and store keys
  const hasKeys = await secureStorage.has('api_keys_configured')

  if (!hasKeys) {
    const keys = await fetchAPIKeysFromServer()

    await secureStorage.set('stripe_key', keys.stripe, {
      accessibility: 'afterFirstUnlock'
    })

    await secureStorage.set('maps_key', keys.maps, {
      accessibility: 'afterFirstUnlock'
    })

    await secureStorage.set('api_keys_configured', 'true')
  }
}

// Logout and cleanup
async function logout() {
  // Clear all secure data
  await secureStorage.clear()

  // Or selectively clear
  await Promise.all([
    secureStorage.remove('auth_token'),
    secureStorage.remove('refresh_token'),
    secureStorage.remove('user_data')
  ])

  navigateToLogin()
}

// Migration from AsyncStorage
async function migrateToSecureStorage() {
  // Only for demonstration - in practice, avoid storing
  // sensitive data in non-secure storage
  const legacyToken = localStorage.getItem('token')

  if (legacyToken) {
    await secureStorage.set('auth_token', legacyToken)
    localStorage.removeItem('token')
    console.log('Migrated token to secure storage')
  }
}
```

## Types

```typescript
type AccessibilityLevel =
  | 'whenUnlocked'           // Only when device is unlocked
  | 'afterFirstUnlock'       // After first unlock (persistent)
  | 'whenPasscodeSetThisDeviceOnly'  // Requires passcode, no backup
  | 'whenUnlockedThisDeviceOnly'     // Unlocked, no backup
  | 'afterFirstUnlockThisDeviceOnly' // After unlock, no backup

interface SetOptions {
  accessibility?: AccessibilityLevel
  requireBiometrics?: boolean
}

interface GetOptions {
  authenticationPrompt?: string
}
```

## Platform Details

### iOS (Keychain)

- Data stored in iOS Keychain
- Supports accessibility levels for data protection
- Can require biometric authentication
- Persists across app reinstalls (unless `ThisDeviceOnly`)
- Syncs to iCloud Keychain (unless `ThisDeviceOnly`)

### Android (Keystore)

- Data encrypted with Android Keystore
- Hardware-backed encryption on supported devices
- Can require biometric authentication (API 28+)
- Cleared on app uninstall
- Not synced across devices

## Security Best Practices

1. **Use appropriate accessibility**
   - `whenUnlockedThisDeviceOnly` for highest security
   - `afterFirstUnlock` for background access needs

2. **Require biometrics for sensitive data**
   - Encryption keys, payment info, health data

3. **Clear on logout**
   - Always clear tokens and sensitive data

4. **Don't store passwords**
   - Store tokens, not raw passwords
   - Use proper authentication flows

5. **Handle errors gracefully**
   - Keychain/Keystore can fail in edge cases
   - Have fallback authentication methods
