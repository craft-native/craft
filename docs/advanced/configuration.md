# Advanced Configuration

This guide covers advanced configuration options for Craft applications.

## Configuration Hierarchy

Craft loads configuration in this order (later overrides earlier):

1. Default values
2. `craft.toml` / `craft.json` / `craft.config.ts`
3. Environment variables
4. Command-line arguments
5. Programmatic configuration

## Complete Configuration Reference

### TypeScript Configuration

```typescript
// craft.config.ts
import type { CraftConfig } from 'craft-native'
import os from 'node:os'
import path from 'node:path'

export default {
  // Application Identity
  name: 'my-app',
  version: '1.0.0',
  description: 'A cross-platform desktop application',
  author: 'Your Name <you@example.com>',
  license: 'MIT',

  // Application IDs
  appId: 'com.mycompany.myapp',
  bundleId: 'com.mycompany.myapp', // macOS
  productName: 'My App',

  // Window Configuration
  window: {
    title: 'My App',
    icon: './assets/icon.png',

    // Size
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    maxWidth: 1920,
    maxHeight: 1080,

    // Position
    x: undefined, // Auto
    y: undefined, // Auto
    center: true,

    // Appearance
    frameless: false,
    transparent: false,
    resizable: true,
    movable: true,
    minimizable: true,
    maximizable: true,
    closable: true,
    focusable: true,

    // Behavior
    alwaysOnTop: false,
    fullscreen: false,
    fullscreenable: true,
    simpleFullscreen: false,
    skipTaskbar: false,
    kiosk: false,

    // Initial State
    show: true,
    maximized: false,
    minimized: false,

    // Background
    backgroundColor: '#ffffff',
    vibrancy: undefined, // macOS only

    // Title Bar
    titleBarStyle: 'default', // 'default' | 'hidden' | 'hiddenInset'
    titleBarOverlay: false,
  },

  // Webview Configuration
  webview: {
    // Developer Tools
    devTools: process.env.NODE_ENV === 'development',

    // JavaScript
    javascript: true,
    javascriptCanOpenWindows: false,
    javascriptCanAccessClipboard: true,

    // Storage
    localStorage: true,
    sessionStorage: true,
    indexedDB: true,
    webSQL: false,

    // Media
    autoplayMedia: false,
    webgl: true,
    webgpu: false,

    // Security
    webSecurity: true,
    allowRunningInsecureContent: false,
    contentSecurityPolicy: undefined,

    // Network
    proxyRules: undefined,
    proxyBypassList: undefined,

    // Appearance
    darkMode: 'auto', // 'auto' | 'light' | 'dark'
    transparentBackground: false,
    defaultFontSize: 16,
    defaultMonospaceFontSize: 13,
    minimumFontSize: 0,

    // User Agent
    userAgent: undefined,

    // Zoom
    zoomFactor: 1.0,
    zoomLevel: 0,

    // Spell Check
    spellcheck: true,
    spellcheckLanguages: ['en-US'],

    // Hot Reload
    hotReload: process.env.NODE_ENV === 'development',
    hotReloadIgnore: ['node_modules/**'],
  },

  // Build Configuration
  build: {
    outDir: './dist',
    assetsDir: './assets',
    resourcesDir: './resources',

    // Targets
    target: ['macos', 'linux', 'windows'],

    // macOS
    mac: {
      target: ['dmg', 'pkg'],
      arch: ['arm64', 'x64'],
      category: 'public.app-category.productivity',
      entitlements: './build/entitlements.mac.plist',
      icon: './assets/icon.icns',
      hardenedRuntime: true,
      gatekeeperAssess: true,
    },

    // Windows
    win: {
      target: ['msi', 'nsis'],
      arch: ['x64'],
      icon: './assets/icon.ico',
      requestedExecutionLevel: 'asInvoker',
    },

    // Linux
    linux: {
      target: ['deb', 'rpm', 'AppImage'],
      arch: ['x64'],
      icon: './assets/icon.png',
      category: 'Utility',
    },

    // Code Signing
    signing: {
      mac: {
        identity: process.env.APPLE_IDENTITY,
        teamId: process.env.APPLE_TEAM_ID,
      },
      win: {
        certificateFile: process.env.WIN_CSC_LINK,
        certificatePassword: process.env.WIN_CSC_KEY_PASSWORD,
      },
    },
  },

  // Development
  dev: {
    port: 3000,
    host: 'localhost',
    hotReload: true,
    watch: ['./src/**/*', './assets/**/*'],
    ignore: ['./node_modules/**', './.git/**'],
    openDevTools: true,
  },

  // Plugins
  plugins: [],

  // Hooks
  hooks: {
    'before:build': async () => {},
    'after:build': async () => {},
    'before:package': async () => {},
    'after:package': async () => {},
  },
} satisfies CraftConfig
```

### TOML Configuration

```toml
# craft.toml

[package]
name = "my-app"
version = "1.0.0"
description = "A cross-platform desktop application"
author = "Your Name <you@example.com>"
license = "MIT"
appId = "com.mycompany.myapp"

[window]
title = "My App"
width = 1200
height = 800
minWidth = 800
minHeight = 600
center = true
resizable = true
frameless = false
transparent = false
alwaysOnTop = false

[webview]
devTools = false
darkMode = "auto"
javascript = true
localStorage = true
webSecurity = true
hotReload = false

[build]
outDir = "./dist"
target = ["macos", "linux", "windows"]

[build.mac]
target = ["dmg"]
arch = ["arm64", "x64"]

[build.win]
target = ["msi"]
arch = ["x64"]

[build.linux]
target = ["deb", "AppImage"]
arch = ["x64"]

[dev]
port = 3000
hotReload = true
watch = ["./src/**/*"]
```

## Environment Variables

### Supported Variables

```bash
# Application
CRAFT_APP_NAME=my-app
CRAFT_APP_VERSION=1.0.0

# Window
CRAFT_WINDOW_WIDTH=1200
CRAFT_WINDOW_HEIGHT=800
CRAFT_WINDOW_TITLE="My App"

# Webview
CRAFT_DEVTOOLS=true
CRAFT_DARK_MODE=true
CRAFT_HOT_RELOAD=true

# Build
CRAFT_BUILD_TARGET=macos,linux,windows

# Development
CRAFT_DEV_PORT=3000
CRAFT_ALLOW_LOCAL_TLS=1
NODE_ENV=development
```

### `CRAFT_ALLOW_LOCAL_TLS`

A development proxy that fronts your local services over HTTPS — rpx, or
anything else using a locally issued certificate — presents a certificate
signed by a CA that is not a public root. The webview rejects it, the
navigation fails, and you get a blank window with no explanation on something
like `https://dashboard.myapp.localhost`.

Setting this variable tells Craft to accept that certificate:

```bash
CRAFT_ALLOW_LOCAL_TLS=1 craft --url https://dashboard.myapp.localhost
```

It applies only to loopback addresses (`127.0.0.0/8`, `::1`) and the
`localhost` TLD (`localhost`, `*.localhost`). Every other host keeps ordinary
certificate validation, including a host that *resolves* to loopback but is
not named for it — `127.0.0.1.nip.io` is still validated normally.

This is deliberately an environment variable and not a `craft.config.ts`
option: config travels into the app you ship, and a certificate exception that
can be committed is one that eventually reaches users who never asked for it.
Set it on the machine doing the development. Unset — or set to `0`, `false` or
`no` — Craft installs no certificate handling at all.

### Environment Files

```bash
# .env
CRAFT_APP_NAME=my-app
CRAFT_DEVTOOLS=true

# .env.development
NODE_ENV=development
CRAFT_HOT_RELOAD=true
CRAFT_DEV_PORT=3000

# .env.production
NODE_ENV=production
CRAFT_DEVTOOLS=false
```

## Platform-Specific Configuration

### macOS

```typescript
export default {
  window: {
    // macOS-specific window options
    titleBarStyle: 'hiddenInset',
    vibrancy: 'under-window', // Translucent background
    visualEffectState: 'active',
  },

  build: {
    mac: {
      category: 'public.app-category.productivity',
      entitlements: './build/entitlements.mac.plist',
      hardenedRuntime: true,
      gatekeeperAssess: true,
      extendInfo: {
        NSCameraUsageDescription: 'This app needs camera access',
      },
    },
  },
}
```

### Windows

```typescript
export default {
  window: {
    // Windows-specific
    frame: true,
    thickFrame: true,
  },

  build: {
    win: {
      requestedExecutionLevel: 'asInvoker',
      signAndEditExecutable: true,
      icon: './assets/icon.ico',
    },
  },
}
```

### Linux

```typescript
export default {
  build: {
    linux: {
      category: 'Utility',
      desktop: {
        Name: 'My App',
        Comment: 'A desktop application',
        Categories: 'Utility;',
        StartupWMClass: 'my-app',
      },
    },
  },
}
```

## Runtime Configuration

### Dynamic Configuration

```typescript
import { createApp, configure } from 'craft-native'

// Configure at runtime
configure({
  window: {
    title: getTitle(),
    width: getUserPreference('windowWidth') || 1200,
  },
  webview: {
    darkMode: getSystemTheme(),
  },
})

const app = await createApp()
```

### Configuration API

```typescript
import { config } from 'craft-native'

// Get configuration
const windowConfig = config.get('window')
const darkMode = config.get('webview.darkMode')

// Set configuration
config.set('window.title', 'New Title')

// Watch for changes
config.on('change', (key, newValue, oldValue) => {
  console.log(`${key} changed from ${oldValue} to ${newValue}`)
})
```

## Validation

### Schema Validation

```typescript
import { validateConfig } from 'craft-native'

const config = loadConfig()
const errors = validateConfig(config)

if (errors.length > 0) {
  console.error('Invalid configuration:')
  errors.forEach((error) => {
    console.error(`  - ${error.path}: ${error.message}`)
  })
  process.exit(1)
}
```

### Type Checking

```typescript
import type { CraftConfig } from 'craft-native'

// TypeScript will catch configuration errors
const config: CraftConfig = {
  window: {
    width: 'invalid', // Error: Type 'string' is not assignable to type 'number'
  },
}
```

## Debugging Configuration

### Print Resolved Configuration

```bash
craft config --print

# Output
# {
# "name": "my-app"
# "window": {
# "width": 1200
# "height": 800
#
# }
# }
```

### Validate Configuration

```bash
craft config --validate

# Output
# Configuration is valid
```

### Show Configuration Sources

```bash
craft config --sources

# Output
# window.width: 1200 (from: craft.toml)
# window.title: "My App" (from: environment variable CRAFT_WINDOW_TITLE)
# webview.devTools: true (from: command line --devtools)
```

## Next Steps

- [Custom Bindings](/advanced/custom-bindings) - Extend Craft functionality
- [Performance](/advanced/performance) - Optimization strategies
- [Cross-Platform](/advanced/cross-platform) - Platform-specific development
