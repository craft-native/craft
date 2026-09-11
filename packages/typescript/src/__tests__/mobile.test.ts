/**
 * Mobile API Tests
 *
 * Tests for cross-platform mobile functionality.
 */

import { describe, expect, it } from 'bun:test'
import type {
  DeviceInfo,
  DeviceCapabilities,
  HapticStyle,
  HapticNotificationType,
  PermissionType,
  PermissionStatus,
  CameraOptions,
  PhotoResult,
  BiometricType,
  Location,
  LocationOptions,
  ShareOptions,
  AppState,
  NotificationOptions,
  HealthDataResult,
  LiveActivityHandle,
  LiveActivityOptions,
} from '../api/mobile'
import { normalizeDeepLinkURL } from '../api/mobile'

describe('Mobile deep links', () => {
  it('normalizes native payloads to the public string contract', () => {
    expect(normalizeDeepLinkURL('wildloop://record')).toBe('wildloop://record')
    expect(normalizeDeepLinkURL({ url: 'wildloop://trail/42', scheme: 'wildloop' })).toBe('wildloop://trail/42')
    expect(normalizeDeepLinkURL({ scheme: 'wildloop' })).toBeNull()
  })
})

describe('Mobile API Types', () => {
  describe('DeviceInfo', () => {
    it('should define device information structure', () => {
      const info: DeviceInfo = {
        platform: 'ios',
        osVersion: '17.0',
        model: 'iPhone 15 Pro',
        manufacturer: 'Apple',
        deviceId: 'test-device-id',
        isTablet: false,
        screen: {
          width: 393,
          height: 852,
          scale: 3
        },
        battery: {
          level: 100,
          isCharging: false
        },
        network: {
          type: 'wifi',
          isConnected: true
        }
      }

      expect(info.platform).toBe('ios')
      expect(info.osVersion).toBe('17.0')
      expect(info.model).toBe('iPhone 15 Pro')
    })
  })

  describe('DeviceCapabilities', () => {
    it('should define device capabilities', () => {
      const capabilities: DeviceCapabilities = {
        camera: true,
        biometrics: true,
        nfc: true,
        bluetooth: true,
        gps: true,
        accelerometer: true,
        gyroscope: true,
        haptics: true,
        ar: false,
        faceId: true,
        touchId: false
      }

      expect(capabilities.camera).toBe(true)
      expect(capabilities.biometrics).toBe(true)
    })
  })

  describe('HapticStyle', () => {
    it('should support haptic styles', () => {
      const styles: HapticStyle[] = ['light', 'medium', 'heavy', 'soft', 'rigid']
      expect(styles).toContain('light')
      expect(styles).toContain('heavy')
    })
  })

  describe('HapticNotificationType', () => {
    it('should support notification types', () => {
      const types: HapticNotificationType[] = ['success', 'warning', 'error']
      expect(types).toContain('success')
      expect(types).toContain('error')
    })
  })

  describe('PermissionType', () => {
    it('should define permission types', () => {
      const permissions: PermissionType[] = [
        'camera',
        'microphone',
        'photos',
        'location',
        'locationAlways',
        'notifications',
        'contacts',
        'calendar',
        'reminders',
        'bluetooth',
        'motion'
      ]

      expect(permissions).toContain('camera')
      expect(permissions).toContain('location')
      expect(permissions).toContain('notifications')
    })
  })

  describe('PermissionStatus', () => {
    it('should define permission statuses', () => {
      const statuses: PermissionStatus[] = ['granted', 'denied', 'undetermined', 'restricted']
      expect(statuses).toContain('granted')
      expect(statuses).toContain('denied')
    })
  })

  describe('CameraOptions', () => {
    it('should define camera options', () => {
      const options: CameraOptions = {
        camera: 'back',
        quality: 80,
        maxWidth: 1920,
        maxHeight: 1080,
        saveToGallery: false
      }

      expect(options.camera).toBe('back')
      expect(options.quality).toBe(80)
      expect(options.saveToGallery).toBe(false)
    })
  })

  describe('PhotoResult', () => {
    it('should define photo result structure', () => {
      const result: PhotoResult = {
        uri: 'file:///path/to/photo.jpg',
        width: 1920,
        height: 1080,
        mimeType: 'image/jpeg',
        base64: 'base64data'
      }

      expect(result.uri).toContain('photo.jpg')
      expect(result.width).toBe(1920)
      expect(result.mimeType).toBe('image/jpeg')
    })
  })

  describe('BiometricType', () => {
    it('should define biometric types', () => {
      const types: BiometricType[] = ['faceId', 'touchId', 'fingerprint', 'face', 'iris']
      expect(types).toContain('touchId')
      expect(types).toContain('face')
    })
  })

  describe('Location', () => {
    it('should define location structure', () => {
      const location: Location = {
        latitude: 37.7749,
        longitude: -122.4194,
        altitude: 10,
        accuracy: 5,
        heading: 90,
        speed: 0,
        timestamp: Date.now()
      }

      expect(location.latitude).toBe(37.7749)
      expect(location.longitude).toBe(-122.4194)
      expect(location.accuracy).toBe(5)
    })
  })

  describe('LocationOptions', () => {
    it('should define location options', () => {
      const options: LocationOptions = {
        enableHighAccuracy: true,
        timeout: 10000,
        maximumAge: 5000
      }

      expect(options.enableHighAccuracy).toBe(true)
      expect(options.timeout).toBe(10000)
    })
  })

  describe('ShareOptions', () => {
    it('should define share options', () => {
      const options: ShareOptions = {
        title: 'Share this',
        text: 'Check out this content',
        url: 'https://example.com'
      }

      expect(options.title).toBe('Share this')
      expect(options.url).toBe('https://example.com')
    })
  })

  describe('AppState', () => {
    it('should define app states', () => {
      const states: AppState[] = ['active', 'inactive', 'background']
      expect(states).toContain('active')
      expect(states).toContain('background')
    })
  })

  describe('NotificationOptions', () => {
    it('should define notification options', () => {
      const options: NotificationOptions = {
        title: 'New Message',
        body: 'You have a new message',
        sound: 'default',
        badge: 1,
        data: { messageId: '123' }
      }

      expect(options.title).toBe('New Message')
      expect(options.body).toBe('You have a new message')
      expect(options.badge).toBe(1)
    })
  })

  describe('native activity integrations', () => {
    it('defines HealthKit and Live Activity payloads', () => {
      const health: HealthDataResult = { value: 4219, unit: 'count' }
      const live: LiveActivityOptions = {
        activityId: 'activity-1',
        title: 'WildLoop',
        status: 'Recording',
        distanceMeters: 1609,
        durationSeconds: 480,
      }
      const handle: LiveActivityHandle = {
        id: 'native-activity-1',
        update: async () => {},
        end: async () => {},
      }
      expect(health.value).toBe(4219)
      expect(live.distanceMeters).toBe(1609)
      expect(handle.id).toBe('native-activity-1')
    })
  })
})
