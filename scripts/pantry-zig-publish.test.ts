import { expect, test } from 'bun:test'
import { confirmZigPublication, zigPackageUrl } from './pantry-zig-publish'

// v0.0.500's upload lost its reply (curl 16 at 22:31:10Z) and the registry
// published it at 22:31:17Z (#524). That record must count as published;
// anything that is not this run's clean upload must not.
const since = new Date('2026-11-12T22:28:00Z')
const published = {
  name: 'craft',
  version: '0.0.500',
  publishedAt: '2026-11-12T22:31:17.278Z',
  artifactSha256: '822eadb4',
  malwareScan: { verdict: 'clean' },
}
const expected = { name: 'craft', version: '0.0.500', since }

test('a lost reply whose version the registry published after the job started counts as published', () => {
  expect(confirmZigPublication(published, expected)).toEqual({ published: true, publishedAt: '2026-11-12T22:31:17.278Z', artifactSha256: '822eadb4' })
})

test('anything other than this run\'s clean upload still fails the job', () => {
  const refused = (record: Parameters<typeof confirmZigPublication>[0]) => confirmZigPublication(record, expected)
  // Nothing there, or another package.
  expect(refused(undefined)).toMatchObject({ published: false, reason: 'the registry returned no package record' })
  expect(refused({ ...published, name: 'other' })).toMatchObject({ published: false })
  // The previous release is still the latest: the upload did not land.
  expect(refused({ ...published, version: '0.0.499' })).toMatchObject({ published: false, reason: 'the registry\'s latest craft is "0.0.499", not 0.0.500' })
  // This version, but from before this job: not this run's upload.
  expect(refused({ ...published, publishedAt: '2026-11-12T22:00:00Z' })).toMatchObject({ published: false })
  expect(refused({ ...published, publishedAt: 'not a time' })).toMatchObject({ published: false, reason: 'the registry record has no publication time' })
  // Published but not cleared by the registry's own scan.
  expect(refused({ ...published, malwareScan: { verdict: 'pending' } })).toMatchObject({ published: false })
  expect(refused({ ...published, malwareScan: null })).toMatchObject({ published: false })
})

test('it reads the registry\'s record of the package by name', () => {
  expect(zigPackageUrl('craft')).toBe('https://registry.pantry.dev/zig/packages/craft')
})
