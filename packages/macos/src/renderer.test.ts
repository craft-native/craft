import { expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

test.skipIf(process.platform !== 'darwin')('renders component layouts through AppKit and the shared Zig ABI', async () => {
  const root = resolve(import.meta.dir, '../../..')
  const temp = mkdtempSync(join(tmpdir(), 'craft-macos-layout-'))
  async function run(args: string[]) {
    const child = Bun.spawn(args, { cwd: root, stdout: 'pipe', stderr: 'pipe' })
    const [code, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    expect({ code, error: code === 0 ? '' : err }).toEqual({ code: 0, error: '' })
    return out
  }
  try {
    const library = join(temp, 'liblayout.a')
    const zig = process.env.CRAFT_ZIG || 'zig'
    await run([zig, 'build-lib', 'packages/zig/src/native_layout.zig', '-O', 'ReleaseSafe', '-static', '-lc', `-femit-bin=${library}`])
    const executable = join(temp, 'checks')
    await run(['swiftc', '-swift-version', '5', '-framework', 'Cocoa', '-framework', 'AVKit', 'packages/macos/templates/CraftMacRenderer.swift', 'packages/macos/fixtures/LayoutChecks.swift', '-Xlinker', '-force_load', '-Xlinker', library, '-Xlinker', '-export_dynamic', '-o', executable])
    expect(await run([executable])).toContain('PASS native component sizing')
  }
  finally { rmSync(temp, { recursive: true, force: true }) }
}, 120_000)
