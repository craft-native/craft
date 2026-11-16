import { expect, test } from 'bun:test'
import { verifyMobileMediaCache } from '../mobile-testing'
import { androidMediaProbeSource, mediaCommandFailure, mediaCommandLimitMs } from '../mobile-media-testing'

test('the Android media probe includes the shipped resumable downloader and durable worker', async () => {
  const shell = await Bun.file(new URL('../../../android/templates/CraftNativeShell.kt.template', import.meta.url)).text()
  const source = androidMediaProbeSource(shell)
  expect(source).toContain('internal object CraftNativeMedia {')
  expect(source).toContain('internal class CraftResumableDownload(')
  expect(source).toContain('internal class CraftNativeMediaWorker(')
  expect(source).not.toContain('internal class CraftNativeChunks')
  expect(() => androidMediaProbeSource(source.replace('internal class CraftNativeMediaWorker', 'class MissingWorker'))).toThrow('CraftNativeMediaWorker')
})

test('media cache tests reject an unknown platform before creating a probe', async () => {
  await expect(verifyMobileMediaCache({ platform: 'desktop' as any })).rejects.toThrow('Choose ios or android')
})

test('media cache tests refuse physical and implicit Android devices', async () => {
  await expect(verifyMobileMediaCache({ platform: 'android' })).rejects.toThrow('explicit disposable Android emulator')
  await expect(verifyMobileMediaCache({ platform: 'android', device: 'phone-123' })).rejects.toThrow('explicit disposable Android emulator')
})

test('media cache tests refuse implicit iOS device selectors', async () => {
  await expect(verifyMobileMediaCache({ platform: 'ios', device: 'booted' })).rejects.toThrow('simulator UUID')
})

test('media cache source overrides must be explicit local paths', async () => {
  await expect(verifyMobileMediaCache({ platform: 'ios', sourceRoot: 'https://example.invalid' })).rejects.toThrow('absolute local path')
})

test('a media harness command stopped by its limit says so, with the time it took (#549)', async () => {
  const create = ['hdiutil', 'create', '-size', '16m', '/scratch/cache-pressure.sparseimage']
  // hdiutil exits 1 and prints this when the limit's signal reaches it.
  const stopped = mediaCommandFailure(create, 1, 180_012, '', 'canceling...\nhdiutil: create canceled', 180_000)
  expect(stopped).toStartWith('hdiutil create was stopped at its 180 s limit (after 180.0 s):')
  expect(stopped).toContain('hdiutil: create canceled')
  const failed = mediaCommandFailure(create, 1, 2_345, '', 'hdiutil: create failed - No space left on device', 180_000)
  expect(failed).toStartWith('hdiutil failed (1) after 2.3 s:')
  expect(failed).not.toContain('limit')
  expect(mediaCommandLimitMs).toBe(180_000)
  const harness = await Bun.file(new URL('../mobile-media-testing.ts', import.meta.url)).text()
  expect(harness).toContain('timeout: mediaCommandLimitMs')
  expect(harness).toContain('throw new Error(mediaCommandFailure(args, status, elapsedMs, output, errors))')
})
