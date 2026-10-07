# Native STX on iOS and Android

Craft's experimental `native` mobile renderer runs a compiled STX route bundle
without a browser view. iOS evaluates the bundle with JavaScriptCore and creates
UIKit controls. Android evaluates the same bundle with JavaScriptSandbox and
creates Android views. Native mode never creates `WKWebView` or `WebView`, and it
fails visibly when its bundle or JavaScript runtime is unavailable.

The default renderer remains `web`. Opting into native mode does not change an
existing web-rendered application.

## Build the same bundle for both platforms

Configure routes in `stx-native.config.json`, then compile the directory that
contains that file:

```bash
stx-native compile --format bundle --output ./native-screen.js

craft ios init MyApp --renderer native --output ./ios
craft ios build --output ./ios --native-bundle ./native-screen.js

craft android init MyApp --package com.example.myapp --renderer native --output ./android
craft android build --output ./android --native-bundle ./native-screen.js
```

Native mode does not accept a web distribution or development-server URL. The
bundle must be local at build time.

## Current component contract

| STX primitive | iOS | Android |
| --- | --- | --- |
| `View`, `SafeAreaView` | `CraftNativeFlowView` | `CraftNativeFlexLayout` (a `LinearLayout`) |
| `Text` | `UILabel` | `TextView` |
| `Button` | `UIButton` | `Button` |
| `TextInput` | `UITextField` | `EditText` |
| `Image` | `UIImageView` | `ImageView` |
| `ScrollView` | `UIScrollView` | `ScrollView` or `HorizontalScrollView` |
| `FlatList` | `UICollectionView` | `RecyclerView` |

On iOS, `CraftNativeFlowView` remains a `UIStackView` subclass for source and
accessibility compatibility while supplying the shared wrapping and positioning
rules; Android keeps the corresponding `LinearLayout` compatibility surface.

`key` is scoped to sibling nodes. `testID` is also accepted as an identity for
existing screens. Unkeyed children reconcile by position. A rerender updates an
existing native control when its identity and type are unchanged, preserving
input focus, selection, draft text, and scroll objects. Duplicate sibling keys
fall back to positional identity rather than attaching state to the wrong view.

## Incremental update protocol

Generated native hosts advertise `mutationProtocolVersion: 1` on
`globalThis.__stxNativeBridge`. A current `stx-native` bundle uses `MUTATE`
batches when that value is present and continues to send the original
whole-document `RENDER` message to older hosts. If a host rejects a mutation
batch, the bundle resynchronizes with `RENDER`, so a bundle can run against
both generations of Craft.

Every batch has one protocol version, a non-empty identifier, consecutive
revisions, and at least one operation:

```json
{
  "type": "MUTATE",
  "payload": {
    "version": 1,
    "batchId": "screen-4",
    "baseRevision": 3,
    "revision": 4,
    "operations": [
      {
        "op": "updateNode",
        "id": "root/key:counter",
        "patch": { "children": ["Count: 4"] }
      }
    ]
  }
}
```

Version 1 supports these operations:

| Operation | Required fields | Effect |
| --- | --- | --- |
| `createNode` | `id`, `node`; optional `root` | Creates a detached node, or the document root when `root` is `true` |
| `updateNode` | `id`, `patch` | Replaces supplied `props`, `style`, `events`, or text `children` fields |
| `insertChild` | `parentId`, `childId`, `index` | Attaches a detached node to a container |
| `moveChild` | `parentId`, `childId`, `index` | Reorders a child within its current parent |
| `removeNode` | `id` | Removes the node and its descendants |

`View`, `SafeAreaView`, and `ScrollView` are the container node types. Node
children in `createNode` and `updateNode` may contain text only; node
relationships use `insertChild`. Indexes are zero-based and may equal the
current child count when inserting or moving to the end.

The host validates the complete batch against a copy of its retained tree. It
commits and advances the revision only if every operation succeeds, then sends:

```json
{
  "type": "MUTATION_ACK",
  "payload": { "version": 1, "batchId": "screen-4", "revision": 4 }
}
```

Malformed or stale batches leave both the native view tree and revision
unchanged. The reply is `MUTATION_ERROR` with `version`, `batchId`, `code`,
`message`, and, when an operation failed, its zero-based `operationIndex`.
Error codes are deterministic across iOS and Android: `INVALID_BATCH`,
`UNSUPPORTED_VERSION`, `REVISION_MISMATCH`, `INVALID_REVISION`,
`INVALID_OPERATION`, `UNKNOWN_OPERATION`, `INVALID_NODE`, `DUPLICATE_NODE`,
`ROOT_EXISTS`, `INVALID_PATCH`, `UNKNOWN_PARENT`, `UNKNOWN_NODE`,
`INVALID_PARENT`, `NODE_ATTACHED`, `CYCLE`, `INVALID_INDEX`, `NOT_A_CHILD`, and
`MISSING_ROOT`, and `INVALID_TREE`. A successful batch must leave every node
reachable from its single, unattached root.

Stable node IDs are derived from sibling-scoped `key` values, with `testID`
accepted for existing screens and position used as the fallback. Updating a
node keeps its native object, event bindings, accessibility metadata, input
focus and selection. Structural operations reconcile the affected parent
subtree and preserve unrelated controls and scroll views. Root replacement is
the only mutation path that intentionally performs a full native render.

The shared style subset is deliberately smaller than the public `ViewStyle`
type:

- numeric `width`, `height`, `minWidth`, `maxWidth`, `minHeight`, and `maxHeight`;
- `flexDirection` (`row`, `column`, and their reverse forms), `alignItems`,
  `alignSelf`, `justifyContent`, `flexWrap: 'wrap'`, `gap`, `rowGap`, and
  `columnGap`;
- `position: 'relative'` (the default) and `position: 'absolute'` with numeric
  `top`, `right`, `bottom`, and `left` insets;
- `padding`, its four side properties, `paddingHorizontal`, and
  `paddingVertical`;
- `backgroundColor`, `opacity`, `borderWidth`, `borderColor`, `borderRadius`,
  `overflow: 'hidden'`, and `display: 'none'`;
- for text: `color`, `fontFamily`, `fontSize`, `fontStyle`, `fontWeight`,
  `letterSpacing`, `lineHeight`, `textAlign`, `textDecorationLine`, and
  `textTransform`;
- for images: `resizeMode` (`contain`, `cover`, `stretch`, or `center`).

Colors use platform color syntax; hexadecimal colors are portable. Dimensions,
spacing, and font sizes are points on iOS and density-independent units on
Android. Both hosts use the same line-breaking, gap, min/max clamping, absolute
inset, and stretch/center/flex-end rules; text and image intrinsic sizes are
measured by the host-native control. Percentage dimensions, transforms, and
shadows remain outside the native renderer contract. Unsupported values are
ignored rather than interpreted as CSS.

Scroll content is measured with an unbounded scroll-axis constraint, so intrinsic
text and image sizes contribute to the content extent instead of collapsing to
zero when the viewport supplies an unspecified size.

## Images and scrolling

Use `{ uri: value }` for an image source. Data-image URIs and HTTPS URLs work on
both platforms. A source with no URI scheme resolves from the iOS asset catalog
or Android app assets, so the asset must be packaged separately under the same
name for a shared bundle. Plain HTTP, file URLs, and other schemes are rejected.
Invalid data, missing bundled images, failed HTTPS downloads, and unsupported
schemes clear stale pixels, log a diagnostic, and expose a short accessibility
error value. Route teardown and node removal cancel outstanding downloads.

`ScrollView` uses `horizontal` (or a row flex direction) to choose its axis and
renders its children as native views. `scrollEnabled`, the platform scroll
indicators, and nested scrolling are native. `onScroll` reports
`contentOffset`, `contentSize`, and `layoutMeasurement`; `onScrollBeginDrag`
and `onScrollEndDrag` report the corresponding gesture boundaries. Paging,
refresh controls, and momentum callbacks remain outside this versioned
contract. Use `ScrollView` for bounded content and `FlatList` for data sets that
need recycling.

## Recycling lists

`FlatList` compiles a keyed item template into retained native rows. iOS uses a
diffable `UICollectionView` data source; Android uses `RecyclerView`, stable
IDs, and `DiffUtil`. Inserts, updates, moves, and removals reuse unaffected rows
instead of rebuilding the list. Visible text inputs retain their draft, focus,
accessibility metadata, and event handlers, and keyed updates retain the
viewport anchor. The simulator and emulator suites exercise this contract with
10,000 rows without materializing the full data set.

```stx
<script>
let people = [{ id: 'ada', name: 'Ada' }, { id: 'grace', name: 'Grace' }]

function loadMore() {
  // Guard duplicate requests while an asynchronous load is in flight.
}
</script>

<FlatList
  data={people}
  keyExtractor={item.id}
  numColumns={2}
  onEndReached={loadMore}
  onEndReachedThreshold={0.2}
>
  <Text listRole="header">People</Text>
  <View listRole="item" accessibilityLabel={item.name}>
    <Text>{index}: {item.name}</Text>
  </View>
  <View listRole="separator" style="height: 1" />
  <Text listRole="empty">Nobody here</Text>
  <Text listRole="footer">End of people</Text>
</FlatList>
```

The item template can reference `item` and its zero-based `index`.
`keyExtractor` must produce a stable, unique value; moving an item with the
same key keeps its native row state. `horizontal`, `inverted`, and
`numColumns` select the native layout. `numColumns` applies to vertical lists;
header, separator, empty, and footer content span every column. Empty content
is shown only when the data set has no items. Separator content is inserted
between item rows, never before the first or after the last.

`onEndReachedThreshold` is the fraction of data rows allowed to remain when
`onEndReached` fires. Header, separator, empty, and footer nodes do not count
toward the threshold and a chrome-only list does not fire it. A given content
signature fires at most once, but appending data creates a new signature and
may fire again if the viewport is still within the threshold; handlers should
therefore guard concurrent pagination requests.

For backward compatibility, a `FlatList` without a `listRole="item"` template
keeps its existing static children. Older compiled bundles also continue to
use whole-document `RENDER`; the native host accepts both that path and the
incremental mutation protocol.

## Events, accessibility, and navigation

`onPress` and `onClick` deliver an empty `nativeEvent` from buttons and other
pressable native views. `TextInput` accepts `onChange` or `onChangeText` and
delivers `nativeEvent.text`; `onFocus`, `onBlur`, `onEndEditing`, and
`onSubmitEditing` are also native events. `keyboardType`, `returnKeyType`,
`autoCapitalize`, `autoCorrect`, `secureTextEntry`, `editable`, and `autoFocus`
map to the platform input control. `FlatList` supports `onEndReached`.
`ScrollView` emits the scroll callbacks described above.

`accessibilityLabel`, `accessibilityHint`, `accessibilityValue`,
`accessibilityState`, and `accessibilityRole` map to native accessibility
metadata and traits. The portable roles are `button`, `image`, `header`,
`link`, `search`, and `none`; unknown roles retain the platform control's
native class. `accessibilityState` supports `disabled`, `selected`, and
`checked`.

`craft.navigation.push`, `replace`, and `back` use the platform navigation
stack. A pushed route receives `craft.route.params`; returning to an earlier
route reveals its existing native tree and JavaScript state. Native events are
delivered only to the top route, and route teardown removes its subscriptions
and cancels its in-flight requests.

## Capability bridge

The generated iOS and Android hosts advertise a versioned capability bridge on
`globalThis.__stxNativeBridge`:

```ts
globalThis.craft.platform // 'ios' or 'android'
globalThis.craft.capabilityProtocolVersion // 1
globalThis.craft.capabilities.storage // true when enabled
globalThis.craft.capabilities.secureStorage // true when enabled
globalThis.craft.capabilities.biometric // true when enabled
```

The shared asynchronous surface is:

```ts
await craft.storage.set('profile', { name: 'Ada' })
const profile = await craft.storage.get('profile')
await craft.db.execute('CREATE TABLE IF NOT EXISTS notes (text TEXT)')
const notes = await craft.db.query('SELECT text FROM notes')
await craft.db.beginTransaction()
await craft.db.commit() // or await craft.db.rollback()

const stopState = craft.lifecycle.onStateChange((state) => console.log(state))
const state = craft.lifecycle.getState() // synchronous current state
const initial = await craft.deepLinks.getInitialURL()
const stopLinks = craft.deepLinks.onLink((link) => console.log(link.url))
const id = await craft.notifications.schedule({ title: 'Reminder', delay: 60_000 })
await craft.notifications.cancel(id)

await craft.secureStorage.set('session-token', 'secret')
const token = await craft.secureStorage.get('session-token')
await craft.secureStorage.delete('session-token')
const available = await craft.biometrics.isAvailable()
const biometricType = await craft.biometrics.getBiometricType()
if (available) await craft.biometrics.authenticate('Unlock WildLoop')
```

Storage is JSON-serializable and survives process termination. SQLite is stored
in the app's persistent data directory and supports typed string, number,
boolean, and null parameters. `execute` resolves to `{ rowsAffected,
lastInsertId }`; transaction methods resolve to `true` on success. Local
notification schedules are persisted by the OS on iOS and through
`AlarmManager` on Android, so they do not depend on a running JavaScript
process. The Android receiver is registered only for native-renderer projects.

`enableLocalDatabase`, `enableLocalNotifications`, and `enableDeepLinks` are
explicit configuration gates. `enableSecureStorage` and `enableBiometric` gate
the corresponding secure-storage and biometric methods. Secure storage accepts
string values and persists them in the iOS Keychain or Android encrypted
preferences; a missing key resolves to `null`. Biometric availability is a
device check, so an enabled simulator or emulator may still report `false`.
A disabled or unavailable capability rejects with
`CAPABILITY_DISABLED` or `NOT_SUPPORTED`; malformed keys, SQL, or notification
arguments reject with `INVALID_ARGUMENT`. Every request has a 30-second native
deadline. A timeout rejects with `TIMEOUT`, sends `API_CANCEL`, and native route
teardown cancels any remaining work. Unsupported protocol versions reject with
`UNSUPPORTED_VERSION`.

`deepLinks.getInitialURL()` claims the launch URL once for the native app
process. It can be called from any route, but later routes receive `null`; a
URL delivered through `deepLinks.onLink` is marked `initial: true`. URLs received
through a resumed activity or scene are marked `initial: false` and remain
available to subscribers even after the launch URL has been claimed. Android
persists the launch claim across activity recreation, so rotation and process
handoff do not replay a stale intent.

The old flat notification methods (`scheduleNotification`,
`cancelNotification`, `cancelAllNotifications`, and `getPendingNotifications`)
remain available as aliases. Existing device info, clipboard, haptics,
mutation, and legacy web-renderer behavior are unchanged. To migrate a web
screen, keep the existing `craft-native/mobile` calls and use the nested
capability methods only where persistence or native lifecycle behavior is
needed; browser-rendered apps continue using their existing web fallbacks.

## Verification

The repository exercises the same compiled multi-route fixture on both
platforms:

```bash
bun packages/ios/scripts/test-native-render.ts
bun packages/ios/scripts/test-native-navigation.ts
bun packages/android/scripts/test-native-navigation.ts
cd benchmarks && bun run bench:native-mutations
```

The iOS commands require macOS and a bootable simulator. The Android command
requires `ANDROID_HOME`, `adb`, Gradle, and a running emulator. CI is the source
of truth when those platform prerequisites are unavailable locally. The
host-neutral benchmark includes 100, 1,000, and 10,000-node full renders and
single-node mutations; the platform suites separately verify native recycling,
capability persistence across relaunch, and notification cancellation.
