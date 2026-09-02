/**
 * Craft Auto-Updater
 * Automatic updates with delta/differential update support
 */

import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'fs'
import { join, basename, dirname } from 'path'
import { execFileSync, spawn } from 'child_process'
import { createHash } from 'crypto'
import { EventEmitter } from 'events'

// Types
export interface UpdateInfo {
  version: string
  releaseDate: string
  releaseNotes?: string
  mandatory?: boolean
  minVersion?: string
  platforms: {
    [platform: string]: PlatformUpdate
  }
}

export interface PlatformUpdate {
  url: string
  size: number
  sha256: string
  signature?: string
  delta?: DeltaUpdate[]
}

export interface DeltaUpdate {
  fromVersion: string
  url: string
  size: number
  sha256: string
}

export interface UpdaterConfig {
  /**
   * Manifest URL. Must be HTTPS in production (file:// is allowed for tests).
   * The constructor will throw on a plain `http://` URL.
   */
  updateUrl: string
  currentVersion: string
  appPath: string // Path to app bundle
  autoDownload?: boolean
  autoInstall?: boolean
  channel?: 'stable' | 'beta' | 'alpha'
  checkInterval?: number // ms
  /**
   * PEM-encoded public key (SPKI / RFC 5280) used to verify update bundle
   * signatures. When omitted, signed updates from the manifest are still
   * verified by SHA-256 hash but the signature field is rejected as
   * unverifiable (the updater refuses to install rather than fall back to
   * "trust on first use"). For ed25519 keys, supply the standard
   * `-----BEGIN PUBLIC KEY-----` PEM.
   */
  publicKeyPem?: string
  /**
   * Signature scheme used to sign manifest entries. Defaults to `'ed25519'`.
   * Must match how the build pipeline produced `PlatformUpdate.signature`.
   */
  signatureAlgorithm?: 'ed25519' | 'rsa-sha256'
}

export interface UpdateProgress {
  phase: 'checking' | 'downloading' | 'extracting' | 'installing' | 'done' | 'error'
  percent: number
  bytesDownloaded?: number
  bytesTotal?: number
  speed?: number // bytes/sec
}

export type UpdaterEvent =
  | 'checking-for-update'
  | 'update-available'
  | 'update-not-available'
  | 'download-progress'
  | 'update-downloaded'
  | 'before-quit-for-update'
  | 'error'

/**
 * Run `find <root> -name <pattern> -type <kind> -print0` and return the
 * first match. Splitting on `\0` is required because macOS/Linux paths
 * can legally contain newlines — splitting on `\n` (the previous
 * implementation) corrupted those paths. Returns `''` when no match.
 */
function findFirstByName(root: string, namePattern: string, kind: 'd' | 'f'): string {
  const out = execFileSync('find', [root, '-name', namePattern, '-type', kind, '-print0'])
  const nullByte = String.fromCharCode(0)
  const parts = out.toString('utf-8').split(nullByte).filter(s => s.length > 0)
  return parts[0] ?? ''
}

// Auto Updater
export class AutoUpdater extends EventEmitter {
  private config: UpdaterConfig
  private updateInfo: UpdateInfo | null = null
  private downloadPath: string | null = null
  private checkTimer: NodeJS.Timeout | null = null
  // Conditional-GET cache so repeat checks against the manifest server
  // return 304 instead of a full body. Cleared when the URL changes.
  private cachedEtag: string | null = null
  private cachedLastModified: string | null = null
  private cachedManifest: UpdateInfo | null = null

  private emitError(error: unknown): void {
    if (this.listenerCount('error') > 0) this.emit('error', error)
    else console.error('[Updater]', error)
  }

  constructor(config: UpdaterConfig) {
    super()

    // Refuse insecure manifest URLs at construction time so a typo can't
    // ship an HTTP-fetched manifest (which would defeat the signature
    // scheme by letting MITM rewrite it). file:// is allowed for tests.
    const url = config.updateUrl
    if (typeof url !== 'string' || url.length === 0) {
      throw new Error('Updater: updateUrl is required')
    }
    if (!/^(?:https:|file:)\/\//i.test(url)) {
      throw new Error(`Updater: updateUrl must use https:// (got: ${url})`)
    }

    this.config = {
      autoDownload: true,
      autoInstall: false,
      channel: 'stable',
      checkInterval: 60 * 60 * 1000, // 1 hour
      ...config,
    }
  }

  /**
   * Start automatic update checking
   */
  startAutoCheck(): void {
    this.checkForUpdates()

    if (this.config.checkInterval) {
      this.checkTimer = setInterval(() => {
        this.checkForUpdates()
      }, this.config.checkInterval)
    }
  }

  /**
   * Stop automatic update checking
   */
  stopAutoCheck(): void {
    if (this.checkTimer) {
      clearInterval(this.checkTimer)
      this.checkTimer = null
    }
  }

  /**
   * Check for available updates
   */
  async checkForUpdates(): Promise<UpdateInfo | null> {
    this.emit('checking-for-update')

    try {
      const platform = this.getPlatform()
      const url = `${this.config.updateUrl}?v=${this.config.currentVersion}&channel=${this.config.channel}&platform=${platform}`

      const headers: Record<string, string> = {}
      if (this.cachedEtag) headers['If-None-Match'] = this.cachedEtag
      if (this.cachedLastModified) headers['If-Modified-Since'] = this.cachedLastModified

      const response = await fetch(url, { headers })

      // 304 Not Modified — reuse the prior manifest. If the cached entry
      // already announces a newer version that the user hasn't acted on
      // yet (e.g. they dismissed the banner), re-emit `update-available`
      // so dismissed-but-still-relevant updates resurface on the next
      // poll instead of becoming silently invisible after the first 200.
      if (response.status === 304 && this.cachedManifest) {
        if (this.isNewerVersion(this.cachedManifest.version, this.config.currentVersion)) {
          this.updateInfo = this.cachedManifest
          this.emit('update-available', this.cachedManifest)
          return this.cachedManifest
        }
        this.emit('update-not-available')
        return null
      }

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      const updateInfo = await response.json() as UpdateInfo
      // Capture validators for the next check. response.headers.get is
      // case-insensitive per the Fetch spec.
      this.cachedEtag = response.headers.get('etag') || null
      this.cachedLastModified = response.headers.get('last-modified') || null
      this.cachedManifest = updateInfo

      if (this.isNewerVersion(updateInfo.version, this.config.currentVersion)) {
        // Check minimum version requirement
        if (updateInfo.minVersion && this.isNewerVersion(updateInfo.minVersion, this.config.currentVersion)) {
          console.log(`Update requires minimum version ${updateInfo.minVersion}`)
        }

        this.updateInfo = updateInfo
        this.emit('update-available', updateInfo)

        if (this.config.autoDownload) {
          await this.downloadUpdate()
        }

        return updateInfo
      }
else {
        this.emit('update-not-available')
        return null
      }
    }
catch (error) {
      this.emitError(error)
      return null
    }
  }

  /**
   * Download the update
   */
  async downloadUpdate(): Promise<string | null> {
    if (!this.updateInfo) {
      throw new Error('No update available')
    }

    const platform = this.getPlatform()
    const platformUpdate = this.updateInfo.platforms[platform]

    if (!platformUpdate) {
      throw new Error(`No update available for platform: ${platform}`)
    }

    // Check for delta update
    const deltaUpdate = platformUpdate.delta?.find(
      (d) => d.fromVersion === this.config.currentVersion
    )

    const _updateSource = deltaUpdate || platformUpdate
    const url = deltaUpdate?.url || platformUpdate.url
    const expectedSize = deltaUpdate?.size || platformUpdate.size
    const expectedHash = deltaUpdate?.sha256 || platformUpdate.sha256

    // Create download directory
    const downloadDir = join(this.config.appPath, '..', '.craft-updates')
    mkdirSync(downloadDir, { recursive: true })

    const fileName = basename(url)
    this.downloadPath = join(downloadDir, fileName)

    // Download with progress
    try {
      const response = await fetch(url)
      if (!response.ok) {
        throw new Error(`Download failed: HTTP ${response.status}`)
      }

      const contentLength = parseInt(response.headers.get('content-length') || '0', 10)
      const total = contentLength || expectedSize

      let downloaded = 0
      const startTime = Date.now()

      const fileStream = createWriteStream(this.downloadPath)
      const reader = response.body?.getReader()

      if (!reader) {
        throw new Error('Failed to get response reader')
      }

      while (true) {
        const { done, value } = await reader.read()

        if (done) break

        fileStream.write(value)
        downloaded += value.length

        const elapsed = (Date.now() - startTime) / 1000
        const speed = downloaded / elapsed

        const progress: UpdateProgress = {
          phase: 'downloading',
          percent: Math.round((downloaded / total) * 100),
          bytesDownloaded: downloaded,
          bytesTotal: total,
          speed,
        }

        this.emit('download-progress', progress)
      }

      fileStream.end()
      await new Promise<void>((resolve, reject) => {
        fileStream.once('finish', resolve)
        fileStream.once('error', reject)
      })

      // Verify hash
      const hash = await this.computeFileHash(this.downloadPath)
      if (hash !== expectedHash) {
        unlinkSync(this.downloadPath)
        throw new Error('Download verification failed: hash mismatch')
      }

      // A delta is a patch, not an installable bundle. Reconstruct the full
      // update first, then verify it against the full manifest entry.
      if (deltaUpdate) {
        if (!statSync(this.config.appPath).isFile()) {
          throw new Error('Delta updates require appPath to point to the installed bundle file')
        }
        const patchPath = this.downloadPath
        const reconstructedPath = join(downloadDir, `reconstructed-${basename(platformUpdate.url)}`)
        await DeltaGenerator.apply(this.config.appPath, patchPath, reconstructedPath)
        const reconstructedHash = await this.computeFileHash(reconstructedPath)
        if (reconstructedHash !== platformUpdate.sha256) {
          try { unlinkSync(reconstructedPath) } catch { /* best effort */ }
          throw new Error('Delta reconstruction failed: full bundle hash mismatch')
        }
        unlinkSync(patchPath)
        this.downloadPath = reconstructedPath
      }

      // When a public key is configured, every update MUST carry a
      // signature — otherwise an attacker who controlled the manifest could
      // publish unsigned updates and bypass verification entirely.
      if (this.config.publicKeyPem && !platformUpdate.signature) {
        unlinkSync(this.downloadPath)
        throw new Error(
          'Updater: publicKeyPem is configured but the manifest entry has no signature. '
          + 'Refusing to install unsigned update.',
        )
      }

      // Verify signature if available
      if (platformUpdate.signature) {
        const valid = await this.verifySignature(this.downloadPath, platformUpdate.signature)
        if (!valid) {
          unlinkSync(this.downloadPath)
          throw new Error('Download verification failed: invalid signature')
        }
      }

      this.emit('update-downloaded', {
        path: this.downloadPath,
        version: this.updateInfo.version,
        isDelta: !!deltaUpdate,
      })

      if (this.config.autoInstall) {
        await this.installUpdate()
      }

      return this.downloadPath
    }
catch (error) {
      this.emitError(error)
      return null
    }
  }

  /**
   * Install the downloaded update.
   *
   * Re-verifies SHA-256 (and signature, if a public key is configured)
   * against the manifest entry immediately before invoking the privileged
   * installer. This is belt-and-suspenders insurance: `download()` already
   * verifies, but `installUpdate()` is a public method, the file lives on
   * disk between download and install, and a privileged installer
   * touching attacker-tampered bytes is the kind of mistake that turns
   * into a CVE.
   */
  async installUpdate(restartAfter = true): Promise<void> {
    if (!this.downloadPath || !existsSync(this.downloadPath)) {
      throw new Error('No update downloaded')
    }

    if (this.updateInfo) {
      const platform = this.getPlatform()
      const platformUpdate = this.updateInfo.platforms[platform]
      if (platformUpdate) {
        const hash = await this.computeFileHash(this.downloadPath)
        if (hash !== platformUpdate.sha256) {
          // Treat the local copy as compromised — drop it so a retry
          // forces a fresh download from the manifest URL.
          try { unlinkSync(this.downloadPath) } catch { /* best effort */ }
          throw new Error(
            `Updater.installUpdate: pre-install hash mismatch on ${this.downloadPath}. `
            + 'The downloaded bundle changed between download and install — refusing to run installer.',
          )
        }
        if (this.config.publicKeyPem && !platformUpdate.signature) {
          throw new Error(
            'Updater.installUpdate: publicKeyPem is configured but manifest has no signature. '
            + 'Refusing to install unsigned update.',
          )
        }
        if (platformUpdate.signature) {
          const valid = await this.verifySignature(this.downloadPath, platformUpdate.signature)
          if (!valid) {
            try { unlinkSync(this.downloadPath) } catch { /* best effort */ }
            throw new Error('Updater.installUpdate: invalid signature on downloaded bundle')
          }
        }
      }
    }

    this.emit('before-quit-for-update')

    const platform = this.getPlatform()

    // Extract/install update
    const progress: UpdateProgress = { phase: 'installing', percent: 0 }
    this.emit('download-progress', progress)

    try {
      switch (platform) {
        case 'darwin':
          await this.installMacOSUpdate()
          break
        case 'win32':
          await this.installWindowsUpdate()
          break
        case 'linux':
          await this.installLinuxUpdate()
          break
      }

      // Clean up download
      if (this.downloadPath && existsSync(this.downloadPath)) {
        unlinkSync(this.downloadPath)
      }

      progress.phase = 'done'
      progress.percent = 100
      this.emit('download-progress', progress)

      if (restartAfter) {
        this.restartApp()
      }
    }
catch (error) {
      progress.phase = 'error'
      this.emitError(error)
      throw error
    }
  }

  private async installMacOSUpdate(): Promise<void> {
    const downloadPath = this.downloadPath!
    const appPath = this.config.appPath

    // Determine update type by extension
    if (downloadPath.endsWith('.zip')) {
      // Extract zip to temp location
      const tempDir = join(dirname(downloadPath), 'extracted')
      mkdirSync(tempDir, { recursive: true })

      execFileSync('unzip', ['-o', downloadPath, '-d', tempDir])

      // Find the .app in extracted contents. `-print0` + null-byte split
      // is required because macOS allows newlines in path names; the
      // previous `\n`-split parse silently truncated such paths.
      const extractedApp = findFirstByName(tempDir, '*.app', 'd')

      if (extractedApp) {
        // Replace current app
        const { rmSync, renameSync } = await import('fs')
        rmSync(appPath, { recursive: true, force: true })
        renameSync(extractedApp, appPath)
      }

      // Clean up
      const { rmSync } = await import('fs')
      rmSync(tempDir, { recursive: true, force: true })
    }
else if (downloadPath.endsWith('.dmg')) {
      // Mount DMG
      const mountOutput = execFileSync('hdiutil', ['attach', downloadPath, '-nobrowse']).toString()
      const mountPoint = mountOutput.match(/\/Volumes\/[^\n]+/)?.[0]

      if (mountPoint) {
        // Find and copy the app
        const dmgApp = findFirstByName(mountPoint, '*.app', 'd')

        if (dmgApp) {
          const { rmSync, cpSync } = await import('fs')
          rmSync(appPath, { recursive: true, force: true })
          cpSync(dmgApp, appPath, { recursive: true })
        }

        // Unmount
        execFileSync('hdiutil', ['detach', mountPoint])
      }
    }
else if (downloadPath.endsWith('.pkg')) {
      // Verify the .pkg's embedded signing chain BEFORE handing it to
      // root. `pkgutil --check-signature` exits non-zero on an unsigned
      // or revoked package; a clean exit means the chain is trusted by
      // the system. This is independent of the SDK's own
      // sha256/manifest-signature check (which already ran in
      // `installUpdate`) — both layers must hold for us to call sudo.
      try {
        execFileSync('pkgutil', ['--check-signature', downloadPath], { stdio: 'pipe' })
      }
      catch (e) {
        throw new Error(
          `Refusing to install ${downloadPath}: pkgutil --check-signature failed. `
          + 'The .pkg is not signed by a trusted Apple certificate chain. '
          + `Underlying error: ${(e as Error).message}`,
        )
      }
      // Install package. `installer` requires root, which we delegate to sudo —
      // this will prompt the user via their sudo configuration (TouchID on macOS).
      execFileSync('sudo', ['installer', '-pkg', downloadPath, '-target', '/'])
    }
  }

  private async installWindowsUpdate(): Promise<void> {
    const downloadPath = this.downloadPath!

    if (downloadPath.endsWith('.exe')) {
      // Run installer silently
      spawn(downloadPath, ['/S', '/SILENT', '/VERYSILENT'], {
        detached: true,
        stdio: 'ignore',
      })
    }
else if (downloadPath.endsWith('.msi')) {
      // Run MSI installer
      spawn('msiexec', ['/i', downloadPath, '/quiet', '/norestart'], {
        detached: true,
        stdio: 'ignore',
      })
    }
else if (downloadPath.endsWith('.zip')) {
      // Extract and replace. Use -File to run a script block with safe args.
      const appDir = dirname(this.config.appPath)
      execFileSync('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Expand-Archive -Force -Path $env:CRAFT_UPDATE_SRC -DestinationPath $env:CRAFT_UPDATE_DST',
      ], {
        env: { ...process.env, CRAFT_UPDATE_SRC: downloadPath, CRAFT_UPDATE_DST: appDir },
      })
    }
  }

  private async installLinuxUpdate(): Promise<void> {
    const downloadPath = this.downloadPath!

    if (downloadPath.endsWith('.AppImage')) {
      // Replace AppImage
      execFileSync('chmod', ['+x', downloadPath])
      const { renameSync } = await import('fs')
      renameSync(downloadPath, this.config.appPath)
    }
else if (downloadPath.endsWith('.deb')) {
      execFileSync('sudo', ['dpkg', '-i', downloadPath])
    }
else if (downloadPath.endsWith('.rpm')) {
      execFileSync('sudo', ['rpm', '-U', downloadPath])
    }
else if (downloadPath.endsWith('.tar.gz')) {
      const appDir = dirname(this.config.appPath)
      execFileSync('tar', ['-xzf', downloadPath, '-C', appDir])
    }
  }

  private restartApp(): void {
    const platform = this.getPlatform()
    const appPath = this.config.appPath

    // Spawn new process and exit current
    switch (platform) {
      case 'darwin':
        spawn('open', ['-n', appPath], { detached: true, stdio: 'ignore' })
        break
      case 'win32':
        spawn(appPath, [], { detached: true, stdio: 'ignore' })
        break
      case 'linux':
        spawn(appPath, [], { detached: true, stdio: 'ignore' })
        break
    }

    process.exit(0)
  }

  private getPlatform(): string {
    switch (process.platform) {
      case 'darwin':
        return 'darwin'
      case 'win32':
        return 'win32'
      default:
        return 'linux'
    }
  }

  private isNewerVersion(a: string, b: string): boolean {
    const partsA = a.split('.').map(Number)
    const partsB = b.split('.').map(Number)

    for (let i = 0; i < Math.max(partsA.length, partsB.length); i++) {
      const numA = partsA[i] || 0
      const numB = partsB[i] || 0

      if (numA > numB) return true
      if (numA < numB) return false
    }

    return false
  }

  private async computeFileHash(filePath: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const hash = createHash('sha256')
      const stream = createReadStream(filePath)

      stream.on('data', (chunk) => hash.update(chunk))
      stream.on('end', () => resolve(hash.digest('hex')))
      stream.on('error', reject)
    })
  }

  /**
   * Verify a downloaded bundle against the signature published in the
   * manifest. Returns false if the signature doesn't validate; throws when
   * the updater is misconfigured (no key or bad PEM) so misconfiguration
   * cannot silently pass as "valid".
   */
  private async verifySignature(filePath: string, signature: string): Promise<boolean> {
    const pem = this.config.publicKeyPem
    if (!pem) {
      throw new Error(
        'Updater.verifySignature: publicKeyPem is not configured. '
        + 'Refusing to install signed update without a verification key.'
      )
    }

    const algo = this.config.signatureAlgorithm ?? 'ed25519'
    const { createPublicKey, verify, createVerify } = await import('node:crypto')

    let publicKey: ReturnType<typeof createPublicKey>
    try {
      publicKey = createPublicKey({ key: pem, format: 'pem' })
    }
    catch (e) {
      throw new Error(`Updater.verifySignature: invalid publicKeyPem: ${(e as Error).message}`)
    }

    // Signature is base64-encoded in the manifest.
    let sigBytes: Buffer
    try {
      sigBytes = Buffer.from(signature, 'base64')
    }
    catch {
      return false
    }

    const data = readFileSync(filePath)

    if (algo === 'ed25519') {
      // ed25519 uses the one-shot `verify` (no createVerify hashing step).
      return verify(null, data, publicKey, sigBytes)
    }

    // rsa-sha256
    const verifier = createVerify('SHA256')
    verifier.update(data)
    verifier.end()
    return verifier.verify(publicKey, sigBytes)
  }

  /**
   * Get current update info
   */
  getUpdateInfo(): UpdateInfo | null {
    return this.updateInfo
  }

  /**
   * Get download path
   */
  getDownloadPath(): string | null {
    return this.downloadPath
  }
}

// Delta Update Generator
export class DeltaGenerator {
  /**
   * Generate a delta/patch file between two versions
   */
  static async generate(
    oldPath: string,
    newPath: string,
    outputPath: string
  ): Promise<{ size: number; sha256: string }> {
    // Use bsdiff for binary delta
    try {
      execFileSync('bsdiff', [oldPath, newPath, outputPath])

      const stats = statSync(outputPath)
      const hash = await DeltaGenerator.computeHash(outputPath)

      return {
        size: stats.size,
        sha256: hash,
      }
    }
catch {
      // Fall back to xdelta3
      execFileSync('xdelta3', ['-e', '-s', oldPath, newPath, outputPath])

      const stats = statSync(outputPath)
      const hash = await DeltaGenerator.computeHash(outputPath)

      return {
        size: stats.size,
        sha256: hash,
      }
    }
  }

  /**
   * Apply a delta/patch to create new version
   */
  static async apply(basePath: string, deltaPath: string, outputPath: string): Promise<void> {
    try {
      execFileSync('bspatch', [basePath, outputPath, deltaPath])
    }
catch {
      execFileSync('xdelta3', ['-d', '-s', basePath, deltaPath, outputPath])
    }
  }

  private static async computeHash(filePath: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const hash = createHash('sha256')
      const stream = createReadStream(filePath)

      stream.on('data', (chunk) => hash.update(chunk))
      stream.on('end', () => resolve(hash.digest('hex')))
      stream.on('error', reject)
    })
  }
}

// Update Server Generator
export function generateUpdateManifest(options: {
  version: string
  releaseNotes?: string
  platforms: {
    darwin?: { path: string; url: string }
    win32?: { path: string; url: string }
    linux?: { path: string; url: string }
  }
  deltas?: {
    platform: string
    fromVersion: string
    path: string
    url: string
  }[]
}): UpdateInfo {
  const manifest: UpdateInfo = {
    version: options.version,
    releaseDate: new Date().toISOString(),
    releaseNotes: options.releaseNotes,
    platforms: {},
  }

  for (const [platform, info] of Object.entries(options.platforms)) {
    if (!info) continue

    // Hash and stat from the same buffer so a writer can't swap the file
    // between the size lookup and the digest. `readFileSync` opens with
    // O_RDONLY, but on POSIX another process can still rename underneath
    // us — copying the bytes once and deriving both metrics from that
    // snapshot is the cheapest way to make the manifest entry consistent.
    const bytes = readFileSync(info.path)
    const hash = createHash('sha256').update(bytes).digest('hex')

    manifest.platforms[platform] = {
      url: info.url,
      size: bytes.length,
      sha256: hash,
      delta: [],
    }

    const platformDeltas = options.deltas?.filter((d) => d.platform === platform) || []
    for (const delta of platformDeltas) {
      const deltaBytes = readFileSync(delta.path)
      const deltaHash = createHash('sha256').update(deltaBytes).digest('hex')

      manifest.platforms[platform].delta!.push({
        fromVersion: delta.fromVersion,
        url: delta.url,
        size: deltaBytes.length,
        sha256: deltaHash,
      })
    }
  }

  return manifest
}

// CLI Command
export async function updaterCommand(args: string[]): Promise<void> {
  const [subcommand, ...rest] = args

  switch (subcommand) {
    case 'check': {
      const url = rest[0]
      const version = rest[1] || '0.0.0'

      if (!url) {
        console.error('Usage: craft updater check <update-url> [current-version]')
        process.exit(1)
      }

      const updater = new AutoUpdater({
        updateUrl: url,
        currentVersion: version,
        appPath: process.cwd(),
        autoDownload: false,
      })

      const update = await updater.checkForUpdates()

      if (update) {
        console.log(`Update available: ${update.version}`)
        console.log(`Release date: ${update.releaseDate}`)
        if (update.releaseNotes) {
          console.log(`\nRelease notes:\n${update.releaseNotes}`)
        }
      }
else {
        console.log('No updates available')
      }
      break
    }

    case 'generate-delta': {
      const oldPath = rest[0]
      const newPath = rest[1]
      const outputPath = rest[2]

      if (!oldPath || !newPath || !outputPath) {
        console.error('Usage: craft updater generate-delta <old-file> <new-file> <output>')
        process.exit(1)
      }

      console.log('Generating delta update...')
      const result = await DeltaGenerator.generate(oldPath, newPath, outputPath)

      console.log(`Delta generated: ${outputPath}`)
      console.log(`Size: ${result.size} bytes`)
      console.log(`SHA256: ${result.sha256}`)
      break
    }

    case 'generate-manifest': {
      const version = rest[0]
      const outputPath = rest[1] || 'update.json'

      if (!version) {
        console.error('Usage: craft updater generate-manifest <version> [output]')
        process.exit(1)
      }

      const manifest: UpdateInfo = {
        version,
        releaseDate: new Date().toISOString(),
        platforms: {},
      }

      writeFileSync(outputPath, JSON.stringify(manifest, null, 2))
      console.log(`Manifest generated: ${outputPath}`)
      console.log('Edit the file to add platform-specific update URLs')
      break
    }

    default:
      console.log(`
Craft Auto-Updater

Usage: craft updater <command> [options]

Commands:
  check <url> [version]                    Check for updates
  generate-delta <old> <new> <output>      Generate delta update
  generate-manifest <version> [output]     Generate update manifest

Examples:
  craft updater check https://api.example.com/updates 1.0.0
  craft updater generate-delta app-1.0.0.zip app-1.1.0.zip delta-1.0.0-1.1.0.patch
  craft updater generate-manifest 1.1.0 update.json
`)
  }
}

export default AutoUpdater
