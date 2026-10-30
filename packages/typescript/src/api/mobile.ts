/**
 * @fileoverview Craft Mobile API
 * @description Unified cross-platform mobile API for iOS and Android.
 * Provides consistent access to device features, sensors, and native capabilities.
 * @module @craft-native/api/mobile
 *
 * @example
 * ```typescript
 * import { device, haptics, permissions, camera, biometrics, location, share } from '@craft-native/api/mobile'
 *
 * // Get device info
 * const info = await device.getInfo()
 * console.log(`Running on ${info.platform} ${info.osVersion}`)
 *
 * // Request permissions
 * const granted = await permissions.request('camera')
 *
 * // Trigger haptic feedback
 * await haptics.impact('medium')
 *
 * // Take a photo
 * const photo = await camera.takePicture()
 * ```
 */

import { secureUUID } from '../bridge/ids.js'
import { createLiveActivityHandle } from './live-activity-handle.js'

/** localStorage key for the persisted web-fallback device id. */
const WEB_DEVICE_ID_KEY = '__craft_web_device_id__'

/**
 * Internal: return a stable device id for the web fallback. Persists in
 * localStorage so two `device.getInfo()` calls in the same session (and
 * across reloads) report the *same* id. The previous implementation
 * generated a fresh `Math.random` id every call, which made
 * `deviceId`-keyed analytics impossible to tie back to a single browser.
 */
export function _webFallbackDeviceId(): string {
  if (typeof globalThis !== 'undefined' && (globalThis as any).localStorage) {
    try {
      const ls = (globalThis as any).localStorage as Storage
      const existing = ls.getItem(WEB_DEVICE_ID_KEY)
      if (existing && /^web-[0-9a-f-]+$/i.test(existing)) return existing
      const fresh = `web-${secureUUID()}`
      ls.setItem(WEB_DEVICE_ID_KEY, fresh)
      return fresh
    }
    catch {
      // Private-browsing modes throw on localStorage.setItem; fall through.
    }
  }
  // No localStorage → at least use a strong RNG. The id won't persist
  // between calls, but it won't pretend to either.
  return `web-${secureUUID()}`
}

/**
 * Test-only hook to clear the cached device id.
 */
export function _resetWebFallbackDeviceIdForTests(): void {
  if (typeof globalThis !== 'undefined' && (globalThis as any).localStorage) {
    try { ((globalThis as any).localStorage as Storage).removeItem(WEB_DEVICE_ID_KEY) }
    catch { /* ignore */ }
  }
}

// ============================================================================
// Device Info API
// ============================================================================

/**
 * Device information.
 *
 * Optional sub-fields (`screen`, `battery`, `network`) reflect what the
 * native side might omit — e.g. desktop hosts have no battery, headless
 * environments have no screen. Consumers must defensively check before
 * accessing nested properties.
 */
export interface DeviceInfo {
  /** Platform: 'ios' | 'android' | 'macos' | 'windows' | 'linux' */
  platform: 'ios' | 'android' | 'macos' | 'windows' | 'linux'
  /** OS version string (e.g., "17.0", "14") */
  osVersion: string
  /** Device model (e.g., "iPhone 15 Pro", "Pixel 8") */
  model: string
  /** Device manufacturer */
  manufacturer: string
  /** Unique device identifier */
  deviceId: string
  /** Whether device is a tablet */
  isTablet: boolean
  /** Screen dimensions (omitted by headless or desktop hosts) */
  screen?: {
    width: number
    height: number
    scale: number
  }
  /** Battery info (omitted on devices without a battery) */
  battery?: {
    level: number
    isCharging: boolean
  }
  /** Network status (omitted when the host doesn't report it) */
  network?: {
    type: 'wifi' | 'cellular' | 'ethernet' | 'none'
    isConnected: boolean
  }
}

/**
 * Device capabilities.
 */
export interface DeviceCapabilities {
  /** Has camera */
  camera: boolean
  /** Has biometric authentication */
  biometrics: boolean
  /** Has NFC */
  nfc: boolean
  /** Has Bluetooth */
  bluetooth: boolean
  /** Has GPS */
  gps: boolean
  /** Can continue location recording in the background */
  backgroundLocation?: boolean
  /** Has accelerometer */
  accelerometer: boolean
  /** Has gyroscope */
  gyroscope: boolean
  /** Has haptic feedback */
  haptics: boolean
  /** Has AR support */
  ar: boolean
  /** Has Face ID (iOS) or face unlock */
  faceId: boolean
  /** Has Touch ID (iOS) or fingerprint */
  touchId: boolean
}

/**
 * Device information and capabilities API.
 *
 * @example
 * ```typescript
 * // Get device info
 * const info = await device.getInfo()
 * console.log(`Platform: ${info.platform}`)
 * console.log(`Model: ${info.model}`)
 * console.log(`Battery: ${info.battery.level}%`)
 *
 * // Check capabilities
 * const caps = await device.getCapabilities()
 * if (caps.biometrics) {
 *   // Enable biometric login
 * }
 *
 * // Check if running on mobile
 * if (device.isMobile()) {
 *   // Show mobile-specific UI
 * }
 * ```
 */
export const device = {
  /**
   * Get comprehensive device information.
   *
   * @returns Promise resolving to DeviceInfo
   */
  async getInfo(): Promise<DeviceInfo> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.device) {
      return craft.device.getInfo()
    }
    // Return web defaults
    return {
      platform: detectPlatform(),
      osVersion: 'unknown',
      model: 'unknown',
      manufacturer: 'unknown',
      deviceId: _webFallbackDeviceId(),
      isTablet: false,
      screen: {
        width: typeof window !== 'undefined' ? window.innerWidth || 0 : 0,
        height: typeof window !== 'undefined' ? window.innerHeight || 0 : 0,
        scale: typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1
      },
      battery: { level: 100, isCharging: false },
      network: { type: 'wifi', isConnected: typeof navigator !== 'undefined' ? navigator.onLine ?? true : true }
    }
  },

  /**
   * Get device capabilities.
   *
   * @returns Promise resolving to DeviceCapabilities
   */
  async getCapabilities(): Promise<DeviceCapabilities> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.device) {
      return craft.device.getCapabilities()
    }
    return {
      camera: true,
      biometrics: false,
      nfc: false,
      bluetooth: false,
      gps: 'geolocation' in navigator,
      accelerometer: false,
      gyroscope: false,
      haptics: 'vibrate' in navigator,
      ar: false,
      faceId: false,
      touchId: false
    }
  },

  /**
   * Check if running on a mobile device.
   */
  isMobile(): boolean {
    const platform = detectPlatform()
    return platform === 'ios' || platform === 'android'
  },

  /**
   * Check if running on iOS.
   */
  isIOS(): boolean {
    return detectPlatform() === 'ios'
  },

  /**
   * Check if running on Android.
   */
  isAndroid(): boolean {
    return detectPlatform() === 'android'
  },

  /**
   * Get current locale.
   */
  getLocale(): string {
    return navigator?.language || 'en-US'
  },

  /**
   * Get timezone.
   */
  getTimezone(): string {
    return Intl.DateTimeFormat().resolvedOptions().timeZone
  }
}

// ============================================================================
// Haptics API
// ============================================================================

/**
 * Haptic feedback style.
 */
export type HapticStyle = 'light' | 'medium' | 'heavy' | 'soft' | 'rigid'

/**
 * Haptic notification type.
 */
export type HapticNotificationType = 'success' | 'warning' | 'error'

/**
 * Haptic feedback API.
 * Provides tactile feedback on supported devices.
 *
 * @example
 * ```typescript
 * // Impact feedback
 * await haptics.impact('medium')
 *
 * // Notification feedback
 * await haptics.notification('success')
 *
 * // Selection feedback (for UI selection changes)
 * await haptics.selection()
 *
 * // Custom vibration pattern (Android)
 * await haptics.vibrate([100, 50, 100])
 * ```
 */
export const haptics = {
  /**
   * Trigger impact haptic feedback.
   *
   * @param style - Impact style intensity
   */
  async impact(style: HapticStyle = 'medium'): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.haptics) {
      return craft.haptics.impact(style)
    }
    // Web fallback using Vibration API
    if ('vibrate' in navigator) {
      const duration = { light: 10, medium: 20, heavy: 30, soft: 5, rigid: 25 }[style]
      navigator.vibrate(duration)
    }
  },

  /**
   * Trigger notification haptic feedback.
   *
   * @param type - Notification type
   */
  async notification(type: HapticNotificationType = 'success'): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.haptics) {
      return craft.haptics.notification(type)
    }
    if ('vibrate' in navigator) {
      const patterns = {
        success: [10, 30, 10],
        warning: [30, 30, 30],
        error: [50, 50, 50, 50, 50]
      }
      navigator.vibrate(patterns[type])
    }
  },

  /**
   * Trigger selection haptic feedback.
   * Use when a selection changes (e.g., picker value change).
   */
  async selection(): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.haptics) {
      return craft.haptics.selection()
    }
    if ('vibrate' in navigator) {
      navigator.vibrate(5)
    }
  },

  /**
   * Warm the haptic engine ahead of a haptic the page knows is coming (the
   * start of a drag, a long press about to complete), so it plays on the frame
   * it is asked for. `impact`, `notification` or `selection` for one kind, an
   * impact style or notification type for that one, nothing for all. iOS keeps
   * a prepared engine awake for a few seconds. A no-op elsewhere.
   */
  async prepare(kind?: HapticStyle | HapticNotificationType | 'impact' | 'notification' | 'selection'): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.haptics?.prepare) {
      try { await craft.haptics.prepare(kind) } catch {}
    }
  },

  /**
   * Vibrate with a custom pattern.
   *
   * @param pattern - Array of durations in ms [vibrate, pause, vibrate, ...]
   */
  async vibrate(pattern: number[]): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.haptics) {
      return craft.haptics.vibrate(pattern)
    }
    if ('vibrate' in navigator) {
      navigator.vibrate(pattern)
    }
  }
}

// ============================================================================
// Permissions API
// ============================================================================

/**
 * Permission types.
 */
export type PermissionType =
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

/**
 * Permission status.
 */
export type PermissionStatus = 'granted' | 'denied' | 'undetermined' | 'restricted'

/**
 * Permissions API.
 * Request and check native permissions.
 *
 * @example
 * ```typescript
 * // Check permission status
 * const status = await permissions.check('camera')
 *
 * // Request permission
 * if (status !== 'granted') {
 *   const newStatus = await permissions.request('camera')
 *   if (newStatus === 'granted') {
 *     // Permission granted, proceed
 *   }
 * }
 *
 * // Check multiple permissions
 * const statuses = await permissions.checkMultiple(['camera', 'microphone'])
 *
 * // Request multiple permissions
 * const results = await permissions.requestMultiple(['camera', 'microphone', 'photos'])
 * ```
 */
export const permissions = {
  /**
   * Check the status of a permission.
   *
   * @param permission - Permission to check
   * @returns Promise resolving to PermissionStatus
   */
  async check(permission: PermissionType): Promise<PermissionStatus> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.permissions) {
      return craft.permissions.check(permission)
    }
    // Web fallback using Permissions API
    try {
      const webPermission = mapToWebPermission(permission)
      if (webPermission && navigator.permissions) {
        const result = await navigator.permissions.query({ name: webPermission as PermissionName })
        return mapWebPermissionStatus(result.state)
      }
    }
catch {
      // Permissions API not supported
    }
    return 'undetermined'
  },

  /**
   * Request a permission.
   *
   * @param permission - Permission to request
   * @returns Promise resolving to new PermissionStatus
   */
  async request(permission: PermissionType): Promise<PermissionStatus> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.permissions) {
      return craft.permissions.request(permission)
    }
    // Web fallback - trigger permission request through relevant API
    try {
      if (permission === 'camera' || permission === 'microphone') {
        const constraints: MediaStreamConstraints = {}
        if (permission === 'camera') constraints.video = true
        if (permission === 'microphone') constraints.audio = true
        const stream = await navigator.mediaDevices.getUserMedia(constraints)
        stream.getTracks().forEach(track => track.stop())
        return 'granted'
      }
      if (permission === 'location') {
        return new Promise((resolve) => {
          navigator.geolocation.getCurrentPosition(
            () => resolve('granted'),
            () => resolve('denied')
          )
        })
      }
      if (permission === 'notifications') {
        const result = await Notification.requestPermission()
        return result === 'granted' ? 'granted' : 'denied'
      }
    }
catch {
      return 'denied'
    }
    return 'undetermined'
  },

  /**
   * Check multiple permissions.
   *
   * @param permissionList - Array of permissions to check
   * @returns Promise resolving to object mapping permissions to statuses
   */
  async checkMultiple(permissionList: PermissionType[]): Promise<Record<PermissionType, PermissionStatus>> {
    const results: Record<string, PermissionStatus> = {}
    for (const perm of permissionList) {
      results[perm] = await this.check(perm)
    }
    return results as Record<PermissionType, PermissionStatus>
  },

  /**
   * Request multiple permissions.
   *
   * @param permissionList - Array of permissions to request
   * @returns Promise resolving to object mapping permissions to statuses
   */
  async requestMultiple(permissionList: PermissionType[]): Promise<Record<PermissionType, PermissionStatus>> {
    const results: Record<string, PermissionStatus> = {}
    for (const perm of permissionList) {
      results[perm] = await this.request(perm)
    }
    return results as Record<PermissionType, PermissionStatus>
  },

  /**
   * Open app settings (to change permissions manually).
   */
  async openSettings(): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.permissions) {
      return craft.permissions.openSettings()
    }
  }
}

// ============================================================================
// Camera API
// ============================================================================

/**
 * Camera options.
 */
export interface CameraOptions {
  /** Camera to use: 'front' | 'back' */
  camera?: 'front' | 'back'
  /** Photo quality: 0-100 */
  quality?: number
  /** Max width in pixels */
  maxWidth?: number
  /** Max height in pixels */
  maxHeight?: number
  /** Save to camera roll */
  saveToGallery?: boolean
}

/**
 * Photo result.
 */
export interface PhotoResult {
  /** Base64 encoded image data */
  base64: string
  /** Image URI/path */
  uri: string
  /** Image width */
  width: number
  /** Image height */
  height: number
  /** MIME type */
  mimeType: string
}

/** A file copied into the app-owned native file area. */
export interface FileInfo {
  /** App-owned path suitable for `fetch` FormData and sharing. */
  path: string
  /** Original (sanitized) file name. */
  name: string
  /** Preferred MIME type, or `application/octet-stream` when unknown. */
  type: string
  /** Number of bytes in the copied file. */
  size: number
}

/** General document picker options. */
export interface PickFileOptions {
  /** MIME types, UTIs, or filename extensions (for example `pdf` or `public.data`). */
  contentTypes?: string[]
  /** Maximum number of documents; native hosts clamp this to 1–20. */
  maxSelections?: number
  /** Maximum size of each document in bytes; native hosts default to 512 MiB. */
  maxBytes?: number
}

/** General document picker API. */
export const files = {
  async pickFile(options: PickFileOptions = {}): Promise<FileInfo[]> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.files) {
      return craft.files.pickFile(options)
    }
    if (typeof document === 'undefined') {
      throw new Error('File picker not available. Must run in Craft or a browser.')
    }
    return new Promise((resolve, reject) => {
      const input = document.createElement('input')
      input.type = 'file'
      if (options.contentTypes?.length) input.accept = options.contentTypes.join(',')
      const requested = Number(options.maxSelections)
      const maxSelections = Number.isFinite(requested) && requested > 0 ? Math.min(20, Math.floor(requested)) : 1
      input.multiple = maxSelections > 1
      input.style.display = 'none'
      let settled = false
      const finish = (result: () => void): void => {
        if (settled) return
        settled = true
        input.remove()
        result()
      }
      input.addEventListener('cancel', () => finish(() => resolve([])), { once: true })
      input.onchange = () => {
        const chosen = Array.from(input.files ?? []).slice(0, maxSelections)
        const limit = Number(options.maxBytes)
        if (Number.isFinite(limit) && limit > 0) {
          const oversized = chosen.find(file => file.size > limit)
          if (oversized) {
            finish(() => reject(Object.assign(new Error('The selected file is too large'), { code: 'FILE_TOO_LARGE' })))
            return
          }
        }
        finish(() => resolve(chosen.map(file => ({
          path: URL.createObjectURL(file),
          name: file.name,
          type: file.type || 'application/octet-stream',
          size: file.size,
        }))))
      }
      document.body.append(input)
      input.click()
    })
  },
}

/**
 * Camera and image picker API.
 *
 * @example
 * ```typescript
 * // Take a photo
 * const photo = await camera.takePicture({ camera: 'back', quality: 80 })
 *
 * // Pick from gallery
 * const image = await camera.pickImage()
 *
 * // Pick multiple images
 * const images = await camera.pickMultiple({ maxCount: 5 })
 * ```
 */
export const camera = {
  /**
   * Take a photo with the device camera.
   *
   * @param options - Camera options
   * @returns Promise resolving to PhotoResult
   */
  async takePicture(options: CameraOptions = {}): Promise<PhotoResult> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.camera) {
      return craft.camera.takePicture(options)
    }
    throw new Error('Camera API not available. Must run in Craft environment.')
  },

  /**
   * Pick an image from the gallery.
   *
   * @returns Promise resolving to PhotoResult
   */
  async pickImage(): Promise<PhotoResult> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.camera) {
      return craft.camera.pickImage()
    }
    // Web fallback using file input
    return new Promise((resolve, reject) => {
      const input = document.createElement('input')
      input.type = 'file'
      input.accept = 'image/*'
      input.onchange = async () => {
        const file = input.files?.[0]
        if (file) {
          const reader = new FileReader()
          reader.onload = () => {
            const base64 = (reader.result as string).split(',')[1]
            resolve({
              base64,
              uri: URL.createObjectURL(file),
              width: 0,
              height: 0,
              mimeType: file.type
            })
          }
          reader.onerror = () => reject(new Error('Failed to read file'))
          reader.readAsDataURL(file)
        }
else {
          reject(new Error('No file selected'))
        }
      }
      input.click()
    })
  },

  /**
   * Pick multiple images from the gallery.
   *
   * @param options - Options including maxCount
   * @returns Promise resolving to array of PhotoResults
   */
  async pickMultiple(options: { maxCount?: number } = {}): Promise<PhotoResult[]> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.camera) {
      return craft.camera.pickMultiple(options)
    }
    throw new Error('Camera API not available. Must run in Craft environment.')
  },

  /**
   * Check if camera is available.
   */
  async isAvailable(): Promise<boolean> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.camera) {
      return craft.camera.isAvailable()
    }
    try {
      const devices = await navigator.mediaDevices.enumerateDevices()
      return devices.some(d => d.kind === 'videoinput')
    }
catch {
      return false
    }
  }
}

// ============================================================================
// Biometrics API
// ============================================================================

/**
 * Biometric type.
 */
export type BiometricType = 'faceId' | 'touchId' | 'fingerprint' | 'face' | 'iris' | 'none'

/**
 * Biometric authentication API.
 *
 * @example
 * ```typescript
 * // Check availability
 * const available = await biometrics.isAvailable()
 * const type = await biometrics.getBiometricType()
 *
 * // Authenticate
 * try {
 *   const success = await biometrics.authenticate('Verify your identity')
 *   if (success) {
 *     // Proceed with authenticated action
 *   }
 * }
catch (error) {
 *   console.log('Authentication failed:', error)
 * }
 * ```
 */
export const biometrics = {
  /**
   * Check if biometric authentication is available.
   */
  async isAvailable(): Promise<boolean> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.biometrics) {
      return craft.biometrics.isAvailable()
    }
    return false
  },

  /**
   * Get the type of biometric authentication available.
   */
  async getBiometricType(): Promise<BiometricType | null> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.biometrics) {
      return craft.biometrics.getBiometricType()
    }
    return null
  },

  /**
   * Authenticate using biometrics.
   *
   * @param reason - Reason shown to user for authentication
   * @returns Promise resolving to true if authenticated
   * @throws Error if authentication fails or is cancelled
   */
  async authenticate(reason: string): Promise<boolean> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.biometrics) {
      return craft.biometrics.authenticate(reason)
    }
    throw new Error('Biometrics not available')
  }
}

// ============================================================================
// Secure Storage API
// ============================================================================

/**
 * Secure storage API for sensitive data.
 * Uses Keychain (iOS) or Keystore (Android).
 *
 * @example
 * ```typescript
 * // Store sensitive data
 * await secureStorage.set('authToken', 'secret-token-123')
 * await secureStorage.set('userCredentials', JSON.stringify({ user: 'john', pass: '***' }))
 *
 * // Retrieve data
 * const token = await secureStorage.get('authToken')
 *
 * // Delete data
 * await secureStorage.delete('authToken')
 *
 * // Clear all secure storage
 * await secureStorage.clear()
 * ```
 */
export const secureStorage = {
  /**
   * Store a value securely.
   *
   * @param key - Storage key
   * @param value - Value to store
   */
  async set(key: string, value: string): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.secureStorage) {
      return craft.secureStorage.set(key, value)
    }
    if (typeof window !== 'undefined' && (window as any).craft)
      throw new Error('Craft secure storage bridge is unavailable')
    // Fallback to localStorage (not secure, but functional for development)
    localStorage.setItem(`secure_${key}`, value)
  },

  /**
   * Retrieve a securely stored value.
   *
   * @param key - Storage key
   * @returns Promise resolving to value or null
   */
  async get(key: string): Promise<string | null> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.secureStorage) {
      return craft.secureStorage.get(key)
    }
    if (typeof window !== 'undefined' && (window as any).craft)
      throw new Error('Craft secure storage bridge is unavailable')
    return localStorage.getItem(`secure_${key}`)
  },

  /**
   * Delete a securely stored value.
   *
   * @param key - Storage key
   */
  async delete(key: string): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.secureStorage) {
      return craft.secureStorage.delete(key)
    }
    if (typeof window !== 'undefined' && (window as any).craft)
      throw new Error('Craft secure storage bridge is unavailable')
    localStorage.removeItem(`secure_${key}`)
  },

  /**
   * Remove a securely stored value using the legacy native contract.
   *
   * New code may use {@link delete}; this alias keeps older native screens
   * and the public `craft.d.ts` contract working across bridge versions.
   *
   * @param key - Storage key
   */
  async remove(key: string): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.secureStorage) {
      if (typeof craft.secureStorage.remove === 'function') return craft.secureStorage.remove(key)
      return craft.secureStorage.delete(key)
    }
    if (typeof window !== 'undefined' && (window as any).craft)
      throw new Error('Craft secure storage bridge is unavailable')
    localStorage.removeItem(`secure_${key}`)
  },

  /**
   * Clear all securely stored values.
   */
  async clear(): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.secureStorage) {
      return craft.secureStorage.clear()
    }
    if (typeof window !== 'undefined' && (window as any).craft)
      throw new Error('Craft secure storage bridge is unavailable')
    Object.keys(localStorage)
      .filter(k => k.startsWith('secure_'))
      .forEach(k => localStorage.removeItem(k))
  }
}

// ============================================================================
// Session API
// ============================================================================

/** `craft.session.onChange`'s listener: the token now, and the one before (null when signed out). */
export type SessionListener = (token: string | null, previous: string | null) => void

/**
 * One change of the signed-in account, as the hosts report it: the
 * `SESSION_CHANGED` message a native screen hears, and the detail of the
 * page's `craftsession` event. `key` is the secure-storage name of the
 * token (`sessionTokenKey` in the Craft config, `auth.token` by default).
 */
export interface SessionChange {
  key: string
  token: string | null
  previous: string | null
}

/** The page event a host dispatches when the signed-in account changes. */
export const SESSION_EVENT = 'craftsession'

/** The bridge message a native screen's runtime hears when the signed-in account changes. */
export const SESSION_MESSAGE = 'SESSION_CHANGED'

/** The default secure-storage name of the sign-in token. */
export const DEFAULT_SESSION_TOKEN_KEY = 'auth.token'

const sessionToken = (value: unknown): string | null => typeof value === 'string' && value !== '' ? value : null

/**
 * The signed-in account, as the app's sign-in token in secure storage
 * (`sessionTokenKey`, default `auth.token`). Every host reports a change of
 * it, whoever made it: a native screen's `secureStorage.set`, the web page's
 * own sign-in (a `shareStorage` key), a sign-out, or another browser tab.
 * Use it to start a screen afresh for another account instead of comparing
 * snapshots on every change.
 *
 * @example
 * ```typescript
 * import { session } from 'craft-native/mobile'
 *
 * let account = session.token()
 * const stop = session.onChange((token, previous) => {
 *   if (!token) return showSignIn()
 *   if (previous && token !== previous) resetScreen()
 *   account = token
 * })
 * ```
 */
export const session = {
  /** The sign-in token now, or null when signed out or the host keeps none. */
  token(): string | null {
    const host = getCraftRoot()?.session
    if (typeof host?.token !== 'function') return null
    try { return sessionToken(host.token()) }
    catch { return null }
  },

  /**
   * Hear each change of the sign-in token, with the new token and the one
   * before it. Fires once per change, after storage holds the new value, on
   * every screen and the page (including the one that wrote it). Returns the
   * unsubscribe function.
   */
  onChange(callback: SessionListener): () => void {
    if (typeof callback !== 'function') throw new TypeError('session.onChange needs a function')
    const host = getCraftRoot()?.session
    if (typeof host?.onChange === 'function') {
      const stop = host.onChange((token: unknown, previous: unknown) => callback(sessionToken(token), sessionToken(previous)))
      return typeof stop === 'function' ? stop : () => {}
    }
    // A host that only dispatches the page event.
    return onCraftEvent(SESSION_EVENT, detail => callback(sessionToken(detail.token), sessionToken(detail.previous)))
  },
}

// ============================================================================
// Location API
// ============================================================================

/**
 * Location coordinates.
 */
export interface Location {
  /** Owner captured when a native recording emits this sample. */
  recordingId?: string
  latitude: number
  longitude: number
  altitude?: number
  accuracy: number
  heading?: number
  speed?: number
  timestamp: number
}

/**
 * Location options.
 */
export interface LocationOptions {
  /** Enable high accuracy (uses more battery) */
  enableHighAccuracy?: boolean
  /** Timeout in milliseconds */
  timeout?: number
  /** Maximum age of cached position in milliseconds */
  maximumAge?: number
}

/** Persist this ID with the owning intent before starting a native recording. */
export interface RecordingStartOptions {
  recordingId?: string
}

/**
 * How hard a route recording works the GPS. `'saver'` is for a long effort (an
 * ultra): fixes come at least 5 m apart rather than every second, and while
 * the pace holds steady iOS asks for ten-metre accuracy instead of the best it
 * can do, going back to the best at once when the pace or the signal changes.
 * Fixes stay under 30 s apart at any speed that counts as moving, so distance
 * and moving time come out as they would at full rate. Android asks for the
 * same spacing and batches delivery.
 */
export interface LocationRecordingPowerOptions {
  powerMode?: 'default' | 'saver'
}

/** Fence a recording operation to the ID returned by start or explicit recovery. */
export interface RecordingOwnershipOptions {
  expectedId: string
}

/** Reading a route back: `since` (epoch ms) asks only for the fixes recorded after it. */
export interface LocationRecordingReadOptions extends RecordingOwnershipOptions {
  since?: number
}

function storageHost(method: string): any {
  const host = getCraftRoot()?.storage
  if (typeof host?.[method] !== 'function')
    throw Object.assign(new Error('This host does not provide native storage'), { code: 'STORAGE_UNSUPPORTED' })
  return host
}

/** Secure IDs supplied by the platform, including WebView-free mobile hosts. */
export const crypto = {
  async randomUUID(): Promise<string> {
    const root = getCraftRoot()
    if (!root) return secureUUID()
    const caps = root.capabilities
    const advertised = Array.isArray(caps) ? caps.includes('crypto') : caps?.crypto === true
    if (!advertised || typeof root.crypto?.randomUUID !== 'function')
      throw Object.assign(new Error('This host does not provide secure UUIDs'), { code: 'CRYPTO_UNSUPPORTED' })
    const id: unknown = await root.crypto.randomUUID()
    if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id))
      throw Object.assign(new Error('The host returned an invalid secure UUID'), { code: 'CRYPTO_INVALID_RESPONSE' })
    return id
  },
}

/** Native storage, including an existing-key atomic checkpoint. */
export const storage = {
  supportsSetIfAbsent(): boolean {
    const root = getCraftRoot()
    const caps = root?.capabilities
    const supported = Array.isArray(caps) ? caps.includes('storageSetIfAbsent') : caps?.storageSetIfAbsent === true
    return supported && typeof root?.storage?.setIfAbsent === 'function'
  },
  supportsCompareAndSet(): boolean {
    const root = getCraftRoot()
    const caps = root?.capabilities
    const supported = Array.isArray(caps) ? caps.includes('storageCompareAndSet') : caps?.storageCompareAndSet === true
    return supported && typeof root?.storage?.compareAndSet === 'function'
  },
  async get<T = unknown>(key: string): Promise<T | null> { return storageHost('get').get(key) },
  async set(key: string, value: unknown): Promise<boolean> { return storageHost('set').set(key, value) },
  async remove(key: string): Promise<boolean> { return storageHost('remove').remove(key) },
  async clear(): Promise<boolean> { return storageHost('clear').clear() },
  async keys(): Promise<string[]> { return storageHost('keys').keys() },
  async setIfAbsent(key: string, value: unknown): Promise<boolean> {
    if (!storage.supportsSetIfAbsent())
      throw Object.assign(new Error('This app build cannot atomically register an intent'), { code: 'STORAGE_SET_IF_ABSENT_UNSUPPORTED' })
    if (typeof key !== 'string' || !key.trim() || JSON.stringify(value) === undefined)
      throw Object.assign(new Error('setIfAbsent needs a key and JSON value'), { code: 'INVALID_ARGUMENT' })
    return storageHost('setIfAbsent').setIfAbsent(key, value)
  },
  async compareAndSet(key: string, expectedValue: unknown, nextValue: unknown): Promise<boolean> {
    if (!storage.supportsCompareAndSet())
      throw Object.assign(new Error('This app build cannot atomically checkpoint existing storage'), { code: 'STORAGE_COMPARE_AND_SET_UNSUPPORTED' })
    if (typeof key !== 'string' || !key.trim() || JSON.stringify(expectedValue) === undefined || JSON.stringify(nextValue) === undefined)
      throw Object.assign(new Error('compareAndSet needs a key and JSON values'), { code: 'INVALID_ARGUMENT' })
    return storageHost('compareAndSet').compareAndSet(key, expectedValue, nextValue)
  },
}

function recordingOwnershipSupported(namespace: 'location' | 'heartRate'): boolean {
  const root = getCraftRoot()
  const flag = namespace === 'location' ? 'locationRecordingOwnership' : 'heartRateRecordingOwnership'
  const caps = root?.capabilities
  const advertised = Array.isArray(caps) ? caps.includes(flag) : caps?.[flag] === true
  return advertised && ['pauseRecording', 'resumeRecording', 'stopRecording', 'readRecording', 'getRecordingState', 'acknowledgeRecording'].every(method => typeof root?.[namespace]?.[method] === 'function')
}

function recordingIntentSupported(namespace: 'location' | 'heartRate'): boolean {
  const root = getCraftRoot()
  const flag = namespace === 'location' ? 'locationRecordingIntentIdentity' : 'heartRateRecordingIntentIdentity'
  const caps = root?.capabilities
  const advertised = Array.isArray(caps) ? caps.includes(flag) : caps?.[flag] === true
  return advertised && recordingOwnershipSupported(namespace) && typeof root?.[namespace]?.startRecording === 'function'
}

function validateRecordingStart(namespace: 'location' | 'heartRate', options: RecordingStartOptions): void {
  if (!Object.prototype.hasOwnProperty.call(options, 'recordingId')) return
  if (typeof options.recordingId !== 'string' || !options.recordingId.trim())
    throw Object.assign(new Error('recordingId must be a nonempty recording ID'), { code: 'INVALID_ARGUMENT' })
  if (!recordingIntentSupported(namespace))
    throw Object.assign(new Error('This app build cannot start the persisted recording intent'), { code: 'RECORDING_INTENT_IDENTITY_UNSUPPORTED' })
}

function verifyRecordingStart<T extends { id: string | null }>(options: RecordingStartOptions, result: T): T {
  if (options.recordingId !== undefined && result.id !== options.recordingId)
    throw Object.assign(new Error('The native recording does not match the persisted intent'), { code: 'RECORDING_CONFLICT' })
  return result
}

function validateRecordingOwnership(namespace: 'location' | 'heartRate', options?: Partial<RecordingOwnershipOptions>): void {
  if (!options || !Object.prototype.hasOwnProperty.call(options, 'expectedId')) return
  if (typeof options.expectedId !== 'string' || !options.expectedId.trim())
    throw Object.assign(new Error('expectedId must be a nonempty recording ID'), { code: 'INVALID_ARGUMENT' })
  if ((getCraftRoot() || namespace === 'heartRate') && !recordingOwnershipSupported(namespace))
    throw Object.assign(new Error('This app build cannot enforce recording ownership'), { code: 'RECORDING_OWNERSHIP_UNSUPPORTED' })
  if (namespace === 'location' && !getCraftRoot() && options.expectedId !== webLocationRecording.id)
    throw Object.assign(new Error('The active location recording has changed'), { code: 'RECORDING_CONFLICT' })
}

export interface LocationRecordingState {
  id: string | null
  active: boolean
  paused: boolean
  startedAt: number | null
  sampleCount?: number
}

export interface LocationRecordingResult extends LocationRecordingState {
  locations: Location[]
}

let webLocationRecording: LocationRecordingResult = {
  id: null,
  active: false,
  paused: false,
  startedAt: null,
  locations: []
}
let webLocationRecordingWatchId: number | null = null

/**
 * Location API.
 *
 * @example
 * ```typescript
 * // Get current location
 * const loc = await location.getCurrentPosition()
 * console.log(`Lat: ${loc.latitude}, Lng: ${loc.longitude}`)
 *
 * // Watch location changes
 * const watchId = location.watchPosition((loc) => {
 *   console.log('New position:', loc)
 * })
 *
 * // Stop watching
 * location.clearWatch(watchId)
 * ```
 */
export const location = {
  supportsRecordingOwnership: (): boolean => recordingOwnershipSupported('location'),
  supportsRecordingIntentIdentity: (): boolean => recordingIntentSupported('location'),
  /**
   * Get current position.
   *
   * @param options - Location options
   * @returns Promise resolving to Location
   */
  async getCurrentPosition(options: LocationOptions = {}): Promise<Location> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location) {
      return craft.location.getCurrentPosition(options)
    }
    return new Promise((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(
        (pos) => resolve({
          latitude: pos.coords.latitude,
          longitude: pos.coords.longitude,
          altitude: pos.coords.altitude ?? undefined,
          accuracy: pos.coords.accuracy,
          heading: pos.coords.heading ?? undefined,
          speed: pos.coords.speed ?? undefined,
          timestamp: pos.timestamp
        }),
        reject,
        {
          enableHighAccuracy: options.enableHighAccuracy,
          timeout: options.timeout,
          maximumAge: options.maximumAge
        }
      )
    })
  },

  /**
   * Watch position changes.
   *
   * @param callback - Function called on position change
   * @param options - Location options
   * @returns Watch ID to use with clearWatch
   */
  watchPosition(callback: (location: Location) => void, options: LocationOptions = {}): number {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location) {
      return craft.location.watchPosition(callback, options)
    }
    return navigator.geolocation.watchPosition(
      (pos) => callback({
        latitude: pos.coords.latitude,
        longitude: pos.coords.longitude,
        altitude: pos.coords.altitude ?? undefined,
        accuracy: pos.coords.accuracy,
        heading: pos.coords.heading ?? undefined,
        speed: pos.coords.speed ?? undefined,
        timestamp: pos.timestamp
      }),
      console.error,
      {
        enableHighAccuracy: options.enableHighAccuracy,
        timeout: options.timeout,
        maximumAge: options.maximumAge
      }
    )
  },

  /**
   * Stop watching position.
   *
   * @param watchId - Watch ID returned from watchPosition
   */
  clearWatch(watchId: number): void {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location) {
      return craft.location.clearWatch(watchId)
    }
    navigator.geolocation.clearWatch(watchId)
  },

  async startRecording(options: LocationOptions & RecordingStartOptions & LocationRecordingPowerOptions = {}): Promise<LocationRecordingState> {
    validateRecordingStart('location', options)
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location?.startRecording)
      return verifyRecordingStart(options, await craft.location.startRecording(options))

    if (webLocationRecording.active)
      throw Object.assign(new Error('A location recording is already active'), { code: 'RECORDING_ALREADY_ACTIVE' })
    if (webLocationRecordingWatchId !== null)
      navigator.geolocation.clearWatch(webLocationRecordingWatchId)
    webLocationRecording = {
      id: secureUUID(),
      active: true,
      paused: false,
      startedAt: Date.now(),
      locations: []
    }
    webLocationRecordingWatchId = location.watchPosition((position) => {
      if (!webLocationRecording.paused) webLocationRecording.locations.push(position)
    }, options)
    return { ...webLocationRecording, sampleCount: 0 }
  },

  async pauseRecording(options?: RecordingOwnershipOptions): Promise<LocationRecordingState> {
    validateRecordingOwnership('location', options)
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location?.pauseRecording)
      return craft.location.pauseRecording(options)
    webLocationRecording.paused = true
    return { ...webLocationRecording, sampleCount: webLocationRecording.locations.length }
  },

  async resumeRecording(options?: RecordingOwnershipOptions): Promise<LocationRecordingState> {
    validateRecordingOwnership('location', options)
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location?.resumeRecording)
      return craft.location.resumeRecording(options)
    webLocationRecording.paused = false
    return { ...webLocationRecording, sampleCount: webLocationRecording.locations.length }
  },

  async stopRecording(options?: RecordingOwnershipOptions): Promise<LocationRecordingResult> {
    validateRecordingOwnership('location', options)
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location?.stopRecording)
      return craft.location.stopRecording(options)
    if (webLocationRecordingWatchId !== null) {
      location.clearWatch(webLocationRecordingWatchId)
      webLocationRecordingWatchId = null
    }
    webLocationRecording.active = false
    webLocationRecording.paused = false
    return { ...webLocationRecording, locations: [...webLocationRecording.locations] }
  },

  async getRecordingState(options?: RecordingOwnershipOptions): Promise<LocationRecordingState> {
    validateRecordingOwnership('location', options)
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location?.getRecordingState)
      return craft.location.getRecordingState(options)
    return { ...webLocationRecording, sampleCount: webLocationRecording.locations.length }
  },

  async acknowledgeRecording(options: RecordingOwnershipOptions): Promise<boolean> {
    if (!options || !Object.prototype.hasOwnProperty.call(options, 'expectedId'))
      throw Object.assign(new Error('Acknowledgement needs expectedId'), { code: 'INVALID_ARGUMENT' })
    validateRecordingOwnership('location', options)
    const craft = getCraftMobile()
    if (craft?.location?.acknowledgeRecording) return craft.location.acknowledgeRecording(options)
    if (webLocationRecording.active)
      throw Object.assign(new Error('The recording is still active'), { code: 'RECORDING_ALREADY_ACTIVE' })
    webLocationRecording = { id: null, active: false, paused: false, startedAt: null, locations: [] }
    return true
  },

  /**
   * The recording's fixes. With `since`, iOS reads only the fixes after it
   * from the end of the track; a host that does not know `since` answers with
   * every fix, so a caller skips those it already has.
   */
  async readRecording(options?: LocationRecordingReadOptions): Promise<Location[]> {
    validateRecordingOwnership('location', options)
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.location?.readRecording)
      return craft.location.readRecording(options)
    const since = options?.since
    return typeof since === 'number' && Number.isFinite(since)
      ? webLocationRecording.locations.filter(location => location.timestamp > since)
      : [...webLocationRecording.locations]
  }
}

// ============================================================================
// Share API
// ============================================================================

/**
 * Share options.
 */
export interface ShareOptions {
  /** Text to share */
  text?: string
  /** URL to share */
  url?: string
  /** Title for the share */
  title?: string
  /** File paths/URIs to share */
  files?: string[]
}

/**
 * Share API.
 *
 * @example
 * ```typescript
 * // Share text
 * await share.share({ text: 'Check out this app!' })
 *
 * // Share URL
 * await share.share({ url: 'https://example.com', title: 'Cool Website' })
 *
 * // Share file
 * await share.share({ files: ['/path/to/image.png'] })
 * ```
 */
export const share = {
  /**
   * Open native share dialog.
   *
   * Resolves `true` when the person shared and `false` when they dismissed the
   * dialog, on the native bridges and in the browser alike.
   *
   * @param options - Share options
   */
  async share(options: ShareOptions): Promise<boolean> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.share) {
      return craft.share.share(options)
    }
    // Web Share API fallback
    if (navigator.share) {
      try {
        await navigator.share({
          title: options.title,
          text: options.text,
          url: options.url
        })
        return true
      }
      catch (error) {
        // A dismissed dialog rejects with AbortError here. The native bridges
        // answer false for the same thing, so this does too rather than
        // turning a person's choice into an exception.
        if (error instanceof DOMException && error.name === 'AbortError') return false
        throw error
      }
    }
else {
      throw new Error('Share API not available')
    }
  },

  /**
   * Check if sharing is available.
   */
  isAvailable(): boolean {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.share) {
      return true
    }
    return 'share' in navigator
  }
}

// ============================================================================
// App Lifecycle API
// ============================================================================

/**
 * App state.
 */
export type AppState = 'active' | 'inactive' | 'background'

/**
 * App lifecycle events API.
 *
 * @example
 * ```typescript
 * // Listen for app state changes
 * const removeListener = lifecycle.onStateChange((state) => {
 *   if (state === 'background') {
 *     // Save data, pause tasks
 *   }
else if (state === 'active') {
 *     // Refresh data
 *   }
 * })
 *
 * // Get current state
 * const state = lifecycle.getState()
 *
 * // Remove listener
 * removeListener()
 * ```
 */
export const lifecycle = {
  /**
   * Get current app state.
   */
  getState(): AppState {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.lifecycle) {
      return craft.lifecycle.getState()
    }
    return document.visibilityState === 'visible' ? 'active' : 'background'
  },

  /**
   * Listen for app state changes.
   *
   * @param callback - Function called when state changes
   * @returns Function to remove listener
   */
  onStateChange(callback: (state: AppState) => void): () => void {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.lifecycle) {
      return craft.lifecycle.onStateChange(callback)
    }
    const handler = () => {
      callback(document.visibilityState === 'visible' ? 'active' : 'background')
    }
    document.addEventListener('visibilitychange', handler)
    return () => document.removeEventListener('visibilitychange', handler)
  },

  /**
   * The app came back to the foreground (`craftResume`), with how long it was
   * away. A page can refresh what may have gone stale. iOS shell only.
   */
  onResume(callback: (event: { backgroundedMs: number }) => void): () => void {
    return onCraftEvent('craftResume', detail => callback({ backgroundedMs: Number(detail.backgroundedMs) || 0 }))
  },

  /**
   * iOS is short of memory (`craftMemoryWarning`): drop caches, or the page's
   * content process may be ended. iOS shell only.
   */
  onMemoryWarning(callback: () => void): () => void {
    return onCraftEvent('craftMemoryWarning', () => callback())
  }
}

// ============================================================================
// Notifications API
// ============================================================================

/**
 * Notification options.
 */
export interface NotificationOptions {
  /** Notification title */
  title: string
  /** Notification body */
  body?: string
  /** Badge count (iOS) */
  badge?: number
  /** Sound name */
  sound?: string
  /** Custom data payload */
  data?: Record<string, unknown>
  /** Schedule for future (timestamp) */
  scheduleAt?: number
}

/** A notification as the bridges read it: `delay` in place of `scheduleAt`. */
export type BridgeNotification = Omit<NotificationOptions, 'scheduleAt'> & { delay?: number }

/** A local notification waiting for delivery. */
export interface PendingLocalNotification {
  id: string
  title: string
  body: string
}

/**
 * The bridges' spelling of a notification: `scheduleAt` becomes `delay`.
 *
 * Both bridges schedule from `delay`, milliseconds from now, and iOS also from
 * `timestamp`; neither reads `scheduleAt`, so a reminder meant for an hour
 * from now fired at once (#261). `delay` rather than `timestamp` because
 * Android reads only `delay`, and because an interval is what an instant
 * means, where iOS's calendar trigger would move with the device's time zone.
 * A moment already past sends no delay at all, which both bridges deliver
 * now: a zero delay raises inside UserNotifications on the Swift side.
 */
export function bridgeNotification(options: NotificationOptions, now: number = Date.now()): BridgeNotification {
  const { scheduleAt, ...rest } = options
  if (scheduleAt === undefined) return rest
  const wait = Math.ceil(scheduleAt - now)
  return wait > 0 ? { ...rest, delay: wait } : rest
}

/**
 * Local notifications API.
 *
 * @example
 * ```typescript
 * // Show immediate notification
 * await notifications.show({
 *   title: 'Hello!',
 *   body: 'This is a notification'
 * })
 *
 * // Schedule notification
 * await notifications.schedule({
 *   title: 'Reminder',
 *   body: 'Time to take a break',
 *   scheduleAt: Date.now() + 3600000 // 1 hour from now
 * })
 *
 * // Cancel all notifications
 * await notifications.cancelAll()
 * ```
 */
export const notifications = {
  /**
   * Show a local notification immediately.
   *
   * @param options - Notification options
   */
  async show(options: NotificationOptions): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.notifications) {
      return craft.notifications.show(options)
    }
    // Web Notifications API fallback
    if ('Notification' in window && Notification.permission === 'granted') {
      new Notification(options.title, { body: options.body })
    }
  },

  /**
   * Schedule a notification for the future.
   *
   * @param options - Notification options with scheduleAt
   */
  async schedule(options: NotificationOptions): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.notifications) {
      return craft.notifications.schedule(bridgeNotification(options))
    }
    throw new Error('Scheduled notifications not available in web')
  },

  /**
   * Cancel one scheduled notification.
   */
  async cancel(id: string): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.notifications) {
      return craft.notifications.cancel(id)
    }
    throw new Error('Scheduled notifications not available in web')
  },

  /**
   * Read notifications that have not fired yet.
   */
  async pending(): Promise<PendingLocalNotification[]> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.notifications) {
      return craft.notifications.pending()
    }
    return []
  },

  /**
   * Cancel all scheduled notifications.
   */
  async cancelAll(): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.notifications) {
      return craft.notifications.cancelAll()
    }
  },

  /**
   * Set app badge count (iOS).
   *
   * @param count - Badge count (0 to clear)
   */
  async setBadge(count: number): Promise<void> {
    const craft = getCraftMobile()
    if (typeof window !== 'undefined' && craft?.notifications) {
      return craft.notifications.setBadge(count)
    }
  }
}

export interface NetworkStatus {
  type: 'wifi' | 'cellular' | 'ethernet' | 'none' | 'unknown'
  isConnected: boolean
}

let webWakeLock: { release: () => Promise<void> } | null = null

export const keepAwake = {
  async enable(): Promise<void> {
    const craft = getCraftRoot()
    if (craft?.setKeepAwake) {
      await craft.setKeepAwake(true)
      return
    }
    const wakeLock = (navigator as Navigator & { wakeLock?: { request: (type: 'screen') => Promise<{ release: () => Promise<void> }> } }).wakeLock
    webWakeLock = await wakeLock?.request('screen') ?? null
  },
  async disable(): Promise<void> {
    const craft = getCraftRoot()
    if (craft?.setKeepAwake) {
      await craft.setKeepAwake(false)
      return
    }
    await webWakeLock?.release()
    webWakeLock = null
  }
}

export interface SpeechOptions {
  /** Speaking rate, 0.5 to 2. 1 is the voice's normal pace. */
  rate?: number
  /** BCP-47 language tag, such as 'en-US'. Defaults to the device's language. */
  language?: string
  /** Stop whatever is being said first. Defaults to true; false queues behind it. */
  interrupt?: boolean
  /** Voice pitch, 0.5 to 2. 1 is the voice's own; lower sounds calmer. */
  pitch?: number
  /**
   * Seconds of quiet before the words (up to 5), after whatever was said
   * before them: a pause between two queued cues.
   */
  preDelay?: number
}

interface WebSpeech {
  synthesis: {
    speak: (utterance: any) => void
    cancel: () => void
  }
  Utterance: new (text: string) => any
}

/** The page's own Web Speech API, when it has one. */
function getWebSpeech(): WebSpeech | undefined {
  if (typeof window === 'undefined') return undefined
  const scope = window as any
  if (!scope.speechSynthesis || typeof scope.SpeechSynthesisUtterance !== 'function') return undefined
  return { synthesis: scope.speechSynthesis, Utterance: scope.SpeechSynthesisUtterance }
}

/**
 * Utterances the web fallback is still speaking. Held because some engines
 * drop an utterance nothing references before it ends, and then never fire
 * `end`, which would leave its promise open for good.
 */
const speakingOnTheWeb = new Set<unknown>()

function speechRate(rate: number | undefined): number {
  return typeof rate === 'number' && Number.isFinite(rate) ? Math.min(Math.max(rate, 0.5), 2) : 1
}

/**
 * Short spoken cues: "Rest, 15 seconds. Up next: Dead Bug".
 *
 * Inside a Craft app this is native text-to-speech, which ducks the person's
 * music rather than stopping it and, on iOS, plays with the silent switch on.
 * In a browser it falls back to the Web Speech API, which does neither, and
 * where there is no speech at all it answers `false` rather than throwing, so
 * a cue never breaks the flow around it.
 */
/*
 * Screen brightness.
 *
 * For a page that shows very little for a long time - a workout's big timer,
 * a boarding pass - and wants the backlight down (or up) while it does. On
 * iOS the brightness is the device's, not the app's, so it outlives the page
 * unless something puts it back: `restore()` does, and so does the page going
 * out of view (the app sent to the background, the screen locked). Coming
 * back re-applies the level the page asked for. Android scopes the change to
 * the app's window and `restore()` hands the screen back to the system,
 * auto-brightness included.
 *
 * Off a phone there is no backlight to set: `isAvailable()` is false and the
 * calls resolve `null` without doing anything.
 */
interface BrightnessState {
  /** The person's own level, read before the first change. */
  original: number | null
  /** What the page asked for, re-applied when it comes back into view. */
  wanted: number | null
  unwatch: (() => void) | null
}

const brightnessState: BrightnessState = { original: null, wanted: null, unwatch: null }

function brightnessLevel(level: unknown): number | null {
  const value = Number(level)
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : null
}

async function putBrightnessBack(craft: any): Promise<void> {
  if (typeof craft?.resetBrightness === 'function') await craft.resetBrightness()
  else if (brightnessState.original !== null) await craft.setBrightness(brightnessState.original)
}

function watchBrightnessVisibility(): void {
  if (brightnessState.unwatch || typeof document === 'undefined') return
  const onVisibility = () => {
    const craft = getCraftRoot()
    if (!craft?.setBrightness || brightnessState.wanted === null) return
    if (document.visibilityState === 'hidden') void putBrightnessBack(craft).catch(() => {})
    else void craft.setBrightness(brightnessState.wanted).catch(() => {})
  }
  document.addEventListener('visibilitychange', onVisibility)
  brightnessState.unwatch = () => document.removeEventListener('visibilitychange', onVisibility)
}

export const brightness = {
  isAvailable(): boolean {
    return typeof getCraftRoot()?.setBrightness === 'function'
  },

  /** The screen's brightness, 0 to 1, or null where there is none to read. */
  async get(): Promise<number | null> {
    const craft = getCraftRoot()
    if (typeof craft?.getBrightness !== 'function') return null
    return brightnessLevel(await craft.getBrightness())
  },

  /**
   * Set the brightness, 0 to 1 (clamped). The first call since the last
   * `restore()` remembers the person's own level to go back to. Resolves with
   * the level the screen reports, or null off a phone.
   */
  async set(level: number): Promise<number | null> {
    const craft = getCraftRoot()
    const wanted = brightnessLevel(level)
    if (typeof craft?.setBrightness !== 'function' || wanted === null) return null
    if (brightnessState.wanted === null && typeof craft.getBrightness === 'function')
      brightnessState.original = brightnessLevel(await craft.getBrightness())
    brightnessState.wanted = wanted
    watchBrightnessVisibility()
    return brightnessLevel(await craft.setBrightness(wanted))
  },

  /** Put the person's own brightness back. Safe to call when nothing was set. */
  async restore(): Promise<void> {
    const craft = getCraftRoot()
    const held = brightnessState.wanted !== null
    brightnessState.wanted = null
    brightnessState.unwatch?.()
    brightnessState.unwatch = null
    if (held && typeof craft?.setBrightness === 'function') await putBrightnessBack(craft)
    brightnessState.original = null
  },
}

export const speech = {
  isAvailable(): boolean {
    return Boolean(getCraftRoot()?.speech?.speak) || getWebSpeech() !== undefined
  },

  /**
   * Speak `text`. Resolves when the utterance ends: `true` when it was
   * spoken, `false` when it was stopped, interrupted or could not be spoken.
   * Rejects with code `INVALID_ARGUMENT` when `text` is empty.
   */
  async speak(text: string, options: SpeechOptions = {}): Promise<boolean> {
    const native = getCraftRoot()?.speech
    const web = native?.speak ? undefined : getWebSpeech()
    if (!native?.speak && !web) return false

    if (typeof text !== 'string' || !text.trim()) {
      throw Object.assign(new Error('speech.speak needs some text to say'), { code: 'INVALID_ARGUMENT' })
    }
    if (native?.speak) return (await native.speak(text, options)) === true

    const { synthesis, Utterance } = web!
    // Cancelling ends the utterance in progress with an error, which settles
    // its promise false, the same answer native gives an interrupted cue.
    if (options.interrupt !== false) synthesis.cancel()
    return new Promise<boolean>((resolve) => {
      const utterance = new Utterance(text)
      utterance.rate = speechRate(options.rate)
      utterance.pitch = speechRate(options.pitch)
      if (options.language) utterance.lang = options.language
      const settle = (spoken: boolean) => {
        speakingOnTheWeb.delete(utterance)
        resolve(spoken)
      }
      utterance.onend = () => settle(true)
      utterance.onerror = () => settle(false)
      speakingOnTheWeb.add(utterance)
      try {
        synthesis.speak(utterance)
      }
      catch {
        settle(false)
      }
    })
  },

  /** Stop speaking at once. Every pending `speak()` resolves `false`. */
  async stop(): Promise<void> {
    const native = getCraftRoot()?.speech
    if (native?.stop) {
      await native.stop()
      return
    }
    getWebSpeech()?.synthesis.cancel()
  },
}

/*
 * Crash and error reporting (bughq).
 *
 * The native shell captures crashes, hangs, ANRs and uncaught JavaScript
 * errors on its own once the app's config has `crashReporting`. This is the
 * JavaScript side: hand over an event built by an error SDK (so it shares the
 * app's offline outbox, session and device context), name the signed-in user,
 * and add breadcrumbs that a later crash report carries.
 *
 * Works from a web view (`window.craft`) and from a native screen or the app
 * script (`globalThis.craft`). Off the app, every call resolves false/null.
 */

export interface CrashReporterContext {
  enabled: boolean
  platform?: 'ios' | 'android'
  release?: string
  environment?: string
  session?: { id: string, startedAt: string }
  contexts?: Record<string, Record<string, unknown>>
  [key: string]: unknown
}

function crashReporterBridge(): any {
  const root = (globalThis as any).craft
  return root?.crashReporter && typeof root.crashReporter.capture === 'function' ? root.crashReporter : undefined
}

export const crashReporter = {
  /** True inside an app whose config turns crash reporting on. */
  isAvailable(): boolean {
    const root = (globalThis as any).craft
    if (!crashReporterBridge()) return false
    const caps = root?.capabilities
    // Web view bridges declare a flag; native screens list capability names.
    if (Array.isArray(caps)) return caps.includes('crashReporter')
    return caps?.crashReporter !== false
  },

  /** Queue an event in the bughq ingest shape (`type`, `message`, `stack`, ...). */
  async capture(event: Record<string, unknown>): Promise<boolean> {
    const bridge = crashReporterBridge()
    if (!bridge || !event || typeof event.message !== 'string') return false
    try {
      return (await bridge.capture(event)) !== false
    }
    catch {
      return false
    }
  },

  /** The app's own user id (never an email), or null on sign-out. */
  async setUser(id: string | number | null): Promise<boolean> {
    const bridge = crashReporterBridge()
    if (!bridge) return false
    try {
      return (await bridge.setUser(id == null ? null : String(id))) !== false
    }
    catch {
      return false
    }
  },

  async addBreadcrumb(breadcrumb: { type?: string, category?: string, level?: string, message?: string, data?: Record<string, unknown> }): Promise<boolean> {
    const bridge = crashReporterBridge()
    if (!bridge) return false
    try {
      return (await bridge.addBreadcrumb(breadcrumb)) !== false
    }
    catch {
      return false
    }
  },

  async flush(): Promise<boolean> {
    const bridge = crashReporterBridge()
    if (!bridge) return false
    try {
      return (await bridge.flush()) !== false
    }
    catch {
      return false
    }
  },

  /** The release, session and device context the native reporter stamps on events. */
  async context(): Promise<CrashReporterContext | null> {
    const bridge = crashReporterBridge()
    if (!bridge) return null
    try {
      return (await bridge.context()) as CrashReporterContext
    }
    catch {
      return null
    }
  },
}

/*
 * Apple Music: what the Music app is playing, and its transport.
 *
 * iOS only, and only Apple Music: the bridge drives
 * MPMusicPlayerController.systemMusicPlayer, which is the Music app's queue.
 * iOS gives no app the controls of another player, so while Spotify or a
 * podcast app plays, the song fields are null and `otherAudioPlaying` is true.
 *
 * Nothing is read before `requestAuthorization()`, which shows iOS's media
 * library prompt once; call it when the person asks to see their music, never
 * on load. Off a phone (a browser, Android) `isAvailable()` is false and every
 * call answers a snapshot with `available: false` without doing anything.
 */
export type MusicAuthorization = 'authorized' | 'denied' | 'restricted' | 'notDetermined' | 'unavailable'

export type MusicPlaybackState = 'stopped' | 'playing' | 'paused' | 'interrupted' | 'seekingForward' | 'seekingBackward' | 'unknown'

export interface NowPlaying {
  /** False where there is no Music app to ask: a browser, Android, an app built without `enableAppleMusic`. */
  available: boolean
  authorization: MusicAuthorization
  /** `appleMusic`, or `simulated` for the simulator's stand-in; null without access. */
  source: 'appleMusic' | 'simulated' | null
  playbackState: MusicPlaybackState
  isPlaying: boolean
  itemId: string | null
  title: string | null
  artist: string | null
  album: string | null
  /** Seconds. */
  duration: number | null
  /** Seconds into the song at `timestamp`. */
  position: number | null
  /** A small square JPEG (120 px) as a data URL, when the song has artwork. */
  artworkDataURL: string | null
  /** Some app is playing audio, Apple Music included: read it beside `isPlaying`. */
  otherAudioPlaying: boolean
  /** When the snapshot was taken, in ms since the epoch. */
  timestamp: number
}

export interface MusicSkipOptions {
  /**
   * Past this many seconds into a song, go back to its start instead of the
   * previous song, as the Music app's own button does. 3 by default; 0
   * always goes to the previous song.
   */
  restartAfter?: number
}

export type MusicMethod = 'getAuthorizationStatus' | 'requestAuthorization' | 'getNowPlaying' | 'play' | 'pause' | 'togglePlayPause' | 'skipToNext' | 'skipToPrevious' | 'observe'

const MUSIC_AUTHORIZATIONS: readonly MusicAuthorization[] = ['authorized', 'denied', 'restricted', 'notDetermined', 'unavailable']
const MUSIC_STATES: readonly MusicPlaybackState[] = ['stopped', 'playing', 'paused', 'interrupted', 'seekingForward', 'seekingBackward', 'unknown']

function musicAuthorization(value: unknown): MusicAuthorization {
  return MUSIC_AUTHORIZATIONS.includes(value as MusicAuthorization) ? value as MusicAuthorization : 'unavailable'
}

function musicText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null
}

function musicSeconds(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null
}

/** A snapshot from native, made safe to render whatever an older or newer build sent. */
export function normalizeNowPlaying(value: unknown): NowPlaying {
  const raw = (value && typeof value === 'object' ? value : {}) as Record<string, unknown>
  const playbackState = MUSIC_STATES.includes(raw.playbackState as MusicPlaybackState) ? raw.playbackState as MusicPlaybackState : 'unknown'
  const artwork = musicText(raw.artworkDataURL)
  return {
    available: raw.available !== false && Object.keys(raw).length > 0,
    authorization: musicAuthorization(raw.authorization),
    source: raw.source === 'appleMusic' || raw.source === 'simulated' ? raw.source : null,
    playbackState,
    isPlaying: raw.isPlaying === true,
    itemId: musicText(raw.itemId),
    title: musicText(raw.title),
    artist: musicText(raw.artist),
    album: musicText(raw.album),
    duration: musicSeconds(raw.duration),
    position: musicSeconds(raw.position),
    // Only an image the bridge drew; never a URL a page could be pointed at.
    artworkDataURL: artwork && artwork.startsWith('data:image/') ? artwork : null,
    otherAudioPlaying: raw.otherAudioPlaying === true,
    timestamp: typeof raw.timestamp === 'number' && Number.isFinite(raw.timestamp) ? raw.timestamp : Date.now(),
  }
}

function nothingPlaying(): NowPlaying {
  return normalizeNowPlaying({ available: false, authorization: 'unavailable' })
}

function nativeMusic(): any {
  const craft = getCraftRoot()
  if (!craft?.music || craft.capabilities?.music === false) return undefined
  return craft.music
}

interface MusicWatch {
  listeners: Set<(nowPlaying: NowPlaying) => void>
  stop: (() => void) | null
}

const musicWatch: MusicWatch = { listeners: new Set(), stop: null }

function startMusicWatch(native: any): void {
  if (musicWatch.stop || typeof window === 'undefined') return
  const onChange = (event: Event) => {
    const nowPlaying = normalizeNowPlaying((event as CustomEvent<unknown>).detail)
    for (const listener of [...musicWatch.listeners]) {
      try {
        listener(nowPlaying)
      }
      catch {}
    }
  }
  window.addEventListener('craftMusicChange', onChange)
  void Promise.resolve(native.observe?.(true)).catch(() => {})
  musicWatch.stop = () => {
    window.removeEventListener('craftMusicChange', onChange)
    void Promise.resolve(native.observe?.(false)).catch(() => {})
  }
}

async function musicCommand(method: 'play' | 'pause' | 'togglePlayPause' | 'skipToNext' | 'skipToPrevious', options?: MusicSkipOptions): Promise<NowPlaying> {
  const native = nativeMusic()
  if (typeof native?.[method] !== 'function') return nothingPlaying()
  return normalizeNowPlaying(await native[method](options))
}

export const music = {
  /** Whether this app can show and steer the Music app. */
  isAvailable(): boolean {
    return typeof nativeMusic()?.getNowPlaying === 'function'
  },

  /** Whether this app build answers `method`; an older build may lack one. */
  supports(method: MusicMethod): boolean {
    return typeof nativeMusic()?.[method] === 'function'
  },

  /** Where access stands, without asking. `unavailable` off a phone. */
  async getAuthorizationStatus(): Promise<MusicAuthorization> {
    const native = nativeMusic()
    if (typeof native?.getAuthorizationStatus !== 'function') return 'unavailable'
    return musicAuthorization(await native.getAuthorizationStatus())
  },

  /**
   * Ask for media library access: iOS's prompt the first time, its
   * remembered answer after that. Call it from the person's own tap.
   */
  async requestAuthorization(): Promise<MusicAuthorization> {
    const native = nativeMusic()
    if (typeof native?.requestAuthorization !== 'function') return 'unavailable'
    return musicAuthorization(await native.requestAuthorization())
  },

  /** The song, its artwork and the playback state, as one snapshot. */
  async getNowPlaying(): Promise<NowPlaying> {
    const native = nativeMusic()
    if (typeof native?.getNowPlaying !== 'function') return nothingPlaying()
    return normalizeNowPlaying(await native.getNowPlaying())
  },

  /** Each resolves with the snapshot once the Music app has moved. */
  play: (): Promise<NowPlaying> => musicCommand('play'),
  pause: (): Promise<NowPlaying> => musicCommand('pause'),
  togglePlayPause: (): Promise<NowPlaying> => musicCommand('togglePlayPause'),
  skipToNext: (): Promise<NowPlaying> => musicCommand('skipToNext'),
  skipToPrevious: (options: MusicSkipOptions = {}): Promise<NowPlaying> => musicCommand('skipToPrevious', options),

  /**
   * Hear every change of song or playback state, pushed by native rather
   * than polled. The first listener starts native observation and the last
   * one to leave stops it. Off a phone it never fires.
   */
  onChange(callback: (nowPlaying: NowPlaying) => void): () => void {
    const native = nativeMusic()
    if (typeof native?.observe !== 'function') return () => {}
    musicWatch.listeners.add(callback)
    startMusicWatch(native)
    return () => {
      if (!musicWatch.listeners.delete(callback) || musicWatch.listeners.size > 0) return
      musicWatch.stop?.()
      musicWatch.stop = null
    }
  },
}

/*
 * A Bluetooth heart-rate strap, or a watch broadcasting its heart rate (the
 * standard Heart Rate Service every Polar, Garmin and Wahoo strap speaks).
 *
 * iOS and Android (`enableHeartRate`): scan for straps nearby, connect to one
 * (it is remembered, and `reconnect()` finds it again without a scan), hear
 * each reading with its RR intervals, and record the readings natively for a
 * workout: the recording keeps going with the screen locked or the web view
 * suspended (on Android, in a foreground service), and survives the app being
 * closed, like the route recording. Off a phone (a browser), or in a build
 * without the flag, `isAvailable()` is false, the state says
 * `available: false`, and nothing ever fires.
 */
export type HeartRateAuthorization = 'authorized' | 'denied' | 'restricted' | 'notDetermined' | 'unavailable'

export type BluetoothState = 'poweredOn' | 'poweredOff' | 'unauthorized' | 'unsupported' | 'resetting' | 'unknown'

export type HeartRateConnection = 'disconnected' | 'connecting' | 'connected' | 'reconnecting'

export interface HeartRateDevice {
  id: string
  name: string
  /** Signal strength, dBm; 0 for a strap the phone is already connected to. */
  rssi: number | null
}

export interface HeartRateRecordingState {
  id: string | null
  active: boolean
  paused: boolean
  /** ms since the epoch. */
  startedAt: number | null
  sampleCount: number | null
}

export interface HeartRateState {
  /** False off a phone, in a build without `enableHeartRate`, or on a phone without Bluetooth. */
  available: boolean
  bluetooth: BluetoothState
  authorization: HeartRateAuthorization
  scanning: boolean
  connection: HeartRateConnection
  /** The strap connected, or being connected to. */
  device: HeartRateDevice | null
  /** The strap `reconnect()` asks for. */
  lastDevice: HeartRateDevice | null
  /** The latest reading while it is fresh (ten seconds), else null. */
  bpm: number | null
  lastReadingAt: number | null
  recording: HeartRateRecordingState
}

export interface HeartRateReading {
  bpm: number
  /** Milliseconds between beats, oldest first; empty when the strap sends none. */
  rrIntervals: number[]
  /** Whether the strap touches skin; null when it cannot tell. */
  contact: boolean | null
  energyExpended: number | null
  /** ms since the epoch. */
  timestamp: number
  deviceId: string | null
}

/** A reading as a recording keeps it. */
export interface HeartRateSample {
  /** ms since the epoch. */
  timestamp: number
  bpm: number
  /** Milliseconds between beats, when the strap sent them. */
  rr?: number[]
}

export type HeartRateMethod = 'getState' | 'requestAuthorization' | 'scan' | 'stopScan' | 'getDevices' | 'connect' | 'reconnect' | 'disconnect'
  | 'startRecording' | 'pauseRecording' | 'resumeRecording' | 'stopRecording' | 'getRecordingState' | 'readRecording' | 'acknowledgeRecording'

const HR_AUTHORIZATIONS: readonly HeartRateAuthorization[] = ['authorized', 'denied', 'restricted', 'notDetermined', 'unavailable']
const HR_BLUETOOTH: readonly BluetoothState[] = ['poweredOn', 'poweredOff', 'unauthorized', 'unsupported', 'resetting', 'unknown']
const HR_CONNECTIONS: readonly HeartRateConnection[] = ['disconnected', 'connecting', 'connected', 'reconnecting']

function hrRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

function hrNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/** A heart rate a strap could really give, whole beats. */
function hrBpm(value: unknown): number | null {
  const bpm = hrNumber(value)
  return bpm !== null && bpm >= 20 && bpm <= 250 ? Math.round(bpm) : null
}

function hrIntervals(value: unknown): number[] {
  return Array.isArray(value) ? value.filter((ms): ms is number => typeof ms === 'number' && Number.isFinite(ms) && ms > 0 && ms < 5000) : []
}

export function normalizeHeartRateDevice(value: unknown): HeartRateDevice | null {
  const raw = hrRecord(value)
  if (typeof raw.id !== 'string' || !raw.id) return null
  return { id: raw.id, name: typeof raw.name === 'string' && raw.name.trim() ? raw.name : 'Heart rate monitor', rssi: hrNumber(raw.rssi) }
}

function normalizeHeartRateRecording(value: unknown): HeartRateRecordingState {
  const raw = hrRecord(value)
  return {
    id: typeof raw.id === 'string' ? raw.id : null,
    active: raw.active === true,
    paused: raw.paused === true,
    startedAt: hrNumber(raw.startedAt),
    sampleCount: hrNumber(raw.sampleCount),
  }
}

/** A state from native, made safe to render whatever an older or newer build sent. */
export function normalizeHeartRateState(value: unknown): HeartRateState {
  const raw = hrRecord(value)
  return {
    available: raw.available !== false && Object.keys(raw).length > 0,
    bluetooth: HR_BLUETOOTH.includes(raw.bluetooth as BluetoothState) ? raw.bluetooth as BluetoothState : 'unknown',
    authorization: HR_AUTHORIZATIONS.includes(raw.authorization as HeartRateAuthorization) ? raw.authorization as HeartRateAuthorization : 'unavailable',
    scanning: raw.scanning === true,
    connection: HR_CONNECTIONS.includes(raw.connection as HeartRateConnection) ? raw.connection as HeartRateConnection : 'disconnected',
    device: normalizeHeartRateDevice(raw.device),
    lastDevice: normalizeHeartRateDevice(raw.lastDevice),
    bpm: hrBpm(raw.bpm),
    lastReadingAt: hrNumber(raw.lastReadingAt),
    recording: normalizeHeartRateRecording(raw.recording),
  }
}

/** A reading event's detail, or null for one that is not a usable reading. */
export function normalizeHeartRateReading(value: unknown): HeartRateReading | null {
  const raw = hrRecord(value)
  const bpm = hrBpm(raw.bpm)
  if (bpm === null) return null
  return {
    bpm,
    rrIntervals: hrIntervals(raw.rrIntervals),
    contact: typeof raw.contact === 'boolean' ? raw.contact : null,
    energyExpended: hrNumber(raw.energyExpended),
    timestamp: hrNumber(raw.timestamp) ?? Date.now(),
    deviceId: typeof raw.deviceId === 'string' ? raw.deviceId : null,
  }
}

/** A recording's samples, oldest first, one per timestamp, implausible ones left out. */
export function normalizeHeartRateSamples(value: unknown): HeartRateSample[] {
  if (!Array.isArray(value)) return []
  const seen = new Set<number>()
  const samples: HeartRateSample[] = []
  for (const item of value) {
    const raw = hrRecord(item)
    const timestamp = hrNumber(raw.timestamp)
    const bpm = hrBpm(raw.bpm)
    if (timestamp === null || bpm === null || seen.has(timestamp)) continue
    seen.add(timestamp)
    const rr = hrIntervals(raw.rr)
    samples.push(rr.length ? { timestamp, bpm, rr } : { timestamp, bpm })
  }
  return samples.sort((a, b) => a.timestamp - b.timestamp)
}

function noHeartRate(): HeartRateState {
  return normalizeHeartRateState({ available: false })
}

function nativeHeartRate(): any {
  const craft = getCraftRoot()
  if (!craft?.heartRate || craft.capabilities?.heartRate === false) return undefined
  return craft.heartRate
}

interface HeartRateWatch {
  readings: Set<(reading: HeartRateReading) => void>
  devices: Set<(device: HeartRateDevice) => void>
  states: Set<(state: HeartRateState) => void>
  stop: (() => void) | null
}

const heartRateWatch: HeartRateWatch = { readings: new Set(), devices: new Set(), states: new Set(), stop: null }

function hrNotify<T>(listeners: Set<(value: T) => void>, value: T): void {
  for (const listener of [...listeners]) {
    try {
      listener(value)
    }
    catch {}
  }
}

/** One window listener for every subscriber, there while anyone listens. */
function hrSubscribe<T>(set: Set<(value: T) => void>, callback: (value: T) => void): () => void {
  if (!nativeHeartRate() || typeof window === 'undefined') return () => {}
  set.add(callback)
  if (!heartRateWatch.stop) {
    const onEvent = (event: Event) => {
      const detail = hrRecord((event as CustomEvent<unknown>).detail)
      if (detail.type === 'reading') {
        const reading = normalizeHeartRateReading(detail)
        if (reading) hrNotify(heartRateWatch.readings, reading)
      }
      else if (detail.type === 'device') {
        const device = normalizeHeartRateDevice(detail.device)
        if (device) hrNotify(heartRateWatch.devices, device)
      }
      else if (detail.type === 'state') {
        hrNotify(heartRateWatch.states, normalizeHeartRateState(detail))
      }
    }
    window.addEventListener('craftHeartRate', onEvent)
    heartRateWatch.stop = () => window.removeEventListener('craftHeartRate', onEvent)
  }
  return () => {
    if (!set.delete(callback)) return
    if (heartRateWatch.readings.size + heartRateWatch.devices.size + heartRateWatch.states.size > 0) return
    heartRateWatch.stop?.()
    heartRateWatch.stop = null
  }
}

async function heartRateCall<T>(method: HeartRateMethod, fallback: () => T, normalize: (value: unknown) => T, ...args: unknown[]): Promise<T> {
  const native = nativeHeartRate()
  if (typeof native?.[method] !== 'function') return fallback()
  return normalize(await native[method](...args))
}

const noRecording = (): HeartRateRecordingState => normalizeHeartRateRecording({})

export const heartRate = {
  supportsRecordingOwnership: (): boolean => recordingOwnershipSupported('heartRate'),
  supportsRecordingIntentIdentity: (): boolean => recordingIntentSupported('heartRate'),
  /** Whether this app can read a heart-rate strap. */
  isAvailable(): boolean {
    return typeof nativeHeartRate()?.getState === 'function'
  },

  /** Whether this app build answers `method`; an older build may lack one. */
  supports(method: HeartRateMethod): boolean {
    return typeof nativeHeartRate()?.[method] === 'function'
  },

  /** Bluetooth, the connection, the strap and its latest reading, without asking anything. */
  getState: (): Promise<HeartRateState> => heartRateCall('getState', noHeartRate, normalizeHeartRateState),

  /**
   * Ask for Bluetooth: the system's prompt the first time (iOS's, or
   * Android's Nearby devices), its remembered answer after that. Scanning and connecting ask too; call this from the person's
   * tap to ask first.
   */
  requestAuthorization: (): Promise<HeartRateAuthorization> => heartRateCall('requestAuthorization', () => 'unavailable' as const,
    value => HR_AUTHORIZATIONS.includes(value as HeartRateAuthorization) ? value as HeartRateAuthorization : 'unavailable'),

  /** Look for straps for `timeout` seconds (15 by default); `onDevice` hears each one. */
  scan: (options: { timeout?: number } = {}): Promise<HeartRateState> => heartRateCall('scan', noHeartRate, normalizeHeartRateState, options),
  stopScan: (): Promise<HeartRateState> => heartRateCall('stopScan', noHeartRate, normalizeHeartRateState),

  /** What the last scan found, strongest signal first. */
  getDevices: (): Promise<HeartRateDevice[]> => heartRateCall('getDevices', () => [], value => Array.isArray(value)
    ? value.map(normalizeHeartRateDevice).filter((device): device is HeartRateDevice => device !== null)
    : []),

  /**
   * Connect to a strap from `scan` and subscribe to its readings; it is
   * remembered for `reconnect()`. Rejects with code TIMEOUT when it does not
   * answer within 15 s, while still asking for it: a strap wakes up when worn.
   */
  connect: (id: string): Promise<HeartRateState> => heartRateCall('connect', noHeartRate, normalizeHeartRateState, id),

  /** Ask for the remembered strap again, without waiting for it. */
  reconnect: (): Promise<HeartRateState> => heartRateCall('reconnect', noHeartRate, normalizeHeartRateState),

  /** Stop asking for the strap; `forget` also drops it from memory. */
  disconnect: (options: { forget?: boolean } = {}): Promise<HeartRateState> => heartRateCall('disconnect', noHeartRate, normalizeHeartRateState, options),

  /** Keep every reading natively from now on: screen locked, page suspended or app closed. */
  async startRecording(options?: RecordingStartOptions): Promise<HeartRateRecordingState> {
    const supplied = options ?? {}
    validateRecordingStart('heartRate', supplied)
    return verifyRecordingStart(supplied, await heartRateCall('startRecording', noRecording, normalizeHeartRateRecording, ...(options === undefined ? [] : [options])))
  },
  async pauseRecording(options?: RecordingOwnershipOptions): Promise<HeartRateRecordingState> {
    validateRecordingOwnership('heartRate', options)
    return heartRateCall('pauseRecording', noRecording, normalizeHeartRateRecording, ...(options === undefined ? [] : [options]))
  },
  async resumeRecording(options?: RecordingOwnershipOptions): Promise<HeartRateRecordingState> {
    validateRecordingOwnership('heartRate', options)
    return heartRateCall('resumeRecording', noRecording, normalizeHeartRateRecording, ...(options === undefined ? [] : [options]))
  },

  /** Ends the recording and hands back every reading it kept. */
  async stopRecording(options?: RecordingOwnershipOptions): Promise<HeartRateRecordingState & { samples: HeartRateSample[] }> {
    validateRecordingOwnership('heartRate', options)
    return heartRateCall('stopRecording', () => ({ ...noRecording(), samples: [] }),
      value => ({ ...normalizeHeartRateRecording(value), samples: normalizeHeartRateSamples(hrRecord(value).samples) }), ...(options === undefined ? [] : [options]))
  },

  async getRecordingState(options?: RecordingOwnershipOptions): Promise<HeartRateRecordingState> {
    validateRecordingOwnership('heartRate', options)
    return heartRateCall('getRecordingState', noRecording, normalizeHeartRateRecording, ...(options === undefined ? [] : [options]))
  },
  async acknowledgeRecording(options: RecordingOwnershipOptions): Promise<boolean> {
    if (!options || !Object.prototype.hasOwnProperty.call(options, 'expectedId'))
      throw Object.assign(new Error('Acknowledgement needs expectedId'), { code: 'INVALID_ARGUMENT' })
    validateRecordingOwnership('heartRate', options)
    return heartRateCall('acknowledgeRecording', () => false, value => value === true, options)
  },

  /** The recording so far; only what came after `since` (ms) when given. */
  async readRecording(options: { since?: number, expectedId?: string } = {}): Promise<HeartRateSample[]> {
    validateRecordingOwnership('heartRate', options)
    return heartRateCall('readRecording', () => [], normalizeHeartRateSamples, options)
  },

  /** Every reading from the connected strap, about once a second. */
  onReading: (callback: (reading: HeartRateReading) => void): (() => void) => hrSubscribe(heartRateWatch.readings, callback),
  /** Each strap a scan finds. */
  onDevice: (callback: (device: HeartRateDevice) => void): (() => void) => hrSubscribe(heartRateWatch.devices, callback),
  /** Bluetooth, scanning or the connection changed. */
  onState: (callback: (state: HeartRateState) => void): (() => void) => hrSubscribe(heartRateWatch.states, callback),
}

// ============================================================================
// Scheduled workouts (Apple Watch, WorkoutKit)
// ============================================================================

/**
 * Structured workouts scheduled onto the paired Apple Watch (iOS 17+, an app
 * built with `enableScheduledWorkouts`): each appears in the watch's Workout
 * app on its day, with its steps, goals and alerts. Plain JSON in SI units.
 * In a browser, on Android and in a build without the capability
 * `isSupported()` answers false and every other call rejects with
 * `unsupported` (code `UNSUPPORTED`).
 */
export type ScheduledWorkoutsAuthorization = 'authorized' | 'denied' | 'notDetermined' | 'restricted' | 'unsupported'

export type AppleWorkoutGoal =
  | { type: 'open' }
  | { type: 'time', seconds: number }
  | { type: 'distance', meters: number }
  | { type: 'energy', kilocalories: number }

export type AppleWorkoutAlert =
  /** Beats per minute. */
  | { type: 'heartRate', min: number, max: number }
  | { type: 'heartRateZone', zone: number }
  /** Watts. */
  | { type: 'power', min: number, max: number }
  | { type: 'powerZone', zone: number }
  /** Metres per second (the current speed); a pace range is sent as speed. */
  | { type: 'speed', min: number, max: number }
  /** Steps or revolutions per minute. */
  | { type: 'cadence', min: number, max: number }

export interface AppleWorkoutStep {
  goal: AppleWorkoutGoal
  /** Dropped (the step kept) when WorkoutKit refuses it for the activity. */
  alert?: AppleWorkoutAlert
  /** Shown on the watch from iOS 18; ignored on 17. At most 64 characters. */
  displayName?: string
}

export interface AppleIntervalBlock {
  /** 1 or more. */
  iterations: number
  steps: Array<{ purpose: 'work' | 'recovery', step: AppleWorkoutStep }>
}

export interface AppleCustomWorkout {
  /** An HKWorkoutActivityType case name: 'running', 'cycling', 'swimming', 'traditionalStrengthTraining'... */
  activity: string
  location: 'indoor' | 'outdoor' | 'unknown'
  /** Swimming only: a pool swim is scheduled indoor, open water outdoor, when `location` is 'unknown'. */
  swimmingLocation?: 'pool' | 'openWater'
  /** Accepted for the record; WorkoutKit takes no pool length (the watch asks when the swim starts). */
  poolLengthMeters?: number
  displayName: string
  warmup?: AppleWorkoutStep
  cooldown?: AppleWorkoutStep
  blocks: AppleIntervalBlock[]
}

export interface AppleWorkoutPlan {
  /** A UUID; the plan's identity on the watch. */
  id: string
  /** The local calendar day, 'YYYY-MM-DD'. */
  date: string
  /** Local time of day, 07:00 when not given. */
  hour?: number
  minute?: number
  workout: AppleCustomWorkout
}

/** A plan on the watch's schedule. */
export interface ScheduledWorkout {
  /** Lowercase UUID. */
  id: string
  date: string
  hour?: number
  minute?: number
  /** The person has done it. */
  complete: boolean
}

export interface ScheduleWorkoutResult {
  id: string
  /** Alerts WorkoutKit refused and left out, each by where it was ("block 1 step 2: power alert..."). */
  droppedAlerts?: string[]
}

export type ScheduledWorkoutsMethod = 'isSupported' | 'authorization' | 'requestAuthorization' | 'list' | 'schedule' | 'remove' | 'removeAll'

const SCHEDULED_AUTHORIZATIONS: ScheduledWorkoutsAuthorization[] = ['authorized', 'denied', 'notDetermined', 'restricted', 'unsupported']

function nativeScheduledWorkouts(): any {
  const craft = getCraftRoot()
  if (!craft?.scheduledWorkouts || craft.capabilities?.scheduledWorkouts !== true) return undefined
  return craft.scheduledWorkouts
}

/** The rejection every call but isSupported() gets where nothing can schedule. */
export function scheduledWorkoutsUnsupported(): Error {
  return Object.assign(new Error('unsupported'), { code: 'UNSUPPORTED' })
}

function scheduledAuthorization(value: unknown): ScheduledWorkoutsAuthorization {
  return SCHEDULED_AUTHORIZATIONS.includes(value as ScheduledWorkoutsAuthorization) ? value as ScheduledWorkoutsAuthorization : 'unsupported'
}

/** A row of `list()`, or null for one that is not a scheduled plan. */
export function normalizeScheduledWorkout(value: unknown): ScheduledWorkout | null {
  if (!value || typeof value !== 'object') return null
  const row = value as Record<string, unknown>
  if (typeof row.id !== 'string' || !row.id || typeof row.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(row.date)) return null
  const out: ScheduledWorkout = { id: row.id.toLowerCase(), date: row.date, complete: row.complete === true }
  if (typeof row.hour === 'number' && Number.isFinite(row.hour)) out.hour = row.hour
  if (typeof row.minute === 'number' && Number.isFinite(row.minute)) out.minute = row.minute
  return out
}

async function scheduledCall<T>(method: ScheduledWorkoutsMethod, normalize: (value: unknown) => T, ...args: unknown[]): Promise<T> {
  const native = nativeScheduledWorkouts()
  if (typeof native?.[method] !== 'function') throw scheduledWorkoutsUnsupported()
  return normalize(await native[method](...args))
}

export const scheduledWorkouts = {
  /** Whether this app build has the bridge at all (not whether this phone can schedule: `isSupported()`). */
  isAvailable(): boolean {
    return typeof nativeScheduledWorkouts()?.isSupported === 'function'
  },

  /** Whether this app build answers `method`; an older build may lack one. */
  supports(method: ScheduledWorkoutsMethod): boolean {
    return typeof nativeScheduledWorkouts()?.[method] === 'function'
  },

  /** iOS 17 or later and WorkoutKit can schedule here; false everywhere else, never rejects. */
  async isSupported(): Promise<boolean> {
    const native = nativeScheduledWorkouts()
    if (typeof native?.isSupported !== 'function') return false
    try {
      return await native.isSupported() === true
    }
    catch {
      return false
    }
  },

  /** What the person allowed, without asking. */
  authorization: (): Promise<ScheduledWorkoutsAuthorization> => scheduledCall('authorization', scheduledAuthorization),

  /** iOS's prompt the first time; its remembered answer after that. Call it from the person's tap. */
  requestAuthorization: (): Promise<ScheduledWorkoutsAuthorization> => scheduledCall('requestAuthorization', scheduledAuthorization),

  /** Every plan on the watch's schedule. */
  list: (): Promise<ScheduledWorkout[]> => scheduledCall('list', value => Array.isArray(value)
    ? value.map(normalizeScheduledWorkout).filter((row): row is ScheduledWorkout => row !== null)
    : []),

  /**
   * Put a plan on the watch's schedule (again on another day moves it).
   * Rejects with a message naming what WorkoutKit refused: an activity or a
   * goal it cannot schedule (an alert it refuses is dropped instead, listed in
   * `droppedAlerts`), more plans than the watch holds (LIMIT_REACHED), or a
   * schedule nothing kept, such as no paired watch (NOT_SCHEDULED).
   */
  schedule: (plan: AppleWorkoutPlan): Promise<ScheduleWorkoutResult> => {
    if (!plan || typeof plan !== 'object' || typeof plan.id !== 'string')
      return Promise.reject(Object.assign(new Error('schedule needs a plan with an id'), { code: 'INVALID_ARGUMENT' }))
    return scheduledCall('schedule', (value) => {
      const row = (value && typeof value === 'object' ? value : {}) as Record<string, unknown>
      const out: ScheduleWorkoutResult = { id: typeof row.id === 'string' ? row.id.toLowerCase() : plan.id.toLowerCase() }
      if (Array.isArray(row.droppedAlerts) && row.droppedAlerts.length)
        out.droppedAlerts = row.droppedAlerts.filter((item): item is string => typeof item === 'string')
      return out
    }, plan)
  },

  /** Take a plan off every day it is scheduled; true when there was one. */
  remove: (id: string): Promise<boolean> => scheduledCall('remove', value => value === true, id),

  /** Clear the schedule; how many plans it held. */
  removeAll: (): Promise<number> => scheduledCall('removeAll', value => typeof value === 'number' && Number.isFinite(value) ? value : 0),
}

export const deepLinks = {
  async getInitialURL(): Promise<string | null> {
    return normalizeDeepLinkURL(await getCraftRoot()?.deepLinks?.getInitialURL?.())
  },
  /**
   * The second argument says whether this is the link that launched the app.
   * A page that also calls `getInitialURL()` after an await gets that link
   * from both, and can skip it here when `initial` is true.
   */
  onLink(callback: (url: string, link: { initial: boolean }) => void): () => void {
    const craft = getCraftRoot()
    if (craft?.deepLinks?.onLink) {
      return craft.deepLinks.onLink((value: unknown) => {
        const url = normalizeDeepLinkURL(value)
        if (url) callback(url, { initial: (value as { initial?: unknown } | null)?.initial === true })
      }) ?? (() => {})
    }
    if (typeof globalThis === 'undefined') return () => {}
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail
      const url = normalizeDeepLinkURL(detail)
      if (url) callback(url, { initial: (detail as { initial?: unknown } | null)?.initial === true })
    }
    globalThis.addEventListener('craftDeepLink', listener)
    return () => globalThis.removeEventListener('craftDeepLink', listener)
  }
}

export function normalizeDeepLinkURL(value: unknown): string | null {
  if (typeof value === 'string') return value.trim() || null
  if (!value || typeof value !== 'object') return null
  const url = (value as { url?: unknown }).url
  return typeof url === 'string' && url.trim() ? url : null
}

export const network = {
  async getStatus(): Promise<NetworkStatus> {
    const craft = getCraftRoot()
    if (craft?.getNetworkStatus) return await craft.getNetworkStatus()
    return {
      type: 'unknown',
      isConnected: typeof navigator === 'undefined' ? false : navigator.onLine,
    }
  },
  onChange(callback: (status: NetworkStatus) => void): () => void {
    const craft = getCraftRoot()
    if (craft?.onNetworkChange) {
      craft.onNetworkChange(callback)
      return () => craft.offNetworkChange?.()
    }
    if (typeof globalThis === 'undefined') return () => {}
    const listener = () => callback({ type: 'unknown', isConnected: navigator.onLine })
    globalThis.addEventListener('online', listener)
    globalThis.addEventListener('offline', listener)
    return () => {
      globalThis.removeEventListener('online', listener)
      globalThis.removeEventListener('offline', listener)
    }
  }
}

/** A tab the native tab bar shows. */
export interface NativeTab {
  /** Comes back in `onSelect` when the tab is tapped. */
  id: string
  title: string
  /** An SF Symbol name, such as `calendar`; the current tab draws its `.fill` variant when there is one. */
  symbol: string
  /** A count on the icon; empty draws none. */
  badge?: string
}

export interface NativeTabBarOptions {
  /** The current tab's id. */
  selected?: string
  /** The current tab's colour, as `#rrggbb`; the system's label colour if unset. */
  tint?: string
  tintDark?: string
  /** Whether Craft's horizontal tab-switch gesture may begin over the page. Defaults to true. */
  swipeEnabled?: boolean
  /** The selected tab highlight. Omit to keep the default capsule. */
  selection?: {
    /** Continuous corner radius in points. The highlight height is the upper bound. */
    cornerRadius?: number
  }
}

interface ChromeHandler { postMessage: (message: unknown) => void }

/**
 * The shell's chrome channel, there from the first byte of the document.
 * `window.craft` is installed only once the page has loaded, too late for a
 * tab bar or a splash.
 */
function chromeHandler(): ChromeHandler | null {
  if (typeof window === 'undefined') return null
  const handler = (window as any).webkit?.messageHandlers?.craftChrome
  return handler && typeof handler.postMessage === 'function' ? handler : null
}

function postChrome(message: Record<string, unknown>): boolean {
  const handler = chromeHandler()
  if (!handler) return false
  try {
    handler.postMessage(message)
    return true
  }
  catch {
    return false
  }
}

/**
 * The phone's own tab bar, floating over the page: Liquid Glass on iOS 26 and
 * later. The page describes it and keeps it on the current tab; a tap comes
 * back through `onSelect` for the page to navigate. Where there is no native
 * bar (a browser, Android for now), `isAvailable()` is false and every call is
 * a no-op answering false, so the page draws its own.
 *
 * While the bar shows, `--craft-tab-bar-height` on the root element says how
 * much of the screen's bottom it covers.
 */
export const tabBar = {
  isAvailable(): boolean {
    return chromeHandler() !== null
  },
  set(tabs: NativeTab[], options: NativeTabBarOptions = {}): boolean {
    return postChrome({ type: 'tabBar', tabs, ...options })
  },
  select(id: string): boolean {
    return postChrome({ type: 'selectTab', id })
  },
  hide(): boolean {
    return postChrome({ type: 'hideTabBar' })
  },
  onSelect(callback: (id: string) => void): () => void {
    if (typeof window === 'undefined') return () => {}
    const listener = (event: Event) => {
      const id = (event as CustomEvent<{ id?: unknown }>).detail?.id
      if (typeof id === 'string') callback(id)
    }
    window.addEventListener('craftTabSelect', listener)
    return () => window.removeEventListener('craftTabSelect', listener)
  },
}

/**
 * The launch splash, which the shell holds over the page until the page says
 * it is ready, so the app goes from its launch screen to content with no blank
 * page in between. Call `hide()` once the first screen has painted. The shell
 * hides it anyway once the page's first contentful paint is on screen, and
 * after `splashMaxSeconds` (three by default) at most.
 */
export const splash = {
  hide(): boolean {
    return postChrome({ type: 'ready' })
  },
}

// ============================================================================
// Hybrid apps: native screens beside the page (iOS)
// ============================================================================

/**
 * The shell's hybrid channel, present only in an app that mixes native
 * screens into its page (`nativeScreens` in craft.config.json).
 */
function hybridHandler(): ChromeHandler | null {
  if (typeof window === 'undefined') return null
  const handler = (window as any).webkit?.messageHandlers?.craftHybrid
  return handler && typeof handler.postMessage === 'function' ? handler : null
}

function postHybrid(message: Record<string, unknown>): boolean {
  const handler = hybridHandler()
  if (!handler) return false
  try {
    handler.postMessage(message)
    return true
  }
  catch {
    return false
  }
}

/** Letters, digits, `.`, `_` and `-`, not starting with a dot: the names the shell accepts. */
export function isSnapshotName(name: string): boolean {
  return typeof name === 'string' && /^[A-Za-z0-9_-][\w.-]{0,127}$/.test(name)
}

/**
 * Data the page keeps for its native screens. A native screen reads a
 * snapshot synchronously before its first frame (`craft.snapshots.get(name)`),
 * so it opens on the last data the page saw instead of an empty skeleton.
 * Write one whenever the page has fresh data a native screen shows.
 *
 * Each is `Application Support/craft-snapshots/<name>.json` in the app.
 * Outside a hybrid app every call is a no-op answering false.
 */
export const snapshots = {
  isAvailable(): boolean {
    return hybridHandler() !== null
  },
  /** Keep `value` (anything JSON can hold) as `name`. Answers whether it was handed to the shell. */
  set(name: string, value: unknown): boolean {
    if (!isSnapshotName(name)) throw new TypeError(`Snapshot names are letters, digits, ".", "_" and "-": ${String(name)}`)
    const json = JSON.stringify(value)
    if (json === undefined) throw new TypeError(`Snapshot ${name} is not JSON`)
    return postHybrid({ type: 'snapshotSet', name, json })
  },
  remove(name: string): boolean {
    if (!isSnapshotName(name)) return false
    return postHybrid({ type: 'snapshotRemove', name })
  },
  /** Every snapshot, as on signing out. */
  clear(): boolean {
    return postHybrid({ type: 'snapshotClear' })
  },
}

interface HybridPageScript {
  match: (url: string) => { path: string, screen: string, params: Record<string, string> } | null
}

function hybridPage(): HybridPageScript | undefined {
  if (typeof window === 'undefined') return undefined
  const page = (window as any).__craftHybrid
  return page && typeof page.match === 'function' ? page : undefined
}

/**
 * Navigation between the page and the app's native screens.
 *
 * The shell already hands the stx router's navigations to native paths to
 * the native screens, and Back at the entry a native screen opened goes back
 * to it, so most pages need none of this. It is for code that navigates
 * without the router.
 */
export const hybrid = {
  /** Whether this page runs inside a hybrid app. */
  isActive(): boolean {
    return hybridHandler() !== null
  },
  /** The native screen `path` opens, or null when it is the page's. */
  nativeScreenFor(path: string): { path: string, screen: string, params: Record<string, string> } | null {
    return hybridPage()?.match(path) ?? null
  },
  /** Open `path` as the shell would: a tab, a native screen, or the page pushed. */
  open(path: string): boolean {
    if (typeof path !== 'string' || !path.startsWith('/')) throw new TypeError(`hybrid.open needs an app path: ${String(path)}`)
    return postHybrid({ type: 'open', path })
  },
  /** Back to the native screen under this page, when there is one. */
  back(): boolean {
    return postHybrid({ type: 'back' })
  },
}

// ============================================================================
// Native UI: dialogs, menus, the in-app browser, symbols, and chrome (iOS)
// ============================================================================

/** A rect in the viewport's CSS pixels. */
export interface NativeRect {
  x: number
  y: number
  width: number
  height: number
}

/** Where a popover, sheet or menu points: a rect, or an element to point at. */
export type NativeAnchor = NativeRect | { getBoundingClientRect(): { left: number, top: number, width: number, height: number } }

export interface DialogAlertOptions {
  title: string
  message?: string
  /** The button. The system's own "OK" if unset. */
  okLabel?: string
}

export interface DialogConfirmOptions {
  title: string
  message?: string
  /** The confirming button. The system's own "OK" if unset. */
  confirmLabel?: string
  /** The system's own "Cancel" if unset. */
  cancelLabel?: string
  /** Paints the confirming button red, as iOS does for a delete. */
  destructive?: boolean
}

export interface ActionSheetAction {
  id: string
  title: string
  /** `cancel` answers `null` whatever its id. */
  style?: 'default' | 'destructive' | 'cancel'
}

export interface ActionSheetOptions {
  title?: string
  message?: string
  actions: ActionSheetAction[]
  /** Where the sheet points on iPad (and, from iOS 26, on iPhone). */
  anchor?: NativeAnchor
}

export interface ContextMenuItem {
  id: string
  title: string
  /** An SF Symbol name, such as `trash`. */
  symbol?: string
  destructive?: boolean
  disabled?: boolean
}

export interface ContextMenuOptions {
  items: ContextMenuItem[]
  anchor: NativeAnchor
  title?: string
}

export interface BrowserOpenOptions {
  /** `safari`: SFSafariViewController in the app. `auth`: the system's web sign-in sheet. */
  mode?: 'safari' | 'auth'
  /** For `auth`: the URL scheme the provider redirects back to. */
  callbackScheme?: string
}

export interface BrowserOpenResult {
  /** For `auth`: the callback URL the provider redirected to. */
  url?: string
  cancelled: boolean
  error?: string
}

export type SymbolWeight = 'ultraLight' | 'thin' | 'light' | 'regular' | 'medium' | 'semibold' | 'bold' | 'heavy' | 'black'

export interface SymbolImageOptions {
  /** Default 17. */
  pointSize?: number
  weight?: SymbolWeight
  /** A CSS colour. The label colour if unset. */
  color?: string
  scale?: 'small' | 'medium' | 'large'
}

export type StatusBarStyle = 'default' | 'light' | 'dark'

/** The reading and motion settings the page should match. */
export interface NativeAppearance {
  /** The Dynamic Type size, as UIKit names it: `large` is the default. */
  contentSizeCategory: string
  /** Body text's scale from its default size; also `--craft-font-scale` on the root element. */
  fontScale: number
  reduceMotion: boolean
  reduceTransparency: boolean
  colorScheme: 'light' | 'dark'
}

/** A `craftSilentPush` or `craftBackgroundRefresh`. */
export interface BackgroundWorkEvent {
  /** Pass to `background.complete` to answer this one. */
  id?: string
  /** The push's payload, for a silent push. */
  payload?: Record<string, unknown>
}

/**
 * Call a `window.craft` namespace method if the shell has it, settling with
 * `fallback` when it does not, when it fails, or when it answers nothing. The
 * new native UI never throws at a page: on the web every call resolves.
 */
interface NativeCallOptions {
  /** Log a bridge exception before returning the documented fallback value. */
  warnOnError?: boolean
}

async function callNative<T>(namespace: string, method: string, args: unknown[], fallback: T, options: NativeCallOptions = {}): Promise<T> {
  const target = getCraftRoot()?.[namespace]
  if (!target || typeof target[method] !== 'function') return fallback
  try {
    const value = await target[method](...args)
    return value === undefined || value === null ? fallback : value as T
  }
  catch (error) {
    if (options.warnOnError) {
      console.warn(`[craft] Native ${namespace}.${method} failed; using its fallback value.`, error)
    }
    return fallback
  }
}

function hasNative(namespace: string): boolean {
  return Boolean(getCraftRoot()?.[namespace])
}

/**
 * The system's alert, confirmation and action sheet. Off the iOS shell every
 * call resolves without showing anything (`confirm` with false, `actionSheet`
 * with null), so check `isAvailable()` to draw a web fallback.
 */
export const dialog = {
  isAvailable(): boolean {
    return hasNative('dialog')
  },
  async alert(options: DialogAlertOptions | string): Promise<void> {
    await callNative('dialog', 'alert', [options], undefined)
  },
  confirm(options: DialogConfirmOptions | string): Promise<boolean> {
    return callNative('dialog', 'confirm', [options], false)
  },
  /** The chosen action's id, or null when dismissed. */
  actionSheet(options: ActionSheetOptions): Promise<string | null> {
    return callNative<string | null>('dialog', 'actionSheet', [options], null, { warnOnError: true })
  },
}

/**
 * The system's context menu, anchored at a rect or element: the list with SF
 * Symbols a long press shows (iOS 17.4 and later; the edit menu, then an
 * action sheet, before). The chosen item's id, or null when dismissed.
 */
export const contextMenu = {
  isAvailable(): boolean {
    return hasNative('contextMenu')
  },
  show(options: ContextMenuOptions): Promise<string | null> {
    return callNative<string | null>('contextMenu', 'show', [options], null)
  },
}

/**
 * A page elsewhere without leaving the app: SFSafariViewController, or for
 * `mode: 'auth'` the system's web sign-in sheet, which answers with the
 * callback URL. On the web, `safari` opens a new tab and `auth` cannot catch
 * the callback, so it answers cancelled.
 */
export const browser = {
  isAvailable(): boolean {
    return hasNative('browser')
  },
  async open(url: string, options: BrowserOpenOptions = {}): Promise<BrowserOpenResult> {
    if (hasNative('browser')) return callNative<BrowserOpenResult>('browser', 'open', [url, options], { cancelled: true })
    if (options.mode !== 'auth' && typeof window !== 'undefined' && typeof window.open === 'function') {
      window.open(url, '_blank', 'noopener')
      return { cancelled: false }
    }
    return { cancelled: true }
  },
}

/** An SF Symbol rasterised to a PNG data URL, or null where there are none. */
export const symbols = {
  image(name: string, options: SymbolImageOptions = {}): Promise<string | null> {
    return callNative<string | null>('symbols', 'image', [name, options], null)
  },
}

/** The status bar's text: light, dark, or the system's choice for the app's appearance. */
export const statusBar = {
  setStyle(style: StatusBarStyle): Promise<boolean> {
    return callNative('statusBar', 'setStyle', [style], false)
  },
}

/** The shell's chrome around the page. */
export const chrome = {
  /** What shows past the page's edges when it rubber-bands (iOS 15). */
  setUnderPageColor(color: string): Promise<boolean> {
    return callNative('chrome', 'setUnderPageColor', [color], false)
  },
  /** WebKit's bar above the keyboard (previous, next, Done). Hidden by default. */
  setKeyboardAccessory(visible: boolean): Promise<boolean> {
    return callNative('chrome', 'setKeyboardAccessory', [visible], false)
  },
}

/**
 * The system's pull-to-refresh on the page's scroll view. A pull fires
 * `onRefresh`; call `end()` once the new content is in. It is removed when the
 * document changes, so a page enables it for itself.
 */
export const refresh = {
  isAvailable(): boolean {
    return hasNative('refresh')
  },
  enable(options: { tintColor?: string } = {}): Promise<boolean> {
    return callNative('refresh', 'enable', [options], false)
  },
  disable(): Promise<boolean> {
    return callNative('refresh', 'disable', [], false)
  },
  end(): Promise<boolean> {
    return callNative('refresh', 'end', [], false)
  },
  onRefresh(callback: () => void): () => void {
    return onCraftEvent('craftRefresh', () => callback())
  },
}

/**
 * Background time: a silent push (`content-available` on iOS, an FCM data
 * message on Android) and the scheduled refresh (`backgroundRefresh.enabled`
 * in the Craft config). Each event's detail carries an `id`; answer that one
 * with `complete(ok, id)` once its work is done. iOS ends a task the page has
 * not answered after 25 seconds.
 *
 * @example
 * ```typescript
 * background.onSilentPush(async ({ id, payload }) => {
 *   const ok = await sync(payload).then(() => true, () => false)
 *   await background.complete(ok, id)
 * })
 * ```
 */
export const background = {
  /**
   * Finish background work: `ok` is whether it succeeded (iOS reports it to
   * the system as the task's result). Pass the event's `id` to finish that
   * task alone; without one, every pending task finishes, which also ends a
   * refresh that is still working when a push's handler settles. Resolves
   * whether the host took the answer (false off a Craft shell).
   */
  complete(ok = true, id?: string): Promise<boolean> {
    return callNative('background', 'complete', [ok, id], false)
  },
  onRefresh(callback: (event: BackgroundWorkEvent) => void): () => void {
    return onCraftEvent('craftBackgroundRefresh', detail => callback(detail as BackgroundWorkEvent))
  },
  onSilentPush(callback: (event: BackgroundWorkEvent) => void): () => void {
    return onCraftEvent('craftSilentPush', detail => callback(detail as BackgroundWorkEvent))
  },
}

/**
 * Text size, Reduce Motion, Reduce Transparency and Light or Dark. In the iOS
 * shell from the native settings (Dynamic Type included, which a web page
 * cannot otherwise see); elsewhere from the media queries a browser has.
 */
export const appearance = {
  get(): NativeAppearance | null {
    const native = getCraftRoot()?.appearance
    if (native) return native as NativeAppearance
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return null
    return {
      contentSizeCategory: 'large',
      fontScale: 1,
      reduceMotion: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
      reduceTransparency: window.matchMedia('(prefers-reduced-transparency: reduce)').matches,
      colorScheme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
    }
  },
  onChange(callback: (appearance: NativeAppearance) => void): () => void {
    return onCraftEvent('craftAppearance', detail => callback(detail as unknown as NativeAppearance))
  },
}

export const appReview = {
  async request(): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.requestReview) return false
    return Boolean(await craft.requestReview())
  }
}

export const pushNotifications = {
  async register(): Promise<string> {
    const craft = getCraftRoot()
    if (!craft?.registerPush) throw new Error('Push notifications are unavailable')
    return craft.registerPush()
  },
  onToken(callback: (token: string) => void): () => void {
    return onCraftEvent('craftPushToken', detail => callback(String(detail.token ?? '')))
  },
  /**
   * A tap on a notification, with the payload it was sent with.
   *
   * Goes through the bridge's replay where there is one, so a tap that
   * launched the app still reaches a page that subscribes once it has
   * hydrated — rather than only one listening before the bridge was ready.
   */
  onNotification(callback: (data: Record<string, unknown>) => void): () => void {
    const craft = getCraftRoot()
    if (craft?.notifications?.onTap) {
      return craft.notifications.onTap((detail: unknown) => {
        callback((detail ?? {}) as Record<string, unknown>)
      }) ?? (() => {})
    }
    return onCraftEvent('craftNotificationResponse', detail => callback(detail))
  },
  /**
   * A notification that arrived while the app was open, with the payload it
   * was sent with — the same shape `onNotification` hands a tap.
   *
   * The banner still shows. This is for a page that wants to react while it
   * is on screen, such as refreshing what the push was about. Live only: an
   * arrival before the page subscribed is not held for it. iOS only for now.
   */
  onReceive(callback: (data: Record<string, unknown>) => void): () => void {
    const craft = getCraftRoot()
    if (craft?.notifications?.onReceive) {
      return craft.notifications.onReceive((detail: unknown) => {
        callback((detail ?? {}) as Record<string, unknown>)
      }) ?? (() => {})
    }
    return onCraftEvent('craftNotificationReceived', detail => callback(detail))
  }
}

export type HealthDataType =
  | 'steps'
  | 'heartRate'
  | 'activeEnergy'
  | 'distance'
  | 'workouts'
  | 'restingHeartRate'
  | 'heartRateVariability'
  | 'bodyMass'
  | 'sleep'
  /** Food logged by any app, per day: kcal eaten, then grams of protein, carbohydrate and fat. */
  | 'dietaryEnergy'
  | 'dietaryProtein'
  | 'dietaryCarbohydrates'
  | 'dietaryFat'
  /** Mindful minutes (meditation, breathing): read with getMindfulSessions, written with saveMindfulSession. */
  | 'mindful'
  /** Blood glucose from a CGM or meter, in mg/dL: read with getSamples. Read only. */
  | 'bloodGlucose'
  /**
   * Insulin from a pump, pen or closed loop, in international units, each
   * marked basal or bolus: read with getSamples. Read only. HealthKit only:
   * Health Connect has no insulin type, so Android answers none.
   */
  | 'insulinDelivery'

/** The types with one value per day. `sleep` is hours asleep, counted on the day you woke. */
export type HealthDailyType = Exclude<HealthDataType, 'workouts' | 'mindful' | 'bloodGlucose' | 'insulinDelivery'>

/** Quantity types that can be written with `health.saveData()`. */
export type HealthQuantityType = Exclude<HealthDataType, 'workouts' | 'sleep' | 'mindful' | 'bloodGlucose' | 'insulinDelivery'>

/** The types `health.getSamples()` reads one sample at a time: glucose, insulin and carbs, as a diabetes app needs them. */
export type HealthSampleType = 'bloodGlucose' | 'insulinDelivery' | 'dietaryCarbohydrates'

export interface HealthSamplesQuery extends HealthSampleQuery {
  /** At most this many, oldest first. Defaults to 10000, capped at 50000. Start defaults to 7 days ago. */
  limit?: number
}

/** One glucose reading, insulin dose or carb entry as the writing app saved it. */
export interface HealthQuantitySample {
  /** HealthKit's UUID or Health Connect's record id: stable across reads. */
  id: string
  /** In `unit`: mg/dL for glucose, IU for insulin, g for carbs. */
  value: number
  unit: 'mg/dL' | 'IU' | 'g'
  /** Epoch milliseconds. */
  startDate: number
  /** Epoch milliseconds; the same as `startDate` for an instant reading. A basal delivery spans its segment. */
  endDate: number
  sourceName: string
  sourceBundleId: string
  /** True when this app wrote it. */
  ownApp: boolean
  deviceName?: string
  /** Insulin only: what the dose was for. */
  insulinReason?: 'basal' | 'bolus'
  /** Glucose only: when it was taken relative to a meal, when the source said. */
  mealTime?: 'beforeMeal' | 'afterMeal' | 'fasting' | 'general'
  /** Glucose only (Health Connect): what was sampled, when the source said. */
  specimen?: 'capillaryBlood' | 'interstitialFluid' | 'plasma' | 'serum' | 'tears' | 'wholeBlood'
}

export interface HealthAuthorizationOptions {
  /** `false` asks to read only. Default: also allowed to save workouts. */
  write?: boolean
}

export interface HealthDataOptions {
  startDate?: number
  endDate?: number
}

export interface HealthDataResult {
  value: number
  unit: string
}

export interface HealthDataSaveResult {
  /** HealthKit's UUID for the saved quantity sample. */
  id: string
}

export type HealthWorkoutType = 'running' | 'walking' | 'hiking' | 'cycling'

export interface HealthWorkoutLocation {
  latitude: number
  longitude: number
  altitude?: number
  accuracy?: number
  timestamp: number
}

export interface HealthWorkout {
  activityId: string
  type: HealthWorkoutType
  startDate: number
  endDate: number
  distanceMeters?: number
  activeEnergyCalories?: number
  locations?: HealthWorkoutLocation[]
}

export interface HealthWorkoutResult {
  id: string
}

export interface HealthWorkoutQuery {
  /** Epoch milliseconds. Defaults to 30 days ago. */
  startDate?: number
  /** Epoch milliseconds. Defaults to now. */
  endDate?: number
  /** At most this many, newest first. Defaults to 200, capped at 1000. */
  limit?: number
}

/** The activity of a workout read from Apple Health, named independently of the SDK. */
export type HealthWorkoutActivity =
  | 'running' | 'cycling' | 'walking' | 'hiking' | 'swimming' | 'rowing' | 'elliptical'
  | 'stairClimbing' | 'yoga' | 'pilates' | 'strength' | 'hiit' | 'crossTraining'
  | 'crossCountrySkiing' | 'skiing' | 'paddling' | 'climbing' | 'dance' | 'mobility' | 'other'

/** A workout recorded by the watch, or by any app that writes to Apple Health. */
export interface HealthWorkoutSample {
  /** HealthKit's UUID: stable across reads, so it can key an import. */
  id: string
  type: HealthWorkoutActivity
  startDate: number
  endDate: number
  durationSeconds: number
  sourceName: string
  indoor: boolean
  distanceMeters?: number
  elevationGainMeters?: number
  activeEnergyCalories?: number
  averageHeartRate?: number
  maxHeartRate?: number
}

export interface HealthDailyValue {
  /** The local day, YYYY-MM-DD. */
  date: string
  value: number
  unit: string
}

export interface HealthSampleQuery {
  /** Epoch milliseconds. Defaults to a day before `endDate`. */
  startDate?: number
  /** Epoch milliseconds. Defaults to now. */
  endDate?: number
}

export interface HealthHeartRateQuery extends HealthSampleQuery {
  /** At most this many, oldest first. Defaults to 10000, capped at 50000. */
  limit?: number
}

/** One heart-rate reading from Apple Health, in beats per minute. */
export interface HealthHeartRateSample {
  bpm: number
  /** Epoch milliseconds. */
  startDate: number
  /** Epoch milliseconds; the same as `startDate` for a single reading. */
  endDate: number
  /** The app that wrote it, e.g. the watch's own name. */
  sourceName: string
  /** The device that measured it, when the source says ("Apple Watch"). */
  deviceName?: string
  deviceModel?: string
  /** A series of readings (a watch workout) also carries its count, lowest and highest. */
  count?: number
  min?: number
  max?: number
  /** What the wearer was doing, when the watch says. */
  motionContext?: 'sedentary' | 'active'
}

/** A sleep analysis stage: in bed, awake, or asleep (staged or not). */
export type HealthSleepStage = 'inBed' | 'awake' | 'asleep' | 'core' | 'deep' | 'rem'

/** One stretch of a night as a source recorded it. */
export interface HealthSleepInterval {
  /** Epoch milliseconds. */
  startDate: number
  /** Epoch milliseconds. */
  endDate: number
  stage: HealthSleepStage
  /** Every asleep stage; false for time in bed and time awake. */
  asleep: boolean
  sourceName: string
  deviceName?: string
}

/** A meditation or breathing session to record as mindful minutes. */
export interface HealthMindfulSession {
  /**
   * The app's own id for the session (up to 128 characters), kept as the
   * sample's external UUID. Saving the same id again keeps the first sample.
   */
  id: string
  /** Epoch milliseconds. */
  startDate: number
  /** Epoch milliseconds, after `startDate` and at most a day later. */
  endDate: number
}

export interface HealthMindfulSessionResult {
  /** HealthKit's UUID for the sample. */
  id: string
  /** The id it was saved with. */
  externalId: string
  /** True when this id was saved before and that sample was kept. */
  existing: boolean
}

export interface HealthMindfulSessionQuery extends HealthSampleQuery {
  /** At most this many, oldest first. Defaults to 1000, capped at 5000. Start defaults to 30 days ago. */
  limit?: number
}

/** A mindful session in Apple Health, from any app that writes them. */
export interface HealthMindfulSample {
  /** HealthKit's UUID. */
  id: string
  /** Epoch milliseconds. */
  startDate: number
  /** Epoch milliseconds. */
  endDate: number
  durationSeconds: number
  sourceName: string
  sourceBundleId: string
  /** True when this app wrote it. */
  ownApp: boolean
  /** The id the writing app saved it with, when it gave one. */
  externalId?: string
  deviceName?: string
}

export interface HealthHeartRateUpdatesOptions {
  /** Epoch milliseconds: samples that start at or after this. Defaults to two minutes ago. */
  since?: number
}

export type HealthLiveWorkoutType =
  | 'running' | 'walking' | 'hiking' | 'cycling' | 'swimming' | 'rowing'
  | 'elliptical' | 'strength' | 'hiit'

export interface HealthLiveWorkoutOptions {
  type: HealthLiveWorkoutType
  location?: 'indoor' | 'outdoor' | 'unknown'
}

export interface HealthLiveWorkoutStarted {
  id: string
  type: HealthLiveWorkoutType
  /** Epoch milliseconds. */
  startDate: number
}

export interface HealthLiveWorkoutResult {
  id: string
  workoutId: string
  /** Epoch milliseconds. */
  endDate: number
  durationSeconds: number
}

export interface HealthLiveWorkoutEvent {
  id: string
  event: 'state' | 'metrics' | 'error'
  state?: 'notStarted' | 'prepared' | 'running' | 'paused' | 'stopped' | 'ended' | 'unknown'
  /** Epoch milliseconds for a state transition. */
  date?: number
  heartRateBpm?: number
  activeEnergyCalories?: number
  distanceMeters?: number
  message?: string
}

/** The health reads and writes a host may or may not have, depending on the app build it runs in. */
export type HealthReadMethod = 'getWorkouts' | 'getDailyStatistics' | 'getHeartRateSamples' | 'getSamples' | 'getSleepIntervals' | 'saveData' | 'saveMindfulSession' | 'getMindfulSessions' | 'startHeartRateUpdates' | 'stopHeartRateUpdates' | 'startWorkout' | 'pauseWorkout' | 'resumeWorkout' | 'endWorkout' | 'discardWorkout'

/** The samples of one `craftHealthHeartRate` event that look like heart-rate samples. */
function healthHeartRateSamples(detail: unknown): HealthHeartRateSample[] {
  const samples = (detail as { samples?: unknown } | null | undefined)?.samples
  if (!Array.isArray(samples)) return []
  return samples.filter((sample): sample is HealthHeartRateSample => typeof sample?.bpm === 'number'
    && Number.isFinite(sample.bpm)
    && typeof sample.startDate === 'number'
    && typeof sample.endDate === 'number')
}

export const health = {
  /**
   * Whether this app build answers `method`. An app installed before a read
   * existed has none, so a page checks before offering what needs it.
   */
  supports(method: HealthReadMethod): boolean {
    return typeof getCraftRoot()?.health?.[method] === 'function'
  },
  /**
   * Ask for the health data a page needs. `{ write: false }` asks to read
   * only, for an app that never writes back; by default it may also save
   * workouts, energy and distance.
   */
  async requestAuthorization(types: HealthDataType[], options: HealthAuthorizationOptions = {}): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.health?.requestAuthorization) throw new Error('Health data is unavailable')
    return Boolean(await craft.health.requestAuthorization(types, options))
  },
  async getData(type: HealthDataType, options: HealthDataOptions = {}): Promise<HealthDataResult> {
    const craft = getCraftRoot()
    if (!craft?.health?.getData) throw new Error('Health data is unavailable')
    return craft.health.getData(type, options)
  },
  /** Save one quantity sample, such as a meal's dietary energy or macros. iOS only for now. */
  async saveData(type: HealthQuantityType, value: number, options: HealthDataOptions = {}): Promise<HealthDataSaveResult> {
    const craft = getCraftRoot()
    if (!craft?.health?.saveData) throw new Error('Saving health data is unavailable')
    return craft.health.saveData(type, value, options)
  },
  async saveWorkout(workout: HealthWorkout): Promise<HealthWorkoutResult> {
    const craft = getCraftRoot()
    if (!craft?.health?.saveWorkout) throw new Error('Saving health workouts is unavailable')
    return craft.health.saveWorkout(workout)
  },
  /** Workouts in Apple Health, newest first. iOS only for now. */
  async getWorkouts(options: HealthWorkoutQuery = {}): Promise<HealthWorkoutSample[]> {
    const craft = getCraftRoot()
    if (!craft?.health?.getWorkouts) throw new Error('Reading health workouts is unavailable')
    return craft.health.getWorkouts(options)
  },
  /** One value per local day between two dates. iOS only for now. */
  async getDailyStatistics(type: HealthDailyType, options: HealthDataOptions = {}): Promise<HealthDailyValue[]> {
    const craft = getCraftRoot()
    if (!craft?.health?.getDailyStatistics) throw new Error('Daily health statistics are unavailable')
    return craft.health.getDailyStatistics(type, options)
  },
  /** Every heart-rate reading between two instants, oldest first. iOS only for now. */
  async getHeartRateSamples(options: HealthHeartRateQuery = {}): Promise<HealthHeartRateSample[]> {
    const craft = getCraftRoot()
    if (!craft?.health?.getHeartRateSamples) throw new Error('Reading heart-rate samples is unavailable')
    return craft.health.getHeartRateSamples(options)
  },
  /**
   * Every glucose reading, insulin dose or carb entry between two instants,
   * oldest first, each with its own id so a sync can store it once. Needs
   * the type's read grant. Health Connect has no insulin, so Android answers
   * an empty list for `insulinDelivery`.
   */
  async getSamples(type: HealthSampleType, options: HealthSamplesQuery = {}): Promise<HealthQuantitySample[]> {
    const craft = getCraftRoot()
    if (!craft?.health?.getSamples) throw new Error('Reading health samples is unavailable')
    return craft.health.getSamples(type, options)
  },
  /** Sleep between two instants, oldest first: time in bed and each asleep or awake stage. iOS only for now. */
  async getSleepIntervals(options: HealthSampleQuery = {}): Promise<HealthSleepInterval[]> {
    const craft = getCraftRoot()
    if (!craft?.health?.getSleepIntervals) throw new Error('Reading sleep intervals is unavailable')
    return craft.health.getSleepIntervals(options)
  },
  /**
   * Record a meditation or breathing session as mindful minutes. Needs the
   * `mindful` grant with writing allowed. Saving the same `id` again keeps
   * the first sample. iOS only for now.
   */
  async saveMindfulSession(session: HealthMindfulSession): Promise<HealthMindfulSessionResult> {
    const craft = getCraftRoot()
    if (!craft?.health?.saveMindfulSession) throw new Error('Saving mindful sessions is unavailable')
    return craft.health.saveMindfulSession(session)
  },
  /** Mindful sessions between two instants, oldest first, each marked `ownApp` when this app wrote it. iOS only for now. */
  async getMindfulSessions(options: HealthMindfulSessionQuery = {}): Promise<HealthMindfulSample[]> {
    const craft = getCraftRoot()
    if (!craft?.health?.getMindfulSessions) throw new Error('Reading mindful sessions is unavailable')
    return craft.health.getMindfulSessions(options)
  },
  /**
   * Heart rate as Apple Health receives it, until `stopHeartRateUpdates()`:
   * the samples since `since` (two minutes ago by default) first, then each
   * batch as the watch syncs it, to every `onHeartRate` listener. Needs the
   * `heartRate` grant. One stream at a time; starting again replaces it.
   * HealthKit only has what the watch has synced: every few seconds during a
   * workout or Mindfulness session on the watch, every few minutes otherwise.
   * iOS only for now.
   */
  async startHeartRateUpdates(options: HealthHeartRateUpdatesOptions = {}): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.health?.startHeartRateUpdates) throw new Error('Heart-rate updates are unavailable')
    return Boolean(await craft.health.startHeartRateUpdates(options))
  },
  /** Stops the stream `startHeartRateUpdates` started; true also when none ran. */
  async stopHeartRateUpdates(): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.health?.stopHeartRateUpdates) throw new Error('Heart-rate updates are unavailable')
    return Boolean(await craft.health.stopHeartRateUpdates())
  },
  /** Starts an OS-owned live workout session (iOS 26+ for now). */
  async startWorkout(options: HealthLiveWorkoutOptions): Promise<HealthLiveWorkoutStarted> {
    const craft = getCraftRoot()
    if (!craft?.health?.startWorkout) throw new Error('Live workouts are unavailable')
    return craft.health.startWorkout(options)
  },
  /** Pauses the current live workout. */
  async pauseWorkout(): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.health?.pauseWorkout) throw new Error('Live workouts are unavailable')
    return Boolean(await craft.health.pauseWorkout())
  },
  /** Resumes the current live workout. */
  async resumeWorkout(): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.health?.resumeWorkout) throw new Error('Live workouts are unavailable')
    return Boolean(await craft.health.resumeWorkout())
  },
  /** Ends and saves the current live workout. */
  async endWorkout(): Promise<HealthLiveWorkoutResult> {
    const craft = getCraftRoot()
    if (!craft?.health?.endWorkout) throw new Error('Live workouts are unavailable')
    return craft.health.endWorkout()
  },
  /** iOS: ends the live session without saving a workout. Does not delete existing health samples. */
  async discardWorkout(): Promise<boolean> {
    const craft = getCraftRoot()
    if (!craft?.health?.discardWorkout) throw new Error('Discarding live workouts is unavailable')
    return Boolean(await craft.health.discardWorkout())
  },
  /** Receives OS workout state transitions; returns the unsubscribe. */
  onWorkout(callback: (event: HealthLiveWorkoutEvent) => void): () => void {
    if (typeof window === 'undefined' || typeof getCraftRoot()?.health?.startWorkout !== 'function') return () => {}
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<unknown>).detail as HealthLiveWorkoutEvent | null | undefined
      if (detail && typeof detail.id === 'string' && (detail.event === 'state' || detail.event === 'metrics' || detail.event === 'error')) callback(detail)
    }
    window.addEventListener('craftHealthWorkout', listener)
    return () => window.removeEventListener('craftHealthWorkout', listener)
  },
  /**
   * Each batch of new heart-rate samples while `startHeartRateUpdates` runs,
   * oldest first, every sample once. Returns the unsubscribe; off a phone, or
   * in a build without the stream, it never calls back.
   */
  onHeartRate(callback: (samples: HealthHeartRateSample[]) => void): () => void {
    if (typeof window === 'undefined' || typeof getCraftRoot()?.health?.startHeartRateUpdates !== 'function') return () => {}
    const listener = (event: Event) => {
      const samples = healthHeartRateSamples((event as CustomEvent<unknown>).detail)
      if (samples.length) callback(samples)
    }
    window.addEventListener('craftHealthHeartRate', listener)
    return () => window.removeEventListener('craftHealthHeartRate', listener)
  },
}

export interface LiveActivityState {
  /** Native step boundaries retained on device; at most 1000, with detail limited to 96 characters. Only the current state is sent to the widget. */
  transitions?: Array<{ at: number, detail: string, duration?: number | null }>
  /** An actual HealthKit workout (iOS 26+, already authorised) owns background updates. */
  workoutType?: string
  sessionStartedAt?: number
  /** What to show once staleAt passes without fresh app state. */
  staleStatus?: string
  /** Current step, interval or session detail. */
  detail?: string
  /** Epoch milliseconds; system-rendered timers keep advancing while the app sleeps. */
  timerStartedAt?: number | null
  timerEndsAt?: number | null
  paused?: boolean
  remainingSeconds?: number | null
  heartRate?: number | null
  showsDistance?: boolean
  staleAt?: number | null
  status?: string
  distanceMeters?: number
  durationSeconds?: number
  progress?: number
}

export interface LiveActivityOptions extends LiveActivityState {
  symbol?: string
  deepLink?: string
  tint?: string
  activityId: string
  title: string
}

export interface LiveActivityHandle {
  readonly id: string
  update(state: LiveActivityState): Promise<void>
  end(finalState?: LiveActivityState): Promise<void>
}

export interface LiveActivitiesApi {
  isAvailable(): Promise<boolean>
  list(): Promise<Array<{ id: string, activityId: string, title: string }>>
  start(options: LiveActivityOptions): Promise<LiveActivityHandle>
  update(id: string, state: LiveActivityState): Promise<void>
  /** @deprecated Pass the activity id returned by start, or use handle.update(state). */
  update(state: LiveActivityState): Promise<void>
  end(id: string, finalState?: LiveActivityState): Promise<void>
  /** @deprecated Pass the activity id returned by start, or use handle.end(finalState). */
  end(): Promise<void>
}

async function updateLiveActivity(idOrState: string | LiveActivityState, state?: LiveActivityState): Promise<void> {
  const craft = getCraftRoot()
  if (!craft?.liveActivity?.update) return
  if (typeof idOrState === 'string') {
    await craft.liveActivity.update(idOrState, state ?? {})
    return
  }
  await craft.liveActivity.update(idOrState)
}

async function endLiveActivity(id?: string, finalState?: LiveActivityState): Promise<void> {
  const craft = getCraftRoot()
  if (!craft?.liveActivity?.end) return
  if (id !== undefined) {
    await craft.liveActivity.end(id, finalState)
    return
  }
  await craft.liveActivity.end()
}

export const liveActivities: LiveActivitiesApi = {
  async isAvailable() { return Boolean(await getCraftRoot()?.liveActivity?.isAvailable?.()) },
  async list() { return await getCraftRoot()?.liveActivity?.list?.() ?? [] },
  async start(options: LiveActivityOptions): Promise<LiveActivityHandle> {
    const craft = getCraftRoot()
    if (!craft?.liveActivity?.start) throw new Error('Live Activities are unavailable')
    const result = await craft.liveActivity.start(options)
    if (!result || typeof result.id !== 'string' || result.id.length === 0) {
      throw new Error('Live Activities returned an invalid activity id')
    }
    return createLiveActivityHandle(
      result.id,
      state => updateLiveActivity(result.id, state),
      finalState => endLiveActivity(result.id, finalState),
    )
  },
  update: updateLiveActivity,
  end: endLiveActivity,
}

export const watchConnectivity = {
  async send(message: Record<string, unknown>): Promise<Record<string, unknown>> {
    const craft = getCraftRoot()
    if (!craft?.watch?.send) throw new Error('Apple Watch connectivity is unavailable')
    return craft.watch.send(message)
  },
  async updateContext(context: Record<string, unknown>): Promise<void> {
    const craft = getCraftRoot()
    if (!craft?.watch?.updateContext) throw new Error('Apple Watch connectivity is unavailable')
    await craft.watch.updateContext(context)
  },
  async isReachable(): Promise<boolean> {
    const result = await getCraftRoot()?.watch?.isReachable?.()
    return Boolean(result?.reachable)
  },
  onMessage(callback: (message: Record<string, unknown>) => void): () => void {
    return onCraftEvent('craftWatchMessage', callback)
  },
  onReachabilityChange(callback: (reachable: boolean) => void): () => void {
    return onCraftEvent('craftWatchReachability', detail => callback(Boolean(detail.reachable)))
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

function onCraftEvent(eventName: string, callback: (detail: Record<string, unknown>) => void): () => void {
  if (typeof globalThis === 'undefined') return () => {}
  const listener = (event: Event) => callback((event as CustomEvent<Record<string, unknown>>).detail ?? {})
  globalThis.addEventListener(eventName, listener)
  return () => globalThis.removeEventListener(eventName, listener)
}

function getCraftRoot(): any {
  if (typeof window === 'undefined') return undefined
  return (window as any).craft
}

function detectPlatform(): DeviceInfo['platform'] {
  if (typeof window === 'undefined') return 'linux'
  const ua = navigator.userAgent.toLowerCase()
  if (/iphone|ipad|ipod/.test(ua)) return 'ios'
  if (/android/.test(ua)) return 'android'
  if (/macintosh|mac os x/.test(ua)) return 'macos'
  if (/windows/.test(ua)) return 'windows'
  return 'linux'
}

function mapToWebPermission(permission: PermissionType): string | null {
  const mapping: Record<string, string> = {
    camera: 'camera',
    microphone: 'microphone',
    location: 'geolocation',
    notifications: 'notifications'
  }
  return mapping[permission] || null
}

function mapWebPermissionStatus(state: PermissionState): PermissionStatus {
  const mapping: Record<PermissionState, PermissionStatus> = {
    granted: 'granted',
    denied: 'denied',
    prompt: 'undetermined'
  }
  return mapping[state]
}

// Mobile bridge type for window.craft with mobile-specific properties
interface CraftMobileBridge {
  device?: {
    getInfo(): Promise<DeviceInfo>
    getCapabilities(): Promise<DeviceCapabilities>
  }
  haptics?: {
    impact(style: HapticStyle): Promise<void>
    notification(type: HapticNotificationType): Promise<void>
    selection(): Promise<void>
    prepare?(kind?: string): Promise<void>
    vibrate(pattern: number[]): Promise<void>
  }
  permissions?: {
    check(permission: PermissionType): Promise<PermissionStatus>
    request(permission: PermissionType): Promise<PermissionStatus>
    openSettings(): Promise<void>
  }
  camera?: {
    takePicture(options: CameraOptions): Promise<PhotoResult>
    pickImage(): Promise<PhotoResult>
    pickMultiple(options: { maxCount?: number }): Promise<PhotoResult[]>
    isAvailable(): Promise<boolean>
  }
  files?: {
    pickFile(options?: PickFileOptions): Promise<FileInfo[]>
  }
  biometrics?: {
    isAvailable(): Promise<boolean>
    getBiometricType(): Promise<BiometricType | null>
    authenticate(reason: string): Promise<boolean>
  }
  secureStorage?: {
    set(key: string, value: string): Promise<void>
    get(key: string): Promise<string | null>
    /** Compatibility alias for callers using the legacy native contract. */
    remove(key: string): Promise<void>
    delete(key: string): Promise<void>
    clear(): Promise<void>
  }
  location?: {
    getCurrentPosition(options: LocationOptions): Promise<Location>
    watchPosition(callback: (location: Location) => void, options: LocationOptions): number
    clearWatch(watchId: number): void
    startRecording?(options: LocationOptions & RecordingStartOptions): Promise<LocationRecordingState>
    pauseRecording?(options?: RecordingOwnershipOptions): Promise<LocationRecordingState>
    resumeRecording?(options?: RecordingOwnershipOptions): Promise<LocationRecordingState>
    stopRecording?(options?: RecordingOwnershipOptions): Promise<LocationRecordingResult>
    getRecordingState?(options?: RecordingOwnershipOptions): Promise<LocationRecordingState>
    acknowledgeRecording?(options: RecordingOwnershipOptions): Promise<boolean>
    readRecording?(options?: LocationRecordingReadOptions): Promise<Location[]>
  }
  share?: {
    share(options: ShareOptions): Promise<boolean>
  }
  lifecycle?: {
    getState(): AppState
    onStateChange(callback: (state: AppState) => void): () => void
  }
  notifications?: {
    show(options: NotificationOptions): Promise<void>
    schedule(options: BridgeNotification): Promise<void>
    cancel(id: string): Promise<void>
    cancelAll(): Promise<void>
    pending(): Promise<PendingLocalNotification[]>
    setBadge(count: number): Promise<void>
  }
  health?: {
    requestAuthorization(types: HealthDataType[], options?: HealthAuthorizationOptions): Promise<boolean>
    getData(type: HealthDataType, options: HealthDataOptions): Promise<HealthDataResult>
    saveData?(type: HealthQuantityType, value: number, options: HealthDataOptions): Promise<HealthDataSaveResult>
    saveWorkout(workout: HealthWorkout): Promise<HealthWorkoutResult>
    getWorkouts?(options: HealthWorkoutQuery): Promise<HealthWorkoutSample[]>
    getDailyStatistics?(type: HealthDailyType, options: HealthDataOptions): Promise<HealthDailyValue[]>
    getHeartRateSamples?(options: HealthHeartRateQuery): Promise<HealthHeartRateSample[]>
    getSamples?(type: HealthSampleType, options: HealthSamplesQuery): Promise<HealthQuantitySample[]>
    getSleepIntervals?(options: HealthSampleQuery): Promise<HealthSleepInterval[]>
    saveMindfulSession?(session: HealthMindfulSession): Promise<HealthMindfulSessionResult>
    getMindfulSessions?(options: HealthMindfulSessionQuery): Promise<HealthMindfulSample[]>
    startHeartRateUpdates?(options: HealthHeartRateUpdatesOptions): Promise<boolean>
    stopHeartRateUpdates?(): Promise<boolean>
    startWorkout?(options: HealthLiveWorkoutOptions): Promise<HealthLiveWorkoutStarted>
    pauseWorkout?(): Promise<boolean>
    resumeWorkout?(): Promise<boolean>
    endWorkout?(): Promise<HealthLiveWorkoutResult>
    discardWorkout?(): Promise<boolean>
  }
  liveActivity?: {
    isAvailable?(): Promise<boolean>
    list?(): Promise<Array<{ id: string, activityId: string, title: string }>>
    start(options: LiveActivityOptions): Promise<{ id: string }>
    update(id: string, state: LiveActivityState): Promise<void>
    update(state: LiveActivityState): Promise<void>
    end(id: string, finalState?: LiveActivityState): Promise<void>
    end(): Promise<void>
  }
  watch?: {
    send(message: Record<string, unknown>): Promise<Record<string, unknown>>
    updateContext(context: Record<string, unknown>): Promise<void>
    isReachable(): Promise<{ reachable: boolean }>
  }
}

/**
 * Helper to access window.craft with mobile-specific type extensions.
 * This avoids conflicts with the CraftBridgeAPI declaration in types.ts.
 */
function getCraftMobile(): CraftMobileBridge | undefined {
  if (typeof window !== 'undefined') {
    return (window as any).craft as CraftMobileBridge | undefined
  }
  return undefined
}

const mobile: {
  crypto: typeof crypto
  storage: typeof storage
  device: typeof device
  haptics: typeof haptics
  permissions: typeof permissions
  camera: typeof camera
  files: typeof files
  biometrics: typeof biometrics
  secureStorage: typeof secureStorage
  location: typeof location
  share: typeof share
  lifecycle: typeof lifecycle
  notifications: typeof notifications
  keepAwake: typeof keepAwake
  brightness: typeof brightness
  speech: typeof speech
  crashReporter: typeof crashReporter
  music: typeof music
  heartRate: typeof heartRate
  scheduledWorkouts: typeof scheduledWorkouts
  deepLinks: typeof deepLinks
  network: typeof network
  appReview: typeof appReview
  pushNotifications: typeof pushNotifications
  health: typeof health
  liveActivities: typeof liveActivities
  watchConnectivity: typeof watchConnectivity
  tabBar: typeof tabBar
  splash: typeof splash
  snapshots: typeof snapshots
  hybrid: typeof hybrid
  dialog: typeof dialog
  contextMenu: typeof contextMenu
  browser: typeof browser
  symbols: typeof symbols
  statusBar: typeof statusBar
  chrome: typeof chrome
  refresh: typeof refresh
  background: typeof background
  session: typeof session
  appearance: typeof appearance
} = {
  crypto: crypto,
  storage: storage,
  device: device,
  haptics: haptics,
  permissions: permissions,
  camera: camera,
  files: files,
  biometrics: biometrics,
  secureStorage: secureStorage,
  location: location,
  share: share,
  lifecycle: lifecycle,
  notifications: notifications,
  keepAwake: keepAwake,
  brightness: brightness,
  speech: speech,
  crashReporter: crashReporter,
  music: music,
  heartRate: heartRate,
  scheduledWorkouts: scheduledWorkouts,
  deepLinks: deepLinks,
  network: network,
  appReview: appReview,
  pushNotifications: pushNotifications,
  health: health,
  liveActivities: liveActivities,
  watchConnectivity: watchConnectivity,
  tabBar: tabBar,
  splash: splash,
  snapshots: snapshots,
  hybrid: hybrid,
  dialog: dialog,
  contextMenu: contextMenu,
  browser: browser,
  symbols: symbols,
  statusBar: statusBar,
  chrome: chrome,
  refresh: refresh,
  background: background,
  session: session,
  appearance: appearance,
}

export default mobile
