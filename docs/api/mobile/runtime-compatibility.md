# Mobile Runtime Compatibility

Craft's Zig-native mobile bridge preserves the public API's successful reply
shapes, but it does not reproduce unsafe or silent failure behavior from the
legacy platform shims. Invalid input rejects before a native side effect when
continuing would truncate data, escape an app-owned directory, abandon another
request, or report work that did not happen.

This is an intentional compatibility boundary. Applications should treat the
documented validation errors as part of the mobile API contract rather than
depending on a legacy shim's fallback behavior.

## Fail-Closed Input Handling

The native runtime rejects these classes of input:

| Input or state | Zig-native behavior | Legacy behavior avoided |
| --- | --- | --- |
| A string containing an embedded NUL (`\u0000`) | Rejects the request before calling a C or Objective-C string API. | The native API could stop at the NUL and act on a different identifier or path. |
| A saved-file name that is empty, `.`, `..`, or contains `/` | Rejects the request before constructing the destination path. | Joining the value directly to `Documents` could write outside that directory. |
| A malformed or undecodable `data:` URL | Rejects without claiming that a file was written. | The shim could skip the write and still resolve with a destination path. |
| A value with the wrong JSON type, such as a non-numeric timestamp | Rejects with an invalid-parameter error. | A failed cast could silently select a default value or time window. |
| A second operation that conflicts with an active picker, prompt, or scan | Rejects the second request and preserves the first request's callback. | One shared callback slot could be overwritten, leaving the first promise pending forever. |

The checks apply only where the native API has the corresponding hazard. Craft
does not reject arbitrary Unicode, dots within ordinary file names such as
`notes.v2.txt`, or sequential interactive operations.

## Writing Files Safely

Pass a leaf file name to mobile file-saving APIs, not a relative or absolute
path. Encode binary data as one valid base64 data URL.

```typescript
const bytes = 'SGVsbG8sIENyYWZ0IQ=='
await window.craft.saveFile(
  `data:text/plain;base64,${bytes}`,
  'greeting.txt',
  'text/plain',
)
```

Do not use values such as `../Library/settings.json`, `folder/report.pdf`, or a
name containing `\u0000`. If the API rejects, no successful write should be
inferred from a path embedded in the error message.

## Serializing Interactive Requests

System pickers and prompts normally present one modal interaction at a time.
Await one call before starting another call of the same kind:

```typescript
const avatar = await window.craft.pickFile(['public.image'])
const attachment = await window.craft.pickFile(['public.data'])
```

If application state can trigger the same interaction from several places,
disable the other triggers while the first promise is pending or serialize the
requests in an application-owned queue.

## Supplying Typed Values

Pass `Date` instances where the SDK declares dates, identifiers as strings, and
option objects in the shapes declared by `craft-native`. Low-level bridge
payloads encode dates as finite millisecond numbers. Do not rely on native JSON
libraries to coerce strings, nulls, or objects into another type.

```typescript
const endDate = new Date()
const startDate = new Date(endDate.getTime() - 7 * 24 * 60 * 60 * 1000)
const samples = await window.craft.getHealthData('steps', startDate, endDate)
```

Validate untyped external data before passing it to the bridge. A rejection is
recoverable JavaScript behavior; silent coercion can perform the wrong native
operation and is therefore not used as a compatibility mechanism.

## Migrating from a Legacy iOS Build

When upgrading an application that previously used only the generated Swift
dispatcher:

1. Exercise error paths as well as successful calls.
2. Await modal operations instead of launching overlapping requests.
3. Remove path components from saved-file names.
4. Validate timestamps and data URLs before dispatch.
5. Catch promise rejections and show a recovery path to the user.

Successful calls retain their documented public reply shapes. The differences
described here concern invalid input, conflicting operations, and legacy paths
that could resolve after doing incomplete or different work.
