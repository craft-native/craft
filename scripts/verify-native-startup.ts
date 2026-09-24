import { resolve } from 'node:path'

export function verifyNativeStartup(binary: string, version: string): void {
  const result = Bun.spawnSync([resolve(binary), '--version'], {
    stdout: 'pipe', stderr: 'pipe', timeout: 30_000,
  })
  if (result.exitCode !== 0)
    throw new Error(`Native CLI failed to start (${result.signalCode ?? result.exitCode}): ${result.stderr.toString()}`)
  const firstLine = result.stdout.toString().trim().split('\n')[0]
  if (firstLine !== `craft version ${version}`)
    throw new Error(`Native CLI reported ${JSON.stringify(firstLine)}, expected craft version ${version}`)
  console.log(`Verified native CLI startup: craft version ${version}`)
}

if (import.meta.main) {
  const [binary, version] = Bun.argv.slice(2)
  if (!binary || !version)
    throw new Error('Usage: bun scripts/verify-native-startup.ts <binary> <version>')
  verifyNativeStartup(binary, version)
}
