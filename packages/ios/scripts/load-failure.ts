import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Run the page-load failure classifier for real, not just read it (#252).
 *
 * `CraftLoadFailure` decides whether a failed load sends the app to its
 * bundled copy, and the bug it fixes is a single wrong answer: -999, a load a
 * newer one replaced, treated as the network being gone. `index.test.ts` can
 * only check its text. This lifts the enum out of the template, compiles it
 * with Foundation alone on this host, and asks it about real error codes.
 */
export function checkLoadFailureClassifier(
  workspace: string,
  run: (args: string[], cwd: string, label: string) => void,
): void {
  const template = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')
  const start = template.indexOf('enum CraftLoadFailure {')
  if (start === -1)
    throw new Error('CraftApp.swift no longer declares enum CraftLoadFailure')
  let depth = 0
  let end = start
  for (let i = start; i < template.length; i++) {
    if (template[i] === '{') depth++
    else if (template[i] === '}' && --depth === 0) {
      end = i + 1
      break
    }
  }
  const classifier = template.slice(start, end)

  const dir = join(workspace, 'load-failure')
  const main = join(dir, 'main.swift')
  mkdirSync(dir, { recursive: true })
  writeFileSync(main, `import Foundation

${classifier}

func check(_ label: String, _ error: NSError, _ fallsBack: Bool) {
    let got = CraftLoadFailure.isUnreachable(error)
    guard got == fallsBack else {
        print("FAIL: \\(label): isUnreachable = \\(got), expected \\(fallsBack)")
        exit(1)
    }
    print("ok: \\(label) -> \\(fallsBack ? "falls back to the bundle" : "stays on the remote")")
}
func url(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }

// #252: a load a newer one replaced is not a failure.
check("NSURLErrorCancelled (-999)", url(NSURLErrorCancelled), false)
check("WebKitErrorDomain 102, frame load interrupted", NSError(domain: "WebKitErrorDomain", code: 102), false)

// The server was reached. Swapping in the bundle would hide the fault.
check("NSURLErrorSecureConnectionFailed", url(NSURLErrorSecureConnectionFailed), false)
check("NSURLErrorServerCertificateUntrusted", url(NSURLErrorServerCertificateUntrusted), false)
check("NSURLErrorBadServerResponse", url(NSURLErrorBadServerResponse), false)

// Out of reach: the only case the bundled copy stands in for.
check("NSURLErrorNotConnectedToInternet", url(NSURLErrorNotConnectedToInternet), true)
check("NSURLErrorCannotFindHost", url(NSURLErrorCannotFindHost), true)
check("NSURLErrorCannotConnectToHost", url(NSURLErrorCannotConnectToHost), true)
check("NSURLErrorTimedOut", url(NSURLErrorTimedOut), true)
check("NSURLErrorNetworkConnectionLost", url(NSURLErrorNetworkConnectionLost), true)
check("NSURLErrorDNSLookupFailed", url(NSURLErrorDNSLookupFailed), true)
`)
  run(['swiftc', '-o', join(dir, 'load-failure'), main], dir, 'Compiling the page-load failure classifier on its own')
  run([join(dir, 'load-failure')], dir, 'Asking it about real error codes')
}

// Runnable on its own, without the xcodebuild fixtures that make up the rest
// of `test:templates`: `bun packages/ios/scripts/load-failure.ts`.
if (import.meta.main) {
  const { mkdtempSync, rmSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const workspace = mkdtempSync(join(tmpdir(), 'craft-load-failure-'))
  try {
    checkLoadFailureClassifier(workspace, (args, cwd, label) => {
      console.log(`\n${label}`)
      const result = Bun.spawnSync(args, { cwd, stdout: 'inherit', stderr: 'inherit' })
      if (result.exitCode !== 0)
        throw new Error(`${label} exited with ${result.exitCode}`)
    })
  }
  finally {
    rmSync(workspace, { force: true, recursive: true })
  }
}
