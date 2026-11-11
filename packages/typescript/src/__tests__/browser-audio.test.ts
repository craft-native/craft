import { expect, test } from 'bun:test'
import { createBrowserPlatform } from '../browser'

async function fixture(run: (host: Awaited<ReturnType<typeof createBrowserPlatform>>, sounds: FakeAudio[]) => Promise<void>) {
  const sounds: FakeAudio[] = []
  const data = new Map<string, string>()
  const saved = new Map<string, PropertyDescriptor | undefined>()
  const globals = {
    localStorage: { get length() { return data.size }, getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => { data.set(key, value) }, removeItem: (key: string) => data.delete(key), key: (i: number) => [...data.keys()][i] ?? null },
    window: { addEventListener() {}, removeEventListener() {} }, document: undefined,
    location: { origin: 'https://fixture.invalid', href: 'https://fixture.invalid/' },
    navigator: { language: 'en', userAgent: 'Fixture' },
    Audio: class extends FakeAudio { constructor(src: string) { super(src); sounds.push(this) } },
  }
  for (const [key, value] of Object.entries(globals)) { saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key)); Object.defineProperty(globalThis, key, { configurable: true, writable: true, value }) }
  let host: Awaited<ReturnType<typeof createBrowserPlatform>> | undefined
  try { host = await createBrowserPlatform(); await run(host, sounds) }
  finally { host?.dispose(); for (const [key, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else Reflect.deleteProperty(globalThis, key) } }
}
class FakeAudio {
  paused = true
  volume = 1
  loop = false
  onended: (() => void) | null = null
  onerror: (() => void) | null = null
  error = null
  constructor(public src: string) {}
  async play() { this.paused = false }
  pause() { this.paused = true }
  removeAttribute(name: string) { if (name === 'src') this.src = '' }
}
const signal = () => new AbortController().signal

test('simultaneous plays of one ID retain only the newest audio owner', async () => {
  await fixture(async (host, sounds) => {
    const first = host.call('Audio', 'play', ['ambient', '/birds.wav', { loop: true }], signal()).catch(error => error)
    const second = host.call('Audio', 'play', ['ambient', '/birds.wav', { loop: true }], signal())
    expect(await first).toMatchObject({ name: 'AbortError' })
    expect(await second).toBe(true)
    expect(sounds.filter(sound => !sound.paused)).toHaveLength(1)
    await host.call('Audio', 'stopAll', [], signal())
    expect(sounds.every(sound => sound.paused && !sound.src)).toBe(true)
  })
})

test('stopping or disposing pending media never constructs or starts delayed audio', async () => {
  for (const action of ['stop', 'stopAll', 'dispose']) await fixture(async (host, sounds) => {
    let release!: (url: string) => void
    let entered!: () => void
    const waiting = new Promise<void>(resolve => { entered = resolve })
    host.resolveMedia = () => { entered(); return new Promise(resolve => { release = resolve }) }
    const playing = host.call('Audio', 'play', ['ambient', '/birds.wav', {}], signal()).catch(error => error)
    await waiting
    if (action === 'dispose') host.dispose()
    else await host.call('Audio', action, ['ambient'], signal())
    release('/birds.wav')
    expect(await playing).toMatchObject({ name: 'AbortError' })
    expect(sounds).toHaveLength(0)
  })
})

test('disposal and cancellation silence an audio element whose play promise is pending', async () => {
  for (const dispose of [true, false]) await fixture(async (host, sounds) => {
    let release!: () => void
    let entered!: () => void
    const waiting = new Promise<void>(resolve => { entered = resolve })
    const original = FakeAudio.prototype.play
    FakeAudio.prototype.play = async function () { this.paused = false; entered(); await new Promise<void>(resolve => { release = resolve }) }
    try {
      const abort = new AbortController()
      const playing = host.call('Audio', 'play', ['ambient', '/birds.wav', {}], abort.signal).catch(error => error)
      await waiting
      if (dispose) host.dispose(); else abort.abort()
      expect(sounds.every(sound => sound.paused && !sound.src)).toBe(true)
      release()
      expect(await playing).toMatchObject({ name: 'AbortError' })
    }
    finally { FakeAudio.prototype.play = original }
  })
})

test('a replaced element ending cannot remove its successor, and rejected playback releases ownership', async () => {
  await fixture(async (host, sounds) => {
    await host.call('Audio', 'play', ['ambient', '/one.wav', {}], signal())
    const ended = sounds[0]!.onended!
    await host.call('Audio', 'play', ['ambient', '/two.wav', {}], signal())
    ended()
    await host.call('Audio', 'stopAll', [], signal())
    expect(sounds.every(sound => sound.paused && !sound.src)).toBe(true)
    const original = FakeAudio.prototype.play
    FakeAudio.prototype.play = async () => { throw new Error('Autoplay denied') }
    try { await expect(host.call('Audio', 'play', ['ambient', '/denied.wav', {}], signal())).rejects.toThrow('Autoplay denied') }
    finally { FakeAudio.prototype.play = original }
    expect(sounds.every(sound => sound.paused && !sound.src)).toBe(true)
  })
})

test('a fade is a number or none, and a malformed setVolume leaves the sound as it was, as on the native hosts', async () => {
  // A fade that started would wait on these frames, which never come.
  const frames: unknown[] = []
  const saved = ['requestAnimationFrame', 'cancelAnimationFrame'].map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)] as const)
  Object.defineProperty(globalThis, 'requestAnimationFrame', { configurable: true, writable: true, value: (frame: unknown) => frames.push(frame) })
  Object.defineProperty(globalThis, 'cancelAnimationFrame', { configurable: true, writable: true, value: () => {} })
  const settled = async (call: Promise<unknown>) => Promise.race([call, new Promise(resolve => setTimeout(resolve, 50, 'still fading'))])
  try {
    // stop: text is not a duration, so there is no fade. `Number("500")` began one.
    for (const fadeOut of ['500', true, null, -500, { ms: 500 }]) await fixture(async (host, sounds) => {
      await host.call('Audio', 'play', ['tone', '/tone.wav', {}], signal())
      expect(await settled(host.call('Audio', 'stop', ['tone', { fadeOut }], signal())), `stop with fadeOut ${JSON.stringify(fadeOut)}`).toBe(true)
      expect(sounds[0]!.paused, `stop with fadeOut ${JSON.stringify(fadeOut)} left the sound playing`).toBe(true)
      expect(frames, 'no fade may have begun').toHaveLength(0)
    })
    await fixture(async (host, sounds) => {
      await host.call('Audio', 'play', ['tone', '/tone.wav', {}], signal())
      expect(await settled(host.call('Audio', 'stopAll', [{ fadeOut: '500' }], signal()))).toBe(true)
      expect(sounds[0]!.paused).toBe(true)
    })
    // setVolume: false, and nothing changes, for what is not a volume or not a fade.
    await fixture(async (host, sounds) => {
      await host.call('Audio', 'play', ['tone', '/tone.wav', { volume: 0.8 }], signal())
      for (const args of [['tone', 'loud'], ['tone', '0.5'], ['tone', true], ['tone', null], ['tone'], ['tone', 0.5, { fade: -10 }]] as unknown[][]) {
        expect(await settled(host.call('Audio', 'setVolume', args, signal())), `setVolume${JSON.stringify(args)}`).toBe(false)
        expect(sounds[0]!.volume, `setVolume${JSON.stringify(args)} changed the volume`).toBe(0.8)
      }
      // A fade given as text is no fade: the volume is set now.
      expect(await settled(host.call('Audio', 'setVolume', ['tone', 0.5, { fade: '500' }], signal()))).toBe(true)
      expect(sounds[0]!.volume).toBe(0.5)
      expect(frames).toHaveLength(0)
      expect(await host.call('Audio', 'setVolume', ['missing', 0.5], signal())).toBe(false)
    })
  }
  finally { for (const [key, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else Reflect.deleteProperty(globalThis, key) } }
})
