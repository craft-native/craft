// #451: install Android SDK packages with sdkmanager, retrying once when a
// download arrives unreadable (dl.google.com now and then serves an archive
// short, often to several runners at once). Any other failure fails at once.
// A retry is never silent: it prints a ::warning naming #451 and writes what
// the first attempt said to the step summary.
//
// Mobile E2E runs this before reactivecircus/android-emulator-runner, whose
// own sdkmanager calls then find the packages installed and download nothing.
//
// Usage: bun packages/android/scripts/sdk-install.ts <package>...
import { appendFileSync } from 'node:fs'
import { truncatedSdkDownload } from '../src/emulator'

export interface SdkInstallAttempt {
  code: number
  output: string
}

export type SdkInstallRunner = (packages: string[]) => Promise<SdkInstallAttempt>

/** sdkmanager on PATH, licenses accepted, bounded at 15 minutes. */
export const sdkmanagerRunner: SdkInstallRunner = async (packages) => {
  const child = Bun.spawn(['sdkmanager', '--install', ...packages, '--channel=0'], {
    stdin: new TextEncoder().encode('y\n'.repeat(100)), stdout: 'pipe', stderr: 'pipe', timeout: 900_000,
  })
  const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()])
  const code = await child.exited
  return { code: code ?? 1, output: `${stdout}\n${stderr}` }
}

/** Installs `packages`, retrying once only after an unreadable download. Returns how many attempts it took. */
export async function installSdkPackages(packages: string[], runner: SdkInstallRunner = sdkmanagerRunner, log: (line: string) => void = console.log): Promise<number> {
  if (!packages.length) throw new Error('Name at least one Android SDK package')
  const first = await runner(packages)
  if (first.code === 0) return 1
  const reason = truncatedSdkDownload(first.output)
  if (!reason) throw new Error(`sdkmanager failed with exit ${first.code} installing ${packages.join(' ')}:\n${first.output.trim().slice(-4000)}`)
  log(`::warning title=Android SDK download arrived truncated (#451)::sdkmanager could not read what it downloaded for ${packages.join(' ')} (${reason}); retrying once`)
  if (process.env.GITHUB_STEP_SUMMARY)
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `### Android SDK download retried (#451)\n\n\`${packages.join(' ')}\`: ${reason}\n\n<details><summary>First attempt's output</summary>\n\n\`\`\`\n${first.output.trim().slice(-4000)}\n\`\`\`\n</details>\n`)
  const second = await runner(packages)
  if (second.code !== 0) throw new Error(`sdkmanager failed again with exit ${second.code} installing ${packages.join(' ')}:\n${second.output.trim().slice(-4000)}`)
  return 2
}

if (import.meta.main) {
  const attempts = await installSdkPackages(process.argv.slice(2))
  console.log(`Installed ${process.argv.slice(2).join(' ')}${attempts > 1 ? ' on the second attempt' : ''}`)
}
