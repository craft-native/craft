import { describe, expect, it } from 'bun:test'
import { liveActivities } from '../api/ios-advanced'

describe('iOS advanced Live Activity handles', () => {
  it('returns handles that retain the id required by update and end', async () => {
    const root = globalThis as any
    const hadCraft = Object.hasOwn(root, 'craft')
    const previousCraft = root.craft
    const hadWindow = Object.hasOwn(root, 'window')
    const previousWindow = root.window
    const calls: unknown[][] = []

    root.craft = { _platform: 'ios' }
    root.window = {
      ...(previousWindow ?? {}),
      craft: {
        liveActivities: {
          start: async (config: { activityType: string }) => ({ id: `native-${config.activityType}` }),
          update: async (...args: unknown[]) => { calls.push(['update', ...args]) },
          end: async (...args: unknown[]) => { calls.push(['end', ...args]) },
        },
      },
    }

    try {
      const delivery = await liveActivities.start({
        activityType: 'delivery',
        attributes: { order: '42' },
        contentState: { status: 'preparing' },
      })
      const workout = await liveActivities.start({
        activityType: 'workout',
        attributes: { route: 'ridge' },
        contentState: { status: 'recording' },
      })

      await delivery.update({ status: 'on-the-way' })
      await workout.end({ status: 'saved' })

      expect(delivery.id).toBe('native-delivery')
      expect(workout.id).toBe('native-workout')
      expect(calls).toEqual([
        ['update', 'native-delivery', { status: 'on-the-way' }, undefined],
        ['end', 'native-workout', { status: 'saved' }, undefined],
      ])
    }
    finally {
      if (hadCraft) root.craft = previousCraft
      else delete root.craft
      if (hadWindow) root.window = previousWindow
      else delete root.window
    }
  })
})
