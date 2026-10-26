import { cp, copyFile, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { resolveZig } from './zig'

const repository = resolve(import.meta.dir, '..')
const source = join(repository, 'packages/zig')
const fixture = join(source, 'test/fixtures/graphics-package-consumer')
const manifest = await readFile(join(source, 'build.zig.zon'), 'utf8')
const pathsBody = manifest.match(/\.paths\s*=\s*\.\{([^}]+)\}/)?.[1]
if (!pathsBody) throw new Error('The source package must declare its shipped paths')
const paths = [...pathsBody.matchAll(/"([^"\r\n]+)"/g)].map(match => match[1]!)
if (!paths.length || paths.some(path => isAbsolute(path) || path.split(/[\\/]/).includes('..')))
  throw new Error('Package paths must remain inside the source package')
const zig = resolveZig(repository).path
// Git Bash's GNU tar interprets a Windows drive letter as a remote host.
// Require the platform's native archiver, which accepts native absolute paths.
const windowsRoot = process.env.SystemRoot || process.env.SYSTEMROOT
if (process.platform === 'win32' && !windowsRoot)
  throw new Error('Windows must declare its native system directory')
const tar = Bun.which('tar', {
  PATH: process.platform === 'win32' ? join(windowsRoot!, 'System32') : process.env.PATH,
})
if (!tar) throw new Error('The native tar archiver is required')

async function run(command: string[], cwd: string, env = process.env): Promise<void> {
  const child = Bun.spawn(command, { cwd, env, stdin: 'ignore', stdout: 'inherit', stderr: 'inherit' })
  const code = await child.exited
  if (code !== 0) throw new Error(`${command[0]} failed with exit code ${code}`)
}

const root = await mkdtemp(join(tmpdir(), 'craft-public-package-'))
try {
  // Match the publisher's declared source paths. The extracted package is never
  // rewritten, and no sibling checkout or existing compiler cache is supplied.
  const archive = join(root, 'craft-source.tar.gz')
  const extracted = join(root, 'package')
  await run([tar, '-czf', archive, '--', ...paths], source)
  await mkdir(extracted)
  await run([tar, '-xzf', archive, '-C', extracted], root)
  await copyFile(join(fixture, 'build.zig'), join(root, 'build.zig'))
  await copyFile(join(fixture, 'build.zig.zon'), join(root, 'build.zig.zon'))
  await cp(join(fixture, 'src'), join(root, 'src'), { recursive: true })
  const bytes = await readFile(archive)
  console.log(`Source archive SHA-256: ${new Bun.CryptoHasher('sha256').update(bytes).digest('hex')}`)
  await run([zig, 'build', 'check', '--summary', 'all'], root, {
    ...process.env,
    ZIG_GLOBAL_CACHE_DIR: join(root, 'global-cache'),
    ZIG_LOCAL_CACHE_DIR: join(root, 'local-cache'),
  })
  console.log('Public graphics source archive verified with fresh dependency resolution and no sibling checkouts.')
}
finally { await rm(root, { recursive: true, force: true }) }
