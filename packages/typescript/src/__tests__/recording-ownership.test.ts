import { afterEach, expect, test } from 'bun:test'
import { crypto, heartRate, location, storage } from '../api/mobile'

const originalWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
afterEach(() => {
  if (originalWindow) Object.defineProperty(globalThis, 'window', originalWindow)
  else Reflect.deleteProperty(globalThis, 'window')
})

function host(capable: boolean) {
  const calls: unknown[][] = []
  const namespace = Object.fromEntries(['startRecording', 'pauseRecording', 'resumeRecording', 'stopRecording', 'readRecording', 'getRecordingState', 'acknowledgeRecording'].map(method => [method, async (...args: unknown[]) => {
    calls.push([method, ...args])
    return method === 'acknowledgeRecording' ? true : method === 'readRecording' ? [] : { id: 'owned', active: true, paused: false, startedAt: 1 }
  }]))
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { craft: {
    capabilities: { geolocation: true, heartRate: true, locationRecordingOwnership: capable, heartRateRecordingOwnership: capable, locationRecordingIntentIdentity: capable, heartRateRecordingIntentIdentity: capable },
    location: namespace, heartRate: namespace,
  } } })
  return calls
}

for (const [name, api] of [['GPS', location], ['heart rate', heartRate]] as const) {
  test(`${name} refuses guarded calls on an old host before any native operation`, async () => {
    const calls = host(false)
    expect(api.supportsRecordingOwnership()).toBe(false)
    for (const method of ['pauseRecording', 'resumeRecording', 'stopRecording', 'readRecording', 'getRecordingState', 'acknowledgeRecording'] as const)
      await expect(api[method]({ expectedId: 'owned' })).rejects.toMatchObject({ code: 'RECORDING_OWNERSHIP_UNSUPPORTED' })
    expect(calls).toEqual([])
  })

  test(`${name} forwards the expected recording ID through every guarded operation`, async () => {
    const calls = host(true)
    expect(api.supportsRecordingOwnership()).toBe(true)
    for (const method of ['pauseRecording', 'resumeRecording', 'stopRecording', 'readRecording', 'getRecordingState', 'acknowledgeRecording'] as const)
      await api[method]({ expectedId: 'owned' })
    expect(calls).toEqual(['pauseRecording', 'resumeRecording', 'stopRecording', 'readRecording', 'getRecordingState', 'acknowledgeRecording'].map(method => [method, { expectedId: 'owned' }]))
  })

  test(`${name} rejects malformed identities without turning them into an unfenced operation`, async () => {
    const calls = host(true)
    for (const expectedId of ['', '  ', null, undefined, 42]) {
      // Exercise JavaScript callers at the native boundary as well as typed callers.
      await expect(api.pauseRecording({ expectedId } as never)).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
    }
    expect(calls).toEqual([])
  })
}

test('heart-rate guarded reads preserve the existing since filter', async () => {
  const calls = host(true)
  await heartRate.readRecording({ expectedId: 'owned', since: 125 })
  expect(calls).toEqual([['readRecording', { expectedId: 'owned', since: 125 }]])
})

test('route reads pass since to the host, which answers with only the newer fixes', async () => {
  const calls = host(true)
  await location.readRecording({ expectedId: 'owned', since: 1_730_000_000_000 })
  expect(calls).toEqual([['readRecording', { expectedId: 'owned', since: 1_730_000_000_000 }]])
})

for (const capable of [false, true]) {
  test(`storage CAS refuses an incomplete host (${capable}) before any write`, async () => {
    const calls: unknown[] = []
    Object.defineProperty(globalThis, 'window', { configurable: true, value: { craft: {
      capabilities: { storage: true, storageCompareAndSet: capable },
      storage: capable ? { set: (...args: unknown[]) => calls.push(args) } : { compareAndSet: (...args: unknown[]) => calls.push(args) },
    } } })
    expect(storage.supportsCompareAndSet()).toBe(false)
    await expect(storage.compareAndSet('draft', { id: 'A' }, { id: 'A', complete: true })).rejects.toMatchObject({ code: 'STORAGE_COMPARE_AND_SET_UNSUPPORTED' })
    expect(calls).toEqual([])
  })
}

test('storage CAS preserves arguments, false conflicts and real storage failures', async () => {
  const calls: unknown[][] = []
  const full = new Error('disk full')
  let outcome: boolean | Error = false
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { craft: {
    capabilities: { storage: true, storageCompareAndSet: true },
    storage: { compareAndSet: async (...args: unknown[]) => {
      calls.push(args)
      if (outcome instanceof Error) throw outcome
      return outcome
    } },
  } } })
  expect(storage.supportsCompareAndSet()).toBe(true)
  const old = { owner: 'A', feedback: 'latest' }
  const next = { ...old, complete: true }
  expect(await storage.compareAndSet('draft', old, next)).toBe(false)
  outcome = true
  expect(await storage.compareAndSet('draft', old, next)).toBe(true)
  outcome = full
  await expect(storage.compareAndSet('draft', old, next)).rejects.toBe(full)
  expect(calls).toEqual(Array.from({ length: 3 }, () => ['draft', old, next]))
})

test('initial storage registration requires its own capability and forwards false without fallback', async () => {
  const calls: unknown[][] = []
  const native = { setIfAbsent: async (...args: unknown[]) => { calls.push(args); return false } }
  const craft = { capabilities: { storageSetIfAbsent: false }, storage: native }
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { craft } })
  expect(storage.supportsSetIfAbsent()).toBe(false)
  await expect(storage.setIfAbsent('intent', null)).rejects.toMatchObject({ code: 'STORAGE_SET_IF_ABSENT_UNSUPPORTED' })
  expect(calls).toEqual([])
  craft.capabilities.storageSetIfAbsent = true
  expect(storage.supportsSetIfAbsent()).toBe(true)
  expect(await storage.setIfAbsent('intent', null)).toBe(false)
  expect(calls).toEqual([['intent', null]])
})

for (const [name, api] of [['GPS', location], ['heart rate', heartRate]] as const) {
  test(`${name} starts the persisted ID and refuses old hosts and malformed IDs`, async () => {
    const old = host(false)
    expect(api.supportsRecordingIntentIdentity()).toBe(false)
    await expect(api.startRecording({ recordingId: 'owned' })).rejects.toMatchObject({ code: 'RECORDING_INTENT_IDENTITY_UNSUPPORTED' })
    expect(old).toEqual([])
    const calls = host(true)
    expect(api.supportsRecordingIntentIdentity()).toBe(true)
    expect(await api.startRecording({ recordingId: 'owned' })).toMatchObject({ id: 'owned' })
    expect(calls).toEqual([['startRecording', { recordingId: 'owned' }]])
    await expect(api.startRecording({ recordingId: 'different' })).rejects.toMatchObject({ code: 'RECORDING_CONFLICT' })
    const count = calls.length
    for (const recordingId of ['', '  ', null, undefined, 42])
      await expect(api.startRecording({ recordingId } as never)).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
    expect(calls.length).toBe(count)
  })
}

test('secure UUIDs use the advertised native service and never fall back on old hosts', async () => {
  let calls = 0
  let result = 'c4847342-93ce-4b80-bdc1-d26075fbc1d3'
  const craft = { capabilities: { crypto: false }, crypto: { randomUUID: async () => { calls += 1; return result } } }
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { craft } })
  await expect(crypto.randomUUID()).rejects.toMatchObject({ code: 'CRYPTO_UNSUPPORTED' })
  expect(calls).toBe(0)
  craft.capabilities.crypto = true
  expect(await crypto.randomUUID()).toBe(result)
  result = 'Math.random-is-not-a-UUID'
  await expect(crypto.randomUUID()).rejects.toMatchObject({ code: 'CRYPTO_INVALID_RESPONSE' })
  expect(calls).toBe(2)
})

function powerHost(capable: boolean, recording = true) {
  const calls: unknown[][] = []
  const call = (method: string, state: () => unknown) => async (...args: unknown[]) => {
    calls.push([method, ...args])
    return state()
  }
  const state = () => ({ id: 'owned', active: true, paused: false, startedAt: 1, powerMode: 'saver', effectivePowerMode: 'saver' })
  const namespace: Record<string, unknown> = Object.fromEntries(['startRecording', 'pauseRecording', 'resumeRecording', 'stopRecording', 'readRecording', 'getRecordingState', 'acknowledgeRecording'].map(method => [method, call(method, state)]))
  if (recording) namespace.setRecordingPowerMode = call('setRecordingPowerMode', state)
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { craft: {
    capabilities: { geolocation: true, locationRecordingOwnership: true, locationRecordingPowerMode: capable },
    location: namespace,
  } } })
  return calls
}

test('the recording power mode is advertised like the other recording methods', () => {
  powerHost(true)
  expect(location.supportsRecordingPowerMode()).toBe(true)
  powerHost(false)
  expect(location.supportsRecordingPowerMode()).toBe(false)
  // The flag without the method, and the method without the flag, are both an old host.
  powerHost(true, false)
  expect(location.supportsRecordingPowerMode()).toBe(false)
  Reflect.deleteProperty(globalThis, 'window')
  expect(location.supportsRecordingPowerMode()).toBe(false)
})

test('setRecordingPowerMode sends the fenced mode to the host and returns its state', async () => {
  const calls = powerHost(true)
  const state = await location.setRecordingPowerMode({ expectedId: 'owned', powerMode: 'auto' })
  expect(calls).toEqual([['setRecordingPowerMode', { expectedId: 'owned', powerMode: 'auto' }]])
  expect(state).toMatchObject({ id: 'owned', powerMode: 'saver', effectivePowerMode: 'saver' })
})

test('setRecordingPowerMode refuses an unfenced call, an unknown mode and an old host before any native operation', async () => {
  let calls = powerHost(true)
  await expect(location.setRecordingPowerMode({ powerMode: 'saver' } as never)).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
  for (const expectedId of ['', '  ', null, undefined, 42])
    await expect(location.setRecordingPowerMode({ expectedId, powerMode: 'saver' } as never)).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
  for (const powerMode of ['', 'AUTO', 'battery', null, undefined, true])
    await expect(location.setRecordingPowerMode({ expectedId: 'owned', powerMode } as never)).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })
  expect(calls).toEqual([])

  calls = powerHost(false)
  await expect(location.setRecordingPowerMode({ expectedId: 'owned', powerMode: 'saver' })).rejects.toMatchObject({ code: 'RECORDING_POWER_MODE_UNSUPPORTED' })
  expect(calls).toEqual([])
})

test('startRecording passes default, saver and auto, and asks an old host before using auto', async () => {
  let calls = powerHost(true)
  for (const powerMode of ['default', 'saver', 'auto'] as const) await location.startRecording({ powerMode })
  expect(calls).toEqual(['default', 'saver', 'auto'].map(powerMode => ['startRecording', { powerMode }]))
  await expect(location.startRecording({ powerMode: 'battery' as never })).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })

  // 'saver' predates the capability; only 'auto' needs it.
  calls = powerHost(false)
  await location.startRecording({ powerMode: 'saver' })
  expect(calls).toEqual([['startRecording', { powerMode: 'saver' }]])
  await expect(location.startRecording({ powerMode: 'auto' })).rejects.toMatchObject({ code: 'RECORDING_POWER_MODE_UNSUPPORTED' })
  expect(calls).toHaveLength(1)
})

test('the browser recording reports its power mode and takes a new one while it runs', async () => {
  Reflect.deleteProperty(globalThis, 'window')
  const watches: ((position: GeolocationPosition) => void)[] = []
  const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { geolocation: {
    watchPosition: (callback: (position: GeolocationPosition) => void) => watches.push(callback),
    clearWatch: () => {},
  } } })
  try {
    await expect(location.setRecordingPowerMode({ expectedId: 'nothing', powerMode: 'saver' })).rejects.toMatchObject({ code: 'RECORDING_CONFLICT' })

    const started = await location.startRecording({ powerMode: 'saver' })
    expect(started).toMatchObject({ active: true, powerMode: 'saver', effectivePowerMode: 'saver' })
    await expect(location.setRecordingPowerMode({ expectedId: 'someone-else', powerMode: 'default' })).rejects.toMatchObject({ code: 'RECORDING_CONFLICT' })
    await expect(location.setRecordingPowerMode({ expectedId: started.id as string, powerMode: 'nope' as never })).rejects.toMatchObject({ code: 'INVALID_ARGUMENT' })

    // The browser has no power-saving signal: auto is kept as asked and runs as default.
    expect(await location.setRecordingPowerMode({ expectedId: started.id as string, powerMode: 'auto' }))
      .toMatchObject({ powerMode: 'auto', effectivePowerMode: 'default' })
    expect(await location.setRecordingPowerMode({ expectedId: started.id as string, powerMode: 'saver' }))
      .toMatchObject({ powerMode: 'saver', effectivePowerMode: 'saver' })
    expect(await location.getRecordingState({ expectedId: started.id as string })).toMatchObject({ powerMode: 'saver', effectivePowerMode: 'saver' })

    const stopped = await location.stopRecording({ expectedId: started.id as string })
    expect(stopped).toMatchObject({ active: false, powerMode: 'saver', effectivePowerMode: 'default' })
    await expect(location.setRecordingPowerMode({ expectedId: started.id as string, powerMode: 'default' })).rejects.toMatchObject({ code: 'NO_ACTIVE_RECORDING' })
    await location.acknowledgeRecording({ expectedId: started.id as string })
    expect(await location.getRecordingState()).toMatchObject({ id: null, powerMode: 'default', effectivePowerMode: 'default' })
  } finally {
    if (navigatorDescriptor) Object.defineProperty(globalThis, 'navigator', navigatorDescriptor)
    else Reflect.deleteProperty(globalThis, 'navigator')
  }
})
