import { createReadStream, existsSync, lstatSync, mkdirSync, realpathSync, statSync } from 'node:fs'
import { dirname, isAbsolute, join } from 'node:path'
import { nativeFixtureBuildTimeoutMs, nativeFixtureCommand } from './native-fixture-command'

const source = join(import.meta.dir, 'held-viewer-frame.swift')

async function hash(path: string): Promise<string> {
  const digest = new Bun.CryptoHasher('sha256')
  for await (const chunk of createReadStream(path)) digest.update(chunk)
  return digest.digest('hex')
}

export interface HeldViewerExtractor {
  path: string
  binarySha256: string
  sourceSha256: string
  swiftc: string
  swiftcSha256: string
  macosSdk: string
}

/** Compilation belongs to the fixture's build phase, before recording starts. */
export async function buildHeldViewerExtractor(options: { output: string }, dependencies: {
  command?: typeof nativeFixtureCommand
  xcrun?: string
  monotonicNow?: () => number
} = {}): Promise<string> {
  const output = options.output
  if (!isAbsolute(output)) throw new Error('Extractor build output must be absolute')
  mkdirSync(output, { recursive: true })
  const manifest = join(output, 'extractor-build.json'), path = join(output, 'held-viewer-frame')
  if (existsSync(manifest) || existsSync(path)) throw new Error('Refusing to overwrite retained extractor build evidence')
  const xcrun = dependencies.xcrun ?? Bun.which('xcrun')
  const command = dependencies.command ?? nativeFixtureCommand
  const calls: { args: string[], timeoutMs: number, startedWall: number, finishedWall?: number, result?: Awaited<ReturnType<typeof nativeFixtureCommand>> }[] = []
  let swiftc: string | undefined, macosSdk: string | undefined
  let sourceSha256: string | undefined, swiftcSha256: string | undefined, binarySha256: string | undefined
  const now = dependencies.monotonicNow ?? (() => performance.now())
  const deadline = now() + nativeFixtureBuildTimeoutMs
  const receipt = (verified: boolean, error?: string) => ({
    verified, error, output, path, source, sourceSha256, swiftc, swiftcSha256,
    macosSdk, binarySha256, xcrun, totalBuildBudgetMs: nativeFixtureBuildTimeoutMs, calls,
  })
  const run = async (args: string[]) => {
    const timeoutMs = Math.max(0, Math.floor(deadline - now()))
    const call: typeof calls[number] = { args, timeoutMs, startedWall: Date.now() / 1000 }
    calls.push(call)
    try {
      if (!timeoutMs) throw new Error('Extractor build exhausted its shared native fixture compilation deadline')
      const result = await command(args, { cwd: output, timeoutMs })
      call.result = result
      if (result.code !== 0 || result.timedOut || result.cancelled)
        throw new Error(`Extractor build command failed: ${JSON.stringify(result)}`)
      return result
    }
    finally { call.finishedWall = Date.now() / 1000 }
  }
  try {
    if (!xcrun || !isAbsolute(xcrun)) throw new Error('Cannot resolve the public xcrun executable')
    swiftc = (await run([xcrun, '--sdk', 'macosx', '--find', 'swiftc'])).stdout.trim()
    macosSdk = (await run([xcrun, '--sdk', 'macosx', '--show-sdk-path'])).stdout.trim()
    if (!isAbsolute(swiftc) || !isAbsolute(macosSdk) || !statSync(macosSdk).isDirectory())
      throw new Error('Public Swift compiler and macOS SDK paths must be absolute and present')
    sourceSha256 = await hash(source)
    swiftcSha256 = await hash(swiftc)
    await run([swiftc, '-sdk', macosSdk, source, '-o', path])
    if (!existsSync(path) || lstatSync(path).isSymbolicLink() || !statSync(path).isFile() || !statSync(path).size || !(statSync(path).mode & 0o111))
      throw new Error('Swift did not produce a fresh executable extractor binary')
    if (sourceSha256 !== await hash(source) || swiftcSha256 !== await hash(swiftc))
      throw new Error('Extractor source or compiler changed during its build')
    binarySha256 = await hash(path)
    if (now() >= deadline) throw new Error('Extractor build exhausted its shared native fixture compilation deadline')
    await Bun.write(manifest, JSON.stringify(receipt(true), null, 2))
    return manifest
  }
  catch (error) {
    await Bun.write(manifest, JSON.stringify(receipt(false, String(error)), null, 2))
    throw error
  }
}

/** Verify the exact prebuilt extractor without compiling inside capture timing. */
export async function verifyHeldViewerExtractor(manifestPath: string, expectedOutput: string): Promise<HeldViewerExtractor> {
  if (!isAbsolute(expectedOutput) || manifestPath !== join(expectedOutput, 'extractor-build.json')
    || lstatSync(manifestPath).isSymbolicLink())
    throw new Error('Extractor manifest must be the retained file in its expected absolute output')
  const evidence = await Bun.file(manifestPath).json()
  const path = join(expectedOutput, 'held-viewer-frame')
  if (evidence.verified !== true || evidence.output !== expectedOutput || evidence.path !== path || evidence.source !== source
    || typeof evidence.swiftc !== 'string' || !isAbsolute(evidence.swiftc)
    || typeof evidence.macosSdk !== 'string' || !isAbsolute(evidence.macosSdk) || !statSync(evidence.macosSdk).isDirectory())
    throw new Error('Extractor manifest does not describe a verified build of the owning source')
  if (lstatSync(path).isSymbolicLink() || realpathSync(dirname(path)) !== realpathSync(expectedOutput)
    || !statSync(path).isFile() || !statSync(path).size || !(statSync(path).mode & 0o111))
    throw new Error('Extractor binary is not an executable file contained in the expected output')
  for (const [file, expected] of [[path, evidence.binarySha256], [source, evidence.sourceSha256], [evidence.swiftc, evidence.swiftcSha256]]) {
    if (typeof expected !== 'string' || !/^[a-f\d]{64}$/.test(expected) || await hash(file) !== expected)
      throw new Error(`Extractor provenance hash changed: ${file}`)
  }
  return { path, binarySha256: evidence.binarySha256, sourceSha256: evidence.sourceSha256,
    swiftc: evidence.swiftc, swiftcSha256: evidence.swiftcSha256, macosSdk: evidence.macosSdk }
}
