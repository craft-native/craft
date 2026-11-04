import { expect, test } from 'bun:test'
import { nativeNotificationProblems, type NativeNotificationCategory } from '../native-notifications'

test('action config requires an executable background recipient and preserves explicit foreground opt-in', () => {
  const categories: NativeNotificationCategory[] = [{ id: 'message', actions: [
    { id: 'reply', title: 'Reply', textInput: { buttonTitle: 'Send', placeholder: 'Message' } },
    { id: 'open', title: 'Open', foreground: true, authenticationRequired: true },
  ] }]
  expect(nativeNotificationProblems(categories, 'App')).toEqual([])
  expect(nativeNotificationProblems(categories)).toHaveLength(1)
  expect(nativeNotificationProblems([{ id: 'message', actions: [categories[0]!.actions[1]] }])).toEqual([])
  expect(nativeNotificationProblems(undefined)).toEqual([])
  expect(nativeNotificationProblems([])).toEqual([])
})

test('invalid categories cannot silently lose actions or decode differently between hosts', () => {
  const valid = { id: 'message', actions: [{ id: 'reply', title: 'Reply' }] }
  for (const input of [null, {}, [null], [{ id: '' }], [valid, valid], [{ ...valid, actions: [] }],
    [{ ...valid, actions: Array(4).fill(valid.actions[0]) }],
    [{ ...valid, actions: [{ id: 'com.apple.default', title: 'Open' }] }],
    [{ ...valid, actions: [{ id: 'reply', title: ' ' }] }],
    [{ ...valid, actions: [{ ...valid.actions[0], foreground: 'yes' }] }],
    [{ ...valid, actions: [{ ...valid.actions[0], textInput: {} }] }],
    [{ ...valid, actions: [{ ...valid.actions[0], textInput: { buttonTitle: 'Send', placeholder: 1 } }] }]]) {
    expect(nativeNotificationProblems(input, 'App').length).toBeGreaterThan(0)
  }
})
