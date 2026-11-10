import { afterAll, afterEach, expect, test } from 'bun:test'
import { chmodSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { verifyNativeStartup } from './verify-native-startup'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

function executable(body: string): string {
  const root = createTempDir('craft-native-startup-test-')
  roots.push(root)
  const path = join(root, 'craft')
  writeFileSync(path, `#!/bin/sh\n${body}\n`)
  chmodSync(path, 0o755)
  return path
}

test('accepts a running native CLI with the requested version', () => {
  expect(() => verifyNativeStartup(executable("printf 'craft version 1.2.3\\nBuilt with Zig\\n'"), '1.2.3')).not.toThrow()
}, 30_000)

test('rejects a stale binary, startup failure, and missing executable', () => {
  expect(() => verifyNativeStartup(executable("printf 'craft version 1.2.2\\n'"), '1.2.3')).toThrow('reported')
  expect(() => verifyNativeStartup(executable('exit 7'), '1.2.3')).toThrow('failed to start')
  expect(() => verifyNativeStartup('/path/that/does/not/exist', '1.2.3')).toThrow()
}, 30_000)
