import { expect, test } from 'bun:test'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

/**
 * npm refuses a package whose version manifest contains a NUL character, and
 * the manifest carries the README's text. packages/create-craft/README.md had
 * its file-tree diagram truncated to control bytes (every box-drawing
 * character reduced to its low byte: U+2500 became \u0000), so create-craft
 * failed to publish from v0.0.93 on - "Package version manifest contains an
 * unsupported NUL character" - and stopped the packages after it too.
 */
const root = resolve(import.meta.dir, '..')
const control = /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/

test('no publishable package ships control characters in its manifest or README', () => {
  for (const path of new Bun.Glob('packages/*/package.json').scanSync({ cwd: root })) {
    const manifest = readFileSync(join(root, path), 'utf8')
    if (JSON.parse(manifest).private)
      continue
    expect(control.test(manifest), `${path} contains a control character`).toBe(false)
    const readme = join(root, dirname(path), 'README.md')
    if (existsSync(readme))
      expect(readFileSync(readme, 'utf8').match(control)?.index ?? -1, `${dirname(path)}/README.md contains a control character`).toBe(-1)
  }
})
