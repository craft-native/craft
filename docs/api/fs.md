# File System API

The File System API provides methods for reading, writing, and managing files and directories.

## Import

```typescript
import { fs } from 'craft-native'
```

## Methods

### fs.readFile(path, options?)

Read the contents of a file.

```typescript
const content = await fs.readFile('/path/to/file.txt')
// Returns: string

const binary = await fs.readFile('/path/to/image.png', { encoding: 'binary' })
// Returns: Uint8Array
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Absolute path to the file |
| options.encoding | `'utf8' \| 'binary'` | File encoding (default: 'utf8') |

**Returns:** `Promise<string | Uint8Array>`

---

### fs.writeFile(path, content, options?)

Write content to a file.

```typescript
await fs.writeFile('/path/to/file.txt', 'Hello, World!')

await fs.writeFile('/path/to/data.bin', new Uint8Array([1, 2, 3]), {
  encoding: 'binary'
})
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Absolute path to the file |
| content | `string \| Uint8Array` | Content to write |
| options.encoding | `'utf8' \| 'binary'` | File encoding (default: 'utf8') |
| options.append | `boolean` | Append to file instead of overwrite |

**Returns:** `Promise<void>`

---

### fs.readDir(path, options?)

Read the contents of a directory.

```typescript
const entries = await fs.readDir('/path/to/dir')
// Returns: Array<{ name: string, isFile: boolean, isDirectory: boolean }>

const recursive = await fs.readDir('/path/to/dir', { recursive: true })
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Absolute path to the directory |
| options.recursive | `boolean` | Include subdirectories (default: false) |

**Returns:** `Promise<DirEntry[]>`

---

### fs.mkdir(path, options?)

Create a directory.

```typescript
await fs.mkdir('/path/to/new-dir')

await fs.mkdir('/path/to/nested/dirs', { recursive: true })
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Path to create |
| options.recursive | `boolean` | Create parent directories (default: false) |

**Returns:** `Promise<void>`

---

### fs.remove(path, options?)

Remove a file or directory.

```typescript
await fs.remove('/path/to/file.txt')

await fs.remove('/path/to/dir', { recursive: true })
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Path to remove |
| options.recursive | `boolean` | Remove directories recursively (default: false) |

**Returns:** `Promise<void>`

---

### fs.exists(path)

Check if a file or directory exists.

```typescript
const exists = await fs.exists('/path/to/file.txt')
// Returns: boolean
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Path to check |

**Returns:** `Promise<boolean>`

---

### fs.stat(path)

Get file or directory information.

```typescript
const info = await fs.stat('/path/to/file.txt')
// Returns: { size: number, isFile: boolean, isDirectory: boolean,
//            created: Date, modified: Date, accessed: Date }
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Path to stat |

**Returns:** `Promise<FileStat>`

---

### fs.copy(src, dest, options?)

Copy a file or directory.

```typescript
await fs.copy('/path/to/source.txt', '/path/to/dest.txt')

await fs.copy('/path/to/dir', '/path/to/dest-dir', { recursive: true })
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| src | `string` | Source path |
| dest | `string` | Destination path |
| options.recursive | `boolean` | Copy directories recursively |
| options.overwrite | `boolean` | Overwrite existing files |

**Returns:** `Promise<void>`

---

### fs.move(src, dest)

Move or rename a file or directory.

```typescript
await fs.move('/path/to/old.txt', '/path/to/new.txt')
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| src | `string` | Source path |
| dest | `string` | Destination path |

**Returns:** `Promise<void>`

---

### watch(path, callback, options?)

Watch a file or directory for changes. `watch` is its own export, not a method
on `fs`.

```typescript
import { watch } from 'craft-native'

const unwatch = await watch('/path/to/dir', (event, filename) => {
  console.log(event, filename) // e.g. 'modify', '/path/to/dir/file.txt'
})

// Stop watching
unwatch()
```

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| path | `string` | Path to watch |
| callback | `(event: string, filename: string) => void` | Called for each change |
| options.recursive | `boolean` | Watch subdirectories too (default: `true`) |

**Returns:** `Promise<() => void>` - resolves once the watch is registered, with
the function that stops it

In a desktop window this goes through `window.craft.fs.watch(path, callback,
options)`, which resolves with a handle, `{ id, unwatch() }`. The page generates
the `id`, native registers the watch under it, and each `craft:fs:change` event
carries it as `detail.id` (with `type` and `path`), so a callback hears only its
own watch. `window.craft.fs.unwatch(id)` and `handle.unwatch()` both stop it, and
a second stop does nothing.

On macOS the watch is registered, but native does not emit change events yet:
`(await window.craft.capabilities()).channels['craft:fs:change']` reports
`unknown`. On Linux and Windows `window.craft.fs.watch` rejects with
`PLATFORM_NOT_SUPPORTED`. Outside a Craft window, `watch` uses `node:fs.watch`.

## Types

```typescript
interface DirEntry {
  name: string
  isFile: boolean
  isDirectory: boolean
}

interface FileStat {
  size: number
  isFile: boolean
  isDirectory: boolean
  created: Date
  modified: Date
  accessed: Date
}

// The detail of a `craft:fs:change` event
interface CraftFsWatchEvent {
  id: string // the watch it belongs to
  type: string // e.g. 'create', 'modify', 'delete', 'rename'
  path: string
}

interface CraftFsWatchHandle {
  id: string
  unwatch(): Promise<void>
}

interface ReadOptions {
  encoding?: 'utf8' | 'binary'
}

interface WriteOptions {
  encoding?: 'utf8' | 'binary'
  append?: boolean
}

interface DirOptions {
  recursive?: boolean
}
```
