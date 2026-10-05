# Native APIs

Craft provides access to native system APIs, enabling deep integration with the operating system.

## Overview

Native APIs include:

- **Notifications**: System notifications
- **Clipboard**: Read/write clipboard
- **File Dialogs**: Open, save, select directories
- **System Info**: OS, CPU, memory, battery
- **Shell**: Open URLs, files, folders
- **Haptic Feedback**: Force Touch trackpad taps (macOS), through the same API as mobile

## Notifications

### Show Notification

```typescript
import { showNotification } from 'craft-native'

await showNotification({
  title: 'Download Complete',
  body: 'Your file has been downloaded.',
  icon: './assets/icon.png',
})
```

### Notification with Actions

```typescript
const notification = await showNotification({
  title: 'New Message',
  body: 'You have a new message from John',
  actions: [
    { id: 'reply', title: 'Reply' },
    { id: 'dismiss', title: 'Dismiss' },
  ],
})

notification.on('action', (actionId) => {
  if (actionId === 'reply') {
    openReplyWindow()
  }
})

notification.on('click', () => {
  focusMainWindow()
})
```

### Notification Options

| Option | Type | Description |
|--------|------|-------------|
| `title` | string | Notification title |
| `body` | string | Notification message |
| `icon` | string | Path to icon |
| `urgency` | string | `'low'`, `'normal'`, `'critical'` |
| `actions` | array | Action buttons |
| `silent` | boolean | Suppress sound |

## Clipboard

### Read/Write Text

```typescript
import { clipboard } from 'craft-native'

// Write text
await clipboard.writeText('Hello, World!')

// Read text
const text = await clipboard.readText()
console.log(text) // "Hello, World!"
```

### Read/Write Image

```typescript
// Write image
const imageBuffer = await Bun.file('./image.png').arrayBuffer()
await clipboard.writeImage(imageBuffer)

// Read image
const image = await clipboard.readImage()
if (image) {
  await Bun.write('./pasted.png', image)
}
```

### Read/Write HTML

```typescript
// Write HTML
await clipboard.writeHTML('<b>Bold text</b>')

// Read HTML
const html = await clipboard.readHTML()
```

### Clipboard Formats

```typescript
// Check available formats
const formats = await clipboard.availableFormats()
console.log(formats) // ['text/plain', 'text/html', 'image/png']

// Read specific format
const data = await clipboard.read('text/html')
```

### Watch Clipboard

```typescript
clipboard.on('change', async () => {
  const text = await clipboard.readText()
  console.log('Clipboard changed:', text)
})
```

## File Dialogs

### Open File Dialog

```typescript
import { dialog } from 'craft-native'

const result = await dialog.showOpenDialog({
  title: 'Open Document',
  filters: [
    { name: 'Documents', extensions: ['txt', 'md', 'doc'] },
    { name: 'All Files', extensions: ['*'] },
  ],
  defaultPath: '~/Documents',
})

if (!result.canceled) {
  const filePath = result.filePaths[0]
  const content = await Bun.file(filePath).text()
}
```

### Open Multiple Files

```typescript
const result = await dialog.showOpenDialog({
  title: 'Select Files',
  multiple: true,
  filters: [{ name: 'Images', extensions: ['png', 'jpg', 'gif'] }],
})

for (const path of result.filePaths) {
  await processImage(path)
}
```

### Save File Dialog

```typescript
const result = await dialog.showSaveDialog({
  title: 'Save Document',
  defaultPath: '~/Documents/untitled.txt',
  filters: [
    { name: 'Text Files', extensions: ['txt'] },
    { name: 'Markdown', extensions: ['md'] },
  ],
})

if (!result.canceled) {
  await Bun.write(result.filePath, content)
}
```

### Select Directory

```typescript
const result = await dialog.showOpenDialog({
  title: 'Select Output Directory',
  properties: ['openDirectory', 'createDirectory'],
})

if (!result.canceled) {
  const outputDir = result.filePaths[0]
  await exportFiles(outputDir)
}
```

### Message Box

```typescript
const result = await dialog.showMessageBox({
  type: 'question',
  title: 'Confirm',
  message: 'Do you want to save changes?',
  detail: 'Your changes will be lost if you don\'t save them.',
  buttons: ['Save', 'Don\'t Save', 'Cancel'],
  defaultId: 0,
  cancelId: 2,
})

if (result.response === 0) {
  await saveDocument()
}
```

## System Information

### OS Information

```typescript
import { system } from 'craft-native'

const os = await system.getOsInfo()
console.log(os)
// {
//   name: 'macOS',
//   version: '14.0',
//   arch: 'arm64',
//   hostname: 'MacBook-Pro.local',
// }
```

### CPU Information

```typescript
const cpu = await system.getCpuInfo()
console.log(cpu)
// {
//   brand: 'Apple M1 Pro',
//   cores: 10,
//   frequency: 3228,
//   usage: 15.5,
// }
```

### Memory Information

```typescript
const memory = await system.getMemoryInfo()
console.log(memory)
// {
//   total: 17179869184,      // 16 GB
//   available: 8589934592,   // 8 GB
//   used: 8589934592,        // 8 GB
//   usedPercent: 50,
// }
```

### Battery Information

```typescript
const battery = await system.getBatteryInfo()
console.log(battery)
// {
//   level: 85,
//   isCharging: true,
//   timeRemaining: 180,  // minutes
// }
```

### Disk Information

```typescript
const disks = await system.getDiskInfo()
disks.forEach((disk) => {
  console.log(`${disk.name}: ${disk.available}/${disk.total} free`)
})
```

## Shell Integration

### Open URL

```typescript
import { shell } from 'craft-native'

// Open in default browser
await shell.openExternal('https://example.com')

// Open email
await shell.openExternal('mailto:hello@example.com')
```

### Open File

```typescript
// Open with default application
await shell.openPath('/path/to/document.pdf')
```

### Show in File Manager

```typescript
// Show in Finder/Explorer
await shell.showItemInFolder('/path/to/file.txt')
```

### Open Folder

```typescript
// Open folder in file manager
await shell.openPath('/path/to/folder')
```

### Move to Trash

```typescript
await shell.trashItem('/path/to/file.txt')
```

## Power Management

### Prevent Sleep

```typescript
import { power } from 'craft-native'

// Prevent system from sleeping
const id = await power.preventSleep('Processing files')

// ... do work ...

// Allow sleep again
await power.allowSleep(id)
```

### Power Events

```typescript
power.on('suspend', () => {
  console.log('System is going to sleep')
  saveState()
})

power.on('resume', () => {
  console.log('System woke up')
  restoreState()
})

power.on('low-battery', () => {
  showNotification({
    title: 'Low Battery',
    body: 'Please save your work',
    urgency: 'critical',
  })
})
```

## Screen Information

### Get Screens

```typescript
import { screen } from 'craft-native'

const screens = await screen.getAllDisplays()
screens.forEach((display) => {
  console.log(`${display.id}: ${display.width}x${display.height} @ ${display.scaleFactor}x`)
})
```

### Primary Screen

```typescript
const primary = await screen.getPrimaryDisplay()
console.log(`Primary: ${primary.width}x${primary.height}`)
```

### Screen at Point

```typescript
const display = await screen.getDisplayNearestPoint(100, 200)
```

## Haptic Feedback

On macOS the `haptics` helpers the mobile apps use play on the Force Touch
trackpad, so one call works on every host.

```typescript
import { haptics } from 'craft-native'

await haptics.selection() // Alignment: a value snapping into place
await haptics.impact('heavy') // LevelChange: the firmest tap
await haptics.notification('success') // Generic
```

A trackpad has three patterns rather than a phone's range, so styles are
folded: `selection` plays Alignment, `heavy` and `error` play LevelChange, and
everything else plays Generic. `vibrate(pattern)` plays one tap if the pattern
asks for anything, since a trackpad tap has no duration.

AppKit plays feedback only while a finger is on the trackpad and the app is
active, and stays silent on a Mac without a Force Touch trackpad. The call
still succeeds: it means AppKit accepted the tap, not that it was felt. On
Linux and Windows the helpers resolve without doing anything, and the raw
`window.craft.haptic(style)` rejects with `PLATFORM_NOT_SUPPORTED` for code
that needs to know. See the [Haptics API](../api/mobile/haptics.md).

## URL Schemes

### Register URL Scheme

```typescript
import { app } from 'craft-native'

// Register custom URL scheme (craft://...)
app.setAsDefaultProtocolClient('craft')

// Handle URL opens
app.on('open-url', (url) => {
  console.log('Opened URL:', url)
  // url = "craft://action?param=value"
  handleDeepLink(url)
})
```

### Handle Deep Links

```typescript
app.on('open-url', (url) => {
  const parsed = new URL(url)

  switch (parsed.pathname) {
    case 'open':
      openDocument(parsed.searchParams.get('file'))
      break
    case 'settings':
      showSettings()
      break
  }
})
```

## Application Info

### Get App Info

```typescript
import { app } from 'craft-native'

console.log(app.getName()) // "My App"
console.log(app.getVersion()) // "1.0.0"
console.log(app.getPath('userData')) // "~/Library/Application Support/MyApp"
console.log(app.getPath('temp')) // "/tmp"
console.log(app.getPath('documents')) // "~/Documents"
```

### App Paths

| Path | Description |
|------|-------------|
| `home` | User's home directory |
| `appData` | App data directory |
| `userData` | User data directory |
| `temp` | Temporary directory |
| `documents` | Documents directory |
| `downloads` | Downloads directory |
| `desktop` | Desktop directory |

## Best Practices

### Permission Handling

```typescript
// Check permission before accessing
const hasPermission = await system.checkPermission('camera')

if (!hasPermission) {
  const granted = await system.requestPermission('camera')
  if (!granted) {
    showNotification({
      title: 'Permission Required',
      body: 'Camera access is required for this feature',
    })
    return
  }
}
```

### Error Handling

```typescript
try {
  await shell.openPath('/path/to/file')
}
catch (error) {
  showNotification({
    title: 'Error',
    body: `Could not open file: ${error.message}`,
  })
}
```

### Platform Detection

```typescript
import { platform } from 'craft-native'

if (platform === 'darwin') {
  // macOS-specific code
}
else if (platform === 'win32') {
  // Windows-specific code
}
else {
  // Linux code
}
```

## Next Steps

- [Window Management](/features/window-management) - Window control
- [IPC Communication](/features/ipc-communication) - Native-web bridge
- [Advanced Configuration](/advanced/configuration) - System settings
