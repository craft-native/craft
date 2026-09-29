# Packaging Your Craft Application

Craft provides comprehensive packaging tools to create installers for your applications on macOS, Windows, and Linux. Your users can easily install and run your apps without needing to install dependencies.

## Quick Start

### Using the API

```typescript
import { packageApp } from 'craft-native'

const results = await packageApp({
  name: 'My App',
  version: '1.0.0',
  binaryPath: './build/myapp',
  platforms: ['macos', 'windows', 'linux'],
})
```

### Using the CLI

```bash
# Install CLI globally
bun add -g craft-native

# Package your app
craft-package --name "My App" --version "1.0.0" --binary ./build/myapp
```

## Supported Formats

| Platform | Formats | Description |
|----------|---------|-------------|
| **macOS** | DMG | Disk image for drag-and-drop installation |
| | PKG | macOS installer package |
| **Windows** | MSI | Windows Installer (requires WiX Toolset) |
| | ZIP | Portable archive |
| **Linux** | DEB | Debian/Ubuntu package |
| | RPM | Fedora/RedHat package |
| | AppImage | Universal Linux binary |

For a DEB or MSI that handles custom URLs, set `urlSchemes` and `launchUrl` on
the platform options. The launcher loads `launchUrl` as the app's page and
passes the incoming URI separately as `--deep-link`; the page can read it with
`window.craft.deepLink.getInitialUrl()`. An app that already embeds its own
page in its binary may omit `launchUrl`. Scheme registration currently applies
to DEB and MSI, not RPM, AppImage, or ZIP.

## TypeScript API

### Complete Example

```typescript
import { packageApp } from 'craft-native'
import { join } from 'path'

async function buildInstallers() {
  const results = await packageApp({
    // Basic info
    name: 'Pomodoro Timer',
    version: '1.0.0',
    description: 'A beautiful Pomodoro timer',
    author: 'Your Name <you@example.com>',
    homepage: 'https://github.com/yourname/pomodoro',

    // Binary path (your built Craft app)
    binaryPath: join(**dirname, 'build/pomodoro'),

    // Output directory for installers
    outDir: join(**dirname, 'dist'),

    // Bundle ID (macOS/iOS)
    bundleId: 'com.example.pomodoro',

    // Icon (optional, platform-specific formats)
    iconPath: join(__dirname, 'assets/icon.icns'),

    // Platforms to build for
    platforms: ['macos', 'windows', 'linux'],

    // macOS options
    macos: {
      dmg: true,  // Create DMG
      pkg: true,  // Create PKG
      signIdentity: 'Developer ID Application: Your Name (TEAM_ID)',
      notarize: true,
      appleId: 'you@example.com',
      applePassword: '@keychain:AC_PASSWORD',
    },

    // Windows options
    windows: {
      msi: true,  // Requires WiX Toolset
      zip: true,  // Portable fallback
      certificatePath: './cert.pfx',
      certificatePassword: process.env.CERT_PASSWORD,
    },

    // Linux options
    linux: {
      deb: true,
      rpm: true,
      appImage: true,
      categories: ['Utility', 'Development'],
      debDependencies: ['libgtk-3-0', 'libwebkit2gtk-4.1-37'],
      rpmDependencies: ['gtk3', 'webkit2gtk3'],
    },
  })

  // Check results
  for (const result of results) {
    if (result.success) {
      console.log(`✅ Created ${result.format}: ${result.outputPath}`)
    } else {
      console.error(`❌ Failed ${result.format}: ${result.error}`)
    }
  }
}

buildInstallers()
```

### Simple Packaging

For quick packaging of the current platform:

```typescript
import { pack } from 'craft-native'

const results = await pack({
  name: 'My App',
  version: '1.0.0',
  binaryPath: './build/myapp',
})
```

## CLI Usage

### Basic Usage

```bash
craft-package --name "My App" --version "1.0.0" --binary ./build/myapp
```

### Advanced Options

```bash
craft-package \
  --name "My App" \
  --version "1.0.0" \
  --binary ./build/myapp \
  --description "My awesome app" \
  --author "Your Name" \
  --bundle-id "com.mycompany.myapp" \
  --icon ./assets/icon.icns \
  --out ./dist \
  --platforms macos,windows,linux \
  --dmg \
  --pkg \
  --msi \
  --deb \
  --rpm \
  --appimage
```

### Using a Config File

Create `package.json`:

```json
{
  "name": "My App",
  "version": "1.0.0",
  "description": "My awesome application",
  "author": "Your Name <you@example.com>",
  "binaryPath": "./build/myapp",
  "bundleId": "com.mycompany.myapp",
  "iconPath": "./assets/icon.icns",
  "outDir": "./dist",
  "platforms": ["macos", "windows", "linux"],
  "macos": {
    "dmg": true,
    "pkg": true
  },
  "windows": {
    "msi": true,
    "zip": true
  },
  "linux": {
    "deb": true,
    "rpm": true,
    "appImage": true,
    "categories": ["Utility"],
    "debDependencies": ["libgtk-3-0", "libwebkit2gtk-4.1-37"],
    "rpmDependencies": ["gtk3", "webkit2gtk3"]
  }
}
```

Then run:

```bash
craft-package --config package.json
```

## Platform-Specific Details

### macOS

#### DMG (Disk Image)

- Provides drag-and-drop installation
- Users drag app to Applications folder
- No admin password required
- Most user-friendly format

#### PKG (Package)

- Traditional installer format
- Can run scripts during installation
- Better for system-level installations
- May require admin password

**Code Signing** (Optional but Recommended):

The bundle is signed before it is wrapped, so the copy inside the DMG or PKG
carries the signature too.

```typescript
macos: {
  dmg: true,
  pkg: true,
  signIdentity: 'Developer ID Application: Your Name (TEAM_ID)',
  installerIdentity: 'Developer ID Installer: Your Name (TEAM_ID)', // signs the .pkg
  entitlements: './app.entitlements',
}
```

**Notarization** (Required for macOS 10.15+):

Runs `notarytool submit --wait` and staples the ticket to the artifact, so the
DMG and PKG open without a Gatekeeper prompt.

```typescript
macos: {
  notarize: true,
  appleId: 'you@example.com',
  applePassword: '@keychain:AC_PASSWORD',
  teamId: 'TEAM_ID',
}
```

#### Mac App Store

`appStore: true` builds the submission package with `productbuild` instead of
`pkgbuild` — the only form App Store Connect accepts. Two differences follow
automatically: the hardened runtime is left off (App Store apps run sandboxed
instead), and notarization is skipped because Apple notarizes during review.

```typescript
macos: {
  appStore: true,
  signIdentity: '3rd Party Mac Developer Application: Your Name (TEAM_ID)',
  installerIdentity: '3rd Party Mac Developer Installer: Your Name (TEAM_ID)',
  entitlements: './app.entitlements',      // must include com.apple.security.app-sandbox
  provisioningProfile: './app.provisionprofile',
  category: 'public.app-category.utilities', // required by App Store review
  minimumSystemVersion: '13.0',
  buildNumber: '17',                       // must increase on every upload
}
```

`menuBarOnly: true` sets `LSUIElement`, so a menu bar app ships without a Dock
icon or app switcher entry.

The resulting `.pkg` is what `pantry`'s release action uploads — see
[Publishing to the App Store](#publishing-to-the-app-store).

### Windows

#### MSI (Windows Installer)

- Professional installer experience
- Requires WiX Toolset: <https://wixtoolset.org/>
- Supports uninstallation
- Can add to PATH automatically
- May require admin privileges

#### ZIP (Portable)

- No installation required
- Extract and run
- Great for portable apps
- No admin privileges needed

**Code Signing** (Recommended):
```typescript
windows: {
  msi: true,
  certificatePath: './cert.pfx',
  certificatePassword: process.env.CERT_PASSWORD,
}
```

### Linux

#### DEB (Debian/Ubuntu)

- For Debian-based distros
- Managed by APT
- Handles dependencies automatically
- Example: `sudo dpkg -i myapp_1.0.0_amd64.deb`

#### RPM (Fedora/RedHat)

- For RPM-based distros
- Managed by DNF/YUM
- Handles dependencies automatically
- Example: `sudo rpm -i myapp-1.0.0-1.x86_64.rpm`

#### AppImage (Universal)

- Works on all Linux distros
- No installation needed
- Single executable file
- No dependencies required
- Example: `chmod +x myapp-1.0.0-x86_64.AppImage && ./myapp-1.0.0-x86_64.AppImage`

## Building for Multiple Platforms

### Cross-Platform Building

You can build for all platforms from any OS, but some formats have limitations:

| Format | Can Build On | Notes |
|--------|--------------|-------|
| DMG | macOS only | Requires hdiutil |
| PKG | macOS only | Requires pkgbuild |
| MSI | Windows only | Requires WiX Toolset |
| ZIP | Any platform | Universal |
| DEB | Any platform | Requires dpkg-deb |
| RPM | Any platform | Requires rpmbuild |
| AppImage | Linux/macOS | Requires appimagetool |

### Recommended Workflow

**Option 1: Platform-Specific Builds**
```bash
# On macOS
craft-package --config package.json --platforms macos

# On Windows
craft-package --config package.json --platforms windows

# On Linux
craft-package --config package.json --platforms linux
```

#### Option 2: CI/CD Pipeline

Use GitHub Actions, GitLab CI, or similar to build on multiple platforms:

```yaml
# .github/workflows/build.yml
name: Build Installers

on: [push]

jobs:
  build-macos:
    runs-on: macos-latest
    steps:

      - uses: actions/checkout@v3
      - run: bun install
      - run: bun run build
      - run: craft-package --config package.json --platforms macos

  build-windows:
    runs-on: windows-latest
    steps:

      - uses: actions/checkout@v3
      - run: bun install
      - run: bun run build
      - run: craft-package --config package.json --platforms windows

  build-linux:
    runs-on: ubuntu-latest
    steps:

      - uses: actions/checkout@v3
      - run: bun install
      - run: bun run build
      - run: craft-package --config package.json --platforms linux

```

## Icon Requirements

Different platforms require different icon formats:

| Platform | Format | Sizes |
|----------|--------|-------|
| macOS | ICNS | 16x16 to 1024x1024 |
| Windows | ICO | 16x16, 32x32, 48x48, 256x256 |
| Linux | PNG | 16x16 to 512x512 |

### Creating Icons

**macOS (.icns)**:
```bash
# Create from PNG
iconutil -c icns icon.iconset
```

**Windows (.ico)**:
```bash
# Use ImageMagick
convert icon.png -define icon:auto-resize=256,128,96,64,48,32,16 icon.ico
```

**Linux (.png)**:
```bash
# Just use PNG files at various sizes
# 16x16, 32x32, 48x48, 128x128, 256x256, 512x512
```

## Distribution

Once you have your installers:

### macOS

- **DMG**: Upload to website or GitHub releases
- **PKG**: Upload to website or distribute via MDM
- **Mac App Store**: Use App Store Connect

#### Publishing to the App Store

`packageApp` stops at a signed `.pkg`; uploading it is `pantry`'s job. Point
`pantry`'s release action at the artifact and a tag push publishes the GitHub
release and the App Store build in one step:

```yaml
- uses: pantry-pm/pantry/packages/action@main
  with:
    release: true
    release-files: dist/MyApp-*.pkg
    release-app-store: true
    release-app-store-bundle-id: com.example.myapp
  env:
    APP_STORE_CONNECT_API_KEY_ID: ${{ secrets.APP_STORE_CONNECT_API_KEY_ID }}
    APP_STORE_CONNECT_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
    APP_STORE_CONNECT_PRIVATE_KEY: ${{ secrets.APP_STORE_CONNECT_PRIVATE_KEY }}
```

The action verifies the package signature, validates it against App Store
Connect, then uploads — so an unsigned or `pkgbuild`-built package fails before
anything is submitted.

### Windows

- **MSI**: Upload to website or GitHub releases
- **Microsoft Store**: Use Partner Center

Files needed at runtime beside the `.exe` must be supplied explicitly for both
MSI and ZIP output. For a Craft binary using WebView2, stage the matching
`WebView2Loader.dll` and pass its path:

```typescript
windows: {
  msi: true,
  zip: true,
  additionalFiles: ['path/to/WebView2Loader.dll'],
}
```

The packager places each additional file beside the executable; it rejects
missing files and duplicate Windows file names.

### Linux

- **DEB**: Host on APT repository or provide direct download
- **RPM**: Host on YUM/DNF repository or provide direct download
- **AppImage**: Upload to website or GitHub releases
- **Snap/Flatpak**: Publish to respective stores

## Auto-Updates

Craft includes built-in auto-update support (see [AUTO_UPDATES.md](./AUTO_UPDATES.md)).

## Troubleshooting

### "Binary not found"

Make sure you build your Craft app first:
```bash
zig build -Doptimize=ReleaseSafe
```

### "WiX Toolset not found" (Windows MSI)

Install WiX Toolset from <https://wixtoolset.org/>

Use ZIP format as fallback:
```typescript
windows: { zip: true }
```

### "dpkg-deb not found" (Linux DEB)

Install on macOS:
```bash
brew install dpkg
```

### "Code signing failed" (macOS)

List available identities:
```bash
security find-identity -v -p codesigning
```

Use the full identity string in your config.

## Examples

See complete examples in the `/examples` directory:

- `examples/package-app.ts` - Full packaging example
- `examples/package-pomodoro.ts` - Pomodoro timer packaging

## API Reference

### `packageApp(config: PackageConfig): Promise<PackageResult[]>`

Main packaging function.

### `pack(options): Promise<PackageResult[]>`

Simplified packaging for current platform only.

### Types

```typescript
interface PackageConfig {
  name: string
  version: string
  binaryPath: string
  description?: string
  author?: string
  homepage?: string
  bundleId?: string
  iconPath?: string
  outDir?: string
  platforms?: Array<'macos' | 'windows' | 'linux'>
  macos?: MacOSOptions
  windows?: WindowsOptions
  linux?: LinuxOptions
}

interface PackageResult {
  success: boolean
  platform: string
  format: string
  outputPath?: string
  error?: string
}
```

See full type definitions in `src/package.ts`.

## Further Reading

- [Code Signing Guide](./CODE_SIGNING.md)
- [Auto-Updates Guide](./AUTO_UPDATES.md)
- [Distribution Guide](./DISTRIBUTION.md)

---

For questions or issues, visit: <https://github.com/home-lang/craft/issues>
