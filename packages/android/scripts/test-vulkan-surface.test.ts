import { expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { NativeFixtureCommandScope } from '../../ios/scripts/native-fixture-command'
import { pinnedZigVersion } from '../../../scripts/zig'
import { emulatorVersionCommand } from './vulkan-surface-probe'

const root = resolve(import.meta.dir, '../../..')
const runner = join(import.meta.dir, 'test-vulkan-surface.ts')

async function fixture(run: (directory: string, scope: NativeFixtureCommandScope) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), 'craft-vulkan-runner-test-'))
  const scope = new NativeFixtureCommandScope()
  try { await run(directory, scope) }
  finally {
    if (!scope.allDisposed) throw new Error(`Runner command group still owns ${directory}`)
    await rm(directory, { recursive: true, force: true })
  }
}

test('invalid Vulkan image selection creates no owned paths and requires no SDK or compiler', async () => {
  await fixture(async (directory, scope) => {
    const result = await scope.run(['/usr/bin/env', `TMPDIR=${directory}`, 'ANDROID_HOME=', 'ANDROID_SDK_ROOT=', 'ANDROID_NDK_HOME=', 'CRAFT_ZIG=', `PATH=${directory}`, process.execPath, runner, '--image', 'invalid', '--output', join(directory, 'output')], { cwd: root, timeoutMs: 10000 })
    expect(result.code).not.toBe(0)
    expect(result.groupDisposed).toBe(true)
    expect(result.stderr).toContain('Choose an Android35/36 SDK image matching the native host ABI')
    expect(await readdir(directory)).toEqual([])
  })
}, 15000)

test('workspace allocation failure retains an honest failure receipt without starting native work', async () => {
  await fixture(async (directory, scope) => {
    const bin = join(directory, 'bin'), output = join(directory, 'output'), blocked = join(directory, 'not-a-directory')
    await mkdir(bin)
    await writeFile(blocked, 'owned test file')
    for (const tool of ['zig', 'sdkmanager', 'avdmanager', 'gradle']) {
      const file = join(bin, tool)
      await writeFile(file, `#!${process.execPath}\nif (${JSON.stringify(tool)} === 'zig' && process.argv[2] === 'version') console.log(${JSON.stringify(pinnedZigVersion(root))}); else { await Bun.write(${JSON.stringify(join(directory, 'unexpected-native-work'))}, process.argv.join(' ')); process.exit(90); }\n`)
      await chmod(file, 0o755)
    }
    const result = await scope.run(['/usr/bin/env', `TMPDIR=${blocked}`, `ANDROID_HOME=${directory}`, `ANDROID_NDK_HOME=${directory}`, `CRAFT_ZIG=${join(bin, 'zig')}`, `PATH=${bin}`, process.execPath, runner, '--output', output], { cwd: root, timeoutMs: 10000 })
    expect(result.code).not.toBe(0)
    expect(result.groupDisposed).toBe(true)
    expect(result.stdout).toContain('"status":"failed"')
    expect(await Bun.file(join(directory, 'unexpected-native-work')).exists()).toBe(false)
    const runs = await readdir(output)
    expect(runs).toHaveLength(1)
    const receipt = JSON.parse(await readFile(join(output, runs[0]!, 'verification.json'), 'utf8'))
    expect(receipt.status).toBe('failed')
    expect(receipt.commandGroupsDisposed).toBe(true)
    expect(receipt.error).toContain('mkdtemp')
  })
}, 15000)

test('emulator identity reaches the headless frontend when GUI audio dependencies are absent', async () => {
  await fixture(async (directory, scope) => {
    const executable = join(directory, 'emulator'), gui = join(directory, 'gui.ts'), headless = join(directory, 'headless.ts'), selected = join(directory, 'selected.json')
    await writeFile(gui, `await Bun.write(${JSON.stringify(selected)}, JSON.stringify({ frontend: 'gui' })); console.error('qemu-system-x86_64: libpulse.so.0: cannot open shared object file'); process.exit(127);\n`)
    await writeFile(headless, `await Bun.write(${JSON.stringify(selected)}, JSON.stringify({ frontend: 'headless', audioEnabled: !process.argv.includes('-no-audio') })); if (!process.argv.includes('-version')) process.exit(90); console.log('Android emulator version 37.2.13.0 (isolated SDK fixture)');\n`)
    await writeFile(executable, `#!${process.execPath}\nconst frontend = process.argv.includes('-no-window') ? ${JSON.stringify(headless)} : ${JSON.stringify(gui)}; const child = Bun.spawnSync([process.execPath, frontend, ...process.argv.slice(2)], { stdout: 'inherit', stderr: 'inherit' }); process.exit(child.exitCode);\n`)
    await chmod(executable, 0o755)

    // The original public command reproduces the Linux loader failure.
    const original = await scope.run([executable, '-version'], { cwd: directory, timeoutMs: 10000 })
    expect(original.code).toBe(127)
    expect(original.stderr).toContain('libpulse.so.0')
    expect(original.groupDisposed).toBe(true)
    expect(JSON.parse(await readFile(selected, 'utf8')).frontend).toBe('gui')

    const identity = await scope.run(emulatorVersionCommand(executable), { cwd: directory, timeoutMs: 10000 })
    expect(identity.code).toBe(0)
    expect(identity.stdout).toContain('Android emulator version 37.2.13.0')
    expect(identity.groupDisposed).toBe(true)
    expect(JSON.parse(await readFile(selected, 'utf8'))).toEqual({ frontend: 'headless', audioEnabled: false })
  })
}, 15000)
