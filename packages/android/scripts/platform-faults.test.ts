import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { classifyPlatformFaults } from './platform-faults'

const fixture = 'dev.craft.checkpointprobe'
// The line from Mobile E2E run 45162367404 (#593).
const messagingBroadcast = '11-23 11:12:46.843   540  4032 I am_anr  : [0,3615,com.google.android.apps.messaging,954973765,Broadcast of Intent { act=android.telephony.action.CARRIER_CONFIG_CHANGED flg=0x15000010 cmp=com.google.android.apps.messaging/.shared.simstatet.AsyncTelephonySimStateReceiver }]'

test('a stock app timing out on a background broadcast is recorded, not fatal', () => {
  const log = ['11-23 11:12:40.000   540   600 I ActivityManager: Start proc', messagingBroadcast].join('\n')
  expect(classifyPlatformFaults(log, fixture)).toEqual({ fatal: [], tolerated: [messagingBroadcast] })
})

test('the fixture\'s own ANR fails the run, whatever its reason', () => {
  const broadcast = `11-23 11:12:46.843 540 4032 I am_anr  : [0,4100,${fixture},954973765,Broadcast of Intent { act=dev.craft.TICK }]`
  const input = `11-23 11:12:46.843 540 4032 I am_anr  : [0,4100,${fixture}:worker,954973765,Input dispatching timed out]`
  expect(classifyPlatformFaults(broadcast, fixture).fatal).toEqual([broadcast])
  expect(classifyPlatformFaults(input, fixture).fatal).toEqual([input])
})

test('an input ANR in another app fails the run, since it puts a dialog on screen', () => {
  const line = '11-23 11:12:46.843 540 4032 I am_anr  : [0,3615,com.google.android.apps.messaging,954973765,Input dispatching timed out (Waiting to send key event)]'
  expect(classifyPlatformFaults(line, fixture)).toEqual({ fatal: [line], tolerated: [] })
})

test('a platform process ANR fails the run even on a broadcast', () => {
  for (const process of ['system_server', 'com.android.systemui', 'com.android.launcher3', 'com.android.phone']) {
    const line = `11-23 11:12:46.843 540 4032 I am_anr  : [0,1000,${process},954973765,Broadcast of Intent { act=android.intent.action.TIME_TICK }]`
    expect(classifyPlatformFaults(line, fixture).fatal).toEqual([line])
  }
})

test('crashes and fatal signals from any process still fail the run', () => {
  const lines = [
    '11-23 11:12:46.843 540 4032 I am_crash: [3615,0,com.google.android.apps.messaging,954973765,java.lang.IllegalStateException,boom,Foo.java,1]',
    '11-23 11:12:46.843 3615 3615 E AndroidRuntime: FATAL EXCEPTION: main',
    '11-23 11:12:46.843 3615 3615 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR)',
  ]
  expect(classifyPlatformFaults([messagingBroadcast, ...lines].join('\n'), fixture)).toEqual({ fatal: lines, tolerated: [messagingBroadcast] })
})

test('an ANR line the parser can\'t attribute stays fatal', () => {
  const line = '11-23 11:12:46.843 540 4032 I am_anr  : something new'
  expect(classifyPlatformFaults(line, fixture).fatal).toEqual([line])
})

test('the checkpoint runner judges its final logs with the classifier', () => {
  const runner = readFileSync(join(import.meta.dir, 'test-checkpoint-interruption.ts'), 'utf8')
  expect(runner).toContain('classifyPlatformFaults(log, packageName)')
  expect(runner).not.toMatch(/am_\(anr\|crash\)/)
})
