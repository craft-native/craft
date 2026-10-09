/**
 * Hybrid apps: the page's side of native screens (snapshots, open, back).
 */

import { afterEach, describe, expect, it } from 'bun:test'
import mobile, { hybrid, isSnapshotName, snapshots } from '../api/mobile'

const previousWindow = (globalThis as any).window

afterEach(() => {
  ;(globalThis as any).window = previousWindow
})

function shell(extra: Record<string, unknown> = {}): unknown[] {
  const posts: unknown[] = []
  ;(globalThis as any).window = {
    webkit: { messageHandlers: { craftHybrid: { postMessage: (message: unknown) => posts.push(message) } } },
    ...extra,
  }
  return posts
}

describe('Mobile snapshots', () => {
  it('hands the shell JSON under a safe name', () => {
    const posts = shell()
    expect(snapshots.isAvailable()).toBe(true)
    expect(snapshots.set('today', { sessions: [1, 2], at: 3 })).toBe(true)
    expect(snapshots.set('hq.calendar-v2', null)).toBe(true)
    expect(snapshots.remove('today')).toBe(true)
    expect(snapshots.clear()).toBe(true)
    expect(posts).toEqual([
      { type: 'snapshotSet', name: 'today', json: '{"sessions":[1,2],"at":3}' },
      { type: 'snapshotSet', name: 'hq.calendar-v2', json: 'null' },
      { type: 'snapshotRemove', name: 'today' },
      { type: 'snapshotClear' },
    ])
  })

  it('refuses a name that could leave the snapshot directory, and a value JSON cannot hold', () => {
    const posts = shell()
    expect(() => snapshots.set('../x', 1)).toThrow(TypeError)
    expect(() => snapshots.set('.hidden', 1)).toThrow(TypeError)
    expect(() => snapshots.set('today', undefined)).toThrow('not JSON')
    expect(snapshots.remove('a/b')).toBe(false)
    expect(posts).toEqual([])
    expect(isSnapshotName('a.b-c_d')).toBe(true)
    expect(isSnapshotName('x'.repeat(128))).toBe(true)
    expect(isSnapshotName('x'.repeat(129))).toBe(false)
    expect(isSnapshotName('')).toBe(false)
  })

  it('does nothing outside a hybrid app', () => {
    ;(globalThis as any).window = { webkit: { messageHandlers: {} } }
    expect(snapshots.isAvailable()).toBe(false)
    expect(snapshots.set('today', {})).toBe(false)
    expect(hybrid.isActive()).toBe(false)
    expect(hybrid.open('/m')).toBe(false)
    expect(hybrid.back()).toBe(false)
    ;(globalThis as any).window = undefined
    expect(snapshots.clear()).toBe(false)
  })
})

describe('Mobile hybrid navigation', () => {
  it('asks the shell to open a path and to go back', () => {
    const posts = shell()
    expect(hybrid.isActive()).toBe(true)
    expect(hybrid.open('/m/workout/42')).toBe(true)
    expect(hybrid.back()).toBe(true)
    expect(posts).toEqual([{ type: 'open', path: '/m/workout/42' }, { type: 'back' }])
    expect(() => hybrid.open('m/workout')).toThrow(TypeError)
  })

  it('answers which native screen a path opens from the shell\'s own table', () => {
    shell({ __craftHybrid: { match: (url: string) => (url === '/m' ? { path: '/m', screen: 'Today', params: {} } : null) } })
    expect(hybrid.nativeScreenFor('/m')).toEqual({ path: '/m', screen: 'Today', params: {} })
    expect(hybrid.nativeScreenFor('/m/settings')).toBeNull()
    ;(globalThis as any).window = {}
    expect(hybrid.nativeScreenFor('/m')).toBeNull()
  })

  it('is part of the default export', () => {
    expect(mobile.snapshots).toBe(snapshots)
    expect(mobile.hybrid).toBe(hybrid)
  })
})
