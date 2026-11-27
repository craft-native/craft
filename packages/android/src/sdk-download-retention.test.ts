import { afterEach, beforeEach, expect, spyOn, test } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'
import { createAndroidEmulator, truncatedSdkDownload } from './emulator'

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

// The #451 retry prints a `::warning`, which GitHub turns into an annotation
// on the run: from these stand-ins it would read as a real truncated download.
// Captured here instead, and asserted where it matters.
let logged: string[] = []
let restoreLog: (() => void) | undefined
beforeEach(() => {
  logged = []
  const spy = spyOn(console, 'log').mockImplementation((...parts: unknown[]) => { logged.push(parts.join(' ')) })
  restoreLog = () => spy.mockRestore()
})
afterEach(() => restoreLog?.())

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

/** The sdkmanager calls device-commands.jsonl recorded, with their exit codes. */
function sdkmanagerCalls(artifacts: string): { args: string[], code: number }[] {
  return readFileSync(join(artifacts, 'device-commands.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line) as { args: string[], code: number })
    .filter(entry => entry.args[0]!.endsWith('sdkmanager'))
}

test('the lines that mean a download arrived unreadable are recognised, and nothing else (#451)', () => {
  expect(truncatedSdkDownload('Unzipping...\njava.io.IOException: Error reading Zip content from a SeekableByteChannel\n')).toBe('java.io.IOException: Error reading Zip content from a SeekableByteChannel')
  expect(truncatedSdkDownload('java.util.zip.ZipException: Archive is not a ZIP archive')).toBe('java.util.zip.ZipException: Archive is not a ZIP archive')
  for (const other of ['Error: Failed to find package \'emulator\'', 'Warning: Failed to read or create install properties file.', 'java.net.UnknownHostException: dl.google.com', ''])
    expect(truncatedSdkDownload(other)).toBeUndefined()
})

test.skipIf(!['darwin', 'linux'].includes(process.platform))('a download that arrives truncated is retried once, and the first attempt stays on record (#451)', async () => {
  const dir = createTempDir('craft-android-provisioning-retry-')
  try {
    const sdk = join(dir, 'sdk'), artifacts = join(dir, 'artifacts')
    mkdirSync(sdk, { recursive: true })
    const sdkmanager = join(dir, 'sdkmanager'), avdmanager = join(dir, 'avdmanager')
    // The first run stages a short archive and fails as the 11-16 runners did;
    // the second installs an emulator, which then has no acceleration, so
    // setup stops right after the step under test.
    writeFileSync(sdkmanager, `#!/bin/sh
if [ ! -f "${dir}/tried" ]; then
  touch "${dir}/tried"
  mkdir -p "${sdk}/.temp/PackageOperation01"
  printf 'PK\\003\\004short' > "${sdk}/.temp/PackageOperation01/emulator.zip"
  echo 'Unzipping...'
  echo 'java.io.IOException: Error reading Zip content from a SeekableByteChannel' >&2
  exit 1
fi
mkdir -p "${sdk}/emulator"
printf '#!/bin/sh\\nexit 1\\n' > "${sdk}/emulator/emulator"
chmod +x "${sdk}/emulator/emulator"
exit 0
`)
    chmodSync(sdkmanager, 0o755)
    writeFileSync(avdmanager, '#!/bin/sh\nexit 0\n')
    chmodSync(avdmanager, 0o755)

    await expect(createAndroidEmulator({
      sdkRoot: sdk, sdkmanager, avdmanager,
      image: `system-images;android-35;google_apis;${abi}`,
      acceleration: 'hardware', artifactsDirectory: artifacts,
      temporaryDirectory: join(dir, 'tmp'), bootTimeoutMs: 1000,
    })).rejects.toThrow(/hardware acceleration is unavailable/)

    expect(sdkmanagerCalls(artifacts).map(call => [call.args.slice(-2).join(' '), call.code])).toEqual([['platform-tools emulator', 1], ['platform-tools emulator', 0]])
    const retry = JSON.parse(readFileSync(join(artifacts, 'android-sdk-download-retry.json'), 'utf8')) as { packages: string[], reason: string, staged: { path: string, looksLike: string }[] }
    expect(retry.packages).toEqual(['platform-tools', 'emulator'])
    expect(retry.reason).toContain('Error reading Zip content')
    expect(retry.staged.find(entry => entry.path.endsWith('emulator.zip'))?.looksLike).toBe('zip')
    expect(logged.filter(line => line.startsWith('::warning title=Android SDK download arrived truncated (#451)::'))).toHaveLength(1)
  }
  finally { removeTempDir(dir) }
}, 120_000)

test.skipIf(!['darwin', 'linux'].includes(process.platform))('any other sdkmanager failure is not retried (#451)', async () => {
  const dir = createTempDir('craft-android-provisioning-noretry-')
  try {
    const sdk = join(dir, 'sdk'), artifacts = join(dir, 'artifacts')
    mkdirSync(sdk, { recursive: true })
    const sdkmanager = join(dir, 'sdkmanager'), avdmanager = join(dir, 'avdmanager')
    writeFileSync(sdkmanager, "#!/bin/sh\necho \"Error: Failed to find package 'emulator'\" >&2\nexit 1\n")
    chmodSync(sdkmanager, 0o755)
    writeFileSync(avdmanager, '#!/bin/sh\nexit 0\n')
    chmodSync(avdmanager, 0o755)

    await expect(createAndroidEmulator({
      sdkRoot: sdk, sdkmanager, avdmanager,
      image: `system-images;android-35;google_apis;${abi}`,
      acceleration: 'hardware', artifactsDirectory: artifacts,
      temporaryDirectory: join(dir, 'tmp'), bootTimeoutMs: 1000,
    })).rejects.toThrow(/sdkmanager failed with exit 1/)

    expect(sdkmanagerCalls(artifacts)).toHaveLength(1)
    expect(existsSync(join(artifacts, 'android-sdk-download-retry.json'))).toBe(false)
  }
  finally { removeTempDir(dir) }
}, 120_000)
