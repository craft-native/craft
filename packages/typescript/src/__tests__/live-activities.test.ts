import { describe, expect, it } from 'bun:test'
import { liveActivities } from '../api/mobile'

describe('browser-safe Live Activity handles', () => {
  it('keeps updates and endings scoped to the activity that created each handle', async () => {
    const root = globalThis as any
    const hadWindow = Object.hasOwn(root, 'window')
    const previousWindow = root.window
    const updates: Array<[string, Record<string, unknown>]> = []
    const endings: Array<[string, Record<string, unknown> | undefined]> = []

    root.window = {
      ...(previousWindow ?? {}),
      craft: {
        liveActivity: {
          start: async (options: { activityId: string }) => ({ id: `native-${options.activityId}` }),
          update: async (id: string, state: Record<string, unknown>) => {
            updates.push([id, state])
          },
          end: async (id: string, finalState?: Record<string, unknown>) => {
            endings.push([id, finalState])
          },
        },
      },
    }

    try {
      const hike = await liveActivities.start({ activityId: 'hike', title: 'Morning hike' })
      const run = await liveActivities.start({ activityId: 'run', title: 'Evening run' })

      expect(hike.id).toBe('native-hike')
      expect(run.id).toBe('native-run')

      await hike.update({ distanceMeters: 1200 })
      await run.update({ distanceMeters: 5000 })
      await hike.end({ status: 'Saved' })
      await run.end()

      expect(updates).toEqual([
        ['native-hike', { distanceMeters: 1200 }],
        ['native-run', { distanceMeters: 5000 }],
      ])
      expect(endings).toEqual([
        ['native-hike', { status: 'Saved' }],
        ['native-run', undefined],
      ])
    }
    finally {
      if (hadWindow) root.window = previousWindow
      else delete root.window
    }
  })

  it('retains the deprecated singleton calls for one-release migration', async () => {
    const root = globalThis as any
    const hadWindow = Object.hasOwn(root, 'window')
    const previousWindow = root.window
    const calls: unknown[][] = []

    root.window = {
      ...(previousWindow ?? {}),
      craft: {
        liveActivity: {
          start: async () => ({ id: 'unused' }),
          update: async (...args: unknown[]) => { calls.push(['update', ...args]) },
          end: async (...args: unknown[]) => { calls.push(['end', ...args]) },
        },
      },
    }

    try {
      await liveActivities.update({ progress: 0.5 })
      await liveActivities.end()
      expect(calls).toEqual([
        ['update', { progress: 0.5 }],
        ['end'],
      ])
    }
    finally {
      if (hadWindow) root.window = previousWindow
      else delete root.window
    }
  })
})
