#!/usr/bin/env bun

/**
 * Mobile end-to-end: generate an app, run it on a simulator or emulator, and
 * assert that a call made from JavaScript reached native code and came back.
 *
 * What this replaces ran nothing. Every step in the old mobile-e2e workflow
 * that would have tested something was guarded by
 * `if: hashFiles('packages/ios/TestApp/TestApp.xcodeproj') != ''`, and that
 * project has never existed in the tree, so each one skipped and the job went
 * green. The Android half looked for `packages/android/gradlew`, which the
 * generator does not write either, and echoed "skipping project-level tests".
 * Months of green with no coverage behind it.
 *
 * So the rules here are the opposite ones. Nothing skips: a missing toolchain,
 * an absent device, an app that never printed anything are all failures with a
 * named cause. The page announces which cases it is going to run before it
 * runs them, so a suite that dies halfway cannot be read as a shorter suite
 * that passed. And every leg writes its console log, its build log and a
 * screenshot under artifacts/mobile-e2e/, uploaded with
 * `if-no-files-found: error` so a run that produced no evidence is red rather
 * than quietly empty.
 *
 *   bun scripts/mobile-e2e.ts --platform ios --ios-runtime packages/zig/zig-out/lib
 *   bun scripts/mobile-e2e.ts --platform android
 */

import type { LegOutcome, RunnerOptions } from './mobile-e2e/types'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { runAndroid } from './mobile-e2e/android'
import { runIos } from './mobile-e2e/ios'

const root = resolve(import.meta.dir, '..')

function flag(name: string): string | undefined {
  const prefixed = `--${name}`
  const index = process.argv.indexOf(prefixed)
  if (index !== -1 && index + 1 < process.argv.length) return process.argv[index + 1]

  const inline = process.argv.find(argument => argument.startsWith(`${prefixed}=`))
  return inline?.slice(prefixed.length + 1)
}

const platform = flag('platform')
if (platform !== 'ios' && platform !== 'android')
  throw new Error('pass --platform ios or --platform android')

const evidenceLabel = process.env.CRAFT_EVIDENCE_LABEL || `${platform}-${process.arch}`
const evidenceDir = join(root, 'artifacts', 'mobile-e2e', evidenceLabel)
const workDir = join(evidenceDir, 'work')

// A single run id, reused as the clipboard nonce suffix. Deliberately not a
// timestamp alone: two legs run minutes apart and each needs its own value, so
// the leg name is mixed in downstream.
const runId = process.env.GITHUB_RUN_ID || String(process.pid)

const options: RunnerOptions = {
  root,
  evidenceDir,
  workDir,
  timeoutMs: Number(flag('timeout') ?? 180_000),
  runId,
  iosRuntimeDir: flag('ios-runtime')
    ? resolve(root, flag('ios-runtime')!)
    : (process.env.CRAFT_IOS_RUNTIME ? resolve(root, process.env.CRAFT_IOS_RUNTIME) : null),
  androidRuntimeDir: flag('android-runtime')
    ? resolve(root, flag('android-runtime')!)
    : (process.env.CRAFT_ANDROID_RUNTIME ? resolve(root, process.env.CRAFT_ANDROID_RUNTIME) : null),
}

async function main(): Promise<void> {
  rmSync(evidenceDir, { force: true, recursive: true })
  mkdirSync(workDir, { recursive: true })

  let outcomes: LegOutcome[] = []
  let error: string | undefined

  try {
    outcomes = platform === 'ios' ? await runIos(options) : await runAndroid(options)
  }
  catch (caught) {
    error = caught instanceof Error ? caught.stack || caught.message : String(caught)
  }

  // A run with no legs is the shape the old workflow had, and it must not read
  // as success. Named here rather than left to the caller, because "zero
  // failures" is true of an empty list.
  if (!error && outcomes.length === 0)
    error = 'no legs ran; the harness produced no result at all'

  const failedLegs = outcomes.filter(leg => leg.status === 'failed')
  if (!error && failedLegs.length)
    error = failedLegs.map(leg => `${leg.name}: ${leg.failures.join('; ')}`).join('\n')

  const report = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    revision: process.env.GITHUB_SHA || 'local',
    platform,
    label: evidenceLabel,
    runner: { os: process.platform, arch: process.arch, bun: Bun.version },
    status: error ? 'failed' : 'passed',
    legs: outcomes,
    error,
  }

  mkdirSync(evidenceDir, { recursive: true })
  writeFileSync(join(evidenceDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`)

  for (const leg of outcomes) {
    const cases = `${leg.passed.length}/${leg.planned.length} cases`
    const zig = leg.zigActions.length ? `zig served ${leg.zigActions.join(', ')}` : 'no zig'
    console.log(`${leg.status === 'passed' ? 'ok  ' : 'FAIL'} ${leg.name} — ${cases}, ${zig}`)
    for (const failure of leg.failures) console.log(`       ${failure}`)
  }

  if (error) {
    // The annotation is what makes the reason visible on the run summary
    // rather than only inside a step log the reader has to expand.
    console.log(`::error::mobile e2e (${evidenceLabel}) failed: ${error.split('\n')[0]}`)
    throw new Error(error)
  }

  console.log(`\nmobile e2e passed on ${platform}; evidence in artifacts/mobile-e2e/${evidenceLabel}`)
}

await main()
