#!/usr/bin/env bun

import { existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

const indexPath = resolve(import.meta.dir, '../docs/api/README.md')
const source = await Bun.file(indexPath).text()
const missing = new Set<string>()

for (const match of source.matchAll(/\]\(([^)]+)\)/g)) {
  const destination = match[1]?.split('#', 1)[0]
  if (!destination || destination.startsWith('#') || /^[a-z][a-z\d+.-]*:/i.test(destination))
    continue

  const target = resolve(dirname(indexPath), decodeURIComponent(destination))
  if (!existsSync(target)) missing.add(destination)
}

if (missing.size > 0) {
  console.error('docs/api/README.md contains links to missing files:')
  for (const destination of [...missing].sort()) console.error(`- ${destination}`)
  process.exit(1)
}

console.log('API documentation index links are valid.')
