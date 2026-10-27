import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { iosPermissions, type IOSPermission } from '../src/runtime-profile'
import type { CraftConfig } from '../src/index'
import { renderUsageDescriptions } from '../src/index'

const permissionAPIs: Record<IOSPermission, string[]> = {
  speech: ['SFSpeechRecognizer'],
  microphone: ['AVAudioRecorder'],
  camera: ['AVCaptureDevice'],
  photos: ['PHPhotoLibrary'],
  location: ['CLLocationManager'],
  contacts: ['CNContactStore'],
  calendar: ['EKEventStore'],
  bluetooth: ['CBCentralManager'],
  motion: ['CMMotionManager'],
  biometric: ['LAContext'],
  music: ['MPMediaLibrary', 'MPMusicPlayerController'],
  health: ['HKHealthStore'],
  nfc: ['NFCNDEFReaderSession'],
}

/** Inspect the actual executable code, including Xcode's Debug dylib layout. */
export function checkPermissionBinary(bundle: string, name: string, config: Partial<CraftConfig>): void {
  const enabled = new Set(iosPermissions(config))
  const plist = Bun.spawnSync(['plutil', '-convert', 'json', '-o', '-', join(bundle, 'Info.plist')], { stdout: 'pipe', stderr: 'pipe' })
  if (plist.exitCode !== 0) throw new Error(`Unable to inspect ${bundle}/Info.plist`)
  const actualKeys = Object.keys(JSON.parse(plist.stdout.toString())).filter(key => key.endsWith('UsageDescription')).sort()
  const expectedKeys = [...renderUsageDescriptions({ appName: name, bundleId: 'dev.craft.probe', ...config }).matchAll(/<key>([^<]+)<\/key>/g)].map(match => match[1]!).sort()
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys))
    throw new Error(`${name}: compiled purpose strings differ from its permission configuration`)
  const binary = existsSync(join(bundle, `${name}.debug.dylib`)) ? join(bundle, `${name}.debug.dylib`) : join(bundle, name)
  const symbols = Bun.spawnSync(['xcrun', 'nm', '-u', binary], { stdout: 'pipe', stderr: 'pipe' })
  if (symbols.exitCode !== 0) throw new Error(`Unable to inspect ${binary}: ${symbols.stderr.toString()}`)
  const strings = Bun.spawnSync(['strings', binary], { stdout: 'pipe', stderr: 'pipe' })
  if (strings.exitCode !== 0) throw new Error(`Unable to inspect dynamic API names in ${binary}`)
  const dynamicNames = new Set(strings.stdout.toString().split('\n'))
  if (!enabled.has('microphone') && dynamicNames.has('requestRecordPermission:'))
    throw new Error(`${name}: microphone permission request survived a disabled build`)
  for (const [permission, apis] of Object.entries(permissionAPIs)) {
    for (const api of apis) {
      const linked = symbols.stdout.toString().includes(`_OBJC_CLASS_$_${api}`)
      const expected = enabled.has(permission as IOSPermission)
      if (linked !== expected || (!expected && dynamicNames.has(api)))
        throw new Error(`${name}: ${api} linked=${linked}, dynamic=${dynamicNames.has(api)}, expected ${expected}`)
    }
  }
  console.log(`ok: ${binary} matches permission profile [${[...enabled].join(', ')}]`)
}
