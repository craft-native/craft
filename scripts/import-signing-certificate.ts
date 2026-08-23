#!/usr/bin/env bun
/**
 * Turn a downloaded Developer ID certificate into the two encrypted values the
 * release needs.
 *
 * Apple issues a `.cer` that is only the *public* half. Signing needs it paired
 * with the private key the CSR was made from, exported together as a `.p12` —
 * which is what CI imports into its throwaway keychain. That pairing is four
 * `security` invocations with a keychain in the middle, and getting one of them
 * wrong produces a `.p12` that imports cleanly and cannot sign.
 *
 * So it is one command:
 *
 *   bun scripts/import-signing-certificate.ts ~/Downloads/developerID_application.cer
 *
 * It reads the export password from `.env.production` rather than inventing
 * one, writes `APPLE_CERTIFICATE_BASE64` and `APPLE_SIGNING_IDENTITY` back into
 * the same file, and leaves nothing in plaintext except inside `.signing/`,
 * which is ignored.
 */
import { $ } from 'bun'
import { existsSync } from 'node:fs'
import { join, resolve } from 'node:path'
import process from 'node:process'

const ENV_FILE = '.env.production'
const SIGNING_DIR = '.signing'
const KEY = join(SIGNING_DIR, 'developer-id.key')

const certificate = process.argv[2]

function fail(message: string): never {
  console.error(message)
  process.exit(1)
}

if (!certificate || certificate === '--help' || certificate === '-h')
  fail('Usage: bun scripts/import-signing-certificate.ts <path to .cer>')

const certificatePath = resolve(certificate)

if (!existsSync(certificatePath))
  fail(`No certificate at ${certificatePath}`)

if (!existsSync(KEY))
  fail(`No private key at ${KEY}. It is the half the CSR was generated from; without it the certificate cannot sign.`)

const buddy = join('node_modules', '.bin', 'buddy')

async function env(name: string): Promise<string> {
  const result = await $`${buddy} env:get ${name} --file ${ENV_FILE}`.quiet().nothrow()

  return result.exitCode === 0 ? result.stdout.toString().trim() : ''
}

const exportPassword = await env('APPLE_CERTIFICATE_PASSWORD')

if (!exportPassword)
  fail(`APPLE_CERTIFICATE_PASSWORD is not set in ${ENV_FILE}.`)

/*
 * A keychain of its own, deleted afterwards.
 *
 * `security import` into the login keychain would prompt, and would leave the
 * key sitting in the user's own keychain with whatever access controls the
 * dialog defaulted to. A scratch keychain is created, used and destroyed.
 */
const keychain = join(SIGNING_DIR, 'import.keychain')
const keychainPassword = crypto.randomUUID()
const p12 = join(SIGNING_DIR, 'developer-id.p12')

await $`security delete-keychain ${keychain}`.quiet().nothrow()
await $`security create-keychain -p ${keychainPassword} ${keychain}`.quiet()

try {
  await $`security unlock-keychain -p ${keychainPassword} ${keychain}`.quiet()
  await $`security import ${KEY} -k ${keychain} -P "" -A -T /usr/bin/codesign -T /usr/bin/security`.quiet()
  await $`security import ${certificatePath} -k ${keychain} -A -T /usr/bin/codesign -T /usr/bin/security`.quiet()
  await $`security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ${keychainPassword} ${keychain}`.quiet().nothrow()

  const identities = await $`security find-identity -v -p codesigning ${keychain}`.quiet()
  const name = identities.stdout.toString().match(/"(Developer ID Application:[^"]+)"/)?.[1]

  if (!name) {
    fail(
      'The certificate imported but no Developer ID Application identity came out of it.\n'
      + 'A Development or Distribution certificate cannot notarize; the release needs Developer ID Application.',
    )
  }

  await $`security export -k ${keychain} -t identities -f pkcs12 -P ${exportPassword} -o ${p12}`.quiet()

  const encoded = (await $`base64 -i ${p12}`.quiet()).stdout.toString().replace(/\n/g, '')

  await $`${buddy} env:set APPLE_CERTIFICATE_BASE64 ${encoded} --file ${ENV_FILE}`.quiet()
  await $`${buddy} env:set APPLE_SIGNING_IDENTITY ${name} --file ${ENV_FILE}`.quiet()

  console.error(`encrypted APPLE_CERTIFICATE_BASE64 and APPLE_SIGNING_IDENTITY into ${ENV_FILE}`)
  console.error(`identity: ${name}`)
}
finally {
  await $`security delete-keychain ${keychain}`.quiet().nothrow()
}
