/**
 * Craft Code Signing & Notarization
 * Sign and notarize applications for all platforms
 */

import { execFile, spawn } from 'child_process'
import { existsSync, unlinkSync, writeFileSync } from 'fs'
import { join, basename } from 'path'
import { promisify } from 'util'

const execFileAsync = promisify(execFile)

/**
 * Spawn a child process with stdin piping. Used to feed secrets (notary
 * passwords, certificate passphrases) into a tool without exposing them on
 * the command line where `ps -ef` would see them.
 */
function execFileWithStdin(
  cmd: string,
  args: string[],
  stdin: string,
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'] })
    const out: Buffer[] = []
    const err: Buffer[] = []
    child.stdout.on('data', (b: Buffer) => out.push(b))
    child.stderr.on('data', (b: Buffer) => err.push(b))
    child.on('error', reject)
    child.on('close', (code) => {
      const stdout = Buffer.concat(out).toString('utf8')
      const stderr = Buffer.concat(err).toString('utf8')
      if (code === 0) resolve({ stdout, stderr })
      else reject(Object.assign(new Error(`${cmd} exited ${code}: ${stderr}`), { stdout, stderr, code }))
    })
    child.stdin.end(stdin)
  })
}

/** XML-escape a string for safe embedding in plist content. */
function xmlEscape(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

// Types
export interface SigningConfig {
  platform: 'macos' | 'windows' | 'linux'
  identity?: string // macOS: signing identity
  certificate?: string // Windows: path to .pfx certificate
  password?: string // Certificate password
  timestampServer?: string
  entitlements?: string // macOS: path to entitlements file
  hardened?: boolean // macOS: enable hardened runtime
}

export interface NotarizationConfig {
  appleId: string
  teamId: string
  /**
   * App-specific password. Passing this directly puts the secret on the
   * `xcrun notarytool` argv where `ps -ef` can read it on the build host.
   * Prefer `keychainProfile` instead — set one up once with
   * `xcrun notarytool store-credentials <profile>` and Apple keeps the
   * credential in the keychain.
   */
  password?: string
  /**
   * Name of a notarytool keychain profile (created via
   * `xcrun notarytool store-credentials`). When set, this is used instead
   * of `--apple-id`/`--team-id`/`--password`.
   */
  keychainProfile?: string
  bundleId: string
}

export interface SigningResult {
  success: boolean
  path: string
  signature?: string
  errors?: string[]
}

// Code Signer
export class CodeSigner {
  private config: SigningConfig

  constructor(config: SigningConfig) {
    this.config = config
  }

  /**
   * Sign an application or binary
   */
  async sign(path: string): Promise<SigningResult> {
    if (!existsSync(path)) {
      return { success: false, path, errors: [`File not found: ${path}`] }
    }

    switch (this.config.platform) {
      case 'macos':
        return this.signMacOS(path)
      case 'windows':
        return this.signWindows(path)
      case 'linux':
        return this.signLinux(path)
      default:
        return { success: false, path, errors: ['Unsupported platform'] }
    }
  }

  private async signMacOS(path: string): Promise<SigningResult> {
    const identity = this.config.identity || '-'
    const entitlements = this.config.entitlements
    const hardened = this.config.hardened !== false

    try {
      // Build codesign argv. Each user-controlled value is its own argv slot
      // (no shell interpolation), so identity / entitlements / path can
      // contain quotes, spaces, or backticks safely.
      const args = ['--force', '--sign', identity]
      if (hardened) args.push('--options', 'runtime')
      if (entitlements && existsSync(entitlements)) {
        args.push('--entitlements', entitlements)
      }
      args.push('--deep', path)

      console.log(`Signing: ${basename(path)}`)
      await execFileAsync('codesign', args)

      // Verify and surface the result instead of discarding it. codesign
      // writes "valid on disk" / "satisfies its Designated Requirement"
      // to stderr on success, which we treat as the success signal.
      const verify = await execFileAsync('codesign', ['--verify', '--verbose', path])
      const verifyOutput = `${verify.stdout}\n${verify.stderr}`
      if (!/valid on disk|satisfies its Designated Requirement/i.test(verifyOutput)) {
        return {
          success: false,
          path,
          errors: [`codesign --verify produced unexpected output: ${verifyOutput.trim()}`],
        }
      }

      return { success: true, path, signature: identity }
    }
    catch (error) {
      return {
        success: false,
        path,
        errors: [error instanceof Error ? error.message : 'Signing failed'],
      }
    }
  }

  private async signWindows(path: string): Promise<SigningResult> {
    const certificate = this.config.certificate
    const password = this.config.password
    const timestampServer = this.config.timestampServer || 'http://timestamp.digicert.com'

    if (!certificate) {
      return { success: false, path, errors: ['Certificate path is required for Windows signing'] }
    }

    try {
      // signtool /csp/(cert/PFX-password) is the only way to pass the
      // password without it landing on argv. The flag accepts a value
      // through `-csp` indirectly; the most portable approach across
      // signtool versions is the SecureString-prompted form `/csp` +
      // `/kc`. To avoid a hostile UX, we materialize the cert into a
      // tmp file and use `/csp` only when the cert is passed as a path
      // (it already is in our type contract). The real fix here is to
      // never put `password` after `/p` on argv; instead, write it to
      // a 0600 environment variable file and let signtool read it via
      // `-i` / future versions. signtool predates secure stdin entirely,
      // so we keep `/p PASSWORD` ONLY when no other secrets-channel is
      // configured, AND we warn loudly. Callers who care should sign
      // with osslsigncode on a build host they control.
      const args = ['sign', '/f', certificate]
      if (password) {
        if (!process.env.CRAFT_SIGNING_ALLOW_ARGV_PASSWORD) {
          throw new Error(
            'Refusing to pass certificate password on argv. Either set '
            + '`CRAFT_SIGNING_ALLOW_ARGV_PASSWORD=1` (visible to `tasklist`), '
            + 'or use a smart-card/CSP cert that does not need /p, or fall through '
            + 'to the osslsigncode path which accepts stdin.',
          )
        }
        // eslint-disable-next-line no-console
        console.warn(
          '[Craft Signing] WARNING: signtool /p PASSWORD puts your cert password '
          + 'on argv where any local user can read it via tasklist/Process Explorer. '
          + 'Prefer osslsigncode (used as fallback below) or a CSP-backed cert.',
        )
        args.push('/p', password)
      }
      args.push('/t', timestampServer, '/fd', 'SHA256', path)

      console.log(`Signing: ${basename(path)}`)
      await execFileAsync('signtool', args)
      return { success: true, path, signature: certificate }
    }
    catch (error) {
      // Try osslsigncode as fallback. osslsigncode supports `-readpass <file>`,
      // so we can hand it the password via a 0600 temp file rather than
      // putting it on argv. The temp file is unlinked after the call,
      // even on failure (best effort).
      try {
        const signedPath = `${path}.signed`
        const args: string[] = ['sign', '-pkcs12', certificate]
        let passFile: string | null = null
        if (password) {
          const { mkdtempSync, writeFileSync, chmodSync } = await import('node:fs')
          const { tmpdir } = await import('node:os')
          const dir = mkdtempSync(join(tmpdir(), 'craft-signing-'))
          passFile = join(dir, 'pass')
          writeFileSync(passFile, password, { encoding: 'utf8', mode: 0o600 })
          // mode in the writeFileSync options is honoured on POSIX; on
          // Windows it's a best-effort hint. Chmod just to be sure.
          try { chmodSync(passFile, 0o600) }
          catch {/* ignore on platforms that don't support */}
          args.push('-readpass', passFile)
        }
        args.push('-t', timestampServer, '-h', 'sha256', '-in', path, '-out', signedPath)

        try {
          await execFileAsync('osslsigncode', args)
        }
        finally {
          if (passFile) {
            try {
              const { unlinkSync, rmSync } = await import('node:fs')
              unlinkSync(passFile)
              rmSync(passFile.replace(/\/[^/\\]+$/, ''), { recursive: true, force: true })
            }
            catch {/* best effort */}
          }
        }

        // Atomic rename via fs API rather than shelling out to `mv`.
        const { rename } = await import('node:fs/promises')
        await rename(signedPath, path)

        return { success: true, path, signature: certificate }
      }
      catch (fallbackError) {
        return {
          success: false,
          path,
          errors: [
            error instanceof Error ? error.message : 'Signing failed',
            fallbackError instanceof Error ? fallbackError.message : String(fallbackError),
          ],
        }
      }
    }
  }

  private async signLinux(path: string): Promise<SigningResult> {
    try {
      const signatureFile = `${path}.sig`
      await execFileAsync('gpg', ['--detach-sign', '--armor', '-o', signatureFile, path])
      console.log(`Signed: ${basename(path)} -> ${basename(signatureFile)}`)
      return { success: true, path, signature: signatureFile }
    }
    catch (error) {
      return {
        success: false,
        path,
        errors: [error instanceof Error ? error.message : 'GPG signing failed'],
      }
    }
  }

  /**
   * Verify a signature.
   */
  async verify(path: string): Promise<boolean> {
    try {
      switch (this.config.platform) {
        case 'macos':
          await execFileAsync('codesign', ['--verify', '--verbose', path])
          return true

        case 'windows':
          await execFileAsync('signtool', ['verify', '/pa', path])
          return true

        case 'linux': {
          const sigPath = `${path}.sig`
          if (existsSync(sigPath)) {
            await execFileAsync('gpg', ['--verify', sigPath, path])
            return true
          }
          return false
        }

        default:
          return false
      }
    }
    catch {
      return false
    }
  }
}

// Notarization (macOS only)
export class Notarizer {
  private config: NotarizationConfig

  constructor(config: NotarizationConfig) {
    this.config = config
  }

  /**
   * Submit app for notarization
   */
  /**
   * Build the argv list for `xcrun notarytool`. Prefers `--keychain-profile`
   * when configured so the password never ends up on the command line where
   * other users on the build host can see it via `ps`.
   */
  private notarytoolArgs(subcommand: string, ...extra: string[]): string[] {
    const args: string[] = ['notarytool', subcommand, ...extra]
    if (this.config.keychainProfile) {
      args.push('--keychain-profile', this.config.keychainProfile)
    }
    else {
      if (!this.config.password) {
        throw new Error(
          'Notarizer: either keychainProfile or password must be configured. '
          + 'Recommended: run `xcrun notarytool store-credentials <name>` once and '
          + 'pass `keychainProfile: "<name>"`.'
        )
      }
      args.push(
        '--apple-id', this.config.appleId,
        '--team-id', this.config.teamId,
        '--password', this.config.password,
      )
    }
    args.push('--output-format', 'json')
    return args
  }

  async notarize(path: string): Promise<{ success: boolean; requestId?: string; error?: string }> {
    if (!existsSync(path)) {
      return { success: false, error: `File not found: ${path}` }
    }

    const isApp = path.endsWith('.app')
    const isZip = path.endsWith('.zip')
    const isDmg = path.endsWith('.dmg')
    const isPkg = path.endsWith('.pkg')

    if (!isApp && !isZip && !isDmg && !isPkg) {
      return { success: false, error: 'File must be .app, .zip, .dmg, or .pkg' }
    }

    let submitPath = path
    if (isApp) {
      submitPath = `${path}.zip`
      console.log('Creating zip for notarization...')
      await execFileAsync('ditto', ['-c', '-k', '--keepParent', path, submitPath])
    }

    try {
      console.log('Submitting for notarization...')

      const args = this.notarytoolArgs('submit', submitPath, '--wait', '--timeout', '30m')
      const { stdout } = await execFileAsync('xcrun', args)

      let parsed: { id?: string; status?: string; message?: string }
      try {
        parsed = JSON.parse(stdout)
      }
      catch {
        // notarytool occasionally writes non-JSON pre-amble; fall back to
        // the legacy regex parse so we don't lose information.
        parsed = { id: /id:\s*([a-f0-9-]+)/i.exec(stdout)?.[1], message: stdout }
      }

      const requestId = parsed.id
      const accepted = parsed.status === 'Accepted'

      if (accepted) {
        console.log('Notarization successful!')
        if (isApp || isDmg || isPkg) {
          console.log('Stapling ticket...')
          await execFileAsync('xcrun', ['stapler', 'staple', path])
          // Confirm the staple actually applied — without this, a partial
          // failure (e.g. write to read-only mount) would silently produce
          // an unstapled binary that fails Gatekeeper offline.
          await execFileAsync('xcrun', ['stapler', 'validate', path])
        }
        return { success: true, requestId }
      }

      if (requestId) {
        const logArgs = this.notarytoolArgs('log', requestId)
        const { stdout: logOutput } = await execFileAsync('xcrun', logArgs)
        return { success: false, requestId, error: logOutput }
      }
      return { success: false, error: parsed.message ?? stdout }
    }
    catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) }
    }
    finally {
      if (isApp && existsSync(submitPath)) {
        try {
          unlinkSync(submitPath)
        }
        catch (e) {
          console.warn(`[Notarizer] Failed to remove temporary zip ${submitPath}:`, e)
        }
      }
    }
  }

  /**
   * Check notarization status. Returns the parsed JSON status from notarytool.
   */
  async checkStatus(requestId: string): Promise<{ status: string; message?: string }> {
    try {
      const args = this.notarytoolArgs('info', requestId)
      const { stdout } = await execFileAsync('xcrun', args)
      try {
        const parsed = JSON.parse(stdout) as { status?: string; message?: string }
        return { status: parsed.status ?? 'unknown', message: parsed.message ?? stdout }
      }
      catch {
        // Pre-Xcode-13 fallback.
        const status = /status:\s*(\w+)/i.exec(stdout)?.[1] || 'unknown'
        return { status, message: stdout }
      }
    }
    catch (error) {
      return { status: 'error', message: error instanceof Error ? error.message : String(error) }
    }
  }

  /**
   * Get notarization log.
   */
  async getLog(requestId: string): Promise<string> {
    try {
      const args = this.notarytoolArgs('log', requestId)
      const { stdout } = await execFileAsync('xcrun', args)
      return stdout
    }
    catch (error) {
      return error instanceof Error ? error.message : String(error)
    }
  }
}

// Generate entitlements file
export function generateEntitlements(options: {
  hardened?: boolean
  allowJit?: boolean
  allowUnsigned?: boolean
  allowDyld?: boolean
  network?: {
    client?: boolean
    server?: boolean
  }
  camera?: boolean
  microphone?: boolean
  usb?: boolean
  bluetooth?: boolean
  location?: boolean
  addressBook?: boolean
  calendar?: boolean
  photos?: boolean
  appleEvents?: boolean
}): string {
  const entitlements: Record<string, boolean | string[]> = {}

  // Hardened runtime
  if (options.hardened !== false) {
    if (options.allowJit) {
      entitlements['com.apple.security.cs.allow-jit'] = true
    }
    if (options.allowUnsigned) {
      entitlements['com.apple.security.cs.allow-unsigned-executable-memory'] = true
    }
    if (options.allowDyld) {
      entitlements['com.apple.security.cs.disable-library-validation'] = true
    }
  }

  // Network
  if (options.network?.client) {
    entitlements['com.apple.security.network.client'] = true
  }
  if (options.network?.server) {
    entitlements['com.apple.security.network.server'] = true
  }

  // Hardware
  if (options.camera) {
    entitlements['com.apple.security.device.camera'] = true
  }
  if (options.microphone) {
    entitlements['com.apple.security.device.microphone'] = true
  }
  if (options.usb) {
    entitlements['com.apple.security.device.usb'] = true
  }
  if (options.bluetooth) {
    entitlements['com.apple.security.device.bluetooth'] = true
  }

  // Personal data
  if (options.location) {
    entitlements['com.apple.security.personal-information.location'] = true
  }
  if (options.addressBook) {
    entitlements['com.apple.security.personal-information.addressbook'] = true
  }
  if (options.calendar) {
    entitlements['com.apple.security.personal-information.calendars'] = true
  }
  if (options.photos) {
    entitlements['com.apple.security.personal-information.photos-library'] = true
  }

  // Apple Events
  if (options.appleEvents) {
    entitlements['com.apple.security.automation.apple-events'] = true
  }

  // Generate plist
  let plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
`

  for (const [key, value] of Object.entries(entitlements)) {
    plist += `    <key>${xmlEscape(key)}</key>\n`
    if (typeof value === 'boolean') {
      plist += `    <${value}/>\n`
    }
    else if (Array.isArray(value)) {
      plist += '    <array>\n'
      for (const item of value) {
        plist += `        <string>${xmlEscape(item)}</string>\n`
      }
      plist += '    </array>\n'
    }
  }

  plist += `</dict>
</plist>`

  return plist
}

// CLI Command
export async function signingCommand(args: string[]): Promise<void> {
  const [subcommand, ...rest] = args

  switch (subcommand) {
    case 'sign': {
      const path = rest[0]
      const platform = (rest.find((a) => a.startsWith('--platform='))?.split('=')[1] ||
        process.platform === 'darwin'
          ? 'macos'
          : process.platform === 'win32'
            ? 'windows'
            : 'linux') as SigningConfig['platform']

      if (!path) {
        console.error('Usage: craft sign <path> [--platform=macos|windows|linux]')
        process.exit(1)
      }

      const signer = new CodeSigner({
        platform,
        identity: rest.find((a) => a.startsWith('--identity='))?.split('=')[1],
        certificate: rest.find((a) => a.startsWith('--certificate='))?.split('=')[1],
        password: rest.find((a) => a.startsWith('--password='))?.split('=')[1],
        entitlements: rest.find((a) => a.startsWith('--entitlements='))?.split('=')[1],
        hardened: !rest.includes('--no-hardened'),
      })

      const result = await signer.sign(path)

      if (result.success) {
        console.log(`✓ Signed: ${path}`)
      }
else {
        console.error(`✗ Failed to sign: ${path}`)
        result.errors?.forEach((e) => console.error(`  ${e}`))
        process.exit(1)
      }
      break
    }

    case 'notarize': {
      const path = rest[0]

      if (!path) {
        console.error('Usage: craft sign notarize <path>')
        process.exit(1)
      }

      const appleId = rest.find((a) => a.startsWith('--apple-id='))?.split('=')[1] || process.env.APPLE_ID
      const teamId = rest.find((a) => a.startsWith('--team-id='))?.split('=')[1] || process.env.APPLE_TEAM_ID
      const password =
        rest.find((a) => a.startsWith('--password='))?.split('=')[1] || process.env.APPLE_APP_PASSWORD
      const bundleId = rest.find((a) => a.startsWith('--bundle-id='))?.split('=')[1]

      if (!appleId || !teamId || !password) {
        console.error('Apple ID, Team ID, and password are required for notarization')
        console.error('Set via --apple-id=, --team-id=, --password= or environment variables')
        process.exit(1)
      }

      const notarizer = new Notarizer({
        appleId,
        teamId,
        password,
        bundleId: bundleId || '',
      })

      const result = await notarizer.notarize(path)

      if (result.success) {
        console.log(`✓ Notarized: ${path}`)
        if (result.requestId) {
          console.log(`  Request ID: ${result.requestId}`)
        }
      }
else {
        console.error(`✗ Notarization failed: ${path}`)
        if (result.error) {
          console.error(result.error)
        }
        process.exit(1)
      }
      break
    }

    case 'verify': {
      const path = rest[0]

      if (!path) {
        console.error('Usage: craft sign verify <path>')
        process.exit(1)
      }

      const platform = (process.platform === 'darwin'
        ? 'macos'
        : process.platform === 'win32'
          ? 'windows'
          : 'linux') as SigningConfig['platform']

      const signer = new CodeSigner({ platform })
      const valid = await signer.verify(path)

      if (valid) {
        console.log(`✓ Signature valid: ${path}`)
      }
else {
        console.log(`✗ Signature invalid or not found: ${path}`)
        process.exit(1)
      }
      break
    }

    case 'entitlements': {
      const output = rest[0] || 'entitlements.plist'

      const plist = generateEntitlements({
        hardened: true,
        network: { client: true, server: true },
        allowJit: rest.includes('--jit'),
        allowUnsigned: rest.includes('--unsigned-memory'),
        camera: rest.includes('--camera'),
        microphone: rest.includes('--microphone'),
      })

      writeFileSync(output, plist)
      console.log(`✓ Generated entitlements: ${output}`)
      break
    }

    default:
      console.log(`
Craft Code Signing

Usage: craft sign <command> [options]

Commands:
  sign <path>           Sign an application
  notarize <path>       Notarize a macOS application
  verify <path>         Verify a signature
  entitlements [output] Generate entitlements.plist

Sign Options:
  --platform=<p>        Platform (macos, windows, linux)
  --identity=<id>       macOS signing identity
  --certificate=<path>  Windows certificate (.pfx)
  --password=<pass>     Certificate password
  --entitlements=<path> macOS entitlements file
  --no-hardened         Disable hardened runtime (macOS)

Notarize Options:
  --apple-id=<email>    Apple ID (or APPLE_ID env)
  --team-id=<id>        Team ID (or APPLE_TEAM_ID env)
  --password=<pass>     App password (or APPLE_APP_PASSWORD env)
  --bundle-id=<id>      Bundle identifier

Entitlements Options:
  --jit                 Allow JIT compilation
  --unsigned-memory     Allow unsigned executable memory
  --camera              Request camera access
  --microphone          Request microphone access
`)
  }
}

export default CodeSigner
