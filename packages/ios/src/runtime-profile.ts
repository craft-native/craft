import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import type { CraftConfig } from './index.js'

// ABI order: packages/zig/src/ios_permissions.zig. Never reorder existing bits.
export const iosPermissionNames = ['speech', 'microphone', 'camera', 'photos', 'location', 'contacts', 'calendar', 'bluetooth', 'motion', 'biometric', 'music', 'health', 'nfc'] as const
export type IOSPermission = typeof iosPermissionNames[number]

export function iosPermissions(config: Partial<CraftConfig>): IOSPermission[] {
  const enabled: Record<IOSPermission, boolean | undefined> = {
    speech: config.enableSpeechRecognition,
    microphone: config.enableSpeechRecognition || config.enableAudioRecording || config.enableVideoRecording,
    camera: config.enableCamera || config.enableVideoRecording || config.enableQRScanner || config.enableAR,
    photos: config.enableCamera || config.enableVideoRecording,
    location: config.enableGeolocation || config.enableBackgroundLocation,
    contacts: config.enableContacts,
    calendar: config.enableCalendar,
    bluetooth: config.enableBluetooth || config.enableHeartRate,
    motion: config.enableMotionSensors,
    biometric: config.enableBiometric,
    music: config.enableAppleMusic,
    health: config.enableHealthKit,
    nfc: config.enableNFC,
  }
  return iosPermissionNames.filter(name => enabled[name] === true)
}

export function iosPermissionMask(config: Partial<CraftConfig>): number {
  return iosPermissions(config).reduce((mask, name) => mask | (1 << iosPermissionNames.indexOf(name)), 0)
}

const archives = ['libcraft-ios.a', 'libcraft-ios-simulator-arm64.a', 'libcraft-ios-simulator-x64.a'] as const
const digest = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex')

/** Refuse stale or mismatched archives before replacing a working runtime. */
export function verifyRuntimeProfile(directory: string, config: Partial<CraftConfig>): void {
  const profile = JSON.parse(readFileSync(join(directory, 'ios-permissions.json'), 'utf8'))
  if (profile.version !== 1 || profile.mask !== iosPermissionMask(config))
    throw new Error('Zig runtime permission profile does not match craft.config.json; rebuild it for this app')
  for (const name of archives) {
    if (!existsSync(join(directory, name)) || profile.sha256?.[name] !== digest(join(directory, name)))
      throw new Error(`Zig runtime archive identity mismatch: ${name}; rebuild it for this app`)
  }
}

/** Build from an explicitly supplied Craft Zig source package, never a guessed checkout. */
export async function withAppRuntime<T>(source: string, config: Partial<CraftConfig>, use: (directory: string) => Promise<T>): Promise<T> {
  const root = resolve(source)
  const manifest = readFileSync(join(root, 'build.zig.zon'), 'utf8')
  const version = /\.minimum_zig_version\s*=\s*"([^"]+)"/.exec(manifest)?.[1]
  if (!version) throw new Error('Craft Zig source must declare its pinned minimum_zig_version')
  const zig = process.env.CRAFT_ZIG || 'zig'
  const actual = Bun.spawnSync([zig, 'version'], { stdout: 'pipe', stderr: 'pipe' })
  if (actual.exitCode !== 0 || actual.stdout.toString().trim() !== version)
    throw new Error(`Per-app iOS runtime requires Zig ${version}; set CRAFT_ZIG to that executable`)
  const output = mkdtempSync(join(tmpdir(), 'craft-ios-runtime-'))
  try {
    const names = iosPermissions(config)
    const command = [zig, 'build', 'build-ios-all', `-Dios-permissions=${names.join(',') || 'none'}`, '-Djs-runtime=false', '-Doptimize=ReleaseFast', '--prefix', output]
    const child = Bun.spawn(command, { cwd: root, stdout: 'inherit', stderr: 'inherit' })
    if (await child.exited !== 0) throw new Error('Per-app iOS Zig runtime build failed; installed runtime was not replaced')
    const directory = join(output, 'lib')
    const profile = JSON.parse(readFileSync(join(directory, 'ios-permissions.json'), 'utf8'))
    if (profile.version !== 1 || profile.mask !== iosPermissionMask(config))
      throw new Error('Craft Zig source did not build the requested iOS permission profile')
    profile.sha256 = Object.fromEntries(archives.map(name => [name, digest(join(directory, name))]))
    writeFileSync(join(directory, 'ios-permissions.json'), `${JSON.stringify(profile, null, 2)}\n`)
    verifyRuntimeProfile(directory, config)
    return await use(directory)
  }
  finally {
    rmSync(output, { recursive: true, force: true })
  }
}
