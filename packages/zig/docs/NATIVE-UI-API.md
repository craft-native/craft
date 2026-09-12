# Native UI API Reference

## Overview

The Craft Native UI API provides native macOS AppKit components accessible from JavaScript. These components render as true native elements, not HTML/CSS, providing authentic macOS look and feel with Liquid Glass effects.

## JavaScript API

### Namespace

All native UI functions are available under `window.craft.nativeUI`.

```javascript
const { nativeUI } = window.craft;
```

Components belong to the window that creates them. IDs only need to be unique
within that window, so separate windows can both use IDs such as `sidebar` or
`files`. Closing a window preserves its components for reopen; permanently
destroying a typed window releases all of its Native UI components. Quick Look
uses macOS's app-wide shared preview panel, so opening it from another window
replaces the current preview.

### Ready Event

The API fires a ready event when initialized:

```javascript
document.addEventListener('craft:nativeui:ready', () => {
    console.log('Native UI is ready!');
});
```

---

## Components

### Sidebar

Native NSOutlineView-based sidebar with Liquid Glass material.

#### Creating a Sidebar

```javascript
const sidebar = nativeUI.createSidebar({
    id: 'my-sidebar'  // Optional, auto-generated if not provided
});
```

#### Methods

##### `sidebar.addSection(section)`

Adds a collapsible section to the sidebar.

```javascript
sidebar.addSection({
    id: 'favorites',           // Required: unique section identifier
    header: 'FAVORITES',       // Optional: section header text (uppercase recommended)
    items: [                   // Required: array of items
        {
            id: 'home',        // Required: unique item identifier
            label: 'Home',     // Required: display text
            icon: 'house',     // Optional: SF Symbol name
            badge: '3'         // Optional: badge text
        },
        {
            id: 'documents',
            label: 'Documents',
            icon: 'doc.on.doc'
        }
    ]
});
```

##### `sidebar.setSelectedItem(itemId)`

Programmatically selects an item.

```javascript
sidebar.setSelectedItem('documents');
```

##### `sidebar.onSelect(callback)`

Registers a callback for selection events.

```javascript
sidebar.onSelect((itemId) => {
    console.log('Selected:', itemId);
});
```

##### `sidebar.destroy()`

Removes the sidebar and cleans up resources.

```javascript
sidebar.destroy();
```

---

### FileBrowser

Native NSTableView-based file browser with sortable columns.

#### Creating a File Browser

```javascript
const browser = nativeUI.createFileBrowser({
    id: 'my-browser'  // Optional
});
```

#### Methods

##### `browser.addFile(file)`

Adds a single file to the browser.

```javascript
browser.addFile({
    id: 'file-1',              // Required: unique identifier
    name: 'document.pdf',      // Required: file name
    icon: 'doc.richtext',      // Optional: SF Symbol name
    dateModified: 'Dec 1, 2024', // Optional: date string
    size: '2.4 MB',            // Optional: size string
    kind: 'PDF Document'       // Optional: file type
});
```

##### `browser.addFiles(files)`

Adds multiple files at once (more efficient for large datasets).

```javascript
browser.addFiles([
    { id: 'file-1', name: 'readme.md', icon: 'doc.text' },
    { id: 'file-2', name: 'index.js', icon: 'chevron.left.forwardslash.chevron.right' },
    { id: 'file-3', name: 'styles.css', icon: 'paintbrush' }
]);
```

##### `browser.clearFiles()`

Removes all files from the browser.

```javascript
browser.clearFiles();
```

##### `browser.onSelect(callback)`

Registers a callback for single-click selection.

```javascript
browser.onSelect((fileId) => {
    console.log('Selected file:', fileId);
});
```

##### `browser.onDoubleClick(callback)`

Registers a callback for double-click events.

```javascript
browser.onDoubleClick((fileId) => {
    console.log('Opening file:', fileId);
    // Open file, navigate to folder, etc.
});
```

##### `browser.destroy()`

Removes the file browser and cleans up resources.

```javascript
browser.destroy();
```

---

### SplitView

Combines sidebar and file browser with a resizable divider.

#### Creating a Split View

```javascript
const sidebar = nativeUI.createSidebar({ id: 'sidebar' });
const browser = nativeUI.createFileBrowser({ id: 'browser' });

const splitView = nativeUI.createSplitView({
    id: 'main-split',      // Optional
    sidebar: sidebar,       // Required: Sidebar instance
    browser: browser        // Required: FileBrowser instance
});
```

#### Methods

##### `splitView.setDividerPosition(position)`

Sets the divider position in pixels.

```javascript
splitView.setDividerPosition(250);  // 250px sidebar width
```

##### `splitView.destroy()`

Removes the split view and all child components.

```javascript
splitView.destroy();
```

---

## SF Symbol Icons

The native UI uses Apple's SF Symbols for icons. Here are commonly used symbols:

### Navigation

- `house` - Home
- `folder` - Folder
- `doc` - Document
- `gear` - Settings
- `magnifyingglass` - Search

### Files

- `doc.text` - Text document
- `doc.richtext` - Rich text/PDF
- `photo` - Image
- `film` - Video
- `music.note` - Audio
- `doc.zipper` - Archive

### Actions

- `plus` - Add
- `minus` - Remove
- `trash` - Delete
- `pencil` - Edit
- `checkmark` - Done

### Communication

- `envelope` - Email
- `message` - Message
- `phone` - Phone
- `video` - Video call

### System

- `icloud` - iCloud
- `network` - Network
- `externaldrive` - External drive
- `laptopcomputer` - Mac
- `clock` - Recent/Time

### Status

- `circle.fill` - Filled circle (for tags)
- `checkmark.circle` - Success
- `xmark.circle` - Error
- `exclamationmark.triangle` - Warning

For a complete list, see [SF Symbols App](https://developer.apple.com/sf-symbols/).

---

## Best Practices

### 1. Batch File Operations

For large file lists, use `addFiles()` instead of multiple `addFile()` calls:

```javascript
// Good - single batch operation
browser.addFiles(filesArray);

// Avoid - multiple individual calls
filesArray.forEach(f => browser.addFile(f));  // Slow!
```

### 2. Use Meaningful IDs

Use descriptive, unique IDs for components and items:

```javascript
// Good
{ id: 'project-settings', label: 'Settings' }

// Avoid
{ id: 'item-1', label: 'Settings' }
```

### 3. Handle Ready State

Always wait for the native UI to be ready:

```javascript
function initUI() {
    if (!window.craft?.nativeUI) {
        setTimeout(initUI, 100);
        return;
    }
    // Initialize components
}

document.addEventListener('DOMContentLoaded', initUI);
```

### 4. Clean Up Resources

Destroy components when no longer needed:

```javascript
// When navigating away or closing
sidebar.destroy();
browser.destroy();
```

### 5. Progressive Loading

For very large datasets, load in batches:

```javascript
async function loadFiles(files) {
    const batchSize = 100;
    for (let i = 0; i < files.length; i += batchSize) {
        browser.addFiles(files.slice(i, i + batchSize));
        await new Promise(r => setTimeout(r, 10));  // Let UI update
    }
}
```

---

## Error Handling

The API throws errors for invalid usage:

```javascript
try {
    const splitView = nativeUI.createSplitView({});
} catch (e) {
    // "createSplitView requires both sidebar and browser options"
}
```

Check for bridge availability:

```javascript
if (!window.webkit?.messageHandlers?.craft) {
    console.error('Not running in Craft environment');
    return;
}
```

---

## Performance Characteristics

| Operation | 100 files | 1,000 files | 10,000 files |
|-----------|-----------|-------------|--------------|
| addFiles() | ~5ms | ~50ms | ~500ms |
| clearFiles() | ~1ms | ~5ms | ~20ms |
| Selection | <1ms | <1ms | <1ms |

Recommendations:

- Up to 1,000 files: Load all at once
- 1,000-5,000 files: Load in batches of 500
- 5,000+ files: Consider pagination or virtualization
