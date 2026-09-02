/**
 * Run the `tsc` this package declares, not the one on PATH.
 *
 * `bunx tsc` resolves through PATH. In CI the pantry action provisions its own
 * typescript into `<repo>/pantry` and puts it ahead of `node_modules/.bin`, so
 * the same command silently ran a different compiler — a dev build the
 * lockfile never pinned, and one whose linux-x64 platform binary is missing:
 *
 *   Error: Unable to resolve @typescript/typescript-linux-x64.
 *
 * Locally nothing shadows `node_modules/.bin`, which is why the break only
 * ever showed up in one CI job. Resolving through the module graph instead of
 * PATH makes both places run the version `bun.lock` says.
 */
import { dirname, join } from 'node:path'

const pkgRoot = dirname(dirname(Bun.resolveSync('typescript', import.meta.dir)))
const tsc = join(pkgRoot, 'bin', 'tsc')

const proc = Bun.spawn(['bun', tsc, ...Bun.argv.slice(2)], { stdio: ['inherit', 'inherit', 'inherit'] })
process.exit(await proc.exited)
