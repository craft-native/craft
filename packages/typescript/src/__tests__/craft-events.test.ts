import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const declarations = resolve(import.meta.dir, '../../types/craft.d.ts')

test('the iOS tab-bar layout event is typed in the shared mobile declarations', () => {
  const source = readFileSync(declarations, 'utf8')
  expect(source).toContain('export interface CraftTabBarLayoutEvent extends CustomEvent')
  expect(source).toContain('craftTabBarLayout: CraftTabBarLayoutEvent;')
  expect(source).toContain('height: number;')
})
