import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import { createAndroidEmulator } from '../packages/android/src/emulator'
import { managedJavaHome } from './managed-java-home'
import { softwareProvisioningCpus } from './software-provisioning-profile'

if (process.platform !== 'linux' || process.arch !== 'x64')
  throw new Error('The emulator verification requires a Linux x86_64 host')
const args = process.argv.slice(2)
if (args.length > 1 || (args.length === 1 && args[0] !== '--cold-provisioning-diagnostic'))
  throw new Error('Only --cold-provisioning-diagnostic is supported')
const diagnostic = args.length === 1
// Release acceptance uses the supported KVM backend and the public helper's
// ten-minute hardware budget. Unsupported TCG measurements stay diagnostic.
const acceleration = diagnostic ? 'software' : 'hardware'
const bootTimeoutMs = diagnostic ? 1_200_000 : 600_000
// Keep the same unmodified stock image and explicit 4 GB guest for acceptance
// and diagnostics. Their backend-specific boot budgets are set above.
const memoryMb = 4096
// Diagnostic CPU overrides never change the acceptance profile. Receipts
// retain the host model, actual guest resources and the selected backend.
const virtualCpus = softwareProvisioningCpus(diagnostic, process.env.CRAFT_ANDROID_DIAGNOSTIC_VIRTUAL_CPUS)
const expectedFingerprint = diagnostic ? process.env.CRAFT_ANDROID_DIAGNOSTIC_FINGERPRINT : undefined
if (diagnostic && !expectedFingerprint)
  throw new Error('The cold-provisioning diagnostic requires the failed stock image fingerprint')

const managed = realpathSync(resolve('pantry'))
function tool(name: string): string {
  const file = realpathSync(join(managed, '.bin', name))
  if (!file.startsWith(managed + sep)) throw new Error(`${name} must belong to the Pantry toolchain`)
  return file
}

const sdkmanager = tool('sdkmanager')
const avdmanager = tool('avdmanager')
const javaHome = managedJavaHome(managed)
const artifacts = resolve(diagnostic ? 'artifacts/android-software-cold-provisioning' : 'artifacts/android-sdk-emulator')
const owned = mkdtempSync(join(tmpdir(), 'craft-emulator-source-'))
mkdirSync(artifacts, { recursive: true })
let session: Awaited<ReturnType<typeof createAndroidEmulator>> | undefined
const proof: Record<string, unknown> = {
  purpose: diagnostic ? 'software-cold-provisioning-diagnostic-not-release-acceptance' : 'android-sdk-emulator-acceptance',
  platform: process.platform, architecture: process.arch, acceleration, sdkmanager, avdmanager, javaHome,
  provisioningProfile: diagnostic ? 'stock-play-software-cold' : 'stock-play-hardware-cold', bootTimeoutMs, memoryMb, virtualCpus,
  expectedFingerprint, runnerImage: process.env.ImageOS, runnerImageVersion: process.env.ImageVersion,
}

try {
  session = await createAndroidEmulator({
    sdkRoot: join(owned, 'sdk'), sdkmanager, avdmanager,
    image: 'system-images;android-35;google_apis_playstore;x86_64',
    acceleration, artifactsDirectory: artifacts,
    bootTimeoutMs, memoryMb, virtualCpus,
    temporaryDirectory: owned, acceptLicenses: true,
    env: { JAVA_HOME: javaHome },
  })
  async function adb(args: string[]): Promise<string> {
    const startedAt = new Date().toISOString()
    const child = Bun.spawn([session!.adb, '-s', session!.serial, ...args], {
      env: session!.env, stdout: 'pipe', stderr: 'pipe', signal: AbortSignal.timeout(30_000),
    })
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    const commands = (proof.adbCommands ??= []) as unknown[]
    commands.push({ args, code, stdout, stderr, startedAt, finishedAt: new Date().toISOString() })
    if (code !== 0) throw new Error(`ADB verification failed (exit ${code}): ${args.join(' ')}: stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)}`)
    return stdout.trim()
  }
  const api = await adb(['shell', 'getprop', 'ro.build.version.sdk'])
  const abi = await adb(['shell', 'getprop', 'ro.product.cpu.abi'])
  const playStore = await adb(['shell', 'pm', 'path', 'com.android.vending'])
  const fingerprint = await adb(['shell', 'getprop', 'ro.build.fingerprint'])
  const cpuPresent = await adb(['shell', 'cat', '/sys/devices/system/cpu/present'])
  const cpuRange = /^0(?:-(\d+))?$/.exec(cpuPresent)
  const guestVirtualCpus = cpuRange ? Number(cpuRange[1] ?? '0') + 1 : 0
  const meminfo = await adb(['shell', 'cat', '/proc/meminfo'])
  const guestMemTotalKb = Number(/^MemTotal:\s+(\d+)\s+kB$/m.exec(meminfo)?.[1])
  if (api !== '35' || abi !== 'x86_64' || !/^package:\/\S+/.test(playStore) || !fingerprint)
    throw new Error('The owned emulator must run the requested stock Play image')
  if (!Number.isSafeInteger(guestMemTotalKb) || guestMemTotalKb <= 0)
    throw new Error('The owned emulator must report its actual guest memory')
  if (guestVirtualCpus !== virtualCpus)
    throw new Error('The owned emulator must report the requested guest CPU count')
  if (diagnostic && fingerprint !== expectedFingerprint)
    throw new Error('The stock Play image changed; this diagnostic cannot explain the retained cold-boot failures')
  Object.assign(proof, { serial: session.serial, api, abi, playStore, fingerprint, guestMemTotalKb, guestVirtualCpus, cpuPresent, verifiedAt: new Date().toISOString() })
}
finally {
  try {
    await session?.dispose()
    const identityPath = join(artifacts, 'android-emulator.json')
    if (existsSync(identityPath)) {
      const identity = JSON.parse(readFileSync(identityPath, 'utf8'))
      if (existsSync(identity.avdDirectory)) throw new Error('The disposable AVD was not removed')
      let alive = false
      try { process.kill(identity.emulatorPid, 0); alive = true }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error }
      if (alive) throw new Error('The owned emulator process was not reaped')
    }
    proof.disposed = true
  }
  finally {
    rmSync(owned, { recursive: true, force: true })
    await Bun.write(join(artifacts, 'verification.json'), JSON.stringify(proof, null, 2) + '\n')
  }
}
