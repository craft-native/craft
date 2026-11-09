import { expect, test } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'
import { createAndroidEmulator } from './emulator'

/**
 * A provisioning failure actually writes the receipt, not just can.
 *
 * `describeDownloadedArchives` is covered by `sdk-download-identity.test.ts`,
 * which proves the classification. Nothing proved the wiring: that when
 * `sdkmanager` rejects what it downloaded, the staging directory is described
 * into `android-sdk-downloads.json` before everything is disposed.
 *
 * That gap matters more than usual here. The whole point of #451's retention
 * is to fire on a failure that has not recurred since it was written — the
 * leg has been green for six consecutive runs — so the first time it runs for
 * real will be the one time it has to work. A diagnostic whose only exercise
 * is the incident it was written for is not a diagnostic.
 *
 * `sdkmanager` stands in for the vendor tool. It stages a response under the
 * owned SDK root's `.temp` exactly where the real one does, then fails the
 * way #451 recorded: exit 1, with the ZipException on stderr and nothing said
 * about the bytes it read.
 */
const abi = process.arch === 'arm64' ? 'arm64-v8a' : 'x86_64'

/** A script at `path` that stages `body` as a download, then fails like the vendor tool. */
function standInSdkManager(path: string, sdk: string, body: string): void {
  writeFileSync(path, `#!/bin/sh
mkdir -p "${sdk}/.temp/PackageOperation01"
printf '%s' '${body}' > "${sdk}/.temp/PackageOperation01/emulator.zip"
echo 'Warning: An error occurred while preparing SDK package Android Emulator' >&2
echo 'java.util.zip.ZipException: Archive is not a ZIP archive' >&2
exit 1
`)
  chmodSync(path, 0o755)
}

test.skipIf(!['darwin', 'linux'].includes(process.platform))('a rejected download is described before anything is disposed', async () => {
  const dir = createTempDir('craft-android-provisioning-')
  try {
    const sdk = join(dir, 'sdk'), artifacts = join(dir, 'artifacts')
    mkdirSync(sdk, { recursive: true })
    const sdkmanager = join(dir, 'sdkmanager'), avdmanager = join(dir, 'avdmanager')
    // The response #451 could not rule out: an error page under a .zip name.
    standInSdkManager(sdkmanager, sdk, '<!DOCTYPE html><html><head><title>502</title></head></html>')
    writeFileSync(avdmanager, '#!/bin/sh\nexit 0\n')
    chmodSync(avdmanager, 0o755)

    await expect(createAndroidEmulator({
      sdkRoot: sdk,
      sdkmanager,
      avdmanager,
      image: `system-images;android-35;google_apis;${abi}`,
      acceleration: 'hardware',
      artifactsDirectory: artifacts,
      temporaryDirectory: join(dir, 'tmp'),
      bootTimeoutMs: 1000,
    })).rejects.toThrow(/sdkmanager failed with exit 1/)

    const receipt = join(artifacts, 'android-sdk-downloads.json')
    expect(existsSync(receipt), 'provisioning failed and said nothing about what it read').toBe(true)
    const described = JSON.parse(readFileSync(receipt, 'utf8')) as { path: string, bytes: number, sha256: string, looksLike: string }[]
    const staged = described.find(entry => entry.path.endsWith('emulator.zip'))
    expect(staged, `the staged response is missing from ${JSON.stringify(described)}`).toBeDefined()
    // The answer the original incident could not get: markup, not a truncated
    // archive and not a corrupt one.
    expect(staged!.looksLike).toBe('markup')
    expect(staged!.bytes).toBeGreaterThan(0)
    expect(staged!.sha256).toMatch(/^[a-f0-9]{64}$/)
  }
  finally { removeTempDir(dir) }
}, 120_000)

test.skipIf(!['darwin', 'linux'].includes(process.platform))('a truncated archive is told apart from an error page', async () => {
  const dir = createTempDir('craft-android-provisioning-zip-')
  try {
    const sdk = join(dir, 'sdk'), artifacts = join(dir, 'artifacts')
    mkdirSync(sdk, { recursive: true })
    const sdkmanager = join(dir, 'sdkmanager'), avdmanager = join(dir, 'avdmanager')
    // A real ZIP's leading bytes with nothing behind them: the other reading
    // of the same ZipException, and the one that would mean a bad transfer
    // rather than a bad response.
    standInSdkManager(sdkmanager, sdk, 'PK\\003\\004truncated')
    writeFileSync(avdmanager, '#!/bin/sh\nexit 0\n')
    chmodSync(avdmanager, 0o755)

    await expect(createAndroidEmulator({
      sdkRoot: sdk,
      sdkmanager,
      avdmanager,
      image: `system-images;android-35;google_apis;${abi}`,
      acceleration: 'hardware',
      artifactsDirectory: artifacts,
      temporaryDirectory: join(dir, 'tmp'),
      bootTimeoutMs: 1000,
    })).rejects.toThrow()

    const described = JSON.parse(readFileSync(join(artifacts, 'android-sdk-downloads.json'), 'utf8')) as { path: string, looksLike: string }[]
    expect(described.find(entry => entry.path.endsWith('emulator.zip'))!.looksLike).toBe('zip')
  }
  finally { removeTempDir(dir) }
}, 120_000)
