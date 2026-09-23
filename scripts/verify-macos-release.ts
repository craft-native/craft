import { resolve } from 'node:path'

function command(args: string[]): string {
  const result = Bun.spawnSync(args, { stdout: 'pipe', stderr: 'pipe', timeout: 30_000 })
  if (result.exitCode !== 0)
    throw new Error(`${args.join(' ')} failed (${result.signalCode ?? result.exitCode})\n${result.stdout}\n${result.stderr}`)
  return `${result.stdout}\n${result.stderr}`
}

export function verifyMacosRelease(binary: string, version: string, execute = true): void {
  if (process.platform !== 'darwin')
    throw new Error('macOS release verification requires macOS trust services')
  command(['codesign', '--verify', '--deep', '--strict', '--verbose=4', binary])
  const metadata = command(['codesign', '--display', '--verbose=4', binary])
  if (!metadata.includes('Signature=adhoc')) {
    if (!metadata.includes('Authority=Developer ID Application:') || !metadata.includes('Timestamp='))
      throw new Error('Developer ID release must have a certificate chain and secure timestamp')
    if (!/flags=.*\bruntime\b/.test(metadata))
      throw new Error('Developer ID release must enable hardened runtime')
  }
  const entitlements = command(['codesign', '--display', '--entitlements', '-', '--xml', binary])
  for (const key of ['com.apple.security.app-sandbox', 'com.apple.security.cs.disable-library-validation', 'com.apple.security.cs.allow-unsigned-executable-memory']) {
    const escaped = key.replaceAll('.', '\\.')
    if (new RegExp(`<key>${escaped}</key>\\s*<true\\s*/>`).test(entitlements))
      throw new Error(`Standalone release must not enable ${key}`)
  }
  if (execute) {
    const output = command([binary, '--version'])
    if (output.trim().split('\n')[0] !== `craft version ${version}`)
      throw new Error(`Expected craft version ${version}, received: ${output}`)
  }
  console.log(`Verified ${binary}${execute ? ` launches as ${version}` : ' signature and entitlements'}`)
}

if (import.meta.main) {
  const [binary, version, option] = Bun.argv.slice(2)
  if (!binary || !version || (option !== undefined && option !== '--no-execute'))
    throw new Error('Usage: bun scripts/verify-macos-release.ts <binary> <version> [--no-execute]')
  verifyMacosRelease(resolve(binary), version, option !== '--no-execute')
}
