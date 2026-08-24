import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { candleArguments, codesignArguments, dmgCapacityMegabytes, dmgCreateArguments, formatPackagingCommandError, macOSInfoPlist, notarytoolArguments, packageApp, pkgbuildArguments, pkgbuildComponentPlist, productbuildArguments, renderWixSource, shouldRetryHdiutil, windowsArchitecture, windowsExecutableName } from './package.js'

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
    expect(first).not.toContain('exec(')
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
    const dir = mkdtempSync(join(tmpdir(), 'craft-bundle-test-'))
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
      macos: { dmg: false, menuBarOnly: true, additionalExecutables: [helperPath] },
    })

    const app = results.find(result => result.format === 'app')
    expect(app?.success).toBe(true)
    const bundled = join(app!.outputPath!, 'Contents', 'MacOS', 'craft')
    expect(existsSync(bundled)).toBe(true)
    expect(readFileSync(join(app!.outputPath!, 'Contents', 'Info.plist'), 'utf8')).toContain('LSUIElement')
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

describe('macOS signing and delivery arguments', () => {
  it('opts Developer ID builds into the hardened runtime and App Store builds out of it', () => {
    expect(codesignArguments({ path: '/tmp/Craft.app', identity: 'Developer ID Application: Acme', hardenedRuntime: true }))
      .toEqual(['--force', '--sign', 'Developer ID Application: Acme', '--timestamp', '--options', 'runtime', '--deep', '/tmp/Craft.app'])
    expect(codesignArguments({ path: '/tmp/Craft.app', identity: '3rd Party Mac Developer Application: Acme', entitlements: '/tmp/app.entitlements' }))
      .toEqual(['--force', '--sign', '3rd Party Mac Developer Application: Acme', '--timestamp', '--entitlements', '/tmp/app.entitlements', '--deep', '/tmp/Craft.app'])
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
