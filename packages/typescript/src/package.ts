/**
 * Craft Packaging API
 *
 * Enables users to create installers for their Craft applications
 * across all platforms (macOS, Windows, Linux)
 */

import { spawn } from 'child_process'
import { createHash } from 'crypto'
import {
  chmodSync,
  copyFileSync,
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'fs'
import { homedir, tmpdir } from 'os'
import { basename, join } from 'path'
import { deflateRawSync } from 'zlib'

// Dependency-free ZIP writer. Craft used to pull `archiver` (→ archiver-utils →
// lazystream → readable-stream) solely to zip a single Windows binary; that
// transitive tree is heavy and broke downstream installs (lazystream requires
// the removed `readable-stream/passthrough` subpath). Bun/Node ship raw DEFLATE
// via node:zlib, so we assemble the ZIP container ourselves.
const CRC32_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++)
      c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

function crc32(data: Uint8Array): number {
  let c = 0xFFFFFFFF
  for (let i = 0; i < data.length; i++)
    c = CRC32_TABLE[(c ^ data[i]) & 0xFF] ^ (c >>> 8)
  return (c ^ 0xFFFFFFFF) >>> 0
}

/** DOS-format date/time for ZIP local/central headers. */
function dosDateTime(d: Date): { time: number; date: number } {
  const time = (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)
  const date = ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()
  return { time: time & 0xFFFF, date: date & 0xFFFF }
}

/**
 * Build a ZIP archive (DEFLATE, level 9) from in-memory entries. Emits the
 * standard container: one local-file-header + data record per entry, a central
 * directory, and the end-of-central-directory record. No external dependencies.
 */
function buildZip(entries: Array<{ name: string; data: Uint8Array }>): Buffer {
  const { time, date } = dosDateTime(new Date())
  const locals: Buffer[] = []
  const central: Buffer[] = []
  let offset = 0

  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, 'utf8')
    const compressed = deflateRawSync(entry.data, { level: 9 })
    const crc = crc32(entry.data)

    const lfh = Buffer.alloc(30)
    lfh.writeUInt32LE(0x04034B50, 0) // local file header signature
    lfh.writeUInt16LE(20, 4) // version needed to extract
    lfh.writeUInt16LE(0, 6) // general-purpose bit flag
    lfh.writeUInt16LE(8, 8) // compression method: deflate
    lfh.writeUInt16LE(time, 10)
    lfh.writeUInt16LE(date, 12)
    lfh.writeUInt32LE(crc, 14)
    lfh.writeUInt32LE(compressed.length, 18)
    lfh.writeUInt32LE(entry.data.length, 22)
    lfh.writeUInt16LE(nameBytes.length, 26)
    lfh.writeUInt16LE(0, 28) // extra field length
    locals.push(lfh, nameBytes, compressed)

    const cdh = Buffer.alloc(46)
    cdh.writeUInt32LE(0x02014B50, 0) // central directory header signature
    cdh.writeUInt16LE(20, 4) // version made by
    cdh.writeUInt16LE(20, 6) // version needed to extract
    cdh.writeUInt16LE(0, 8) // general-purpose bit flag
    cdh.writeUInt16LE(8, 10) // compression method
    cdh.writeUInt16LE(time, 12)
    cdh.writeUInt16LE(date, 14)
    cdh.writeUInt32LE(crc, 16)
    cdh.writeUInt32LE(compressed.length, 20)
    cdh.writeUInt32LE(entry.data.length, 24)
    cdh.writeUInt16LE(nameBytes.length, 28)
    cdh.writeUInt16LE(0, 30) // extra field length
    cdh.writeUInt16LE(0, 32) // file comment length
    cdh.writeUInt16LE(0, 34) // disk number start
    cdh.writeUInt16LE(0, 36) // internal file attributes
    cdh.writeUInt32LE(0, 38) // external file attributes
    cdh.writeUInt32LE(offset, 42) // relative offset of local header
    central.push(cdh, nameBytes)

    offset += lfh.length + nameBytes.length + compressed.length
  }

  const centralBuf = Buffer.concat(central)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054B50, 0) // end of central directory signature
  eocd.writeUInt16LE(0, 4) // number of this disk
  eocd.writeUInt16LE(0, 6) // disk where central directory starts
  eocd.writeUInt16LE(entries.length, 8) // central directory records on this disk
  eocd.writeUInt16LE(entries.length, 10) // total central directory records
  eocd.writeUInt32LE(centralBuf.length, 12) // size of central directory
  eocd.writeUInt32LE(offset, 16) // offset of central directory
  eocd.writeUInt16LE(0, 20) // comment length
  return Buffer.concat([...locals, centralBuf, eocd])
}

export interface PackageConfig {
  /** Application name */
  name: string

  /** Application version (semver) */
  version: string

  /** Application description */
  description?: string

  /** Author/Maintainer */
  author?: string

  /** Homepage URL */
  homepage?: string

  /** Path to application binary */
  binaryPath: string

  /** Path to application icon (platform-specific formats) */
  iconPath?: string

  /** Output directory for installers */
  outDir?: string

  /** Bundle identifier (macOS/iOS) */
  bundleId?: string

  /** Platforms to build for */
  platforms?: Array<'macos' | 'windows' | 'linux'>

  /** macOS-specific options */
  macos?: {
    /** Create DMG installer */
    dmg?: boolean

    /** Create PKG installer */
    pkg?: boolean

    /**
     * Build the PKG as a Mac App Store submission with `productbuild` instead
     * of a plain `pkgbuild` installer. Requires `installerIdentity`, and the
     * app itself must be signed with a `3rd Party Mac Developer Application`
     * identity plus a `.provisionprofile`.
     */
    appStore?: boolean

    /** Application code signing identity, e.g. "Developer ID Application: Acme (TEAMID)" */
    signIdentity?: string

    /** Installer code signing identity, e.g. "3rd Party Mac Developer Installer: Acme (TEAMID)" */
    installerIdentity?: string

    /** Path to the entitlements plist applied when signing the app */
    entitlements?: string

    /** Path to a `.provisionprofile` embedded as `Contents/embedded.provisionprofile` */
    provisioningProfile?: string

    /** Build number (`CFBundleVersion`). Defaults to `version`. */
    buildNumber?: string

    /** `LSApplicationCategoryType`, e.g. "public.app-category.utilities" — required by the App Store */
    category?: string

    /** `LSMinimumSystemVersion`, e.g. "13.0" */
    minimumSystemVersion?: string

    /**
     * Menu bar app: sets `LSUIElement` so the app has no Dock icon and never
     * appears in the app switcher.
     */
    menuBarOnly?: boolean

    /** Notarize the app. Direct distribution only — App Store builds are notarized by Apple. */
    notarize?: boolean

    /** Apple ID for notarization */
    appleId?: string

    /** App-specific password */
    applePassword?: string

    /** Team ID for notarization. Required by `notarytool` alongside `appleId`. */
    teamId?: string

    /**
     * Extra executables copied into `Contents/MacOS/` beside the app binary.
     *
     * A server-backed app (a Bun program driving a Craft webview, say) spawns a
     * helper at runtime; bundle it here so the installed `.app` is
     * self-contained. Resolve it relative to the running executable — on macOS
     * the helper lands next to `process.execPath`.
     */
    additionalExecutables?: string[]
  }

  /** Windows-specific options */
  windows?: {
    /** Create MSI installer */
    msi?: boolean

    /** Create ZIP archive */
    zip?: boolean

    /** Architecture encoded in MSI metadata (defaults to the native host) */
    architecture?: 'x86' | 'x64' | 'arm64'

    /** Code signing certificate */
    certificatePath?: string

    /** Certificate password */
    certificatePassword?: string
  }

  /** Linux-specific options */
  linux?: {
    /** Create DEB package */
    deb?: boolean

    /** Create RPM package */
    rpm?: boolean

    /** Create AppImage */
    appImage?: boolean

    /** Desktop categories */
    categories?: string[]

    /** Dependencies (Debian) */
    debDependencies?: string[]

    /** Dependencies (RPM) */
    rpmDependencies?: string[]
  }
}

interface MSIOptions {
  name: string
  version: string
  binaryPath: string
  outputPath: string
  manufacturer: string
  architecture: 'x86' | 'x64' | 'arm64'
  certificatePath?: string
  certificatePassword?: string
}

export interface PackageResult {
  success: boolean
  platform: string
  format: string
  outputPath?: string
  error?: string
}

export function formatPackagingCommandError(tool: string, code: number | null, stdout: string, stderr: string): string {
  const detail = `${stdout}${stderr}`.trim()
  return `${tool} exited with code ${code}${detail ? `: ${detail}` : ''}`
}

/**
 * Package a Craft application for distribution
 */
export async function packageApp(config: PackageConfig): Promise<PackageResult[]> {
  const results: PackageResult[] = []

  // Validate config
  if (!config.binaryPath || !existsSync(config.binaryPath)) {
    throw new Error(`Binary not found: ${config.binaryPath}`)
  }

  // Default platforms: current platform only
  const platforms = config.platforms || [detectPlatform()]

  // Create output directory
  const outDir = config.outDir || join(process.cwd(), 'dist')
  if (!existsSync(outDir)) {
    mkdirSync(outDir, { recursive: true })
  }

  // Package for each platform
  for (const platform of platforms) {
    switch (platform) {
      case 'macos':
        results.push(...await packageMacOS(config, outDir))
        break
      case 'windows':
        results.push(...await packageWindows(config, outDir))
        break
      case 'linux':
        results.push(...await packageLinux(config, outDir))
        break
    }
  }

  return results
}

/**
 * Package for macOS (DMG + PKG)
 */
async function packageMacOS(config: PackageConfig, outDir: string): Promise<PackageResult[]> {
  const results: PackageResult[] = []
  const { name, version, bundleId = `com.myapp.${name.toLowerCase()}` } = config
  const opts = config.macos || {}

  // App Store builds run sandboxed, so they must not opt into the hardened
  // runtime; every other distribution channel requires it for notarization.
  const hardenedRuntime = !opts.appStore

  // Create app bundle
  const appBundlePath = join(outDir, `${name}.app`)
  const appBundle = createMacOSAppBundle({
    name,
    version,
    bundleId,
    buildNumber: opts.buildNumber,
    category: opts.category,
    minimumSystemVersion: opts.minimumSystemVersion,
    menuBarOnly: opts.menuBarOnly,
    binaryPath: config.binaryPath,
    iconPath: config.iconPath,
    provisioningProfile: opts.provisioningProfile,
    additionalExecutables: opts.additionalExecutables,
    outputPath: appBundlePath,
  })

  if (!appBundle.success) {
    results.push({
      success: false,
      platform: 'macos',
      format: 'app',
      error: appBundle.error,
    })
    return results
  }

  // Sign the bundle before it is wrapped into a DMG or PKG — signing after
  // packaging would leave the copy inside the installer unsigned.
  if (opts.signIdentity) {
    const signed = await runTool('codesign', codesignArguments({
      path: appBundlePath,
      identity: opts.signIdentity,
      entitlements: opts.entitlements,
      hardenedRuntime,
    }))
    if (!signed.success) {
      results.push({ success: false, platform: 'macos', format: 'app', error: signed.error })
      return results
    }
  }
  else if (opts.appStore) {
    results.push({
      success: false,
      platform: 'macos',
      format: 'pkg',
      error: 'App Store packaging requires macos.signIdentity (a "3rd Party Mac Developer Application" identity)',
    })
    return results
  }

  results.push({ success: true, platform: 'macos', format: 'app', outputPath: appBundlePath })

  // Create DMG
  if (opts.dmg !== false) {
    const outputPath = join(outDir, `${name}-${version}.dmg`)
    const dmgResult = await createDMG({ appBundlePath, outputPath, volumeName: name })
    results.push({
      success: dmgResult.success,
      platform: 'macos',
      format: 'dmg',
      outputPath: dmgResult.outputPath,
      error: dmgResult.error,
    })
    if (dmgResult.success)
      results.push(...await notarizeIfRequested(opts, outputPath, 'dmg'))
  }

  // Create PKG
  if (opts.pkg || opts.appStore) {
    const outputPath = join(outDir, `${name}-${version}.pkg`)
    const pkgResult = await createPKG({
      appBundlePath,
      outputPath,
      identifier: bundleId,
      version,
      appStore: opts.appStore === true,
      installerIdentity: opts.installerIdentity,
    })
    results.push({
      success: pkgResult.success,
      platform: 'macos',
      format: opts.appStore ? 'pkg (app store)' : 'pkg',
      outputPath: pkgResult.outputPath,
      error: pkgResult.error,
    })
    // App Store submissions are notarized by Apple during review.
    if (pkgResult.success && !opts.appStore)
      results.push(...await notarizeIfRequested(opts, outputPath, 'pkg'))
  }

  return results
}

/**
 * Notarize and staple an artifact when `macos.notarize` is set. Returns the
 * result rows to append, or nothing when notarization was not requested.
 */
async function notarizeIfRequested(
  opts: NonNullable<PackageConfig['macos']>,
  artifactPath: string,
  format: string,
): Promise<PackageResult[]> {
  if (!opts.notarize)
    return []

  if (!opts.appleId || !opts.applePassword || !opts.teamId) {
    return [{
      success: false,
      platform: 'macos',
      format: `${format} (notarize)`,
      error: 'Notarization requires macos.appleId, macos.applePassword and macos.teamId',
    }]
  }

  const submitted = await runTool('xcrun', notarytoolArguments({
    artifactPath,
    appleId: opts.appleId,
    applePassword: opts.applePassword,
    teamId: opts.teamId,
  }))
  if (!submitted.success)
    return [{ success: false, platform: 'macos', format: `${format} (notarize)`, error: submitted.error }]

  const stapled = await runTool('xcrun', ['stapler', 'staple', artifactPath])
  return [{
    success: stapled.success,
    platform: 'macos',
    format: `${format} (notarize)`,
    outputPath: stapled.success ? artifactPath : undefined,
    error: stapled.success ? undefined : stapled.error,
  }]
}

/**
 * Package for Windows (MSI + ZIP)
 */
async function packageWindows(config: PackageConfig, outDir: string): Promise<PackageResult[]> {
  const results: PackageResult[] = []
  const { name, version } = config
  const opts = config.windows || {}

  // Create MSI (if WiX available)
  if (opts.msi !== false) {
    const msiResult = await createMSI({
      name,
      version,
      binaryPath: config.binaryPath,
      outputPath: join(outDir, `${name}-${version}.msi`),
      manufacturer: config.author || 'Unknown',
      architecture: opts.architecture || windowsArchitecture(process.arch),
      certificatePath: opts.certificatePath,
      certificatePassword: opts.certificatePassword,
    })
    results.push({
      success: msiResult.success,
      platform: 'windows',
      format: 'msi',
      outputPath: msiResult.outputPath,
      error: msiResult.error,
    })
  }

  // Create ZIP (fallback)
  if (opts.zip || opts.msi === false) {
    const zipResult = await createZIP({
      name,
      version,
      binaryPath: config.binaryPath,
      outputPath: join(outDir, `${name}-${version}-windows.zip`),
    })
    results.push({
      success: zipResult.success,
      platform: 'windows',
      format: 'zip',
      outputPath: zipResult.outputPath,
      error: zipResult.error,
    })
  }

  return results
}

/**
 * Package for Linux (DEB + RPM + AppImage)
 */
async function packageLinux(config: PackageConfig, outDir: string): Promise<PackageResult[]> {
  const results: PackageResult[] = []
  const { name, version } = config
  const opts = config.linux || {}

  // Create DEB
  if (opts.deb !== false) {
    const debResult = await createDEB({
      name,
      version,
      binaryPath: config.binaryPath,
      outputPath: join(outDir, `${name}_${version}_amd64.deb`),
      description: config.description || '',
      maintainer: config.author || 'Unknown',
      dependencies: opts.debDependencies || ['libgtk-3-0', 'libwebkit2gtk-4.1-37'],
    })
    results.push({
      success: debResult.success,
      platform: 'linux',
      format: 'deb',
      outputPath: debResult.outputPath,
      error: debResult.error,
    })
  }

  // Create RPM
  if (opts.rpm) {
    const rpmResult = await createRPM({
      name,
      version,
      binaryPath: config.binaryPath,
      outputPath: join(outDir, `${name}-${version}-1.x86_64.rpm`),
      description: config.description || '',
      requires: opts.rpmDependencies || ['gtk3', 'webkit2gtk3'],
    })
    results.push({
      success: rpmResult.success,
      platform: 'linux',
      format: 'rpm',
      outputPath: rpmResult.outputPath,
      error: rpmResult.error,
    })
  }

  // Create AppImage
  if (opts.appImage) {
    const appImageResult = await createAppImage({
      name,
      version,
      binaryPath: config.binaryPath,
      outputPath: join(outDir, `${name}-${version}-x86_64.AppImage`),
      iconPath: config.iconPath,
    })
    results.push({
      success: appImageResult.success,
      platform: 'linux',
      format: 'appimage',
      outputPath: appImageResult.outputPath,
      error: appImageResult.error,
    })
  }

  return results
}

export interface MacOSBundleMetadata {
  name: string
  version: string
  bundleId: string
  /** `CFBundleVersion`. Defaults to `version`. */
  buildNumber?: string
  /** Basename of the `.icns` inside `Contents/Resources`, without the extension */
  iconName?: string
  category?: string
  minimumSystemVersion?: string
  /** Sets `LSUIElement` — no Dock icon, no app switcher entry */
  menuBarOnly?: boolean
}

/**
 * Render `Contents/Info.plist` for a macOS app bundle.
 *
 * Only the keys that were asked for are emitted, so a plain desktop app does
 * not carry menu-bar or App Store metadata it has no use for.
 */
export function macOSInfoPlist(metadata: MacOSBundleMetadata): string {
  const entries: Array<[string, string | true]> = [
    ['CFBundleExecutable', metadata.name],
    ['CFBundleIdentifier', metadata.bundleId],
    ['CFBundleName', metadata.name],
    ['CFBundleShortVersionString', metadata.version],
    ['CFBundleVersion', metadata.buildNumber || metadata.version],
    ['CFBundlePackageType', 'APPL'],
    ['NSHighResolutionCapable', true],
  ]

  if (metadata.iconName) entries.push(['CFBundleIconFile', metadata.iconName])
  if (metadata.category) entries.push(['LSApplicationCategoryType', metadata.category])
  if (metadata.minimumSystemVersion) entries.push(['LSMinimumSystemVersion', metadata.minimumSystemVersion])
  if (metadata.menuBarOnly) entries.push(['LSUIElement', true])

  const body = entries
    .map(([key, value]) => `    <key>${xml(key)}</key>\n${value === true ? '    <true/>' : `    <string>${xml(value)}</string>`}`)
    .join('\n')

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
</dict>
</plist>`
}

/**
 * Build the `codesign` argument list for an app bundle.
 *
 * App Store builds are sandboxed and must *not* opt into the hardened runtime;
 * Developer ID builds must, or notarization rejects them.
 */
export function codesignArguments(opts: {
  path: string
  identity: string
  entitlements?: string
  hardenedRuntime?: boolean
}): string[] {
  return [
    '--force',
    '--sign', opts.identity,
    '--timestamp',
    ...(opts.hardenedRuntime ? ['--options', 'runtime'] : []),
    ...(opts.entitlements ? ['--entitlements', opts.entitlements] : []),
    '--deep',
    opts.path,
  ]
}

/** Build the `productbuild` argument list for a Mac App Store submission package. */
export function productbuildArguments(opts: {
  appBundlePath: string
  outputPath: string
  identity: string
}): string[] {
  return [
    '--component', opts.appBundlePath, '/Applications',
    '--sign', opts.identity,
    opts.outputPath,
  ]
}

/** Build the `xcrun notarytool submit` argument list for a DMG or PKG. */
export function notarytoolArguments(opts: {
  artifactPath: string
  appleId: string
  applePassword: string
  teamId: string
}): string[] {
  return [
    'notarytool',
    'submit', opts.artifactPath,
    '--apple-id', opts.appleId,
    '--password', opts.applePassword,
    '--team-id', opts.teamId,
    '--wait',
  ]
}

/**
 * Helper: Create macOS app bundle
 */
function createMacOSAppBundle(opts: MacOSBundleMetadata & {
  binaryPath: string
  /** Path to a `.icns` file copied into `Contents/Resources` */
  iconPath?: string
  /** Path to a `.provisionprofile` copied to `Contents/embedded.provisionprofile` */
  provisioningProfile?: string
  /** Extra executables copied beside the app binary in `Contents/MacOS/` */
  additionalExecutables?: string[]
  outputPath: string
}): { success: boolean; error?: string } {
  try {
    const { name, binaryPath, iconPath, provisioningProfile, additionalExecutables, outputPath } = opts
    const contents = join(outputPath, 'Contents')
    const macOS = join(contents, 'MacOS')

    // Create bundle structure
    mkdirSync(macOS, { recursive: true })
    mkdirSync(join(contents, 'Resources'), { recursive: true })

    // Copy binary
    copyFileSync(binaryPath, join(macOS, name))

    // Make executable
    chmodSync(join(macOS, name), 0o755)

    // Bundle helper executables (e.g. the webview runtime a server-backed app
    // spawns) so the installed .app is self-contained.
    for (const executable of additionalExecutables || []) {
      if (!existsSync(executable))
        return { success: false, error: `Additional executable not found: ${executable}` }
      const destination = join(macOS, basename(executable))
      copyFileSync(executable, destination)
      chmodSync(destination, 0o755)
    }

    // Copy the icon into Resources so CFBundleIconFile resolves
    let iconName: string | undefined
    if (iconPath) {
      if (!existsSync(iconPath))
        return { success: false, error: `Icon not found: ${iconPath}` }
      iconName = basename(iconPath).replace(/\.icns$/i, '')
      copyFileSync(iconPath, join(contents, 'Resources', `${iconName}.icns`))
    }

    // The App Store rejects submissions whose bundle has no embedded profile
    if (provisioningProfile) {
      if (!existsSync(provisioningProfile))
        return { success: false, error: `Provisioning profile not found: ${provisioningProfile}` }
      copyFileSync(provisioningProfile, join(contents, 'embedded.provisionprofile'))
    }

    writeFileSync(join(contents, 'Info.plist'), macOSInfoPlist({ ...opts, iconName }))

    return { success: true }
  }
catch (error) {
    return { success: false, error: (error as Error).message }
  }
}

const MEBIBYTE = 1024 * 1024

function pathContentBytes(path: string): number {
  const stat = lstatSync(path)
  if (!stat.isDirectory()) return stat.size
  return readdirSync(path).reduce((total, entry) => total + pathContentBytes(join(path, entry)), 0)
}

export function dmgCapacityMegabytes(contentBytes: number): number {
  if (!Number.isSafeInteger(contentBytes) || contentBytes < 0)
    throw new Error(`DMG content size must be a non-negative safe integer: ${contentBytes}`)
  const contentMegabytes = Math.ceil(contentBytes / MEBIBYTE)
  return Math.max(64, Math.ceil(contentMegabytes * 1.25) + 32)
}

export function dmgCreateArguments(opts: {
  appBundlePath: string
  outputPath: string
  volumeName: string
}, contentBytes: number): string[] {
  return [
    'create',
    '-volname', opts.volumeName,
    '-srcfolder', opts.appBundlePath,
    '-size', `${dmgCapacityMegabytes(contentBytes)}m`,
    '-ov',
    // LZMA rather than the older zlib: for an app whose bulk is a compiled
    // runtime this roughly halves the download, and every macOS since 10.15
    // mounts it. hdiutil falls back to UDZO on the rare system that cannot.
    '-format', 'ULMO',
    opts.outputPath,
  ]
}

const HDIUTIL_MAX_ATTEMPTS = 3

export function shouldRetryHdiutil(error: string, attempt: number, maxAttempts: number = HDIUTIL_MAX_ATTEMPTS): boolean {
  if (!Number.isInteger(attempt) || attempt < 1 || !Number.isInteger(maxAttempts) || maxAttempts < 1)
    throw new Error('hdiutil retry attempts must be positive integers')
  return attempt < maxAttempts && /(?:resource busy|resource temporarily unavailable)/i.test(error)
}

/** Run a packaging tool, capturing output so failures carry the real diagnostic. */
function runTool(tool: string, args: string[]): Promise<{ success: true } | { success: false, error: string }> {
  return new Promise((resolve) => {
    const proc = spawn(tool, args)
    let stdout = ''
    let stderr = ''
    proc.stdout?.on('data', chunk => { stdout += chunk.toString() })
    proc.stderr?.on('data', chunk => { stderr += chunk.toString() })
    proc.on('close', (code) => {
      if (code === 0) resolve({ success: true })
      else resolve({ success: false, error: formatPackagingCommandError(tool, code, stdout, stderr) })
    })
    proc.on('error', err => resolve({ success: false, error: err.message }))
  })
}

const runHdiutil = (args: string[]) => runTool('hdiutil', args)

/**
 * Helper: Create DMG from app bundle
 */
async function createDMG(opts: {
  appBundlePath: string
  outputPath: string
  volumeName: string
}): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  // hdiutil rejects volume names containing `/`, `:`, or newlines and
  // truncates anything past 27 chars. Surfacing the error early gives a
  // clearer message than the cryptic exit-code-1 hdiutil returns.
  if (!/^[^/:\n]{1,27}$/.test(opts.volumeName))
    return { success: false, error: `Invalid DMG volume name "${opts.volumeName}"; must be 1..27 chars without /, :, or newline` }

  const args = dmgCreateArguments(opts, pathContentBytes(opts.appBundlePath))
  const failures: string[] = []
  for (let attempt = 1; attempt <= HDIUTIL_MAX_ATTEMPTS; attempt++) {
    const result = await runHdiutil(args)
    if (result.success) return { success: true, outputPath: opts.outputPath }
    failures.push(`attempt ${attempt}: ${result.error}`)
    if (!shouldRetryHdiutil(result.error, attempt))
      return { success: false, error: failures.join('\n') }

    rmSync(opts.outputPath, { force: true })
    await new Promise(resolve => setTimeout(resolve, attempt * 2000))
  }
  return { success: false, error: failures.join('\n') }
}

/**
 * Helper: Create PKG from app bundle
 *
 * Two flavours share this entry point:
 * - a plain `pkgbuild` installer for direct distribution, and
 * - a signed `productbuild` submission package for the Mac App Store, which is
 *   the only form App Store Connect accepts.
 */
/**
 * The component property list `pkgbuild` is given for the app bundle.
 *
 * Written out rather than left to `pkgbuild`'s inference, because its default
 * for a bundle is `BundleIsRelocatable = true`, which puts this in the package:
 *
 *     <relocate><bundle id="dev.example.app"/></relocate>
 *
 * That directive tells `installer` the payload path is only a suggestion: it
 * looks the bundle identifier up on the target volume and, if the system has a
 * copy of that bundle registered anywhere, writes the payload over *that* copy
 * instead — and exits 0. The user sees "The install was successful" and finds
 * nothing at /Applications.
 *
 * It is intermittent by nature, since it turns on whether the system has
 * indexed some other copy yet, which is exactly how it behaved: the native
 * lifecycle workflow's macOS legs failed only on slow runs, on both
 * architectures, with `installer` reporting success and the app absent.
 *
 * `BundleIsVersionChecked` is off for a related reason — with it on, installing
 * an *older* version over a newer one is skipped, which silently turns a
 * rollback into a no-op.
 *
 * The `pkg-info` attribute `relocatable="false"` that appears either way is not
 * this setting and does not govern it; only the `<relocate>` element does.
 */
export function pkgbuildComponentPlist(rootRelativeBundlePath: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <false/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>${xml(rootRelativeBundlePath)}</string>
    </dict>
</array>
</plist>
`
}

/** Build the `pkgbuild` argument list for a non-App-Store package. */
export function pkgbuildArguments(opts: {
  root: string
  componentPlistPath: string
  identifier: string
  version: string
  outputPath: string
  installerIdentity?: string
}): string[] {
  return [
    '--root', opts.root,
    '--component-plist', opts.componentPlistPath,
    '--identifier', opts.identifier,
    '--version', opts.version,
    '--install-location', '/',
    ...(opts.installerIdentity ? ['--sign', opts.installerIdentity] : []),
    opts.outputPath,
  ]
}

async function createPKG(opts: {
  appBundlePath: string
  outputPath: string
  identifier: string
  version: string
  appStore?: boolean
  installerIdentity?: string
}): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  // pkgbuild requires reverse-DNS form for the identifier. Validate
  // upfront so the error message is actionable rather than the cryptic
  // pkgbuild "-identifier requires" output.
  if (!/^[a-zA-Z0-9._-]+$/.test(opts.identifier) || !opts.identifier.includes('.'))
    return { success: false, error: `Invalid pkg identifier "${opts.identifier}"; expected reverse-DNS like com.example.app` }

  if (!/^[A-Za-z0-9._+-]+$/.test(opts.version))
    return { success: false, error: `Invalid pkg version "${opts.version}"` }

  if (opts.appStore) {
    if (!opts.installerIdentity)
      return { success: false, error: 'App Store packaging requires macos.installerIdentity (a "3rd Party Mac Developer Installer" identity)' }

    const built = await runTool('productbuild', productbuildArguments({
      appBundlePath: opts.appBundlePath,
      outputPath: opts.outputPath,
      identity: opts.installerIdentity,
    }))
    return built.success
      ? { success: true, outputPath: opts.outputPath }
      : { success: false, error: built.error }
  }

  // pkgbuild installs the contents of --root, so stage the bundle under the
  // path it should land in.
  const tempDir = mkdtempSync(join(tmpdir(), 'craft-pkg-'))
  try {
    // A `root` child rather than tempDir itself, created 0755. mkdtemp makes
    // its directory 0700, pkgbuild records the --root directory's own mode as
    // the mode of `.`, and `.` under `--install-location /` is the target
    // volume's root. Shipping a package that asks for `/` to be 0700 is not
    // something to leave to the installer's discretion.
    const root = join(tempDir, 'root')
    const appsDir = join(root, 'Applications')
    mkdirSync(appsDir, { recursive: true, mode: 0o755 })
    chmodSync(root, 0o755)
    const bundleName = basename(opts.appBundlePath)
    cpSync(opts.appBundlePath, join(appsDir, bundleName), { recursive: true })

    const componentPlistPath = join(tempDir, 'component.plist')
    writeFileSync(componentPlistPath, pkgbuildComponentPlist(`Applications/${bundleName}`))

    const built = await runTool('pkgbuild', pkgbuildArguments({
      root,
      componentPlistPath,
      identifier: opts.identifier,
      version: opts.version,
      outputPath: opts.outputPath,
      installerIdentity: opts.installerIdentity,
    }))
    return built.success
      ? { success: true, outputPath: opts.outputPath }
      : { success: false, error: built.error }
  }
  finally {
    rmSync(tempDir, { recursive: true, force: true })
  }
}

/**
 * Helper: Create Windows MSI
 */
function xml(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll(`'`, '&apos;')
}

function wixIdentifier(value: string): string {
  const sanitized = value.replace(/[^A-Za-z0-9_.]/g, '_')
  return /^[A-Za-z_]/.test(sanitized) ? sanitized : `_${sanitized}`
}

function deterministicGuid(value: string): string {
  const digest = createHash('sha256').update(value).digest('hex').slice(0, 32).split('')
  digest[12] = '4'
  digest[16] = ((Number.parseInt(digest[16]!, 16) & 0x3) | 0x8).toString(16)
  const hex = digest.join('').toUpperCase()
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

export function windowsArchitecture(architecture: string): 'x86' | 'x64' | 'arm64' {
  if (architecture === 'ia32' || architecture === 'x86') return 'x86'
  if (architecture === 'x64' || architecture === 'arm64') return architecture
  throw new Error(`Unsupported Windows package architecture: ${architecture}`)
}

export function renderWixSource(opts: Pick<MSIOptions, 'name' | 'version' | 'manufacturer' | 'architecture'>, sourceName: string): string {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$/.test(opts.version)) throw new Error(`MSI version must have 3 or 4 numeric parts: ${opts.version}`)
  const id = wixIdentifier(opts.name)
  const manufacturer = opts.manufacturer.trim() || 'Unknown'
  const upgradeCode = deterministicGuid(`${manufacturer}/${opts.name}`)
  const programFilesFolder = opts.architecture === 'x86' ? 'ProgramFilesFolder' : 'ProgramFiles64Folder'
  const win64 = opts.architecture === 'x86' ? 'no' : 'yes'
  return `<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*" Name="${xml(opts.name)}" Language="1033" Version="${opts.version}" Manufacturer="${xml(manufacturer)}" UpgradeCode="${upgradeCode}">
    <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine" Platform="${opts.architecture}" />
    <MajorUpgrade AllowDowngrades="yes" />
    <MediaTemplate EmbedCab="yes" />
    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="${programFilesFolder}">
        <Directory Id="INSTALLFOLDER" Name="${xml(opts.name)}">
          <Component Id="${id}Executable" Guid="*" Win64="${win64}">
            <File Id="${id}File" Source="${xml(sourceName)}" KeyPath="yes" />
          </Component>
        </Directory>
      </Directory>
    </Directory>
    <Feature Id="ProductFeature" Title="${xml(opts.name)}" Level="1">
      <ComponentRef Id="${id}Executable" />
    </Feature>
  </Product>
</Wix>
`
}

export function windowsExecutableName(name: string): string {
  if (name.length === 0 || name.trim() !== name || /[<>:"/\\|?*\u0000-\u001F]/.test(name) || /[. ]$/.test(name))
    throw new Error(`Invalid Windows application name: ${JSON.stringify(name)}`)
  if (/^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(name))
    throw new Error(`Reserved Windows application name: ${JSON.stringify(name)}`)
  return `${name}.exe`
}

/**
 * `candle.exe` arguments.
 *
 * `-arch` is not optional. WiX v3 deprecated `Package/@Platform` in favour of
 * this switch, and candle defaults to `x86` without it — so an x64 payload was
 * being compiled into a 32-bit installer whose one component declares
 * `Win64="yes"` and installs under `ProgramFiles64Folder`. ICE80 exists to
 * catch exactly that contradiction, and `light -sval` below turns validation
 * off, so nothing ever reported it.
 */
export function candleArguments(architecture: 'x86' | 'x64' | 'arm64', wixobjPath: string, wxsPath: string): string[] {
  return ['-nologo', '-arch', architecture, '-out', wixobjPath, wxsPath]
}

function runCommand(command: string, args: string[], cwd?: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: 'inherit', windowsHide: true })
    child.once('error', reject)
    child.once('close', code => code === 0 ? resolve() : reject(new Error(`${command} exited with code ${code}`)))
  })
}

async function createMSI(opts: MSIOptions): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  const tempDir = mkdtempSync(join(tmpdir(), 'craft-msi-'))
  try {
    const binaryName = windowsExecutableName(opts.name)
    const sourcePath = join(tempDir, binaryName)
    const wxsPath = join(tempDir, 'installer.wxs')
    const wixobjPath = join(tempDir, 'installer.wixobj')
    copyFileSync(opts.binaryPath, sourcePath)
    writeFileSync(wxsPath, renderWixSource(opts, binaryName))
    await runCommand('candle.exe', candleArguments(opts.architecture, wixobjPath, wxsPath), tempDir)
    await runCommand('light.exe', ['-nologo', '-sval', '-out', opts.outputPath, wixobjPath], tempDir)
    if (opts.certificatePath) {
      const signArgs = ['sign', '/fd', 'sha256', '/tr', 'https://timestamp.digicert.com', '/td', 'sha256', '/f', opts.certificatePath]
      if (opts.certificatePassword) signArgs.push('/p', opts.certificatePassword)
      signArgs.push(opts.outputPath)
      await runCommand('signtool.exe', signArgs)
      await runCommand('signtool.exe', ['verify', '/pa', '/all', opts.outputPath])
    }
    return { success: true, outputPath: opts.outputPath }
  }
  catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const missingTool = /ENOENT|not found/i.test(message)
    return { success: false, error: missingTool ? `WiX Toolset not found: ${message}` : message }
  }
  finally {
    rmSync(tempDir, { recursive: true, force: true })
  }
}

/**
 * Helper: Create Windows ZIP
 */
async function createZIP(opts: {
  name: string
  version: string
  binaryPath: string
  outputPath: string
}): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  try {
    const data = new Uint8Array(readFileSync(opts.binaryPath))
    const zip = buildZip([{ name: `${opts.name}.exe`, data }])
    writeFileSync(opts.outputPath, zip)
    return { success: true, outputPath: opts.outputPath }
  }
  catch (err) {
    return { success: false, error: `Failed to write ZIP: ${(err as Error).message}` }
  }
}

/**
 * Helper: Create Linux DEB package
 */
async function createDEB(opts: {
  name: string
  version: string
  binaryPath: string
  outputPath: string
  description: string
  maintainer: string
  dependencies: string[]
}): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  return new Promise((resolve) => {
    try {
      // Validate inputs that get interpolated into the DEBIAN/control file.
      // dpkg's control file is line-oriented; newlines or `,` in fields, or
      // `/` in the package name, corrupt the manifest.
      const sanitizedName = opts.name.toLowerCase()
      const safeDebName = /^[a-z0-9._+-]+$/
      const safeVersion = /^[A-Za-z0-9._+-]+$/
      if (!safeDebName.test(sanitizedName)) {
        resolve({ success: false, error: `DEB package name must match ${safeDebName} (got: ${sanitizedName})` })
        return
      }
      if (!safeVersion.test(opts.version)) {
        resolve({ success: false, error: `DEB version must match ${safeVersion} (got: ${opts.version})` })
        return
      }
      const cleanLine = (s: string): string => s.replace(/[\r\n]+/g, ' ').trim()
      const description = cleanLine(opts.description)
      const maintainer = cleanLine(opts.maintainer)
      for (const dep of opts.dependencies) {
        // Allow versioned constraints like `libgtk-3-0 (>= 3.22)`.
        if (!/^[a-z0-9._+-]+(?:\s*\([^)\n,]+\))?$/i.test(dep)) {
          resolve({ success: false, error: `Invalid DEB dependency "${dep}"` })
          return
        }
      }

      // Create DEB package structure
      const tempDir = mkdtempSync(join(tmpdir(), 'craft-deb-'))
      const debianDir = join(tempDir, 'DEBIAN')
      const binDir = join(tempDir, 'usr', 'bin')
      const applicationsDir = join(tempDir, 'usr', 'share', 'applications')

      mkdirSync(debianDir, { recursive: true })
      mkdirSync(binDir, { recursive: true })
      mkdirSync(applicationsDir, { recursive: true })

      // Copy binary
      const binaryName = sanitizedName
      copyFileSync(opts.binaryPath, join(binDir, binaryName))
      chmodSync(join(binDir, binaryName), 0o755)

      // Create control file. Every field has been sanitized above.
      const controlContent = `Package: ${sanitizedName}
Version: ${opts.version}
Section: utils
Priority: optional
Architecture: amd64
Depends: ${opts.dependencies.join(', ')}
Maintainer: ${maintainer}
Description: ${description || opts.name}
`
      writeFileSync(join(debianDir, 'control'), controlContent)

      // Create .desktop file
      const desktopContent = `[Desktop Entry]
Type=Application
Name=${opts.name}
Exec=/usr/bin/${binaryName}
Terminal=false
Categories=Utility;
`
      writeFileSync(join(applicationsDir, `${binaryName}.desktop`), desktopContent)

      // Build DEB using dpkg-deb
      const proc = spawn('dpkg-deb', ['--build', tempDir, opts.outputPath])

      proc.on('close', (code) => {
        rmSync(tempDir, { recursive: true, force: true })
        if (code === 0) {
          resolve({ success: true, outputPath: opts.outputPath })
        }
else {
          resolve({ success: false, error: `dpkg-deb exited with code ${code}` })
        }
      })

      proc.on('error', (err) => {
        rmSync(tempDir, { recursive: true, force: true })
        resolve({ success: false, error: err.message })
      })
    }
catch (error) {
      resolve({ success: false, error: (error as Error).message })
    }
  })
}

/**
 * Helper: Create Linux RPM package
 */
async function createRPM(opts: {
  name: string
  version: string
  binaryPath: string
  outputPath: string
  description: string
  requires: string[]
}): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  return new Promise((resolve) => {

    try {
      // Create RPM build structure
      const buildRoot = join(homedir(), 'rpmbuild')
      const specDir = join(buildRoot, 'SPECS')
      const sourcesDir = join(buildRoot, 'SOURCES')
      const buildDir = join(buildRoot, 'BUILD')
      const rpmsDir = join(buildRoot, 'RPMS')

      mkdirSync(specDir, { recursive: true })
      mkdirSync(sourcesDir, { recursive: true })
      mkdirSync(buildDir, { recursive: true })
      mkdirSync(rpmsDir, { recursive: true })

      // Validate inputs that get interpolated into the .spec file. RPM spec
      // files treat `%` as a macro prefix and parse line-by-line, so
      // newlines or `%` in user data could inject scriptlets / corrupt the
      // spec. Reject early with a clear message.
      const safePackageName = /^[a-z0-9._+-]+$/i
      const safeVersion = /^[A-Za-z0-9._+-]+$/
      const sanitizedName = opts.name.toLowerCase()
      if (!safePackageName.test(sanitizedName)) {
        return resolve({ success: false, error: `RPM package name must match ${safePackageName} (got: ${sanitizedName})` })
      }
      if (!safeVersion.test(opts.version)) {
        return resolve({ success: false, error: `RPM version must match ${safeVersion} (got: ${opts.version})` })
      }
      // Description / summary go into single-line spec headers; collapse
      // newlines and reject `%` to prevent macro expansion.
      const cleanLine = (s: string): string => s.replace(/[\r\n]+/g, ' ').replace(/%/g, '%%')
      const summary = cleanLine(opts.description || opts.name)
      const description = (opts.description || opts.name)
        .split(/\r?\n/).map(line => line.replace(/%/g, '%%')).join('\n')
      const requires = opts.requires.map((r) => {
        if (!safePackageName.test(r)) {
          throw new Error(`RPM Requires entry must match ${safePackageName} (got: ${r})`)
        }
        return r
      }).join(', ')

      // Copy binary to sources
      copyFileSync(opts.binaryPath, join(sourcesDir, sanitizedName))

      // Create spec file
      const specContent = `Name: ${sanitizedName}
Version: ${opts.version}
Release: 1%{?dist}
Summary: ${summary}
License: MIT
Requires: ${requires}

%description
${description}

%install
mkdir -p %{buildroot}/usr/bin
install -m 755 %{SOURCE0} %{buildroot}/usr/bin/${sanitizedName}

%files
/usr/bin/${sanitizedName}
`
      const specPath = join(specDir, `${opts.name.toLowerCase()}.spec`)
      writeFileSync(specPath, specContent)

      // Build RPM
      const proc = spawn('rpmbuild', ['-bb', specPath])

      proc.on('close', (code) => {
        if (code === 0) {
          // Find the built RPM and move it
          const rpmName = `${opts.name.toLowerCase()}-${opts.version}-1.x86_64.rpm`
          const builtRpmPath = join(rpmsDir, 'x86_64', rpmName)
          try {
            copyFileSync(builtRpmPath, opts.outputPath)
            resolve({ success: true, outputPath: opts.outputPath })
          }
catch {
            resolve({ success: false, error: 'Failed to copy built RPM' })
          }
        }
else {
          resolve({ success: false, error: `rpmbuild exited with code ${code}` })
        }
      })

      proc.on('error', (err) => {
        resolve({ success: false, error: err.message })
      })
    }
catch (error) {
      resolve({ success: false, error: (error as Error).message })
    }
  })
}

/**
 * Helper: Create Linux AppImage
 */
async function createAppImage(opts: {
  name: string
  version: string
  binaryPath: string
  outputPath: string
  iconPath?: string
}): Promise<{ success: boolean; outputPath?: string; error?: string }> {
  return new Promise((resolve) => {

    try {
      // Create AppDir structure
      const appDir = mkdtempSync(join(tmpdir(), 'craft-appimage-'))
      const appDirPath = join(appDir, `${opts.name}.AppDir`)
      const binDir = join(appDirPath, 'usr', 'bin')
      const shareDir = join(appDirPath, 'usr', 'share')

      mkdirSync(binDir, { recursive: true })
      mkdirSync(shareDir, { recursive: true })

      // Copy binary
      const binaryName = opts.name.toLowerCase()
      copyFileSync(opts.binaryPath, join(binDir, binaryName))
      chmodSync(join(binDir, binaryName), 0o755)

      // Create AppRun script
      const appRunContent = `#!/bin/bash
SELF=$(readlink -f "$0")
HERE=\${SELF%/*}
export PATH="\${HERE}/usr/bin/:\${PATH}"
exec "\${HERE}/usr/bin/${binaryName}" "$@"
`
      writeFileSync(join(appDirPath, 'AppRun'), appRunContent)
      chmodSync(join(appDirPath, 'AppRun'), 0o755)

      // Create .desktop file
      const desktopContent = `[Desktop Entry]
Type=Application
Name=${opts.name}
Exec=${binaryName}
Terminal=false
Categories=Utility;
Icon=${binaryName}
`
      writeFileSync(join(appDirPath, `${binaryName}.desktop`), desktopContent)

      // Copy or create icon
      if (opts.iconPath && existsSync(opts.iconPath)) {
        copyFileSync(opts.iconPath, join(appDirPath, `${binaryName}.png`))
      }
else {
        // Create placeholder icon (1x1 PNG)
        const placeholderPng = Buffer.from([
          0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
          0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
          0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00,
          0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xff, 0xff, 0x3f,
          0x00, 0x05, 0xfe, 0x02, 0xfe, 0xdc, 0xcc, 0x59, 0xe7, 0x00, 0x00, 0x00,
          0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        ])
        writeFileSync(join(appDirPath, `${binaryName}.png`), placeholderPng)
      }

      // Use appimagetool if available
      const proc = spawn('appimagetool', [appDirPath, opts.outputPath], {
        env: { ...process.env, ARCH: 'x86_64' }
      })

      proc.on('close', (code) => {
        rmSync(appDir, { recursive: true, force: true })
        if (code === 0) {
          chmodSync(opts.outputPath, 0o755)
          resolve({ success: true, outputPath: opts.outputPath })
        }
else {
          resolve({ success: false, error: `appimagetool exited with code ${code}. Install from https://appimage.github.io/appimagetool/` })
        }
      })

      proc.on('error', (err) => {
        rmSync(appDir, { recursive: true, force: true })
        resolve({ success: false, error: `appimagetool not found: ${err.message}` })
      })
    }
catch (error) {
      resolve({ success: false, error: (error as Error).message })
    }
  })
}

/**
 * Detect current platform
 */
function detectPlatform(): 'macos' | 'windows' | 'linux' {
  switch (process.platform) {
    case 'darwin':
      return 'macos'
    case 'win32':
      return 'windows'
    default:
      return 'linux'
  }
}

/**
 * Simple packaging function for quick use
 */
export async function pack(options: {
  name: string
  version: string
  binaryPath: string
  outDir?: string
}): Promise<PackageResult[]> {
  return packageApp({
    ...options,
    platforms: [detectPlatform()],
  })
}
