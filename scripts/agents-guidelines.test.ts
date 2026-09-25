import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { checkAgentsGuidelines } from './agents-guidelines'

const root = join(import.meta.dir, '..')
const read = (name: string): string => readFileSync(join(root, name), 'utf8')

const rules = 'Use pickier, never eslint. buddy-bot handles updates. Use conventional commit messages.'
const briefed = [
  'Set CRAFT_ZIG to the executable pantry.lock pins.',
  'Zig needs the sibling Libraries/zig-js checkout at the SHA in pins.env.',
  'The SDK suite is bun run test:sdk.',
].join('\n')

test('the repository AGENTS.md briefs the environment and keeps the house rules', () => {
  expect(() => checkAgentsGuidelines(read('AGENTS.md'), read('CLAUDE.md'))).not.toThrow()
})

test('rejects an AGENTS.md that only repeats CLAUDE.md', () => {
  expect(() => checkAgentsGuidelines(`# Codex Guidelines\n\n${rules}`, `# Claude Code Guidelines\n\n${rules}`))
    .toThrow('repeats CLAUDE.md')
})

test('names the briefing an AGENTS.md leaves out', () => {
  expect(() => checkAgentsGuidelines(`# Codex\n\n${rules}\n${briefed.replace('pantry.lock', 'the lockfile')}`, `# Claude\n\n${rules}`))
    .toThrow('pinned Zig toolchain')
  expect(() => checkAgentsGuidelines(`# Codex\n\n${rules}\n${briefed.replace('pins.env', 'a pin file')}`, `# Claude\n\n${rules}`))
    .toThrow('sibling first-party checkouts')
  expect(() => checkAgentsGuidelines(`# Codex\n\n${rules}\n${briefed.replace('bun run test:sdk', 'bun test')}`, `# Claude\n\n${rules}`))
    .toThrow('which suite each test script runs')
})

test('refuses to let a rewrite drop a shared house rule', () => {
  expect(() => checkAgentsGuidelines(`# Codex\n\n${rules.replace('buddy-bot', 'the bot')}\n${briefed}`, `# Claude\n\n${rules}`))
    .toThrow('buddy-bot')
})
