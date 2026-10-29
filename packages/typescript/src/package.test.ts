import { afterAll, afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, statSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { candleArguments, codesignArguments, DEFAULT_DEB_DEPENDENCIES, dmgCapacityMegabytes, dmgCreateArguments, formatPackagingCommandError, linuxDesktopEntry, macOSInfoPlist, macOSRuntimeExecutablePath, notarytoolArguments, packageApp, pkgbuildArguments, pkgbuildComponentPlist, productbuildArguments, renderWixSource, shouldRetryHdiutil, urlTypesEntry, WINDOWS_NOTIFICATION_ID_FILE, windowsArchitecture, windowsExecutableName, windowsNotificationAppId } from './package.js'
import { createTempDir, removeAllTempDirs, removeTempDir } from './temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

describe('Linux DEB runtime dependencies', () => {
  it('installs the notify-send provider used by the desktop notification bridge', () => {
    expect(DEFAULT_DEB_DEPENDENCIES).toContain('libnotify-bin')
  })
})

describe('Linux DEB URI schemes', () => {
  it('advertises deduplicated handlers and passes one URL to Craft', () => {
    const entry = linuxDesktopEntry('Craft', 'craft', ['craft-test', 'CRAFT-TEST', 'craft+preview'])
    expect(entry).toContain('Exec=/usr/bin/craft --deep-link %u')
    expect(entry).toContain('MimeType=x-scheme-handler/craft-test;x-scheme-handler/craft+preview;')
    expect(linuxDesktopEntry('Craft', 'craft')).not.toContain('MimeType=')
    expect(() => linuxDesktopEntry('Craft', 'craft', ['not a scheme'])).toThrow('Invalid URL scheme')
  })

  it('loads the packaged page before delivering a cold URI', () => {
    const entry = linuxDesktopEntry('Craft', 'craft', ['craft-test'], 'https://example.test/app?tab=one%20two')
    expect(entry).toContain('Exec=/usr/bin/craft --url "https://example.test/app?tab=one%%20two" --deep-link %u')
    expect(() => linuxDesktopEntry('Craft', 'craft', [], 'javascript:alert(1)')).toThrow('Unsupported packaged app launch URL')
  })
})

describe('Windows MSI packaging', () => {
  it('renders a deterministic major-upgrade installer without shell interpolation', () => {
    const first = renderWixSource({ name: 'Craft App', version: '1.2.3', manufacturer: 'Stacks & Co', architecture: 'x64' }, 'Craft_App.exe')
    expect(renderWixSource({ name: 'Craft App', version: '1.2.3', manufacturer: 'Stacks & Co', architecture: 'x64' }, 'Craft_App.exe')).toBe(first)
    expect(first).toContain('MajorUpgrade')
    expect(first).toContain('AllowDowngrades="yes"')
    expect(first).toContain('Stacks &amp; Co')
    expect(first).toContain('Source="Craft_App.exe"')
    expect(first).toContain('Platform="x64"')
    expect(first).toContain('Directory Id="ProgramFiles64Folder"')
    expect(first).toContain('Win64="yes"')
    expect(first).toContain('Directory Id="ProgramMenuFolder"')
    expect(first).toContain('Shortcut Id="Craft_AppStartMenuShortcut" Directory="ProgramMenuFolder"')
    expect(first).toContain(`ShortcutProperty Key="System.AppUserModel.ID" Value="${windowsNotificationAppId('Craft App', 'Stacks & Co')}"`)
    expect(first).toContain(`Source="${WINDOWS_NOTIFICATION_ID_FILE}" KeyPath="yes"`)
    expect(first).not.toContain('exec(')
  })

  it('registers each requested URL protocol with a quoted executable and URL', () => {
    const source = renderWixSource({ name: 'Craft', version: '1.2.3', manufacturer: 'Craft', architecture: 'x64', urlSchemes: ['craft-test', 'CRAFT-TEST', 'craft+preview'] }, 'Craft.exe')
    expect(source).toContain('Key="Software\\Classes\\craft-test"')
    expect(source).toContain('Name="URL Protocol" Value=""')
    expect(source).toContain('Value="&quot;[#CraftFile]&quot; --deep-link &quot;%1&quot;"')
    expect(source).toContain('Key="Software\\Classes\\craft+preview"')
    expect(source).not.toContain('CraftProtocol2')
    expect(() => renderWixSource({ name: 'Craft', version: '1.2.3', manufacturer: 'Craft', architecture: 'x64', urlSchemes: ['bad scheme'] }, 'Craft.exe')).toThrow('Invalid URL scheme')
  })

  it('uses the packaged page for Start-menu and protocol launches', () => {
    const source = renderWixSource({ name: 'Craft', version: '1.2.3', manufacturer: 'Craft', architecture: 'x64', urlSchemes: ['craft-test'], launchUrl: 'https://example.test/app?tab=one&mode=two' }, 'Craft.exe')
    expect(source).toContain('Arguments="--url &quot;https://example.test/app?tab=one&amp;mode=two&quot;"')
    expect(source).toContain('Value="&quot;[#CraftFile]&quot; --url &quot;https://example.test/app?tab=one&amp;mode=two&quot; --deep-link &quot;%1&quot;"')
  })

  it('rejects versions WiX cannot compare', () => {
    expect(() => renderWixSource({ name: 'Craft', version: 'next', manufacturer: 'Craft', architecture: 'x64' }, 'craft.exe')).toThrow('MSI version')
  })

  it('preserves valid application names independently of WiX identifiers', () => {
    expect(windowsExecutableName('craft-lifecycle')).toBe('craft-lifecycle.exe')
    expect(windowsExecutableName('Craft App')).toBe('Craft App.exe')
    expect(() => windowsExecutableName('craft/app')).toThrow('Invalid Windows application name')
    expect(() => windowsExecutableName('CON')).toThrow('Reserved Windows application name')
  })

  it('compiles for the architecture the source declares', () => {
    // Without -arch, candle defaults to x86 and quietly produces a 32-bit
    // installer around a 64-bit payload — while the source it just compiled
    // says Platform="x64", ProgramFiles64Folder and Win64="yes". ICE80 would
    // catch the contradiction, but light runs with -sval.
    expect(candleArguments('x64', 'out.wixobj', 'in.wxs')).toEqual(['-nologo', '-arch', 'x64', '-out', 'out.wixobj', 'in.wxs'])
    expect(candleArguments('x86', 'out.wixobj', 'in.wxs')).toContain('x86')
    expect(candleArguments('arm64', 'out.wixobj', 'in.wxs')).toContain('arm64')
  })

  it('renders explicit 32-bit metadata only when requested', () => {
    const source = renderWixSource({ name: 'Craft', version: '1.2.3', manufacturer: 'Craft', architecture: 'x86' }, 'Craft.exe')
    expect(source).toContain('Platform="x86"')
    expect(source).toContain('Directory Id="ProgramFilesFolder"')
    expect(source).toContain('Win64="no"')
    expect(windowsArchitecture('ia32')).toBe('x86')
    expect(windowsArchitecture('x64')).toBe('x64')
    expect(windowsArchitecture('arm64')).toBe('arm64')
    expect(() => windowsArchitecture('mips')).toThrow('Unsupported Windows package architecture')
  })

  it('installs companion DLLs in the same MSI directory as the executable', () => {
    const source = renderWixSource(
      { name: 'Craft', version: '1.2.3', manufacturer: 'Craft', architecture: 'x64' },
      'Craft.exe',
      ['WebView2Loader.dll', 'A&B.dll'],
    )
    expect(source).toContain('Source="WebView2Loader.dll" KeyPath="yes"')
    expect(source).toContain('Source="A&amp;B.dll" KeyPath="yes"')
    expect(source).toContain('<ComponentRef Id="CraftExtra0" />')
    expect(source).toContain('<ComponentRef Id="CraftExtra1" />')
  })

  it('includes companion files in a Windows ZIP and rejects ambiguous names', async () => {
    const dir = createTempDir('craft-windows-zip-test-')
    try {
      const binary = join(dir, 'source.exe')
      const loader = join(dir, 'WebView2Loader.dll')
      writeFileSync(binary, 'binary-contents')
      writeFileSync(loader, 'loader-contents')
      const config = {
        name: 'Craft', version: '1.2.3', binaryPath: binary, outDir: dir,
        platforms: ['windows' as const], windows: { msi: false, zip: true, additionalFiles: [loader] },
      }
      const [zip] = await packageApp(config)
      expect(zip?.success).toBe(true)
      expect(zip?.outputPath).toBeDefined()
      const archive = readFileSync(zip!.outputPath!)
      expect(archive.includes(Buffer.from('Craft.exe'))).toBe(true)
      expect(archive.includes(Buffer.from('WebView2Loader.dll'))).toBe(true)
      expect(archive.includes(Buffer.from(WINDOWS_NOTIFICATION_ID_FILE))).toBe(true)

      const [duplicate] = await packageApp({ ...config, windows: { ...config.windows, additionalFiles: [loader, loader] } })
      expect(duplicate?.success).toBe(false)
      expect(duplicate?.error).toContain('Duplicate Windows package file')

      const [missing] = await packageApp({ ...config, windows: { ...config.windows, additionalFiles: [join(dir, 'missing.dll')] } })
      expect(missing?.success).toBe(false)
      expect(missing?.error).toContain('Windows companion file not found')

      const identityFile = join(dir, WINDOWS_NOTIFICATION_ID_FILE)
      writeFileSync(identityFile, 'spoofed')
      const [identityCollision] = await packageApp({ ...config, windows: { ...config.windows, additionalFiles: [identityFile] } })
      expect(identityCollision?.success).toBe(false)
      expect(identityCollision?.error).toContain('Duplicate Windows package file')
    }
    finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('macOS pkg relocation', () => {
  it('pins the install path instead of letting the bundle be relocated', () => {
    const plist = pkgbuildComponentPlist('Applications/Craft App.app')

    // The one that matters. Left to pkgbuild, this is true, and the package
    // then carries <relocate><bundle id="..."/></relocate> — which lets
    // `installer` write the payload over any copy of that bundle the system
    // has registered elsewhere and still exit 0. "The install was successful"
    // with nothing at /Applications is that, and it is intermittent because it
    // depends on what the system has indexed.
    expect(plist).toContain('<key>BundleIsRelocatable</key>\n        <false/>')

    // Off so that installing an older version over a newer one is not skipped;
    // with it on, a rollback silently becomes a no-op.
    expect(plist).toContain('<key>BundleIsVersionChecked</key>\n        <false/>')

    expect(plist).toContain('<string>Applications/Craft App.app</string>')
    expect(plist).toContain('<?xml version="1.0" encoding="UTF-8"?>')
  })

  it('escapes the bundle path rather than emitting broken XML', () => {
    expect(pkgbuildComponentPlist('Applications/Ben & Co.app')).toContain('Applications/Ben &amp; Co.app')
  })

  it('always passes the component plist to pkgbuild', () => {
    const args = pkgbuildArguments({
      root: '/tmp/stage/root',
      componentPlistPath: '/tmp/stage/component.plist',
      identifier: 'dev.craft.lifecycle',
      version: '1.0.0',
      outputPath: '/tmp/out.pkg',
    })
    expect(args).toEqual([
      '--root', '/tmp/stage/root',
      '--component-plist', '/tmp/stage/component.plist',
      '--identifier', 'dev.craft.lifecycle',
      '--version', '1.0.0',
      '--install-location', '/',
      '/tmp/out.pkg',
    ])

    // Signing is additive and must not displace the component plist.
    const signed = pkgbuildArguments({
      root: '/tmp/stage/root',
      componentPlistPath: '/tmp/stage/component.plist',
      identifier: 'dev.craft.lifecycle',
      version: '1.0.0',
      outputPath: '/tmp/out.pkg',
      installerIdentity: '3rd Party Mac Developer Installer: Example',
    })
    expect(signed).toContain('--component-plist')
    expect(signed.slice(-3, -1)).toEqual(['--sign', '3rd Party Mac Developer Installer: Example'])
  })
})

describe('macOS packaging diagnostics', () => {
  it('retains hdiutil output in a failed package result', () => {
    expect(formatPackagingCommandError('hdiutil', 1, '', 'create failed - Resource temporarily unavailable\n'))
      .toBe('hdiutil exited with code 1: create failed - Resource temporarily unavailable')
    expect(formatPackagingCommandError('hdiutil', 1, '', '')).toBe('hdiutil exited with code 1')
  })

  it('overrides source-folder sizing with filesystem headroom', () => {
    expect(dmgCapacityMegabytes(0)).toBe(64)
    expect(dmgCapacityMegabytes(100 * 1024 * 1024)).toBe(157)
    expect(() => dmgCapacityMegabytes(-1)).toThrow('non-negative safe integer')
    expect(dmgCreateArguments({
      appBundlePath: '/tmp/Craft.app',
      outputPath: '/tmp/Craft.dmg',
      volumeName: 'Craft',
    }, 100 * 1024 * 1024)).toEqual([
      'create',
      '-volname', 'Craft',
      '-srcfolder', '/tmp/Craft.app',
      '-size', '157m',
      '-ov',
      '-format', 'ULMO',
      '/tmp/Craft.dmg',
    ])
  })

  it('retries only transient hdiutil contention with a bounded attempt count', () => {
    expect(shouldRetryHdiutil('hdiutil: create failed - Resource busy', 1)).toBe(true)
    expect(shouldRetryHdiutil('Resource temporarily unavailable', 2)).toBe(true)
    expect(shouldRetryHdiutil('Resource busy', 3)).toBe(false)
    expect(shouldRetryHdiutil('No space left on device', 1)).toBe(false)
    expect(() => shouldRetryHdiutil('Resource busy', 0)).toThrow('positive integers')
  })
})

describe('macOS app bundle assembly', () => {
  const workDirs: string[] = []
  afterEach(() => {
    for (const dir of workDirs.splice(0))
      rmSync(dir, { recursive: true, force: true })
  })

  function workDir(): string {
    const dir = createTempDir('craft-bundle-test-')
    workDirs.push(dir)
    return dir
  }

  it('bundles helper executables beside the app binary so the .app is self-contained', async () => {
    const dir = workDir()
    const binaryPath = join(dir, 'app-bin')
    const helperPath = join(dir, 'craft')
    writeFileSync(binaryPath, '#!/bin/sh\n')
    writeFileSync(helperPath, '#!/bin/sh\n')
    chmodSync(binaryPath, 0o755)

    const results = await packageApp({
      name: 'Barista',
      version: '0.1.0',
      binaryPath,
      bundleId: 'org.stacksjs.barista',
      outDir: join(dir, 'out'),
      platforms: ['macos'],
      macos: { dmg: false, menuBarOnly: true, buildNumber: '42', additionalExecutables: [helperPath] },
    })

    const app = results.find(result => result.format === 'app')
    expect(app?.success).toBe(true)
    const bundled = join(app!.outputPath!, 'Contents', 'MacOS', 'craft')
    expect(existsSync(bundled)).toBe(true)
    const metadata = readFileSync(join(app!.outputPath!, 'Contents', 'Info.plist'), 'utf8')
    expect(metadata).toContain('LSUIElement')
    expect(metadata).toMatch(/<key>CFBundleVersion<\/key>\s*<string>42<\/string>/)
  })

  it('writes the declared URL schemes into the bundle it produces', async () => {
    // The unit tests below prove `macOSInfoPlist` can render the key. This
    // proves `packageApp` actually asks it to: `urlSchemes` existed as a
    // config field that nothing read, so an app could declare a scheme,
    // typecheck, package, and never receive a link (#53).
    const dir = workDir()
    const binaryPath = join(dir, 'app-bin')
    writeFileSync(binaryPath, '#!/bin/sh\n')
    chmodSync(binaryPath, 0o755)

    const results = await packageApp({
      name: 'Harness',
      version: '1.0.0',
      binaryPath,
      bundleId: 'org.stacksjs.harness',
      outDir: join(dir, 'out'),
      platforms: ['macos'],
      macos: { dmg: false, urlSchemes: ['harness'] },
    })

    const app = results.find(result => result.format === 'app')
    expect(app?.success).toBe(true)
    const plist = readFileSync(join(app!.outputPath!, 'Contents', 'Info.plist'), 'utf8')
    expect(plist).toContain('<key>CFBundleURLTypes</key>')
    expect(plist).toContain('<string>harness</string>')
  })

  it('fails clearly when a helper executable is missing', async () => {
    const dir = workDir()
    const binaryPath = join(dir, 'app-bin')
    writeFileSync(binaryPath, '#!/bin/sh\n')
    chmodSync(binaryPath, 0o755)

    const results = await packageApp({
      name: 'Barista',
      version: '0.1.0',
      binaryPath,
      bundleId: 'org.stacksjs.barista',
      outDir: join(dir, 'out'),
      platforms: ['macos'],
      macos: { dmg: false, additionalExecutables: [join(dir, 'does-not-exist')] },
    })

    const app = results.find(result => result.format === 'app')
    expect(app?.success).toBe(false)
    expect(app?.error).toContain('Additional executable not found')
  })
})

describe('macOS app bundle metadata', () => {
  it('emits only the keys the app asked for', () => {
    const plist = macOSInfoPlist({ name: 'Craft', version: '1.2.3', bundleId: 'com.example.craft' })
    expect(plist).toContain('<key>CFBundleShortVersionString</key>\n    <string>1.2.3</string>')
    expect(plist).toContain('<key>CFBundleVersion</key>\n    <string>1.2.3</string>')
    expect(plist).not.toContain('LSUIElement')
    expect(plist).not.toContain('CFBundleIconFile')
    expect(plist).not.toContain('LSApplicationCategoryType')
  })

  it('describes a menu bar app the App Store will accept', () => {
    const plist = macOSInfoPlist({
      name: 'Barista',
      version: '0.1.0',
      buildNumber: '17',
      bundleId: 'org.stacksjs.barista',
      iconName: 'AppIcon',
      category: 'public.app-category.utilities',
      minimumSystemVersion: '13.0',
      menuBarOnly: true,
    })
    expect(plist).toContain('<key>CFBundleVersion</key>\n    <string>17</string>')
    expect(plist).toContain('<key>CFBundleIconFile</key>\n    <string>AppIcon</string>')
    expect(plist).toContain('<key>LSApplicationCategoryType</key>\n    <string>public.app-category.utilities</string>')
    expect(plist).toContain('<key>LSMinimumSystemVersion</key>\n    <string>13.0</string>')
    expect(plist).toContain('<key>LSUIElement</key>\n    <true/>')
  })

  it('escapes metadata rather than emitting malformed plist markup', () => {
    expect(macOSInfoPlist({ name: 'Stacks & Co', version: '1.0.0', bundleId: 'com.example.app' }))
      .toContain('<string>Stacks &amp; Co</string>')
  })
})

describe('macOS URL schemes', () => {
  // Craft's receive path was complete — a `kAEGetURL` AppleEvent handler, a
  // buffer for a URL that arrives before the page loads — and nothing could
  // ever cause macOS to send one, because no bundle craft produced declared a
  // scheme. An app could set `urlSchemes`, typecheck, package, and never
  // receive a link.
  const base = { name: 'Harness', version: '1.0.0', bundleId: 'org.stacksjs.harness' }

  it('declares the schemes an app handles', () => {
    const plist = macOSInfoPlist({ ...base, urlSchemes: ['harness'] })
    expect(plist).toContain('<key>CFBundleURLTypes</key>')
    expect(plist).toContain('<string>harness</string>')
    // The URL type has to be named, and the bundle id is the one identifier
    // guaranteed unique to this app.
    expect(plist).toContain('<key>CFBundleURLName</key>\n        <string>org.stacksjs.harness</string>')
    expect(plist).toContain('<key>CFBundleTypeRole</key>\n        <string>Viewer</string>')
  })

  it('puts several schemes in one URL type', () => {
    // They are alternative ways to reach the same app, not different kinds of
    // document — splitting them across dicts would invent a distinction
    // LaunchServices does not make.
    const plist = macOSInfoPlist({ ...base, urlSchemes: ['harness', 'harness-dev'] })
    expect(plist.match(/<key>CFBundleURLSchemes<\/key>/g)).toHaveLength(1)
    expect(plist).toContain('<string>harness</string>')
    expect(plist).toContain('<string>harness-dev</string>')
  })

  it('emits nothing at all when an app handles no schemes', () => {
    // Every app packaged before this key existed must keep producing the same
    // plist, and an empty array is a caller saying "none", not "broken".
    expect(macOSInfoPlist(base)).not.toContain('CFBundleURLTypes')
    expect(macOSInfoPlist({ ...base, urlSchemes: [] })).not.toContain('CFBundleURLTypes')
  })

  it('collapses schemes that differ only in case', () => {
    // LaunchServices matches case-insensitively, so `Harness` and `harness`
    // are one scheme declared twice.
    const entry = urlTypesEntry(base.bundleId, ['harness', 'Harness'])!
    expect(entry.match(/<string>[Hh]arness<\/string>/g)).toHaveLength(1)
    expect(entry).toContain('<string>harness</string>')
  })

  it('refuses a scheme macOS would silently ignore', () => {
    // The failure this prevents is invisible: LaunchServices drops a malformed
    // scheme, the app installs and runs, and links simply never arrive.
    expect(() => macOSInfoPlist({ ...base, urlSchemes: ['1harness'] })).toThrow(/Invalid URL scheme/)
    expect(() => macOSInfoPlist({ ...base, urlSchemes: ['my app'] })).toThrow(/Invalid URL scheme/)
    expect(() => macOSInfoPlist({ ...base, urlSchemes: ['harness://'] })).toThrow(/Invalid URL scheme/)
    expect(() => macOSInfoPlist({ ...base, urlSchemes: [''] })).toThrow(/Invalid URL scheme/)
    // RFC 3986 allows these three inside a scheme, and apps do use them.
    expect(() => macOSInfoPlist({ ...base, urlSchemes: ['x-harness.dev+beta'] })).not.toThrow()
  })

  it('escapes a bundle id rather than emitting malformed markup', () => {
    expect(urlTypesEntry('com.example.a&b', ['harness'])).toContain('<string>com.example.a&amp;b</string>')
  })

  it('returns null rather than an empty array for no schemes', () => {
    expect(urlTypesEntry('com.example.app', [])).toBeNull()
  })
})

describe('macOS signing and delivery arguments', () => {
  it('opts Developer ID builds into the hardened runtime and App Store builds out of it', () => {
    expect(codesignArguments({ path: '/tmp/Craft.app', identity: 'Developer ID Application: Acme', hardenedRuntime: true }))
      .toEqual(['--force', '--sign', 'Developer ID Application: Acme', '--timestamp', '--options', 'runtime', '--deep', '/tmp/Craft.app'])
    expect(codesignArguments({ path: '/tmp/Craft.app', identity: '3rd Party Mac Developer Application: Acme', entitlements: '/tmp/app.entitlements' }))
      .toEqual(['--force', '--sign', '3rd Party Mac Developer Application: Acme', '--timestamp', '--entitlements', '/tmp/app.entitlements', '--deep', '/tmp/Craft.app'])
    expect(codesignArguments({ path: '/tmp/Craft.app', identity: '-', hardenedRuntime: true }))
      .toEqual(['--force', '--sign', '-', '--options', 'runtime', '--deep', '/tmp/Craft.app'])
  })

  it('builds a signed App Store submission package installing into /Applications', () => {
    expect(productbuildArguments({
      appBundlePath: '/tmp/Craft.app',
      outputPath: '/tmp/Craft.pkg',
      identity: '3rd Party Mac Developer Installer: Acme',
    })).toEqual([
      '--component', '/tmp/Craft.app', '/Applications',
      '--sign', '3rd Party Mac Developer Installer: Acme',
      '/tmp/Craft.pkg',
    ])
  })

  it('waits for the notarization verdict instead of returning on submission', () => {
    expect(notarytoolArguments({
      artifactPath: '/tmp/Craft.dmg',
      appleId: 'dev@example.com',
      applePassword: 'app-specific',
      teamId: 'TEAMID',
    })).toEqual([
      'notarytool',
      'submit', '/tmp/Craft.dmg',
      '--apple-id', 'dev@example.com',
      '--password', 'app-specific',
      '--team-id', 'TEAMID',
      '--wait',
    ])
  })
})

it('uses keychain and API key notarization without passwords in process arguments', () => {
  expect(notarytoolArguments({ artifactPath: '/tmp/App.dmg', keychainProfile: 'release' }))
    .toEqual(['notarytool', 'submit', '/tmp/App.dmg', '--wait', '--keychain-profile', 'release'])
  expect(notarytoolArguments({ artifactPath: '/tmp/App.dmg', apiKey: { path: '/tmp/key.p8', keyId: 'KEY', issuer: 'ISSUER' } }))
    .toEqual(['notarytool', 'submit', '/tmp/App.dmg', '--wait', '--key', '/tmp/key.p8', '--key-id', 'KEY', '--issuer', 'ISSUER'])
  expect(() => notarytoolArguments({ artifactPath: '/tmp/App.dmg' })).toThrow('credentials')
})

it('preserves the resources and metadata of a prebuilt macOS app', async () => {
  const root = createTempDir('prebuilt-package')
  try {
    const { mkdirSync } = await import('node:fs')
    const source = join(root, 'source', 'App.app')
    mkdirSync(join(source, 'Contents', 'MacOS'), { recursive: true })
    mkdirSync(join(source, 'Contents', 'Resources'), { recursive: true })
    writeFileSync(join(source, 'Contents', 'Info.plist'), '<plist>app-owned-metadata</plist>')
    writeFileSync(join(source, 'Contents', 'MacOS', 'App'), 'app-executable')
    writeFileSync(join(source, 'Contents', 'Resources', 'index.html'), 'embedded-ui')
    const result = await packageApp({ name: 'App', version: '1.0.0', binaryPath: join(source, 'Contents', 'MacOS', 'App'), outDir: join(root, 'out'), platforms: ['macos'], macos: { appBundlePath: source, dmg: false } })
    expect(result[0].success).toBe(true)
    expect(readFileSync(join(result[0].outputPath!, 'Contents', 'Resources', 'index.html'), 'utf8')).toBe('embedded-ui')
    expect(readFileSync(join(result[0].outputPath!, 'Contents', 'Info.plist'), 'utf8')).toBe('<plist>app-owned-metadata</plist>')
    const invalid = await packageApp({ name: 'Invalid', version: '1.0.0', binaryPath: join(source, 'Contents', 'MacOS', 'App'), outDir: join(root, 'invalid'), platforms: ['macos'], macos: { appBundlePath: root, dmg: false } })
    expect(invalid[0].success).toBe(false)
    expect(invalid[0].error).toBe(`Invalid prebuilt macOS application: ${root}`)
  }
  finally { removeTempDir(root) }
})

it.skipIf(process.platform !== 'darwin')('signs the actual disk image container as well as the application', async () => {
  const root = createTempDir('signed-dmg')
  try {
    const results = await packageApp({
      name: 'SignedImage', version: '1.0.0', bundleId: 'dev.craft.signed-dmg',
      binaryPath: '/usr/bin/true', outDir: root, platforms: ['macos'],
      macos: { dmg: true, signIdentity: '-' },
    })
    expect(results.every(result => result.success), JSON.stringify(results)).toBe(true)
    const image = results.find(result => result.format === 'dmg')!.outputPath!
    expect(Bun.spawnSync(['codesign', '--verify', '--strict', image]).exitCode).toBe(0)
    expect(Bun.spawnSync(['codesign', '-dv', image]).stderr.toString()).toContain('Signature=adhoc')
    expect(Bun.spawnSync(['codesign', '--verify', '--deep', '--strict', results[0].outputPath!]).exitCode).toBe(0)
  }
  finally { removeTempDir(root) }
}, 30000)

it.skipIf(process.platform !== 'darwin')('packages and signs a native GUI agent with its own executable identity', async () => {
  const root = createTempDir('native-agent-package')
  try {
    const results = await packageApp({
      name: 'Example', version: '1.2.3', bundleId: 'dev.craft.agent-test',
      binaryPath: '/usr/bin/true', outDir: root, platforms: ['macos'],
      macos: { nativeRuntimePath: '/usr/bin/true', dmg: false, signIdentity: '-' },
    })
    expect(results[0].success).toBe(true)
    const app = results[0].outputPath!
    const runtime = macOSRuntimeExecutablePath(app)
    expect(existsSync(join(app, 'Contents/MacOS/craft'))).toBe(false)
    expect(existsSync(runtime)).toBe(true)
    const helper = join(app, 'Contents/Helpers/CraftRuntime.app')
    const metadata = (key: string) => Bun.spawnSync(['plutil', '-extract', key, 'raw', '-o', '-', join(helper, 'Contents/Info.plist')]).stdout.toString().trim()
    expect(metadata('CFBundleExecutable')).toBe('CraftRuntime')
    expect(runtime).toBe(join(helper, 'Contents/MacOS/CraftRuntime'))
    expect(metadata('CFBundleName')).toBe('Example')
    expect(metadata('CFBundleIdentifier')).toBe('dev.craft.agent-test.runtime')
    expect(metadata('LSUIElement')).toBe('true')
    const signature = Bun.spawnSync(['codesign', '-dv', runtime])
    expect(signature.stderr.toString()).toContain('Identifier=dev.craft.agent-test.runtime')
    expect(Bun.spawnSync(['codesign', '--verify', '--deep', '--strict', app]).exitCode).toBe(0)
  }
  finally { removeTempDir(root) }
})

it.skipIf(process.platform !== 'darwin')('signs prebuilt app helpers with inheritance and applies store metadata before signing', async () => {
  const root = createTempDir('prebuilt-sandbox-sign')
  try {
    const { mkdirSync, copyFileSync } = await import('node:fs')
    const source = join(root, 'source', 'App.app')
    const contents = join(source, 'Contents')
    mkdirSync(join(contents, 'MacOS'), { recursive: true })
    mkdirSync(join(contents, 'Resources'), { recursive: true })
    writeFileSync(join(contents, 'Info.plist'), macOSInfoPlist({ name: 'App', version: '1.0.0', bundleId: 'dev.craft.sign-test' }))
    copyFileSync('/usr/bin/true', join(contents, 'MacOS', 'App'))
    copyFileSync('/usr/bin/true', join(contents, 'MacOS', 'backend'))
    const entitlements = join(root, 'main.plist')
    writeFileSync(entitlements, '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.files.user-selected.read-write</key><true/></dict></plist>')
    const profile = join(root, 'profile')
    const privacy = join(root, 'PrivacyInfo.xcprivacy')
    writeFileSync(profile, 'test-profile', { mode: 0o600 })
    writeFileSync(privacy, '<plist version="1.0"><dict/></plist>')
    const results = await packageApp({
      name: 'App', version: '1.0.0', bundleId: 'dev.craft.sign-test',
      binaryPath: join(contents, 'MacOS', 'App'), outDir: join(root, 'out'), platforms: ['macos'],
      macos: { appBundlePath: source, dmg: false, appStore: true, signIdentity: '-', entitlements, provisioningProfile: profile, privacyManifest: privacy, buildNumber: '42' },
    })
    expect(results[0].success).toBe(true)
    const app = results[0].outputPath!
    expect(readFileSync(join(app, 'Contents', 'embedded.provisionprofile'), 'utf8')).toBe('test-profile')
    expect(statSync(join(app, 'Contents', 'embedded.provisionprofile')).mode & 0o777).toBe(0o644)
    expect(readFileSync(join(app, 'Contents', 'Resources', 'PrivacyInfo.xcprivacy'), 'utf8')).toContain('<dict/>')
    const metadata = Bun.spawnSync(['plutil', '-extract', 'CFBundleVersion', 'raw', '-o', '-', join(app, 'Contents', 'Info.plist')])
    expect(metadata.stdout.toString().trim()).toBe('42')
    const signedEntitlements = (path: string) => {
      const result = Bun.spawnSync(['codesign', '-d', '--entitlements', ':-', path])
      expect(result.exitCode).toBe(0)
      return result.stdout.toString()
    }
    expect(signedEntitlements(app)).toContain('com.apple.security.files.user-selected.read-write')
    const helper = signedEntitlements(join(app, 'Contents', 'MacOS', 'backend'))
    expect(helper).toContain('com.apple.security.inherit')
    expect(helper).not.toContain('com.apple.security.files.user-selected.read-write')
    expect(Bun.spawnSync(['codesign', '--verify', '--deep', '--strict', app]).exitCode).toBe(0)
    expect(results[1].error).toContain('installerIdentity')
  }
  finally { removeTempDir(root) }
})
