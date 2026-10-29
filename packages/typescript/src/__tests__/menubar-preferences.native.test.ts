import assert from 'node:assert/strict'
import { test } from 'bun:test'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const nativeTest = process.platform === 'darwin' ? test : test.skip

nativeTest('public-only runtimes exclude the live menu bar preference SPI', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'craft-menubar-public-'))
  async function run(args: string[]) {
    const child = Bun.spawn(args, { stdout: 'pipe', stderr: 'pipe' })
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ])
    assert.equal(code, 0, err || out)
  }
  try {
    const main = join(dir, 'main.m')
    const executable = join(dir, 'public-menubar')
    await writeFile(main, `#include <stdbool.h>
#include <stddef.h>
extern bool craft_menubar_layout_available(void);
extern void *craft_menubar_copy_layout_positions(void);
extern void craft_menubar_request_layout_access(void (*selected)(void *));
int main(void) {
    craft_menubar_request_layout_access(NULL);
    return craft_menubar_layout_available() || craft_menubar_copy_layout_positions() != NULL;
}
`)
    await run(['clang', '-mmacosx-version-min=15.0', '-fobjc-arc', '-fblocks', '-DCRAFT_PUBLIC_APIS_ONLY=1',
      '-framework', 'Foundation', join(import.meta.dir, '../../../zig/src/menubar_preferences.m'), main, '-o', executable])
    await run([executable])
    const binary = await readFile(executable)
    assert(!binary.includes(Buffer.from('_CFPreferencesCopyValueWithContainer')), 'the private entry point must not ship in public-only binaries')
  }
  finally {
    await rm(dir, { recursive: true, force: true })
  }
}, 30000)
