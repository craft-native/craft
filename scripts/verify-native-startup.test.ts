import { afterEach, expect, test } from 'bun:test'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { verifyNativeStartup } from './verify-native-startup'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

function executable(body: string): string {
  const root = mkdtempSync(join(tmpdir(), 'craft-native-startup-test-'))
  roots.push(root)
  const path = join(root, 'craft')
  writeFileSync(path, `#!/bin/sh\n${body}\n`)
  chmodSync(path, 0o755)
  return path
}

test('accepts a running native CLI with the requested version', () => {
  expect(() => verifyNativeStartup(executable("printf 'craft version 1.2.3\\nBuilt with Zig\\n'"), '1.2.3')).not.toThrow()
})

test('rejects a stale binary, startup failure, and missing executable', () => {
  expect(() => verifyNativeStartup(executable("printf 'craft version 1.2.2\\n'"), '1.2.3')).toThrow('reported')
  expect(() => verifyNativeStartup(executable('exit 7'), '1.2.3')).toThrow('failed to start')
  expect(() => verifyNativeStartup('/path/that/does/not/exist', '1.2.3')).toThrow()
})
