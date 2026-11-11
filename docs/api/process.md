# Process API

The Process API provides methods for spawning processes, executing commands, and accessing environment information.

## Import

```typescript
import { process } from 'craft-native'
```

## Methods

### process.spawn(command, args?, options?)

Start a program on macOS. This is everything native `shell.spawn` does: the
program is started, it can be killed, and that is all. It runs with Craft's
own standard output and error. Nothing it writes reaches the page, and its
exit is not reported.

```typescript
const child = process.spawn('open', ['-a', 'Preview', '/tmp/report.pdf'])
await child.start()

// Later
await child.kill()
```

There is no `child.stdout`, no `onStdout`, `onStderr` or `onExit`, and no way
to write to stdin. Earlier versions of this page and of the SDK described all
of them. No native bridge ever sent the events behind them, so a handler
registered that way was never called. To read a program's output:

- use `process.exec()` when the command finishes and you want its output whole;
- otherwise run it in your app's own backend process and send what you need to
  the page.

On Windows and Linux the `shell` namespace is not served at all, and `start()`
rejects with `PLATFORM_NOT_SUPPORTED`.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| command | `string` | Program to run. Not a command line: no shell splits it. |
| args | `string[]` | Its arguments, passed as written |
| options.cwd | `string` | Working directory |
| options.shell | `boolean` | Run `command` as one command line through `/bin/sh`. Cannot be combined with `args`. |

**Returns:** `ChildProcess`

---

### process.exec(command, options?)

Execute a command and return the output.

```typescript
const result = await process.exec('ls -la')
console.log(result.stdout)
console.log(result.stderr)
console.log(result.exitCode)

// With options
const result = await process.exec('bun install', {
  cwd: '/path/to/project',
  timeout: 60000
})
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| command | `string` | Command to execute (shell command) |
| options.cwd | `string` | Working directory |

Inside a Craft window this is native `shell.exec` (macOS only), which runs the
command through the shell, refuses shell metacharacters such as `;`, `|` and
`$(`, and ignores `env` and `timeout`. Those two options apply only when the
SDK runs under Bun or Node.

**Returns:** `Promise<ExecResult>`

---

### process.env

Access environment variables.

```typescript
const home = process.env.HOME
const path = process.env.PATH
const customVar = process.env.MY_APP_CONFIG

// All environment variables
console.log(process.env)
```

**Returns:** `Record<string, string | undefined>`

---

### process.cwd()

Get the current working directory.

```typescript
const currentDir = process.cwd()
// Returns: "/Users/username/project"
```

**Returns:** `string`

---

### process.exit(code?)

Exit the application with an optional exit code.

```typescript
process.exit(0)  // Success
process.exit(1)  // Error
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| code | `number` | Exit code (default: 0) |

**Returns:** `never`

---

### process.platform

Get the current platform.

```typescript
const platform = process.platform
// Returns: 'darwin' | 'win32' | 'linux' | 'ios' | 'android'
```

**Returns:** `string`

---

### process.arch

Get the CPU architecture.

```typescript
const arch = process.arch
// Returns: 'x64' | 'arm64' | 'arm'
```

**Returns:** `string`

---

### child.kill()

Kill a spawned process. Native sends the platform's default termination;
there is no signal to choose.

```typescript
const child = process.spawn('long-running-task')
await child.start()

// Kill after 10 seconds
setTimeout(() => {
  child.kill()
}, 10000)
```

**Returns:** `Promise<void>`

## Example Usage

```typescript
import { process } from 'craft-native'

// Run a build script
async function runBuild() {
  const result = await process.exec('bun run build', {
    cwd: '/path/to/project'
  })

  if (result.exitCode !== 0) {
    console.error('Build failed:', result.stderr)
    throw new Error('Build failed')
  }

  console.log('Build output:', result.stdout)
}

// A program that outlives the call. Its output goes wherever Craft's own
// does; the page does not see it.
async function openInEditor(file: string) {
  const editor = process.spawn('code', [file])
  await editor.start()
  return editor
}

// Check if a command exists
async function commandExists(cmd: string): Promise<boolean> {
  try {
    const which = process.platform === 'win32' ? 'where' : 'which'
    const result = await process.exec(`${which} ${cmd}`)
    return result.exitCode === 0
  } catch {
    return false
  }
}

// Platform-specific behavior
function getShell(): string {
  switch (process.platform) {
    case 'win32':
      return 'cmd.exe'
    case 'darwin':
    case 'linux':
      return process.env.SHELL || '/bin/sh'
    default:
      return '/bin/sh'
  }
}
```

## Types

```typescript
interface SpawnOptions {
  cwd?: string
  shell?: boolean
}

interface ExecOptions {
  cwd?: string
  env?: Record<string, string>
  timeout?: number
}

interface ExecResult {
  stdout: string
  stderr: string
  exitCode: number
}

interface ChildProcess {
  /** Identifier the process is registered under, or null before start(). */
  readonly pid: string | null
  start(): Promise<void>
  kill(): Promise<void>
}
```
