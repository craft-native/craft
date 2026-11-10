import { afterEach, expect, it } from 'bun:test'
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { requireAndroidEmulatorRoot } from '../android-adb'

const roots: string[] = []
afterEach(async () => {
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true })
})

async function fixture(rootReply: 'closed' | 'denied' | 'success', uid = '0', reconnect = true) {
  const root = await mkdtemp(join(tmpdir(), 'craft-adb-root-'))
  roots.push(root)
  const adb = join(root, 'adb')
  const log = join(root, 'commands.jsonl')
  await writeFile(adb, `#!/usr/bin/env bun
import { appendFileSync } from 'node:fs'
const args = process.argv.slice(2)
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args)+'\\n')
if (args[2] === 'root') {
  if (${JSON.stringify(rootReply)} === 'closed') { console.error('adb: unable to connect for root: closed'); process.exit(1) }
  if (${JSON.stringify(rootReply)} === 'denied') { console.error('adbd cannot run as root in production builds'); process.exit(1) }
  console.log('restarting adbd as root')
}
if (args[2] === 'wait-for-device' && !${reconnect}) { console.error('transport unavailable'); process.exit(1) }
if (args[2] === 'shell') console.log(${JSON.stringify(uid)})
`)
  await chmod(adb, 0o755)
  return { adb, commands: async () => (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line)) }
}

it('reconnects after the root daemon closes the transport, then proves root without repeating the request', async () => {
  const test = await fixture('closed')
  await requireAndroidEmulatorRoot(test.adb, 'emulator-5582')
  expect(await test.commands()).toEqual([
    ['-s', 'emulator-5582', 'root'],
    ['-s', 'emulator-5582', 'wait-for-device'],
    ['-s', 'emulator-5582', 'shell', 'id', '-u'],
  ])
}, 30_000)

it('requires root after an acknowledged daemon restart too', async () => {
  const test = await fixture('success')
  await requireAndroidEmulatorRoot(test.adb, 'emulator-5582')
  expect((await test.commands()).at(-1)).toEqual(['-s', 'emulator-5582', 'shell', 'id', '-u'])
}, 30_000)

it('rejects production images without attempting to reconnect or fault their storage', async () => {
  const test = await fixture('denied')
  await expect(requireAndroidEmulatorRoot(test.adb, 'emulator-5582')).rejects.toThrow('production builds')
  expect((await test.commands()).length).toBe(1)
}, 30_000)

it('rejects a reconnected daemon that still runs as the shell user', async () => {
  const test = await fixture('closed', '2000')
  await expect(requireAndroidEmulatorRoot(test.adb, 'emulator-5582')).rejects.toThrow('rootable')
}, 30_000)

it('preserves reconnect failures and refuses physical devices before executing ADB', async () => {
  const test = await fixture('closed', '0', false)
  await expect(requireAndroidEmulatorRoot(test.adb, 'emulator-5582')).rejects.toThrow('transport unavailable')
  await expect(requireAndroidEmulatorRoot(test.adb, 'phone')).rejects.toThrow('emulator serial')
  expect((await test.commands()).length).toBe(2)
}, 30_000)
