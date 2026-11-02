import { expect, test } from 'bun:test'
import { nativeVulkanResult } from './vulkan-surface-result'

const complete = { status: 'passed', nativeActivities: 2, nativeSessions: 4, actualGpuFrames: 370, nativeInputEvents: 2, nativeCaptures: 5, fullDisplayedPixelsMatched: true, webViewUsed: false, disposed: true }

test('native Vulkan results require actual repeated sessions, frames and all independent display outcomes', () => {
  expect(nativeVulkanResult(complete)).toBe(complete)
  for (const key of Object.keys(complete)) {
    const missing = { ...complete } as Record<string, unknown>
    delete missing[key]
    expect(() => nativeVulkanResult(missing)).toThrow('did not complete')
  }
})

test('missing, malformed, fractional and non-finite native counts cannot qualify a display run', () => {
  for (const key of ['nativeSessions', 'actualGpuFrames']) {
    for (const value of [undefined, null, NaN, Infinity, -Infinity, '370', {}, [], 0, -1, 4.5, 370.5, Number.MAX_SAFE_INTEGER + 1]) {
      expect(() => nativeVulkanResult({ ...complete, [key]: value })).toThrow('did not complete')
    }
  }
  expect(() => nativeVulkanResult({ ...complete, nativeSessions: 3 })).toThrow('did not complete')
  expect(() => nativeVulkanResult({ ...complete, actualGpuFrames: 369 })).toThrow('did not complete')
  for (const value of [null, false, [], 'passed']) expect(() => nativeVulkanResult(value)).toThrow('did not complete')
})
