#!/usr/bin/env bun
/**
 * The release credentials, read and written through Stacks' env encryption.
 *
 * `.env.production` is committed as ciphertext and the only thing that opens it
 * is `DOTENV_PRIVATE_KEY_PRODUCTION`. This is the two operations that needs — a
 * human setting a value, and CI reading one back — behind one command, because
 * `@stacksjs/env` ships those as functions rather than as a binary and the
 * alternative is a line of `bun -e` in a workflow that nobody can run locally
 * to check.
 *
 *   bun scripts/env.ts set APPLE_TEAM_ID 'XXXXXXXXXX'
 *   bun scripts/env.ts get APPLE_TEAM_ID
 *
 * `--file` defaults to `.env.production`, which is the only encrypted file this
 * repository has.
 *
 * ## Why this is not `buddy env:get`
 *
 * It should be, and `buddy env:get` is a five-line wrapper around the two calls
 * below — same functions, same crypto, same `DOTENV_PRIVATE_KEY_*` lookup. What
 * stops it is installation rather than design: `@stacksjs/buddy` pulls the
 * framework's whole tree, and a few of those packages are not published at the
 * version buddy asks for, so `bunx @stacksjs/buddy env:get` cannot resolve
 * outside a scaffolded application. See stacksjs/stacks — buddy's own
 * undeclared dependencies are fixed as of 0.72.51; the publishing is not.
 *
 * When it installs cleanly, delete this file and call the command.
 */
import process from 'node:process'
import { getEnv, setEnv } from '@stacksjs/env'

const args = process.argv.slice(2)
const fileFlag = args.indexOf('--file')
const file = fileFlag === -1 ? '.env.production' : args[fileFlag + 1]
const positional = fileFlag === -1 ? args : [...args.slice(0, fileFlag), ...args.slice(fileFlag + 2)]

const [command, key, value] = positional

function fail(message: string): never {
  console.error(message)
  process.exit(1)
}

if (!command || command === '--help' || command === '-h') {
  console.log(`
Release credentials, encrypted in ${file}

  bun scripts/env.ts get <KEY>            print one value
  bun scripts/env.ts set <KEY> <VALUE>    encrypt one value in place

  --file <path>   another env file (default: .env.production)

The first \`set\` generates the keypair and writes the private key to
.env.keys, which is gitignored. That key is the only thing that opens this
file: put it in the repository's secrets as DOTENV_PRIVATE_KEY_PRODUCTION and
nowhere else.
`)
  process.exit(0)
}

if (command === 'get') {
  if (!key)
    fail('Usage: bun scripts/env.ts get <KEY>')

  const result = getEnv(key, { file })

  if (!result.success || !result.output)
    fail(result.error ?? `${key} is not set in ${file}`)

  // stdout, alone and unadorned, so a caller can capture it directly.
  console.log(result.output)
}
else if (command === 'set') {
  if (!key || value === undefined)
    fail('Usage: bun scripts/env.ts set <KEY> <VALUE>')

  const result = setEnv(key, value, { file })

  if (!result.success)
    fail(result.error ?? `Could not set ${key} in ${file}`)

  console.error(`encrypted ${key} in ${file}`)
}
else {
  fail(`Unknown command: ${command}. Try --help.`)
}
