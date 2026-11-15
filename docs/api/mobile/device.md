# Device API

Access device information and capabilities.

## Import

```typescript
import { device } from 'craft-native'
```

## Methods

### device.getInfo()

Get detailed device information.

```typescript
const info = await device.getInfo()

console.log(info.platform)      // 'ios' | 'android'
console.log(info.model)         // 'iPhone 15 Pro'
console.log(info.osVersion)     // '17.0'
console.log(info.appVersion)    // '1.0.0'
console.log(info.buildNumber)   // '1'
console.log(info.deviceId)      // Unique device identifier
console.log(info.isEmulator)    // true if running in simulator/emulator
console.log(info.languages)     // ['de-DE', 'en-GB']: the phone's languages, most preferred first
console.log(info.locale)        // 'en_DE': the locale the app runs in
console.log(info.timezone)      // 'Europe/Berlin'
```

`languages` is what an app chooses its language from before anyone has signed
in: the phone's preferred languages as BCP 47 tags, in the owner's order. Take
the first one the app supports. `locale` cannot say: on iOS its language is
the one of the app's own localizations the system matched, so an app that
declares only English reads `en_…` on a German phone, with the phone's region.

**Returns:** `Promise<DeviceInfo>`

---

### device.getCapabilities()

Check device capabilities and feature support.

```typescript
const caps = await device.getCapabilities()

console.log(caps.hasBiometrics)     // Face ID / Touch ID / fingerprint
console.log(caps.hasCamera)         // Camera available
console.log(caps.hasNFC)            // NFC support
console.log(caps.hasBluetooth)      // Bluetooth available
console.log(caps.hasGPS)            // GPS available
console.log(caps.hasHaptics)        // Haptic feedback support
console.log(caps.hasNotch)          // Device has notch/island
console.log(caps.biometricType)     // 'faceId' | 'touchId' | 'fingerprint' | null
```

**Returns:** `Promise<DeviceCapabilities>`

---

### device.getBatteryInfo()

Get battery status information.

```typescript
const battery = await device.getBatteryInfo()

console.log(battery.level)         // 0-100
console.log(battery.isCharging)    // true/false
console.log(battery.isLowPower)    // Low power mode enabled
```

**Returns:** `Promise<BatteryInfo>`

---

### device.getNetworkInfo()

Get network connectivity information.

```typescript
const network = await device.getNetworkInfo()

console.log(network.isConnected)    // Has any connection
console.log(network.type)           // 'wifi' | 'cellular' | 'none'
console.log(network.isWifi)         // Connected via WiFi
console.log(network.isCellular)     // Connected via cellular
console.log(network.cellularType)   // '5g' | '4g' | '3g' | null
```

**Returns:** `Promise<NetworkInfo>`

---

### device.getScreenInfo()

Get screen dimensions and characteristics.

```typescript
const screen = await device.getScreenInfo()

console.log(screen.width)           // Width in points
console.log(screen.height)          // Height in points
console.log(screen.scale)           // Device pixel ratio (2x, 3x)
console.log(screen.fontScale)       // User's font size preference
console.log(screen.safeAreaInsets)  // { top, bottom, left, right }
```

**Returns:** `Promise<ScreenInfo>`

---

### device.getLocale()

Get device locale information.

```typescript
const locale = await device.getLocale()

console.log(locale.languageCode)    // 'en'
console.log(locale.countryCode)     // 'US'
console.log(locale.languageTag)     // 'en-US'
console.log(locale.isRTL)           // Right-to-left language
console.log(locale.calendar)        // 'gregorian'
console.log(locale.timezone)        // 'America/New_York'
```

**Returns:** `Promise<LocaleInfo>`

## Example Usage

```typescript
import { device, Platform } from 'craft-native'

// Adaptive UI based on device
async function setupUI() {
  const info = await device.getInfo()
  const caps = await device.getCapabilities()
  const screen = await device.getScreenInfo()

  // Adjust for notch/island
  if (caps.hasNotch) {
    document.documentElement.style.setProperty(
      '--safe-area-top',
      `${screen.safeAreaInsets.top}px`
    )
  }

  // Show biometric login option
  if (caps.hasBiometrics) {
    showBiometricLoginButton(caps.biometricType)
  }

  // Adjust layout for screen size
  if (screen.width < 375) {
    applyCompactLayout()
  }

  // Respect user's font size preference
  if (screen.fontScale > 1) {
    enableLargeTextMode()
  }
}

// Network-aware data loading
async function loadData() {
  const network = await device.getNetworkInfo()

  if (!network.isConnected) {
    return loadFromCache()
  }

  if (network.isWifi) {
    return loadHighQualityData()
  }

  // On cellular, load lighter version
  return loadLowQualityData()
}

// Battery-conscious features
async function shouldAutoPlay(): Promise<boolean> {
  const battery = await device.getBatteryInfo()

  // Don't autoplay if battery is low
  if (battery.level < 20 || battery.isLowPower) {
    return false
  }

  return true
}
```

## Types

```typescript
interface DeviceInfo {
  platform: 'ios' | 'android'
  model: string
  osVersion: string
  appVersion: string
  buildNumber: string
  deviceId: string
  isEmulator: boolean
  /** The phone's preferred languages, most preferred first, as BCP 47 tags. */
  languages?: readonly string[]
  /** The locale the app runs in: its region and formats. */
  locale?: string
  /** The phone's time zone, as an IANA name. */
  timezone?: string
}

interface DeviceCapabilities {
  hasBiometrics: boolean
  biometricType: 'faceId' | 'touchId' | 'fingerprint' | null
  hasCamera: boolean
  hasNFC: boolean
  hasBluetooth: boolean
  hasGPS: boolean
  hasHaptics: boolean
  hasNotch: boolean
}

interface BatteryInfo {
  level: number
  isCharging: boolean
  isLowPower: boolean
}

interface NetworkInfo {
  isConnected: boolean
  type: 'wifi' | 'cellular' | 'none'
  isWifi: boolean
  isCellular: boolean
  cellularType: '5g' | '4g' | '3g' | null
}

interface ScreenInfo {
  width: number
  height: number
  scale: number
  fontScale: number
  safeAreaInsets: {
    top: number
    bottom: number
    left: number
    right: number
  }
}

interface LocaleInfo {
  languageCode: string
  countryCode: string
  languageTag: string
  isRTL: boolean
  calendar: string
  timezone: string
}
```
