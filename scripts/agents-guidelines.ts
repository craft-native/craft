/**
 * Keeps `AGENTS.md` a real briefing rather than a copy of `CLAUDE.md`.
 *
 * `AGENTS.md` is the only thing a coding agent working from a fresh checkout
 * reads before it runs a command. It was byte-identical to `CLAUDE.md` below
 * its title, so it carried the house rules and none of the environment facts
 * that a machine without this repository's history cannot discover.
 *
 * Every topic below cost a real, separately diagnosed build failure here, in
 * this order: an unpinned `zig` on PATH, the absent sibling checkouts, and a
 * `bun test` that ran the wrong suite. None of them are code defects and none
 * are visible from the tree, which is exactly why they belong in writing.
 */

/** Facts an agent cannot derive from the tree, each with the words that prove it was written down. */
const briefings: { topic: string, needles: string[] }[] = [
  { topic: 'the pinned Zig toolchain', needles: ['CRAFT_ZIG', 'pantry.lock'] },
  { topic: 'the sibling first-party checkouts', needles: ['Libraries/zig-js', 'pins.env'] },
  { topic: 'which suite each test script runs', needles: ['bun run test:sdk'] },
]

/** House rules that must survive any rewrite, since the copy is where they came from. */
const houseRules = ['pickier', 'buddy-bot', 'conventional commit']

/** The text below the first heading, which is the only line the two files are meant to differ on. */
function body(text: string): string {
  return text.split('\n').slice(1).join('\n').trim()
}

export function checkAgentsGuidelines(agents: string, claude: string): void {
  if (body(agents) === body(claude))
    throw new Error('AGENTS.md repeats CLAUDE.md below its title, so it briefs none of the environment a fresh checkout needs')

  for (const { topic, needles } of briefings) {
    const missing = needles.filter(needle => !agents.includes(needle))
    if (missing.length)
      throw new Error(`AGENTS.md does not brief ${topic}; expected to find ${missing.join(' and ')}`)
  }

  const lowered = agents.toLowerCase()
  for (const rule of houseRules) {
    if (!lowered.includes(rule))
      throw new Error(`AGENTS.md dropped the shared house rule: ${rule}`)
  }
}
