import { expect, test } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

for (const tool of ['create-craft', 'craft-sdk']) {
  test(`${tool} rejects an unknown template without preventing a corrected retry`, () => {
    const root = resolve(import.meta.dir, '..')
    const temp = mkdtempSync(join(tmpdir(), 'craft-scaffold-package-'))
    const packageDir = join(root, 'packages', tool === 'create-craft' ? 'create-craft' : 'typescript')
    const run = (args: string[], cwd: string) => Bun.spawnSync(args, { cwd, stdout: 'pipe', stderr: 'pipe' })
    try {
      if (tool === 'craft-sdk') expect(run([process.execPath, 'run', 'build'], packageDir).exitCode).toBe(0)
      const archive = join(temp, 'package.tgz')
      expect(run([process.execPath, 'pm', 'pack', '--filename', archive], packageDir).exitCode).toBe(0)
      const installed = join(temp, 'installed')
      mkdirSync(installed)
      expect(run(['tar', '-xzf', archive, '--strip-components=1', '-C', installed], temp).exitCode).toBe(0)
      // Only create-craft's external CLI parser comes from the workspace.
      mkdirSync(join(installed, 'node_modules/@stacksjs'), { recursive: true })
      symlinkSync(join(root, 'node_modules/@stacksjs/clapp'), join(installed, 'node_modules/@stacksjs/clapp'), 'dir')
      const cli = join(installed, tool === 'create-craft' ? 'bin/cli.ts' : 'dist/cli.js')
      const work = join(temp, 'consumer')
      mkdirSync(work)
      const args = tool === 'create-craft' ? ['demo', '--skip-install'] : ['init', 'demo']
      const invalid = run([process.execPath, cli, ...args, '--template', 'nope'], work)
      expect(invalid.exitCode).not.toBe(0)
      expect(`${invalid.stdout}\n${invalid.stderr}`).toContain('Unknown template "nope"')
      expect(`${invalid.stdout}\n${invalid.stderr}`).toContain('Available templates:')
      expect(invalid.stdout.toString()).not.toContain('Next steps:')
      expect(existsSync(join(work, 'demo'))).toBe(false)
      const valid = run([process.execPath, cli, ...args, '--template', tool === 'create-craft' ? 'minimal' : 'blank'], work)
      expect(valid.exitCode).toBe(0)
      expect(existsSync(join(work, 'demo/package.json'))).toBe(true)
    }
    finally {
      rmSync(temp, { recursive: true, force: true })
    }
  }, 60_000)
}
