import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Run the web content crash budget for real, not just read it.
 *
 * `CraftRecoveryBudget` decides whether a dead web content process is
 * reloaded or the offline page shows instead. Its two failure modes are both
 * silent on a device: a budget that never runs out reloads a crashing page
 * forever, and one that never comes back leaves an app that crashed three
 * times last week on its offline page for good. This lifts the struct out of
 * the template, compiles it with Foundation alone, and walks it through both.
 */
export function checkRecoveryBudget(
  workspace: string,
  run: (args: string[], cwd: string, label: string) => void,
): void {
  const template = readFileSync(join(import.meta.dir, '../templates/CraftApp.swift'), 'utf8')
  const start = template.indexOf('struct CraftRecoveryBudget {')
  if (start === -1)
    throw new Error('CraftApp.swift no longer declares struct CraftRecoveryBudget')
  let depth = 0
  let end = start
  for (let i = start; i < template.length; i++) {
    if (template[i] === '{') depth++
    else if (template[i] === '}' && --depth === 0) {
      end = i + 1
      break
    }
  }
  const budget = template.slice(start, end)

  const dir = join(workspace, 'recovery-budget')
  const main = join(dir, 'main.swift')
  mkdirSync(dir, { recursive: true })
  writeFileSync(main, `import Foundation

${budget}

func check(_ label: String, _ got: CraftRecoveryBudget.Action, _ expected: CraftRecoveryBudget.Action) {
    guard got == expected else {
        print("FAIL: \\(label): \\(got), expected \\(expected)")
        exit(1)
    }
    print("ok: \\(label) -> \\(expected)")
}

// A crash loop: three reloads, then the offline page.
var loop = CraftRecoveryBudget()
check("first crash", loop.onCrash(at: 0), .reload)
check("second crash 5s later", loop.onCrash(at: 5), .reload)
check("third crash 10s later", loop.onCrash(at: 10), .reload)
check("fourth crash 15s later", loop.onCrash(at: 15), .giveUp)
check("and every crash in the same burst after it", loop.onCrash(at: 20), .giveUp)

// Bad luck: a crash a day gets its budget back every time.
var daily = CraftRecoveryBudget()
for day in 0..<7 {
    check("a crash on day \\(day + 1)", daily.onCrash(at: TimeInterval(day) * 86_400), .reload)
}

// A minute after the last crash is a new burst; a moment short is not.
var edge = CraftRecoveryBudget()
_ = edge.onCrash(at: 0); _ = edge.onCrash(at: 1); _ = edge.onCrash(at: 2)
check("59.9s after the third", edge.onCrash(at: 61.9), .giveUp)
check("60s after the last", edge.onCrash(at: 121.9), .reload)

// Crashes every 40 seconds never let the window close.
var slow = CraftRecoveryBudget()
_ = slow.onCrash(at: 0); _ = slow.onCrash(at: 40); _ = slow.onCrash(at: 80)
check("a fourth, 40s after the third", slow.onCrash(at: 120), .giveUp)

// Retry starts afresh.
loop.reset()
check("after Retry", loop.onCrash(at: 21), .reload)
`)
  run(['swiftc', '-o', join(dir, 'recovery-budget'), main], dir, 'Compiling the web content crash budget on its own')
  run([join(dir, 'recovery-budget')], dir, 'Walking it through a crash loop and through bad luck')
}

// Runnable on its own: `bun packages/ios/scripts/recovery-budget.ts`.
if (import.meta.main) {
  const { mkdtempSync, rmSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const workspace = mkdtempSync(join(tmpdir(), 'craft-recovery-budget-'))
  try {
    checkRecoveryBudget(workspace, (args, cwd, label) => {
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
