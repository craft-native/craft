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
import mobile, { bridgeNotification, normalizeDeepLinkURL, notifications, pushNotifications, secureStorage, speech, watchConnectivity } from '../api/mobile'

describe('Mobile deep links', () => {
  it('normalizes native payloads to the public string contract', () => {
    expect(normalizeDeepLinkURL('wildloop://record')).toBe('wildloop://record')
    expect(normalizeDeepLinkURL({ url: 'wildloop://trail/42', scheme: 'wildloop' })).toBe('wildloop://trail/42')
    expect(normalizeDeepLinkURL({ scheme: 'wildloop' })).toBeNull()
  })
})

describe('Mobile notification taps', () => {
  // A tap that launched the app is flushed before a hydrating page subscribes.
  // The bridge holds it for the first subscriber through notifications.onTap,
  // and the SDK has to go through that rather than a bare event listener, or
  // the hold does nothing for anyone using the SDK.
  it('subscribes through the bridge replay when the bridge offers one', () => {
    const previousWindow = (globalThis as any).window
    const unsubscribe = () => {}
    let handed: ((detail: unknown) => void) | undefined
    ;(globalThis as any).window = {
      craft: {
        notifications: {
          onTap: (callback: (detail: unknown) => void) => {
            handed = callback
            return unsubscribe
          },
        },
      },
    }

    try {
      const seen: unknown[] = []
      const returned = pushNotifications.onNotification(data => seen.push(data))
      expect(returned).toBe(unsubscribe)

      // The replay hands over whatever it held; the SDK passes it through.
      handed?.({ screen: 'plant-id' })
      expect(seen).toEqual([{ screen: 'plant-id' }])
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })
})

describe('Mobile scheduled notifications', () => {
  // #261: the bridges schedule from `delay`, and neither reads `scheduleAt`,
  // so a reminder meant for an hour from now fired at once.
  const NOW = 1_700_000_000_000

  it('turns scheduleAt into a delay from now, and sends no scheduleAt', () => {
    const sent = bridgeNotification({ title: 'Reminder', body: 'Break', scheduleAt: NOW + 3_600_000, data: { screen: 'plant-id' } }, NOW)
    expect(sent).toEqual({ title: 'Reminder', body: 'Break', delay: 3_600_000, data: { screen: 'plant-id' } })
    expect('scheduleAt' in sent).toBe(false)
  })

  it('delivers now for a moment already here or past, without a zero delay', () => {
    // A zero delay raises inside UserNotifications on the Swift side, so
    // "now" is no delay at all, which both bridges deliver immediately.
    for (const scheduleAt of [NOW, NOW - 5_000]) {
      const sent = bridgeNotification({ title: 'Now', scheduleAt }, NOW)
      expect(sent).toEqual({ title: 'Now' })
    }
    // A fraction of a millisecond still waits: Android reads whole ms.
    expect(bridgeNotification({ title: 'Soon', scheduleAt: NOW + 0.4 }, NOW)).toEqual({ title: 'Soon', delay: 1 })
  })

  it('leaves a notification with no scheduleAt as it was', () => {
    expect(bridgeNotification({ title: 'Plain', badge: 2 }, NOW)).toEqual({ title: 'Plain', badge: 2 })
  })

  it('schedules through the bridge with the delay, not scheduleAt', async () => {
    const previousWindow = (globalThis as any).window
    const sent: unknown[] = []
    ;(globalThis as any).window = { craft: { notifications: { schedule: async (options: unknown) => { sent.push(options) } } } }
    try {
      const before = Date.now()
      await notifications.schedule({ title: 'Reminder', scheduleAt: before + 3_600_000 })
      const after = Date.now()
      expect(sent).toHaveLength(1)
      const options = sent[0] as { delay?: number, scheduleAt?: number }
      expect(options.scheduleAt).toBeUndefined()
      expect(options.delay).toBeGreaterThanOrEqual(3_600_000 - (after - before))
      expect(options.delay).toBeLessThanOrEqual(3_600_000)
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })

  it('cancels one notification and reads the pending list through the bridge', async () => {
    const previousWindow = (globalThis as any).window
    const cancelled: string[] = []
    const pending = [{ id: 'wake', title: 'Wake up', body: 'Morning' }]
    ;(globalThis as any).window = {
      craft: {
        notifications: {
          cancel: async (id: string) => { cancelled.push(id) },
          pending: async () => pending,
        },
      },
    }
    try {
      await notifications.cancel('wake')
      expect(cancelled).toEqual(['wake'])
      expect(await notifications.pending()).toEqual(pending)
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })
})

describe('Mobile notification arrivals', () => {
  // #256: the bridge's onReceive, passed through, and the bare event when a
  // bridge predates it.
  it('subscribes through the bridge when it offers onReceive', () => {
    const previousWindow = (globalThis as any).window
    const unsubscribe = () => {}
    let handed: ((detail: unknown) => void) | undefined
    ;(globalThis as any).window = {
      craft: { notifications: { onReceive: (callback: (detail: unknown) => void) => { handed = callback; return unsubscribe } } },
    }

    try {
      const seen: unknown[] = []
      expect(pushNotifications.onReceive(data => seen.push(data))).toBe(unsubscribe)
      handed?.({ screen: 'recap' })
      handed?.(undefined)
      expect(seen).toEqual([{ screen: 'recap' }, {}])
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })

  it('listens for craftNotificationReceived when the bridge has no onReceive', () => {
    const seen: unknown[] = []
    const unsubscribe = pushNotifications.onReceive(data => seen.push(data))
    globalThis.dispatchEvent(new CustomEvent('craftNotificationReceived', { detail: { screen: 'recap' } }))
    globalThis.dispatchEvent(new CustomEvent('craftNotificationResponse', { detail: { screen: 'tapped' } }))
    unsubscribe()
    globalThis.dispatchEvent(new CustomEvent('craftNotificationReceived', { detail: { screen: 'late' } }))
    expect(seen).toEqual([{ screen: 'recap' }])
  })
})

describe('Mobile Android bridge promises', () => {
  it('reads the typed watch reachability envelope', async () => {
    const previousWindow = (globalThis as any).window
    ;(globalThis as any).window = {
      craft: {
        watch: {
          isReachable: async () => ({ reachable: true }),
        },
      },
    }

    try {
      expect(await watchConnectivity.isReachable()).toBe(true)
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })
})

describe('Mobile secure storage aliases', () => {
  it('removes through the legacy bridge method when available', async () => {
    const removed: string[] = []
    await withWindow({
      craft: {
        secureStorage: {
          remove: async (key: string) => { removed.push(key) },
          delete: async () => { throw new Error('delete should not be used') },
        },
      },
    }, async () => {
      await secureStorage.remove('session-token')
    })
    expect(removed).toEqual(['session-token'])
  })
})

/** Run `body` with `window` set to `value`, restoring whatever was there. */
async function withWindow(value: Record<string, unknown> | undefined, body: () => Promise<void> | void): Promise<void> {
  const previousWindow = (globalThis as any).window
  if (value === undefined) delete (globalThis as any).window
  else (globalThis as any).window = value
  try {
    await body()
  }
  finally {
    if (previousWindow === undefined) delete (globalThis as any).window
    else (globalThis as any).window = previousWindow
  }
}

/** A stand-in for the Web Speech API that records what it was asked. */
function fakeWebSpeech() {
  const spoken: any[] = []
  let cancels = 0
  class Utterance {
    rate = 1
    lang = ''
    onend: (() => void) | null = null
    onerror: (() => void) | null = null
    constructor(public text: string) {}
  }
  const speechSynthesis = {
    speak: (utterance: any) => { spoken.push(utterance) },
    // What a browser does: the utterance in progress ends with an error.
    cancel: () => {
      cancels += 1
      for (const utterance of spoken.splice(0)) utterance.onerror?.()
    },
  }
  return { window: { speechSynthesis, SpeechSynthesisUtterance: Utterance }, spoken, cancels: () => cancels }
}

describe('Mobile speech', () => {
  it('speaks through the native bridge when the app has one', async () => {
    const calls: unknown[][] = []
    await withWindow({
      craft: {
        speech: {
          speak: async (...args: unknown[]) => { calls.push(['speak', ...args]); return true },
          stop: async () => { calls.push(['stop']) },
        },
      },
      ...fakeWebSpeech().window,
    }, async () => {
      expect(speech.isAvailable()).toBe(true)
      expect(await speech.speak('Rest, 15 seconds', { rate: 1.2, interrupt: false })).toBe(true)
      await speech.stop()
      expect(calls).toEqual([['speak', 'Rest, 15 seconds', { rate: 1.2, interrupt: false }], ['stop']])
    })
  })

  it('answers false, not true, for a cue native cut short', async () => {
    await withWindow({ craft: { speech: { speak: async () => false, stop: async () => {} } } }, async () => {
      expect(await speech.speak('Go')).toBe(false)
    })
  })

  it('falls back to the Web Speech API and settles when the utterance ends', async () => {
    const web = fakeWebSpeech()
    await withWindow({ craft: {}, ...web.window }, async () => {
      expect(speech.isAvailable()).toBe(true)
      const spoken = speech.speak('Up next: Dead Bug', { rate: 5, language: 'en-GB' })
      const utterance = web.spoken[0]
      expect(utterance.text).toBe('Up next: Dead Bug')
      expect(utterance.rate).toBe(2)
      expect(utterance.lang).toBe('en-GB')
      utterance.onend()
      expect(await spoken).toBe(true)
    })
  })

  it('interrupts on the web by default, and the cue cut off settles false', async () => {
    const web = fakeWebSpeech()
    await withWindow(web.window, async () => {
      const first = speech.speak('Work')
      const second = speech.speak('Rest')
      expect(await first).toBe(false)
      web.spoken[0].onend()
      expect(await second).toBe(true)

      const queued = speech.speak('Then', { interrupt: false })
      expect(web.cancels()).toBe(2)
      void speech.stop()
      expect(await queued).toBe(false)
    })
  })

  it('answers false without throwing where there is no speech at all', async () => {
    await withWindow({}, async () => {
      expect(speech.isAvailable()).toBe(false)
      expect(await speech.speak('Go')).toBe(false)
      await speech.stop()
    })
    await withWindow(undefined, async () => {
      expect(speech.isAvailable()).toBe(false)
      expect(await speech.speak('Go')).toBe(false)
    })
  })

  it('refuses empty text where it could speak, the way native does', async () => {
    await withWindow(fakeWebSpeech().window, async () => {
      await expect(speech.speak('  ')).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
    })
  })

  it('is on the default mobile export beside keepAwake', () => {
    expect(mobile.speech).toBe(speech)
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
