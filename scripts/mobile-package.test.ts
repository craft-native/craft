import { expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const root = resolve(import.meta.dir, '..')

for (const platform of ['android', 'ios']) {
  test(`${platform} tarball exposes usable standalone declarations`, () => {
    const temp = mkdtempSync(join(tmpdir(), `craft-${platform}-package-`))
    const packageDir = join(root, 'packages', platform)
    const run = (args: string[], cwd = temp): void => {
      const result = Bun.spawnSync(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
      expect(`${result.stdout}\n${result.stderr}`).not.toContain('error TS')
      expect(result.exitCode).toBe(0)
    }

    try {
      run([process.execPath, 'run', 'build'], packageDir)
      run([process.execPath, 'pm', 'pack', '--filename', join(temp, 'package.tgz')], packageDir)
      const installed = join(temp, 'node_modules', '@craft-native', platform)
      mkdirSync(installed, { recursive: true })
      run(['tar', '-xzf', join(temp, 'package.tgz'), '--strip-components=1', '-C', installed])
      writeFileSync(join(temp, 'consumer.mts'), `
import { init, type InitOptions } from '@craft-native/${platform}'
const options: InitOptions = { name: 'Consumer', output: '/tmp/consumer', runtimeDir: null }
const result: Promise<void> = init(options)
// @ts-expect-error name must be a string, even outside the workspace
init({ name: 42, output: '/tmp/consumer' })
void result
`)
      run([
        process.execPath, join(root, 'packages/typescript/scripts/tsc.ts'),
        'consumer.mts', '--noEmit', '--strict', '--module', 'nodenext',
        '--moduleResolution', 'nodenext', '--target', 'esnext', '--ignoreConfig',
      ])
    }
    finally {
      rmSync(temp, { recursive: true, force: true })
    }
  }, 60_000)
}
