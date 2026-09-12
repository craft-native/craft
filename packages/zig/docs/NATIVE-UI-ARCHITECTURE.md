# Native UI Architecture

## Overview

The Craft Native UI system provides native macOS AppKit components accessible from JavaScript through a bridge architecture. This document explains the internal architecture, component lifecycle, and memory management.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         JavaScript                               │
│  window.craft.nativeUI.createSidebar() ───────────────────────┐ │
│  window.craft.nativeUI.createFileBrowser() ───────────────────┤ │
│  sidebar.addSection() ────────────────────────────────────────┤ │
│  browser.addFiles() ──────────────────────────────────────────┤ │
└───────────────────────────────────────────────────────────────│─┘
                                                                │
┌───────────────────────────────────────────────────────────────│─┐
│                        WKWebView Bridge                       │ │
│  window.webkit.messageHandlers.craft.postMessage() ◄──────────┘ │
│                            │                                    │
│                            ▼                                    │
│  handleBridgeMessage() ─── JSON parsing ─── Route to handler    │
└───────────────────────────────────────────────────────────────│─┘
                                                                │
┌───────────────────────────────────────────────────────────────│─┐
│                     Zig Native UI Bridge                      │ │
│                                                               │ │
│  NativeUIBridge                                               │ │
│  └── window*states: AutoHashMap(NSWindow, WindowState)        │ │
│      ├── sidebars: StringHashMap(*NativeSidebar)              │ │
│      ├── file*browsers: StringHashMap(*NativeFileBrowser)     │ │
│      ├── split*views: StringHashMap(*NativeSplitView)         │ │
│      ├── space*switcher: ?*SpaceSwitcher                      │ │
│      └── active*context*menu*delegate                         │ │
│                            │                                   │ │
│                            ▼                                   │ │
│  handleMessage(action, data) ─────────────────────────────────┤ │
│  ├── "createSidebar"    → createSidebar()                     │ │
│  ├── "addSidebarSection" → addSidebarSection()                │ │
│  ├── "createFileBrowser" → createFileBrowser()                │ │
│  ├── "addFiles"          → addFiles()                         │ │
│  └── "destroyComponent"  → destroyComponent()                 │ │
└───────────────────────────────────────────────────────────────│─┘
                                                                │
┌───────────────────────────────────────────────────────────────│─┐
│                    Native Components (Zig)                    │ │
│                                                               │ │
│  NativeSidebar                    NativeFileBrowser           │ │
│  ├── scroll*view (NSScrollView)   ├── scroll*view             │ │
│  ├── outline*view (NSOutlineView) ├── table*view (NSTableView)│ │
│  ├── data*source                  ├── data*source             │ │
│  └── delegate                     └── delegate                │ │
│                                                               │ │
│  OutlineViewDataSource            TableViewDataSource         │ │
│  ├── objc*class (dynamic)         ├── objc*class (dynamic)    │ │
│  ├── instance                     ├── instance                │ │
│  └── DataStore                    └── DataStore               │ │
│      └── sections[]                   └── files[]             │ │
│          └── items[]                                          │ │
└───────────────────────────────────────────────────────────────│─┘
                                                                │
┌───────────────────────────────────────────────────────────────│─┐
│                      AppKit (Objective-C)                     │ │
│                                                               │ │
│  NSSplitViewController                                        │ │
│  ├── sidebar (NSViewController + NSOutlineView)               │ │
│  └── content (NSViewController + WKWebView)                   │ │
│                                                               │ │
│  Window                                                       │ │
│  └── contentViewController = NSSplitViewController            │ │
└───────────────────────────────────────────────────────────────┘
```

## Component Hierarchy

### NativeSidebar

```
NativeSidebar
├── allocator: std.mem.Allocator
├── scroll*view: NSScrollView
│   └── documentView: NSOutlineView
├── outline*view: NSOutlineView
│   ├── dataSource → OutlineViewDataSource.instance
│   └── delegate → OutlineViewDelegate.instance
├── data*source: OutlineViewDataSource
│   ├── objc*class: Class (CraftOutlineViewDataSource)
│   ├── instance: id
│   └── data: *DataStore
│       └── sections: ArrayList(Section)
│           └── items: ArrayList(Item)
└── delegate: OutlineViewDelegate
    ├── objc*class: Class (CraftOutlineViewDelegate)
    ├── instance: id
    └── callback*data: *CallbackData
```

### NativeFileBrowser

```
NativeFileBrowser
├── allocator: std.mem.Allocator
├── scroll*view: NSScrollView
│   └── documentView: NSTableView
├── table*view: NSTableView
│   ├── columns: [name, dateModified, size, kind]
│   ├── dataSource → TableViewDataSource.instance
│   └── delegate → TableViewDelegate.instance
├── data*source: TableViewDataSource
│   ├── objc*class: Class (CraftTableViewDataSource)
│   ├── instance: id
│   └── data: *DataStore
│       └── files: ArrayList(FileItem)
└── delegate: TableViewDelegate
    ├── objc*class: Class (CraftTableViewDelegate)
    ├── instance: id
    └── callback*data: *CallbackData
```

## Dynamic Objective-C Classes

The native components create Objective-C classes at runtime using the ObjC runtime API:

```zig
// Create class
var objc*class = objc.objc*allocateClassPair(NSObject, "CraftOutlineViewDataSource", 0);

// Add methods

* = objc.class*addMethod(

    objc*class,
    sel("outlineView:numberOfChildrenOfItem:"),
    @ptrCast(&outlineViewNumberOfChildrenOfItem),
    "l@:@@"  // return type and argument encoding
);

// Register class
objc.objc*registerClassPair(objc*class);

// Create instance
const instance = msgSend0(msgSend0(objc*class, "alloc"), "init");
```

### Method Implementations

Each data source and delegate method is implemented as an exported Zig function:

```zig
export fn outlineViewNumberOfChildrenOfItem(
    self: objc.id,      // The ObjC instance
    *: objc.SEL,        // The selector (unused)
    *: objc.id,         // outlineView
    item: objc.id,      // The item (nil for root)
) callconv(.c) c*long {
    // Get Zig data from associated object
    const data = getDataStore(self) orelse return 0;

    if (item == null) {
        return @intCast(data.sections.items.len);
    }
    // ... handle children
}
```

## Memory Management

### Ownership Model

1. **Zig owns component structs**: `NativeSidebar`, `NativeFileBrowser`, etc.
2. **Zig allocates ObjC instances**: Created via `alloc`/`init`
3. **Bridge tracks all components**: `StringHashMap` stores pointers
4. **Explicit cleanup required**: Call `deinit()` to release

### Reference Counting

```zig
pub fn deinit(self: *NativeSidebar) void {
    // Release Objective-C instances
    if (self.scroll*view != null) {

        * = msgSend0(self.scroll*view, "release");

    }
    if (self.outline*view != null) {

        * = msgSend0(self.outline*view, "release");

    }

    // Clean up data source and delegate
    self.data*source.deinit();
    self.delegate.deinit();

    // Free Zig allocations
    self.allocator.destroy(self.data*source);
    self.allocator.destroy(self.delegate);
}
```

### Associated Objects

Zig data pointers are stored in ObjC instances using associated objects:

```zig
// Store pointer
const data*value = msgSend1(NSValue, "valueWithPointer:", @ptrFromInt(data*ptr));
objc.objc*setAssociatedObject(
    instance,
    @ptrFromInt(0x1234),  // Unique key
    data*value,
    OBJC*ASSOCIATION*RETAIN
);

// Retrieve pointer
fn getDataStore(instance: objc.id) ?*DataStore {
    const associated = objc.objc*getAssociatedObject(instance, @ptrFromInt(0x1234));
    if (associated == null) return null;

    const ptr = msgSend0(associated, "pointerValue");
    return @ptrCast(@alignCast(ptr));
}
```

## Component Lifecycle

### Window ownership

Native UI component IDs are scoped to the window whose `WKWebView` posted the
bridge message. The dispatcher derives that window from `WKScriptMessage`; it
does not trust a window ID supplied by JavaScript. This means two windows may
use the same component ID without sharing state or targeting each other's
views.

Ordinary window close retains both the page and its Native UI state so the
window can reopen intact. `window.destroy()` is permanent: before AppKit
releases the window, Craft removes only that window's `WindowState`. Delayed
target/action callbacks, such as a spaces-switcher selection, retain the
owning webview explicitly because bridge sender context ends when dispatch
returns.

Keyboard handlers use Objective-C associated objects on each outline/table
view and monitor instance. A sidebar or file browser therefore reads only its
own space/return callbacks; creating a component in another window cannot
replace them.

The older whole-window native-sidebar constructors use the same ownership
rule. Their parsed section arena, material options, webview, toggle button, and
collapsed state live in a bounded slot keyed by `NSWindow`; the data-source
object carries a reference to that slot. Destroying the window clears just its
slot and parse arena.

Quick Look is the exception. `QLPreviewPanel` is a shared AppKit panel, so its
controller is intentionally app-scoped; showing it from another window
replaces the shared panel's contents.

### Creation

Creation is transactional. Each per-window registry reserves capacity before
allocating its component and owned ID, and publishes the entry only after the
native view has been installed. An allocation or setup error therefore unwinds
the temporary objects without leaving a dangling component ID behind.

```

1. JavaScript: nativeUI.createSidebar({ id: 'main' })
2. Bridge receives: { type: 'nativeUI', action: 'createSidebar', data: { id: 'main' } }
3. NativeUIBridge.createSidebar():

   a. Parse JSON
   b. Create NativeSidebar.init()

      - Create NSScrollView
      - Create NSOutlineView
      - Create OutlineViewDataSource (dynamic ObjC class)
      - Create OutlineViewDelegate (dynamic ObjC class)
      - Connect data source and delegate

   c. Resolve the authenticated sending window
   d. Store in that window's sidebars hashmap
   e. Add to that window via NSSplitViewController

4. Return Sidebar instance to JavaScript

```

### Data Update

```

1. JavaScript: sidebar.addSection({ id: 'nav', items: [...] })
2. Bridge receives: { type: 'nativeUI', action: 'addSidebarSection', data: {...} }
3. NativeUIBridge.addSidebarSection():

   a. Parse JSON
   b. Find sidebar by ID
   c. Append section to DataStore.sections
   d. Call outline*view.reloadData()

4. NSOutlineView queries data source for new data
5. Delegate creates cell views with SF Symbol icons

```

### Destruction

```

1. JavaScript: sidebar.destroy()
2. Bridge receives: { type: 'nativeUI', action: 'destroyComponent', data: { id: 'main', type: 'sidebar' } }
3. NativeUIBridge.destroyComponent():

   a. Find and remove from hashmap
   b. Call sidebar.deinit()

      - Release NSScrollView
      - Release NSOutlineView
      - Destroy data source (release ObjC instance, free DataStore)
      - Destroy delegate (release ObjC instance, free CallbackData)

   c. Free hashmap key string

4. Component removed from view hierarchy

```

## Thread Safety

All native UI operations must occur on the main thread. The WKWebView bridge automatically dispatches to the main thread:

```zig
// Bridge message handler runs on main thread
pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
    // Safe to create/modify AppKit objects here
}
```

## Error Handling

### Edge Cases

1. **Empty data**: Return empty collections, don't crash
2. **Malformed JSON**: Log error, return early
3. **Missing components**: Log warning, no-op
4. **Destroyed bridge**: Check `is*destroyed` flag

```zig
pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
    if (self.is*destroyed) {
        std.debug.print("WARNING: Message after bridge destroyed\n", .{});
        return;
    }

    if (action.len == 0) {
        std.debug.print("WARNING: Empty action\n", .{});
        return;
    }

    // ... handle message
}
```

### Error Propagation

Errors are logged but not propagated to JavaScript (no callback mechanism yet):

```zig
self.createSidebar(data) catch |err| {
    std.debug.print("ERROR creating sidebar: {any}\n", .{err});
};
```

## SF Symbols Integration

Icons use Apple's SF Symbols via NSImage:

```zig
pub fn createSFSymbol(name: [*:0]const u8, config: SymbolConfiguration) ?objc.id {
    const NSImage = macos.getClass("NSImage");
    const nsstring = macos.createNSString(std.mem.span(name));

    // Create symbol image
    const image = macos.msgSend2(
        NSImage,
        "imageWithSystemSymbolName:accessibilityDescription:",
        nsstring,
        @as(objc.id, null)
    );

    // Apply configuration (size, weight)
    if (config.point*size != 17.0) {
        const symbol*config = createSymbolConfiguration(config);
        return macos.msgSend1(image, "imageWithSymbolConfiguration:", symbol*config);
    }

    return image;
}
```

## Performance Considerations

### Batch Operations

Use `addFiles()` instead of multiple `addFile()` calls:

```zig
fn addFiles(self: *Self, data: []const u8) !void {
    // Parse files array
    // Append all to data store
    // Single reloadData() call
}
```

### Debouncing

Rapid updates are debounced to prevent excessive redraws:

```zig
fn shouldDebounceReload(self: *Self) bool {
    const now = std.time.milliTimestamp();
    if (now - self.last*reload*time < RELOAD*DEBOUNCE*MS) {
        return true;
    }
    self.last*reload*time = now;
    return false;
}
```

### Cell Reuse

NSOutlineView and NSTableView automatically reuse cell views:

```zig
// Try to reuse existing cell
var cellView = msgSend2(outlineView, "makeViewWithIdentifier:owner:", identifier, null);

if (cellView == null) {
    // Create new cell only if needed
    cellView = createNewCellView();
}

// Update cell content
updateCellView(cellView, data);
```

## Future Enhancements

1. **Drag and Drop**: NSDraggingSource/NSDraggingDestination protocols
2. **Context Menus**: NSMenu creation and event handling
3. **Quick Look**: QLPreviewPanel integration
4. **Callbacks to JS**: evaluateJavaScript for event callbacks
5. **Multi-selection**: NSTableView multi-select support
