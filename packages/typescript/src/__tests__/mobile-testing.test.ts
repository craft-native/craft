import { afterEach, describe, expect, it } from 'bun:test'
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createMobileTestDevice } from '../mobile-testing'

const directories: string[] = []
afterEach(async () => {
  for (const directory of directories.splice(0)) await rm(directory, { recursive: true, force: true })
})

async function device(installed = true, refuseUpdate = false) {
  const root = await mkdtemp(join(tmpdir(), 'craft-mobile-device-'))
  directories.push(root)
  const state = join(root, 'state.json')
  const log = join(root, 'commands.jsonl')
  await writeFile(state, JSON.stringify({ installed, refuseUpdate, build: '100', boot: 'first', connecting: false }))
  const adb = join(root, 'adb')
  await writeFile(adb, `#!/usr/bin/env bun
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs'
const path = ${JSON.stringify(state)}
const args = process.argv.slice(2)
appendFileSync(${JSON.stringify(log)}, JSON.stringify(args)+'\\n')
const state = JSON.parse(readFileSync(path,'utf8'))
const command = args.slice(2).join(' ')
if (command.startsWith('shell dumpsys')) console.log(state.installed ? 'versionCode='+state.build : '')
if (command === 'shell cat /proc/sys/kernel/random/boot_id') {
  if (state.connecting) { state.connecting=false; writeFileSync(path,JSON.stringify(state)); process.exit(1) }
  console.log(state.boot)
}
if (command === 'reboot') { state.boot='second'; state.connecting=true }
if (command.startsWith('shell getprop')) console.log('1')
if (args[2]==='install') {
  if (state.refuseUpdate) { console.error('INSTALL_FAILED_UPDATE_INCOMPATIBLE'); process.exit(1) }
  if (args[3]!=='-r') process.exit(2)
  state.build='101'
}
writeFileSync(path,JSON.stringify(state))
`)
  await chmod(adb, 0o755)
  const artifact = join(root, 'update.apk')
  await writeFile(artifact, 'test artifact')
  return {
    control: createMobileTestDevice({ platform: 'android', device: 'emulator-5582', appId: 'org.example.workout', adb }), artifact,
    commands: async () => (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line) as string[]),
  }
}

describe('installed mobile app test controls', () => {
  it('requires an explicit simulator or emulator, never a default connected device', () => {
    expect(() => createMobileTestDevice({ platform: 'ios', device: 'booted', appId: 'org.example.workout' })).toThrow('UUID')
    expect(() => createMobileTestDevice({ platform: 'android', device: '', appId: 'org.example.workout' })).toThrow('serial')
    expect(() => createMobileTestDevice({ platform: 'android', device: 'real-phone', appId: 'org.example.workout' })).toThrow('serial')
  }, 30_000)

  it('waits through an ADB disconnect for a new boot, then updates the existing installation in place', async () => {
    const test = await device()
    await test.control.restart()
    expect(await test.control.installUpdate(test.artifact)).toEqual({ previousBuild: '100', build: '101' })
    const commands = await test.commands()
    expect(commands.every(args => args[0] === '-s' && args[1] === 'emulator-5582')).toBe(true)
    expect(commands.some(args => args[2] === 'reboot')).toBe(true)
    expect(commands.find(args => args[2] === 'install')?.slice(2)).toEqual(['install', '-r', test.artifact])
    expect(commands.some(args => args.includes('uninstall') || args.includes('clear'))).toBe(false)
  })

  it('refuses to count a fresh install as update recovery', async () => {
    const test = await device(false)
    await expect(test.control.installUpdate(test.artifact)).rejects.toThrow('not installed')
    expect((await test.commands()).some(args => args[2] === 'install')).toBe(false)
  })

  it('surfaces a rejected update without uninstalling or clearing the previous app', async () => {
    const test = await device(true, true)
    await expect(test.control.installUpdate(test.artifact)).rejects.toThrow('INSTALL_FAILED_UPDATE_INCOMPATIBLE')
    expect(await test.control.installedBuild()).toBe('100')
    expect((await test.commands()).some(args => args.includes('uninstall') || args.includes('clear'))).toBe(false)
  })
})
