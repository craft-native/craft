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
import mobile, { biometrics, brightness, bridgeNotification, crashReporter, files, health, heartRate, music, normalizeDeepLinkURL, normalizeScheduledWorkout, scheduledWorkouts, normalizeHeartRateReading, normalizeHeartRateSamples, normalizeHeartRateState, normalizeNowPlaying, notifications, pushNotifications, secureStorage, speech, splash, tabBar, watchConnectivity } from '../api/mobile'

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

describe('Mobile file picker', () => {
  it('forwards general picker options and returns owned file metadata', async () => {
    const options: any[] = []
    await withWindow({ craft: { files: { pickFile: async (value: unknown) => { options.push(value); return [{ path: '/tmp/route.gpx', name: 'route.gpx', type: 'application/gpx+xml', size: 42 }] } } } }, async () => {
      expect(await files.pickFile({ contentTypes: ['gpx', 'application/pdf'], maxSelections: 3, maxBytes: 1000 })).toEqual([{ path: '/tmp/route.gpx', name: 'route.gpx', type: 'application/gpx+xml', size: 42 }])
    })
    expect(options).toEqual([{ contentTypes: ['gpx', 'application/pdf'], maxSelections: 3, maxBytes: 1000 }])
  })
})

describe('Mobile biometrics contract', () => {
  it('forwards the reason and preserves the native unavailable type', async () => {
    const reasons: string[] = []
    await withWindow({
      craft: {
        biometrics: {
          isAvailable: async () => false,
          getBiometricType: async () => 'none',
          authenticate: async (reason: string) => { reasons.push(reason); return true },
        },
      },
    }, async () => {
      expect(await biometrics.isAvailable()).toBe(false)
      expect(await biometrics.getBiometricType()).toBe('none')
      expect(await biometrics.authenticate('Unlock the vault')).toBe(true)
    })
    expect(reasons).toEqual(['Unlock the vault'])
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

describe('Mobile crash reporter', () => {
  async function withCraft(craft: Record<string, unknown> | undefined, body: () => Promise<void>): Promise<void> {
    const previous = (globalThis as any).craft
    if (craft === undefined) delete (globalThis as any).craft
    else (globalThis as any).craft = craft
    try {
      await body()
    }
    finally {
      if (previous === undefined) delete (globalThis as any).craft
      else (globalThis as any).craft = previous
    }
  }

  it('hands events, the user id and breadcrumbs to the native reporter', async () => {
    const calls: unknown[][] = []
    const bridge = {
      capture: async (event: unknown) => { calls.push(['capture', event]); return true },
      setUser: async (id: unknown) => { calls.push(['setUser', id]); return true },
      addBreadcrumb: async (crumb: unknown) => { calls.push(['addBreadcrumb', crumb]); return true },
      flush: async () => { calls.push(['flush']); return true },
      context: async () => ({ enabled: true, release: '1.0.0+41' }),
    }
    // A web view declares capability flags; a native screen lists names.
    for (const capabilities of [{ crashReporter: true }, ['crashReporter']]) {
      await withCraft({ crashReporter: bridge, capabilities }, async () => {
        expect(crashReporter.isAvailable()).toBe(true)
      })
    }
    await withCraft({ crashReporter: bridge, capabilities: ['crashReporter'] }, async () => {
      expect(await crashReporter.capture({ type: 'TypeError', message: 'boom' })).toBe(true)
      expect(await crashReporter.setUser(967)).toBe(true)
      expect(await crashReporter.setUser(null)).toBe(true)
      expect(await crashReporter.addBreadcrumb({ type: 'navigation', message: '/m' })).toBe(true)
      expect(await crashReporter.flush()).toBe(true)
      expect(await crashReporter.context()).toEqual({ enabled: true, release: '1.0.0+41' })
    })
    expect(calls).toEqual([
      ['capture', { type: 'TypeError', message: 'boom' }],
      ['setUser', '967'],
      ['setUser', null],
      ['addBreadcrumb', { type: 'navigation', message: '/m' }],
      ['flush'],
    ])
  })

  it('answers false and null off the app, and never throws for a bridge that refuses', async () => {
    await withCraft(undefined, async () => {
      expect(crashReporter.isAvailable()).toBe(false)
      expect(await crashReporter.capture({ message: 'x' })).toBe(false)
      expect(await crashReporter.context()).toBeNull()
    })
    const refusing = { capture: async () => { throw new Error('CAPABILITY_DISABLED') }, setUser: async () => { throw new Error('no') }, addBreadcrumb: async () => false, flush: async () => false, context: async () => { throw new Error('no') } }
    await withCraft({ crashReporter: refusing, capabilities: { crashReporter: false } }, async () => {
      expect(crashReporter.isAvailable()).toBe(false)
      expect(await crashReporter.capture({ message: 'x' })).toBe(false)
      expect(await crashReporter.setUser('1')).toBe(false)
      expect(await crashReporter.context()).toBeNull()
    })
  })

  it('refuses an event without a message rather than queueing one bughq would reject', async () => {
    let called = false
    await withCraft({ crashReporter: { capture: async () => { called = true; return true } }, capabilities: ['crashReporter'] }, async () => {
      expect(await crashReporter.capture({ type: 'Error' })).toBe(false)
    })
    expect(called).toBe(false)
  })
})

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

/** A craft root with a backlight, recording what it was asked. */
function fakeBacklight(start: number, options: { reset?: boolean } = {}) {
  const calls: string[] = []
  let level = start
  const craft: Record<string, unknown> = {
    getBrightness: async () => { calls.push('get'); return level },
    setBrightness: async (next: number) => { calls.push(`set ${next}`); level = Math.min(1, Math.max(0, next)); return level },
  }
  if (options.reset) craft.resetBrightness = async () => { calls.push('reset'); level = start; return level }
  return { window: { craft }, calls, level: () => level }
}

describe('health reads', () => {
  it('saves a quantity through the bridge, including a dietary sample', async () => {
    const calls: unknown[][] = []
    await withWindow({
      craft: {
        health: {
          saveData: async (type: unknown, value: unknown, options: unknown) => {
            calls.push([type, value, options])
            return { id: 'HK-food-1' }
          },
        },
      },
    }, async () => {
      expect(health.supports('saveData')).toBe(true)
      expect(await health.saveData('dietaryProtein', 28, { startDate: 1000, endDate: 1000 })).toEqual({ id: 'HK-food-1' })
      expect(calls).toEqual([['dietaryProtein', 28, { startDate: 1000, endDate: 1000 }]])
    })
  })

  it('reads heart rate and sleep through the bridge, passing the range on', async () => {
    const calls: unknown[][] = []
    const reading = { bpm: 52, startDate: 1000, endDate: 1000, sourceName: 'Watch', deviceName: 'Apple Watch' }
    const night = { startDate: 0, endDate: 3600000, stage: 'deep', asleep: true, sourceName: 'Watch' }
    await withWindow({
      craft: {
        health: {
          getHeartRateSamples: async (options: unknown) => { calls.push(['hr', options]); return [reading] },
          getSleepIntervals: async (options: unknown) => { calls.push(['sleep', options]); return [night] },
        },
      },
    }, async () => {
      expect(health.supports('getHeartRateSamples')).toBe(true)
      expect(health.supports('getSleepIntervals')).toBe(true)
      expect(health.supports('getWorkouts')).toBe(false)
      expect(await health.getHeartRateSamples({ startDate: 0, endDate: 5000, limit: 100 })).toEqual([reading])
      expect(await health.getSleepIntervals({ startDate: 0, endDate: 5000 })).toEqual([night as any])
      expect(calls).toEqual([['hr', { startDate: 0, endDate: 5000, limit: 100 }], ['sleep', { startDate: 0, endDate: 5000 }]])
    })
  })

  it('reads glucose, insulin and carbs one sample at a time, passing the type and range on', async () => {
    const calls: unknown[][] = []
    const dose = { id: 'HK-ins-1', value: 1.5, unit: 'IU', startDate: 1000, endDate: 1000, sourceName: 'Loop', sourceBundleId: 'com.loopkit.Loop', ownApp: false, insulinReason: 'bolus' }
    await withWindow({ craft: { health: { getSamples: async (type: unknown, options: unknown) => { calls.push([type, options]); return [dose] } } } }, async () => {
      expect(health.supports('getSamples')).toBe(true)
      expect(await health.getSamples('insulinDelivery', { startDate: 0, endDate: 5000, limit: 50 })).toEqual([dose as any])
      expect(calls).toEqual([['insulinDelivery', { startDate: 0, endDate: 5000, limit: 50 }]])
    })
    await withWindow({ craft: { health: {} } }, async () => {
      expect(health.supports('getSamples')).toBe(false)
      await expect(health.getSamples('bloodGlucose')).rejects.toThrow('unavailable')
    })
  })

  it('saves and reads mindful sessions through the bridge', async () => {
    const calls: unknown[][] = []
    const sample = { id: 'HK-1', startDate: 0, endDate: 300000, durationSeconds: 300, sourceName: 'HQ', sourceBundleId: 'training.hq.app', ownApp: true, externalId: 'hq-1' }
    await withWindow({
      craft: {
        health: {
          saveMindfulSession: async (session: unknown) => { calls.push(['save', session]); return { id: 'HK-1', externalId: 'hq-1', existing: false } },
          getMindfulSessions: async (options: unknown) => { calls.push(['read', options]); return [sample] },
        },
      },
    }, async () => {
      expect(health.supports('saveMindfulSession')).toBe(true)
      expect(health.supports('getMindfulSessions')).toBe(true)
      expect(await health.saveMindfulSession({ id: 'hq-1', startDate: 0, endDate: 300000 })).toEqual({ id: 'HK-1', externalId: 'hq-1', existing: false })
      expect(await health.getMindfulSessions({ startDate: 0, endDate: 5000, limit: 10 })).toEqual([sample])
      expect(calls).toEqual([['save', { id: 'hq-1', startDate: 0, endDate: 300000 }], ['read', { startDate: 0, endDate: 5000, limit: 10 }]])
    })
    await withWindow({ craft: { health: {} } }, async () => {
      expect(health.supports('saveMindfulSession')).toBe(false)
      await expect(health.saveMindfulSession({ id: 'x', startDate: 0, endDate: 1 })).rejects.toThrow('unavailable')
      await expect(health.getMindfulSessions()).rejects.toThrow('unavailable')
    })
  })

  it('streams heart rate as Apple Health receives it, to every listener until it unsubscribes', async () => {
    const calls: unknown[][] = []
    const events = new EventTarget()
    const emit = (detail: unknown) => events.dispatchEvent(Object.assign(new Event('craftHealthHeartRate'), { detail }))
    const watch = { bpm: 64, startDate: 1000, endDate: 1000, sourceName: 'Apple Watch', deviceName: 'Apple Watch', motionContext: 'sedentary' as const }
    await withWindow({
      addEventListener: events.addEventListener.bind(events),
      removeEventListener: events.removeEventListener.bind(events),
      craft: {
        health: {
          startHeartRateUpdates: async (options: unknown) => { calls.push(['start', options]); return true },
          stopHeartRateUpdates: async () => { calls.push(['stop']); return true },
        },
      },
    }, async () => {
      expect(health.supports('startHeartRateUpdates')).toBe(true)
      expect(health.supports('stopHeartRateUpdates')).toBe(true)
      const batches: number[][] = []
      const stop = health.onHeartRate(samples => batches.push(samples.map(sample => sample.bpm)))
      expect(await health.startHeartRateUpdates({ since: 500 })).toBe(true)
      expect(await health.startHeartRateUpdates()).toBe(true)
      emit({ samples: [watch, { ...watch, bpm: 63, startDate: 6000, endDate: 6000 }] })
      // Nothing that is not a sample, and no call for a batch with none.
      emit({ samples: [{ bpm: 'x', startDate: 1, endDate: 1 }, null] })
      emit({})
      stop()
      emit({ samples: [watch] })
      expect(await health.stopHeartRateUpdates()).toBe(true)
      expect(batches).toEqual([[64, 63]])
      expect(calls).toEqual([['start', { since: 500 }], ['start', {}], ['stop']])
    })
  })

  it('has no stream in a browser or an older app: the calls refuse and onHeartRate never calls', async () => {
    for (const window of [undefined, { craft: { health: {} } }]) {
      await withWindow(window, async () => {
        expect(health.supports('startHeartRateUpdates')).toBe(false)
        await expect(health.startHeartRateUpdates()).rejects.toThrow('unavailable')
        await expect(health.stopHeartRateUpdates()).rejects.toThrow('unavailable')
        const stop = health.onHeartRate(() => { throw new Error('never') })
        expect(typeof stop).toBe('function')
        stop()
      })
    }
  })

  it('starts, pauses, resumes and ends a live workout, and filters lifecycle events', async () => {
    const events = new EventTarget()
    const calls: unknown[][] = []
    const started = { id: 'live-1', type: 'running' as const, startDate: 1000 }
    const ended = { id: 'live-1', workoutId: 'hk-1', endDate: 9000, durationSeconds: 8 }
    await withWindow({
      addEventListener: events.addEventListener.bind(events),
      removeEventListener: events.removeEventListener.bind(events),
      craft: { health: {
        startWorkout: async (options: unknown) => { calls.push(['start', options]); return started },
        pauseWorkout: async () => { calls.push(['pause']); return true },
        resumeWorkout: async () => { calls.push(['resume']); return true },
        endWorkout: async () => { calls.push(['end']); return ended },
      } },
    }, async () => {
      expect(health.supports('startWorkout')).toBe(true)
      const seen: string[] = []
      const stop = health.onWorkout(event => seen.push(`${event.event}:${event.state ?? event.message}`))
      expect(await health.startWorkout({ type: 'running', location: 'outdoor' })).toEqual(started)
      expect(await health.pauseWorkout()).toBe(true)
      expect(await health.resumeWorkout()).toBe(true)
      expect(await health.endWorkout()).toEqual(ended)
      events.dispatchEvent(Object.assign(new Event('craftHealthWorkout'), { detail: { id: 'live-1', event: 'state', state: 'paused' } }))
      events.dispatchEvent(Object.assign(new Event('craftHealthWorkout'), { detail: { id: 'live-1', event: 'metrics', heartRateBpm: 148, activeEnergyCalories: 12.5 } }))
      events.dispatchEvent(Object.assign(new Event('craftHealthWorkout'), { detail: { id: 'live-1', event: 'error', message: 'sensor failed' } }))
      events.dispatchEvent(Object.assign(new Event('craftHealthWorkout'), { detail: { id: 'live-1', event: 'unknown' } }))
      stop()
      expect(calls).toEqual([
        ['start', { type: 'running', location: 'outdoor' }],
        ['pause'], ['resume'], ['end'],
      ])
      expect(seen).toEqual(['state:paused', 'metrics:undefined', 'error:sensor failed'])
    })
  })

  it('discards a live workout without falling back to the save method', async () => {
    let saves = 0
    let discards = 0
    await withWindow({ craft: { health: {
      endWorkout: async () => { saves++; throw new Error('must not save') },
      discardWorkout: async () => { discards++; return true },
    } } }, async () => {
      expect(health.supports('discardWorkout')).toBe(true)
      expect(await health.discardWorkout()).toBe(true)
    })
    expect(discards).toBe(1)
    expect(saves).toBe(0)
    for (const window of [undefined, { craft: { health: { endWorkout: async () => { saves++ } } } }]) {
      await withWindow(window, async () => {
        expect(health.supports('discardWorkout')).toBe(false)
        await expect(health.discardWorkout()).rejects.toThrow('unavailable')
      })
    }
    const failure = Object.assign(new Error('Already saving'), { code: 'WORKOUT_ENDING' })
    await withWindow({ craft: { health: { discardWorkout: async () => { throw failure } } } }, async () => {
      await expect(health.discardWorkout()).rejects.toBe(failure)
    })
    expect(saves).toBe(0)
  })

  it('says an older app cannot, and refuses rather than answering nothing', async () => {
    await withWindow({ craft: { health: {} } }, async () => {
      expect(health.supports('getHeartRateSamples')).toBe(false)
      await expect(health.getHeartRateSamples()).rejects.toThrow('unavailable')
      await expect(health.getSleepIntervals()).rejects.toThrow('unavailable')
    })
    await withWindow({}, async () => {
      expect(health.supports('getSleepIntervals')).toBe(false)
    })
  })
})

describe('brightness', () => {
  it('dims, then puts the person\'s own level back', async () => {
    const screen = fakeBacklight(0.8)
    await withWindow(screen.window, async () => {
      expect(brightness.isAvailable()).toBe(true)
      expect(await brightness.set(0.1)).toBe(0.1)
      expect(await brightness.set(0.05)).toBe(0.05)
      await brightness.restore()
      expect(screen.level()).toBe(0.8)
      // The level to go back to is read once, before the first change.
      expect(screen.calls).toEqual(['get', 'set 0.1', 'set 0.05', 'set 0.8'])
    })
  })

  it('hands the screen back to the system where the platform can (Android)', async () => {
    const screen = fakeBacklight(0.6, { reset: true })
    await withWindow(screen.window, async () => {
      await brightness.set(0.2)
      await brightness.restore()
      expect(screen.calls.at(-1)).toBe('reset')
    })
  })

  it('clamps the level and refuses what is not a number', async () => {
    const screen = fakeBacklight(0.5)
    await withWindow(screen.window, async () => {
      expect(await brightness.set(3)).toBe(1)
      expect(await brightness.set(Number.NaN)).toBe(null)
      await brightness.restore()
    })
  })

  it('does nothing off a phone, and restore is safe with nothing set', async () => {
    await withWindow({}, async () => {
      expect(brightness.isAvailable()).toBe(false)
      expect(await brightness.get()).toBe(null)
      expect(await brightness.set(0.1)).toBe(null)
      await brightness.restore()
    })
    const screen = fakeBacklight(0.4)
    await withWindow(screen.window, async () => {
      await brightness.restore()
      expect(screen.calls).toEqual([])
    })
  })

  it('is on the default mobile export', () => {
    expect(mobile.brightness).toBe(brightness)
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

describe('Mobile native chrome', () => {
  it('describes the tab bar and the splash to the shell, through its own channel', () => {
    const previousWindow = (globalThis as any).window
    const posted: unknown[] = []
    const listeners = new Map<string, (event: Event) => void>()
    ;(globalThis as any).window = {
      webkit: { messageHandlers: { craftChrome: { postMessage: (message: unknown) => posted.push(message) } } },
      addEventListener: (name: string, listener: (event: Event) => void) => listeners.set(name, listener),
      removeEventListener: (name: string) => listeners.delete(name),
    }
    try {
      expect(tabBar.isAvailable()).toBe(true)
      expect(tabBar.set([{ id: '/m', title: 'Today', symbol: 'sun.max' }], {
        selected: '/m',
        tint: '#1d4ed8',
        swipeEnabled: false,
        selection: { cornerRadius: 6 },
      })).toBe(true)
      tabBar.select('/m/calendar')
      tabBar.hide()
      splash.hide()
      expect(posted).toEqual([
        {
          type: 'tabBar',
          tabs: [{ id: '/m', title: 'Today', symbol: 'sun.max' }],
          selected: '/m',
          tint: '#1d4ed8',
          swipeEnabled: false,
          selection: { cornerRadius: 6 },
        },
        { type: 'selectTab', id: '/m/calendar' },
        { type: 'hideTabBar' },
        { type: 'ready' },
      ])

      const selected: string[] = []
      const stop = tabBar.onSelect(id => selected.push(id))
      listeners.get('craftTabSelect')!({ detail: { id: '/m/health' } } as unknown as Event)
      listeners.get('craftTabSelect')!({ detail: { id: 42 } } as unknown as Event)
      stop()
      expect(selected).toEqual(['/m/health'])
      expect(listeners.has('craftTabSelect')).toBe(false)
      expect(mobile.tabBar).toBe(tabBar)
      expect(mobile.splash).toBe(splash)
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })

  it('answers false in a browser, so the page draws its own bar', () => {
    const previousWindow = (globalThis as any).window
    ;(globalThis as any).window = {}
    try {
      expect(tabBar.isAvailable()).toBe(false)
      expect(tabBar.set([])).toBe(false)
      expect(splash.hide()).toBe(false)
    }
    finally {
      if (previousWindow === undefined) delete (globalThis as any).window
      else (globalThis as any).window = previousWindow
    }
  })
})

describe('Mobile native UI', () => {
  const withWindow = async (window: Record<string, unknown> | undefined, run: () => Promise<void> | void) => {
    const previous = (globalThis as any).window
    ;(globalThis as any).window = window
    try { await run() }
    finally { (globalThis as any).window = previous }
  }

  it('resolves every call without the shell, never throwing', async () => {
    await withWindow({}, async () => {
      const { dialog, contextMenu, symbols, statusBar, chrome, refresh, background } = await import('../api/mobile')
      expect(dialog.isAvailable()).toBe(false)
      expect(await dialog.alert('Saved')).toBeUndefined()
      expect(await dialog.confirm({ title: 'Delete?' })).toBe(false)
      expect(await dialog.actionSheet({ actions: [{ id: 'a', title: 'A' }] })).toBeNull()
      expect(await contextMenu.show({ items: [{ id: 'a', title: 'A' }], anchor: { x: 0, y: 0, width: 1, height: 1 } })).toBeNull()
      expect(await symbols.image('heart.fill')).toBeNull()
      expect(await statusBar.setStyle('light')).toBe(false)
      expect(await chrome.setUnderPageColor('#000')).toBe(false)
      expect(await chrome.setKeyboardAccessory(true)).toBe(false)
      expect(await refresh.enable()).toBe(false)
      expect(await background.complete(true)).toBe(false)
    })
  })

  it('hands calls to the shell and settles a failure with the fallback', async () => {
    const calls: unknown[][] = []
    const warnings: unknown[][] = []
    const originalWarn = console.warn
    console.warn = (...args: unknown[]) => { warnings.push(args) }
    const craft = {
      dialog: {
        confirm: async (...args: unknown[]) => { calls.push(['confirm', ...args]); return true },
        actionSheet: async () => { throw new Error('native failed') },
      },
      browser: { open: async (...args: unknown[]) => { calls.push(['open', ...args]); return { url: 'hqtraining://done?code=1', cancelled: false } } },
      haptics: { prepare: async (...args: unknown[]) => { calls.push(['prepare', ...args]) } },
    }
    try {
      await withWindow({ craft }, async () => {
        const { dialog, browser, haptics } = await import('../api/mobile')
        expect(dialog.isAvailable()).toBe(true)
        expect(await dialog.confirm({ title: 'Delete?', destructive: true })).toBe(true)
        expect(await dialog.actionSheet({ actions: [] })).toBeNull()
        expect(await browser.open('https://auth.example.com', { mode: 'auth', callbackScheme: 'hqtraining' }))
          .toEqual({ url: 'hqtraining://done?code=1', cancelled: false })
        await haptics.prepare('selection')
      })
    }
    finally {
      console.warn = originalWarn
    }
    expect(calls).toEqual([
      ['confirm', { title: 'Delete?', destructive: true }],
      ['open', 'https://auth.example.com', { mode: 'auth', callbackScheme: 'hqtraining' }],
      ['prepare', 'selection'],
    ])
    expect(warnings).toHaveLength(1)
    expect(warnings[0]?.[0]).toBe('[craft] Native dialog.actionSheet failed; using its fallback value.')
    expect(warnings[0]?.[1]).toBeInstanceOf(Error)
  })

  it('opens a tab for the in-app browser on the web, and cannot sign in there', async () => {
    const opened: unknown[] = []
    await withWindow({ open: (...args: unknown[]) => { opened.push(args) } }, async () => {
      const { browser } = await import('../api/mobile')
      expect(await browser.open('https://example.com')).toEqual({ cancelled: false })
      expect(await browser.open('https://example.com', { mode: 'auth' })).toEqual({ cancelled: true })
    })
    expect(opened).toEqual([['https://example.com', '_blank', 'noopener']])
  })

  it('reads the shell\'s appearance, and the media queries without it', async () => {
    const native = { contentSizeCategory: 'extraLarge', fontScale: 1.118, reduceMotion: true, reduceTransparency: false, colorScheme: 'dark' }
    await withWindow({ craft: { appearance: native } }, async () => {
      const { appearance } = await import('../api/mobile')
      expect(appearance.get()).toEqual(native as any)
    })
    await withWindow({ matchMedia: (query: string) => ({ matches: query.includes('dark') }) }, async () => {
      const { appearance } = await import('../api/mobile')
      expect(appearance.get()).toEqual({ contentSizeCategory: 'large', fontScale: 1, reduceMotion: false, reduceTransparency: false, colorScheme: 'dark' })
    })
  })

  it('lists the new namespaces on the default export', () => {
    for (const name of ['dialog', 'contextMenu', 'browser', 'symbols', 'statusBar', 'chrome', 'refresh', 'background', 'appearance'])
      expect(typeof (mobile as any)[name]).toBe('object')
  })
})

/** The Music app as the bridge presents it, recording what it was asked. */
function fakeMusicApp(options: { authorization?: string, capability?: boolean } = {}) {
  const calls: string[] = []
  const events = new EventTarget()
  let authorization = options.authorization ?? 'notDetermined'
  let playing = false
  let song = 0
  const songs = ['Intervals', 'Long Way Home', 'Cooldown']
  const snapshot = () => authorization === 'authorized'
    ? { available: true, authorization, source: 'simulated', playbackState: playing ? 'playing' : 'paused', isPlaying: playing, itemId: `s${song}`, title: songs[song], artist: 'The Pacers', album: null, duration: 214, position: 12.5, artworkDataURL: 'data:image/jpeg;base64,AAAA', otherAudioPlaying: playing, timestamp: 1 }
    : { available: true, authorization, source: null, playbackState: 'unknown', isPlaying: false, itemId: null, title: null, artist: null, album: null, duration: null, position: null, artworkDataURL: null, otherAudioPlaying: false, timestamp: 1 }
  const command = (name: string, change: () => void) => async (opts?: unknown) => {
    calls.push(opts ? `${name} ${JSON.stringify(opts)}` : name)
    change()
    return snapshot()
  }
  const window = {
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    craft: {
      capabilities: { music: options.capability ?? true },
      music: {
        getAuthorizationStatus: async () => authorization,
        requestAuthorization: async () => {
          calls.push('requestAuthorization')
          authorization = 'authorized'
          return authorization
        },
        getNowPlaying: async () => snapshot(),
        play: command('play', () => { playing = true }),
        pause: command('pause', () => { playing = false }),
        togglePlayPause: command('togglePlayPause', () => { playing = !playing }),
        skipToNext: command('skipToNext', () => { song = (song + 1) % songs.length }),
        skipToPrevious: command('skipToPrevious', () => { song = (song + songs.length - 1) % songs.length }),
        observe: async (enabled: boolean) => {
          calls.push(`observe ${enabled}`)
          return enabled
        },
      },
    },
  }
  const push = () => events.dispatchEvent(Object.assign(new Event('craftMusicChange'), { detail: snapshot() }))
  return { window, calls, push, skip: () => { song = (song + 1) % songs.length } }
}

describe('music', () => {
  it('reads nothing until access is allowed, then shows the song', async () => {
    const app = fakeMusicApp()
    await withWindow(app.window, async () => {
      expect(music.isAvailable()).toBe(true)
      expect(await music.getAuthorizationStatus()).toBe('notDetermined')
      const before = await music.getNowPlaying()
      expect(before).toMatchObject({ available: true, authorization: 'notDetermined', title: null, isPlaying: false })
      expect(await music.requestAuthorization()).toBe('authorized')
      expect(await music.getNowPlaying()).toMatchObject({ title: 'Intervals', artist: 'The Pacers', duration: 214, source: 'simulated' })
    })
  })

  it('plays, pauses, toggles and skips through the bridge', async () => {
    const app = fakeMusicApp({ authorization: 'authorized' })
    await withWindow(app.window, async () => {
      expect((await music.play()).isPlaying).toBe(true)
      expect((await music.togglePlayPause()).isPlaying).toBe(false)
      expect((await music.skipToNext()).title).toBe('Long Way Home')
      expect((await music.skipToPrevious({ restartAfter: 0 })).title).toBe('Intervals')
      await music.pause()
      expect(app.calls).toEqual(['play', 'togglePlayPause', 'skipToNext', 'skipToPrevious {"restartAfter":0}', 'pause'])
    })
  })

  it('pushes changes to every listener and observes only while someone listens', async () => {
    const app = fakeMusicApp({ authorization: 'authorized' })
    await withWindow(app.window, async () => {
      const heard: string[] = []
      const other: string[] = []
      const stop = music.onChange(now => heard.push(now.title ?? ''))
      const stopOther = music.onChange(now => other.push(now.title ?? ''))
      app.skip()
      app.push()
      stop()
      app.skip()
      app.push()
      stopOther()
      app.push()
      expect(heard).toEqual(['Long Way Home'])
      expect(other).toEqual(['Long Way Home', 'Cooldown'])
      await Promise.resolve()
      expect(app.calls).toEqual(['observe true', 'observe false'])
    })
  })

  it('does nothing off a phone, or in an app built without it', async () => {
    for (const window of [{}, fakeMusicApp({ capability: false }).window]) {
      await withWindow(window, async () => {
        expect(music.isAvailable()).toBe(false)
        expect(music.supports('play')).toBe(false)
        expect(await music.getAuthorizationStatus()).toBe('unavailable')
        expect(await music.requestAuthorization()).toBe('unavailable')
        expect(await music.play()).toMatchObject({ available: false, authorization: 'unavailable', title: null })
        const stop = music.onChange(() => { throw new Error('never') })
        stop()
      })
    }
  })

  it('keeps a snapshot safe to render whatever native sent', () => {
    const now = normalizeNowPlaying({ authorization: 'authorized', playbackState: 'warping', title: '  ', duration: -4, artworkDataURL: 'https://example.com/a.jpg', isPlaying: 'yes' })
    expect(now).toMatchObject({ available: true, playbackState: 'unknown', title: null, duration: null, artworkDataURL: null, isPlaying: false })
    expect(normalizeNowPlaying(null)).toMatchObject({ available: false, authorization: 'unavailable' })
  })
})

/** A phone with a strap nearby: the bridge's calls, answered as CraftHeartRate.swift would. */
function fakeStrapApp(options: { capability?: boolean } = {}) {
  const calls: string[] = []
  const events = new EventTarget()
  const strap = { id: 'A1B2', name: 'Polar H10', rssi: -51 }
  let connection = 'disconnected'
  let recording = { id: null as string | null, active: false, paused: false, startedAt: null as number | null }
  const samples = [
    { timestamp: 2000, bpm: 141, rr: [425.8] },
    { timestamp: 1000, bpm: 140 },
    { timestamp: 1000, bpm: 139 },
    { timestamp: 3000, bpm: 0 },
  ]
  const state = () => ({ available: true, bluetooth: 'poweredOn', authorization: 'authorized', scanning: false, connection, device: connection === 'disconnected' ? null : strap, lastDevice: strap, bpm: connection === 'connected' ? 140 : null, lastReadingAt: null, recording })
  const call = (name: string, answer: () => unknown) => async (opts?: unknown) => {
    calls.push(opts === undefined ? name : `${name} ${JSON.stringify(opts)}`)
    return answer()
  }
  const emit = (detail: unknown) => events.dispatchEvent(Object.assign(new Event('craftHeartRate'), { detail }))
  const window = {
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    craft: {
      capabilities: { heartRate: options.capability ?? true },
      heartRate: {
        getState: call('getState', state),
        requestAuthorization: call('requestAuthorization', () => 'authorized'),
        scan: call('scan', () => { emit({ type: 'device', device: strap }); return { ...state(), scanning: true } }),
        stopScan: call('stopScan', state),
        getDevices: call('getDevices', () => [strap, { name: 'no id' }]),
        connect: call('connect', () => { connection = 'connected'; return state() }),
        reconnect: call('reconnect', () => { connection = 'connecting'; return state() }),
        disconnect: call('disconnect', () => { connection = 'disconnected'; return state() }),
        startRecording: call('startRecording', () => (recording = { id: 'r1', active: true, paused: false, startedAt: 500 })),
        pauseRecording: call('pauseRecording', () => (recording = { ...recording, paused: true })),
        resumeRecording: call('resumeRecording', () => (recording = { ...recording, paused: false })),
        stopRecording: call('stopRecording', () => ({ ...recording, active: false, samples })),
        getRecordingState: call('getRecordingState', () => ({ ...recording, sampleCount: 2 })),
        readRecording: call('readRecording', () => samples),
      },
    },
  }
  return { window, calls, emit }
}

describe('heartRate', () => {
  it('finds a strap, connects to it and records its readings', async () => {
    const app = fakeStrapApp()
    await withWindow(app.window, async () => {
      expect(heartRate.isAvailable()).toBe(true)
      expect(heartRate.supports('readRecording')).toBe(true)
      const found: string[] = []
      const stop = heartRate.onDevice(device => found.push(device.name))
      expect((await heartRate.scan({ timeout: 10 })).scanning).toBe(true)
      stop()
      expect(found).toEqual(['Polar H10'])
      expect(await heartRate.getDevices()).toEqual([{ id: 'A1B2', name: 'Polar H10', rssi: -51 }])
      const connected = await heartRate.connect('A1B2')
      expect(connected).toMatchObject({ connection: 'connected', device: { id: 'A1B2', name: 'Polar H10' }, bpm: 140 })
      expect((await heartRate.startRecording()).active).toBe(true)
      expect((await heartRate.pauseRecording()).paused).toBe(true)
      await heartRate.resumeRecording()
      expect(await heartRate.readRecording({ since: 0 })).toEqual([{ timestamp: 1000, bpm: 140 }, { timestamp: 2000, bpm: 141, rr: [425.8] }])
      const done = await heartRate.stopRecording()
      expect(done.active).toBe(false)
      expect(done.samples.map(s => s.bpm)).toEqual([140, 141])
      expect((await heartRate.disconnect({ forget: true })).connection).toBe('disconnected')
      expect(app.calls).toEqual(['scan {"timeout":10}', 'getDevices', 'connect "A1B2"', 'startRecording', 'pauseRecording', 'resumeRecording', 'readRecording {"since":0}', 'stopRecording', 'disconnect {"forget":true}'])
    })
  })

  it('hears readings and state changes while someone listens, and stops listening after', async () => {
    const app = fakeStrapApp()
    await withWindow(app.window, async () => {
      const bpm: number[] = []
      const states: string[] = []
      const stopReadings = heartRate.onReading(reading => bpm.push(reading.bpm))
      const stopStates = heartRate.onState(state => states.push(state.connection))
      app.emit({ type: 'reading', bpm: 152.4, rrIntervals: [394, 'x', -3], contact: true, energyExpended: null, timestamp: 9, deviceId: 'A1B2' })
      // A strap that lost the skin reads 0: no heart rate.
      app.emit({ type: 'reading', bpm: 0, timestamp: 10 })
      app.emit({ type: 'state', connection: 'reconnecting', bluetooth: 'poweredOn', authorization: 'authorized' })
      stopReadings()
      stopStates()
      app.emit({ type: 'reading', bpm: 150, timestamp: 11 })
      expect(bpm).toEqual([152])
      expect(states).toEqual(['reconnecting'])
    })
  })

  it('is a no-op in a browser and in a build without the capability', async () => {
    for (const window of [undefined, fakeStrapApp({ capability: false }).window]) {
      await withWindow(window, async () => {
        expect(heartRate.isAvailable()).toBe(false)
        expect(await heartRate.getState()).toMatchObject({ available: false, connection: 'disconnected', bpm: null })
        expect(await heartRate.requestAuthorization()).toBe('unavailable')
        expect(await heartRate.getDevices()).toEqual([])
        expect(await heartRate.stopRecording()).toMatchObject({ active: false, samples: [] })
        heartRate.onReading(() => { throw new Error('never') })()
      })
    }
  })

  it('reads the shapes Android sends as it reads iOS\'s', () => {
    // CraftHeartRate.kt's state() and reading detail, as org.json serializes
    // them: a Bluetooth address for an id, null for what the strap does not send.
    const strap = { id: 'C4:7F:51:0A:3E:21', name: 'Polar H10 9A1B2C3D' }
    expect(normalizeHeartRateState({
      available: true, bluetooth: 'poweredOn', authorization: 'notDetermined', scanning: false, connection: 'reconnecting',
      device: strap, lastDevice: strap, bpm: null, lastReadingAt: 1_800_000_000_000,
      recording: { id: 'run', active: true, paused: false, startedAt: 1_799_999_000_000 },
    })).toEqual({
      available: true, bluetooth: 'poweredOn', authorization: 'notDetermined', scanning: false, connection: 'reconnecting',
      device: { ...strap, rssi: null }, lastDevice: { ...strap, rssi: null }, bpm: null, lastReadingAt: 1_800_000_000_000,
      recording: { id: 'run', active: true, paused: false, startedAt: 1_799_999_000_000, sampleCount: null },
    })
    expect(normalizeHeartRateReading({ type: 'reading', bpm: 142, rrIntervals: [422.9, 418.0], contact: null, energyExpended: null, timestamp: 1_800_000_000_000, deviceId: strap.id }))
      .toEqual({ bpm: 142, rrIntervals: [422.9, 418], contact: null, energyExpended: null, timestamp: 1_800_000_000_000, deviceId: strap.id })
  })

  it('keeps only samples a heart could give, once each, oldest first', () => {
    expect(normalizeHeartRateSamples([{ timestamp: 5, bpm: 300 }, { timestamp: 4, bpm: 61.6, rr: [] }, { bpm: 70 }, null, { timestamp: 4, bpm: 62 }, { timestamp: 2, bpm: 60, rr: [1000] }]))
      .toEqual([{ timestamp: 2, bpm: 60, rr: [1000] }, { timestamp: 4, bpm: 62 }])
    expect(normalizeHeartRateSamples('nope')).toEqual([])
  })
})

/** A phone whose app schedules workouts onto a watch, as craft.scheduledWorkouts answers. */
function fakeWatchApp(options: { capability?: boolean } = {}) {
  const calls: string[] = []
  const kept: Array<{ id: string, date: string, hour?: number, minute?: number, complete: boolean }> = []
  const call = (name: string, answer: (arg?: any) => unknown) => async (arg?: unknown) => {
    calls.push(arg === undefined ? name : `${name} ${JSON.stringify(arg)}`)
    return answer(arg)
  }
  const window = {
    addEventListener() {},
    removeEventListener() {},
    craft: {
      capabilities: { scheduledWorkouts: options.capability ?? true },
      scheduledWorkouts: {
        isSupported: call('isSupported', () => true),
        authorization: call('authorization', () => 'notDetermined'),
        requestAuthorization: call('requestAuthorization', () => 'authorized'),
        list: call('list', () => [...kept, { id: 'not a row' }, null]),
        schedule: call('schedule', (plan) => {
          if (plan.workout.activity === 'curling') throw Object.assign(new Error("WorkoutKit has no activity 'curling'"), { code: 'INVALID_ARGUMENT' })
          kept.push({ id: plan.id.toUpperCase(), date: plan.date, hour: plan.hour ?? 7, minute: plan.minute ?? 0, complete: false })
          return { id: plan.id, droppedAlerts: ['block 1 step 1: power alert, which WorkoutKit refuses for running (outdoor)'] }
        }),
        remove: call('remove', (id) => {
          const before = kept.length
          kept.splice(0, kept.length, ...kept.filter(row => row.id.toLowerCase() !== id))
          return kept.length < before
        }),
        removeAll: call('removeAll', () => kept.splice(0).length),
      },
    },
  }
  return { window, calls }
}

const watchPlan = {
  id: '6f1c2b8e-5a7d-4c3e-9b1a-2d4e6f8a0b1c',
  date: '2026-10-20',
  hour: 6,
  minute: 30,
  workout: {
    activity: 'running',
    location: 'outdoor' as const,
    displayName: '4 x 1 km',
    blocks: [{ iterations: 4, steps: [{ purpose: 'work' as const, step: { goal: { type: 'distance' as const, meters: 1000 }, alert: { type: 'power' as const, min: 250, max: 280 } } }] }],
  },
}

describe('scheduledWorkouts', () => {
  it('asks, schedules, lists and removes plans on the watch', async () => {
    const app = fakeWatchApp()
    await withWindow(app.window, async () => {
      expect(scheduledWorkouts.isAvailable()).toBe(true)
      expect(scheduledWorkouts.supports('removeAll')).toBe(true)
      expect(await scheduledWorkouts.isSupported()).toBe(true)
      expect(await scheduledWorkouts.authorization()).toBe('notDetermined')
      expect(await scheduledWorkouts.requestAuthorization()).toBe('authorized')
      expect(await scheduledWorkouts.schedule(watchPlan)).toEqual({ id: watchPlan.id, droppedAlerts: ['block 1 step 1: power alert, which WorkoutKit refuses for running (outdoor)'] })
      // Ids come back lowercase; rows that are not plans are left out.
      expect(await scheduledWorkouts.list()).toEqual([{ id: watchPlan.id, date: '2026-10-20', hour: 6, minute: 30, complete: false }])
      expect(await scheduledWorkouts.remove(watchPlan.id)).toBe(true)
      expect(await scheduledWorkouts.remove(watchPlan.id)).toBe(false)
      await scheduledWorkouts.schedule({ ...watchPlan, hour: undefined, minute: undefined })
      expect(await scheduledWorkouts.removeAll()).toBe(1)
      expect(app.calls[0]).toBe('isSupported')
      expect(app.calls).toContain(`remove "${watchPlan.id}"`)
      expect(mobile.scheduledWorkouts).toBe(scheduledWorkouts)
    })
  })

  it('passes on what WorkoutKit refused', async () => {
    const app = fakeWatchApp()
    await withWindow(app.window, async () => {
      const refused = scheduledWorkouts.schedule({ ...watchPlan, workout: { ...watchPlan.workout, activity: 'curling' } })
      await expect(refused).rejects.toMatchObject({ message: "WorkoutKit has no activity 'curling'", code: 'INVALID_ARGUMENT' })
      await expect(scheduledWorkouts.schedule(null as any)).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
    })
  })

  it('is unsupported in a browser, on Android and in a build without the capability', async () => {
    for (const window of [undefined, { craft: { platform: 'android', capabilities: {} } }, fakeWatchApp({ capability: false }).window]) {
      await withWindow(window, async () => {
        expect(scheduledWorkouts.isAvailable()).toBe(false)
        expect(await scheduledWorkouts.isSupported()).toBe(false)
        for (const call of [
          () => scheduledWorkouts.authorization(),
          () => scheduledWorkouts.requestAuthorization(),
          () => scheduledWorkouts.list(),
          () => scheduledWorkouts.schedule(watchPlan),
          () => scheduledWorkouts.remove(watchPlan.id),
          () => scheduledWorkouts.removeAll(),
        ])
          await expect(call()).rejects.toMatchObject({ message: 'unsupported', code: 'UNSUPPORTED' })
      })
    }
  })

  it('answers false rather than rejecting when the phone cannot say', async () => {
    const app = fakeWatchApp()
    app.window.craft.scheduledWorkouts.isSupported = async () => { throw new Error('bridge timed out') }
    await withWindow(app.window, async () => {
      expect(await scheduledWorkouts.isSupported()).toBe(false)
    })
  })

  it('reads list rows defensively', () => {
    expect(normalizeScheduledWorkout({ id: 'ABC', date: '2026-10-20', complete: 1 })).toEqual({ id: 'abc', date: '2026-10-20', complete: false })
    expect(normalizeScheduledWorkout({ id: 'abc', date: '20-10-2026' })).toBeNull()
    expect(normalizeScheduledWorkout('abc')).toBeNull()
  })
})
