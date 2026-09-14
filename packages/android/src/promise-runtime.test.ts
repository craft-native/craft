import { describe, expect, it } from 'bun:test'
import { ANDROID_PROMISE_RUNTIME, renderAndroidPromiseRuntime } from './promise-runtime'

type NativePromise = (
  channel: string,
  resolveName: string,
  rejectName: string,
  invoke: () => void,
  timeoutMs?: number,
  timeoutError?: unknown,
) => Promise<unknown>

interface RuntimeWindow extends Record<string, unknown> {
  __craftPendingPromises: Record<string, unknown>
  __craftPromise: NativePromise
  __craftRejectPendingPromises: (message?: string) => void
}

function installRuntime(runtimeWindow = {} as RuntimeWindow): RuntimeWindow {
  const install = new Function('window', ANDROID_PROMISE_RUNTIME)
  install(runtimeWindow)
  return runtimeWindow
}

describe('Android promise runtime', () => {
  it('rejects competing requests without replacing the active callbacks', async () => {
    const runtimeWindow = installRuntime()
    let calls = 0
    const first = runtimeWindow.__craftPromise('camera', 'cameraResolve', 'cameraReject', () => {
      calls += 1
    })
    const firstResolve = runtimeWindow.cameraResolve

    await expect(runtimeWindow.__craftPromise('camera', 'cameraResolve', 'cameraReject', () => {
      calls += 1
    })).rejects.toThrow('A camera request is already in progress')

    expect(calls).toBe(1)
    expect(runtimeWindow.cameraResolve).toBe(firstResolve)
    ;(firstResolve as (value: unknown) => void)({ uri: 'content://image' })
    await expect(first).resolves.toEqual({ uri: 'content://image' })
    expect(runtimeWindow.cameraResolve).toBeNull()
    expect(runtimeWindow.cameraReject).toBeNull()
    expect(runtimeWindow.__craftPendingPromises.camera).toBeUndefined()
  })

  it('cleans up after synchronous native exceptions and timeouts', async () => {
    const runtimeWindow = installRuntime()
    const nativeError = new Error('Native bridge unavailable')

    await expect(runtimeWindow.__craftPromise('push', 'pushResolve', 'pushReject', () => {
      throw nativeError
    })).rejects.toBe(nativeError)
    expect(runtimeWindow.__craftPendingPromises.push).toBeUndefined()

    const timeoutError = { code: 2, message: 'Location timed out' }
    await expect(runtimeWindow.__craftPromise(
      'location',
      'locationResolve',
      'locationReject',
      () => {},
      1,
      timeoutError,
    )).rejects.toBe(timeoutError)
    expect(runtimeWindow.locationResolve).toBeNull()
    expect(runtimeWindow.locationReject).toBeNull()
  })

  it('rejects and clears every request when the bridge closes', async () => {
    const runtimeWindow = installRuntime()
    const camera = runtimeWindow.__craftPromise('camera', 'cameraResolve', 'cameraReject', () => {})
    const review = runtimeWindow.__craftPromise('review', 'reviewResolve', 'reviewReject', () => {})

    runtimeWindow.__craftRejectPendingPromises('Android bridge closed')

    await expect(camera).rejects.toThrow('Android bridge closed')
    await expect(review).rejects.toThrow('Android bridge closed')
    expect(Object.keys(runtimeWindow.__craftPendingPromises)).toEqual([])
  })

  it('rejects active work before reinstalling the bridge runtime', async () => {
    const runtimeWindow = installRuntime()
    const pending = runtimeWindow.__craftPromise('camera', 'cameraResolve', 'cameraReject', () => {})

    installRuntime(runtimeWindow)

    await expect(pending).rejects.toThrow('Android bridge reinitialized')
    expect(Object.keys(runtimeWindow.__craftPendingPromises)).toEqual([])
  })

  it('renders with the requested Kotlin indentation', () => {
    const rendered = renderAndroidPromiseRuntime('            ')
    expect(rendered.split('\n').every(line => line.startsWith('            '))).toBe(true)
    expect(rendered).toContain('window.__craftRejectPendingPromises')
  })
})
