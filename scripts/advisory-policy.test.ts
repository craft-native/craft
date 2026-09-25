import { expect, test } from 'bun:test'
import { assertAdvisoryPolicy, collectAdvisories, reviewAdvisories } from './advisory-policy'
import { retainedAdvisories } from './retained-advisories'

const low = { id: 1, url: 'https://example.test/a', title: 'dev server read', severity: 'low' }
const moderate = { id: 2, url: 'https://example.test/b', title: 'ssr xss', severity: 'moderate' }
const high = { id: 3, url: 'https://example.test/c', title: 'rce', severity: 'high' }

const reviewed = (id: number, pkg: string, expires: string) => ({
  id,
  package: pkg,
  ghsa: `GHSA-test-${id}`,
  reason: 'dev only, reaches no published artifact',
  reviewed: '2026-09-01',
  expires,
})

test('a reviewed, in-date, unreachable advisory passes', () => {
  const review = assertAdvisoryPolicy({ esbuild: [low] }, [reviewed(1, 'esbuild', '2026-12-31')], '2026-09-25')
  expect(review.retained).toHaveLength(1)
  expect(review.unreviewed).toHaveLength(0)
})

test('an advisory nobody reviewed fails, and the message names it', () => {
  expect(() => assertAdvisoryPolicy({ svelte: [moderate] }, [], '2026-09-25'))
    .toThrow('nobody has reviewed')
})

test('high and critical can never be retained, however carefully worded', () => {
  expect(() => assertAdvisoryPolicy({ tar: [high] }, [reviewed(3, 'tar', '2099-01-01')], '2026-09-25'))
    .toThrow('cannot be retained')
})

test('a retention past its expiry fails, so the reasoning gets re-examined', () => {
  expect(() => assertAdvisoryPolicy({ esbuild: [low] }, [reviewed(1, 'esbuild', '2026-09-24')], '2026-09-25'))
    .toThrow('past review')
})

test('a retention matching no current advisory fails as stale', () => {
  expect(() => assertAdvisoryPolicy({}, [reviewed(1, 'esbuild', '2026-12-31')], '2026-09-25'))
    .toThrow('match no current advisory')
})

test('a retention is scoped to its own package, not the id alone', () => {
  expect(() => assertAdvisoryPolicy({ svelte: [low] }, [reviewed(1, 'esbuild', '2026-12-31')], '2026-09-25'))
    .toThrow('nobody has reviewed')
})

test('an unreadable or failed scan is never an empty report', () => {
  expect(() => collectAdvisories(null)).toThrow('expected an object')
  expect(() => collectAdvisories([])).toThrow('expected an object')
  expect(() => collectAdvisories({ esbuild: 'none' })).toThrow('does not list advisories')
  expect(() => collectAdvisories({ esbuild: [{ id: 1 }] })).toThrow('missing id or severity')
  expect(() => collectAdvisories({ esbuild: [{ id: 1, severity: 'spicy' }] })).toThrow('Invalid bun audit severity')
})

test('no advisories at all is a clean pass', () => {
  expect(reviewAdvisories([], [], '2026-09-25').retained).toHaveLength(0)
})

test('every retained advisory carries a reason, a review date and an expiry', () => {
  expect(retainedAdvisories.length).toBeGreaterThan(0)
  for (const entry of retainedAdvisories) {
    expect(entry.ghsa).toMatch(/^GHSA-/)
    expect(entry.reason.length).toBeGreaterThan(30)
    expect(entry.reviewed).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(entry.expires).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(entry.expires > entry.reviewed).toBe(true)
  }
})
