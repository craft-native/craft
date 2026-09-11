#!/usr/bin/env bun

/**
 * Craft CLI - Build desktop apps with web languages
 */

import { CLI } from '@stacksjs/clapp'
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import process from 'node:process'
import { CRAFT_CLI_SPAWN_MARKER, craftBinaryIsCliShimMessage, craftBinaryNotFoundMessage, resolveCraftBinary } from '../src/binary-resolver'
import { pinCraftNativeDependency } from '../src/scaffold-version'
import { version } from '../package.json'

// If this marker is already set we were spawned by a craft CLI that meant to
// spawn the native binary — so `craft` on PATH resolves to this script. Say so
// now, rather than letting the arg parser reject a flag the user never typed.
const spawnedFrom = process.env[CRAFT_CLI_SPAWN_MARKER]
if (spawnedFrom) {
  console.error(craftBinaryIsCliShimMessage(spawnedFrom))
  process.exit(1)
}

const cli = new CLI('craft')

/**
 * Run the `craft` native binary with the given argv. Craft ships through
 * the pantry registry, so the binary is expected to be on PATH after
 * `pantry install craft`. The shared resolver respects an explicit
 * `CRAFT_BIN` for tests and the monorepo dev loop; everything else
 * delegates to PATH. ENOENT surfaces a single, pantry-pointing error.
 */
async function runCraftBinary(args: string[]): Promise<void> {
  const craftPath = resolveCraftBinary()

  return new Promise((resolve, reject) => {
    const proc = spawn(craftPath, args, {
      stdio: 'inherit',
      // Marks the child so that, if it turns out to be this CLI rather than
      // the native binary, it can recognise the loop and explain it.
      env: { ...process.env, [CRAFT_CLI_SPAWN_MARKER]: craftPath },
    })

    proc.on('exit', (code) => {
      if (code === 0 || code === null) resolve()
      else reject(new Error(`Craft exited with code ${code}`))
    })

    proc.on('error', (error: Error & { code?: string }) => {
      if (error.code === 'ENOENT') {
        reject(new Error(craftBinaryNotFoundMessage(craftPath)))
        return
      }
      reject(error)
    })
  })
}

/**
 * Coerce a CLI value to an integer in [min, max], throwing a friendly
 * error on invalid input. Used so `--width abc` and `--width 9999999999`
 * produce a clear message instead of a downstream crash.
 */
function parseIntInRange(name: string, value: unknown, min: number, max: number): number {
  const n = typeof value === 'number' ? value : Number.parseInt(String(value), 10)
  if (!Number.isFinite(n) || !Number.isInteger(n)) {
    throw new Error(`--${name} must be an integer (got: ${String(value)})`)
  }
  if (n < min || n > max) {
    throw new Error(`--${name} must be between ${min} and ${max} (got: ${n})`)
  }
  return n
}

/**
 * Validate `--url` against URL parsing. Allows `http`, `https`, `file`, and
 * `data:` schemes; everything else (e.g. `javascript:`) is rejected so a
 * malicious shortcut can't bypass the SDK's own URL handling.
 */
function validateUrl(value: string): string {
  let parsed: URL
  try {
    parsed = new URL(value)
  }
  catch {
    throw new Error(`--url must be a valid URL (got: ${value})`)
  }
  const allowed = new Set(['http:', 'https:', 'file:', 'data:'])
  if (!allowed.has(parsed.protocol)) {
    throw new Error(`--url uses unsupported scheme "${parsed.protocol}"; allowed: ${[...allowed].join(', ')}`)
  }
  return parsed.toString()
}

// Default command - launch app with URL
cli
  .command('[url]', 'Launch a Craft desktop app')
  .option('--title <title>', 'Window title')
  .option('--width <width>', 'Window width', { default: 800 })
  .option('--height <height>', 'Window height', { default: 600 })
  .option('--x <x>', 'Window x position')
  .option('--y <y>', 'Window y position')
  .option('--frameless', 'Frameless window')
  .option('--transparent', 'Transparent window')
  .option('--always-on-top', 'Always on top')
  .option('--fullscreen', 'Start in fullscreen')
  .option('--dark-mode', 'Enable dark mode')
  .option('--hot-reload', 'Enable hot reload')
  .option('--dev-tools', 'Enable developer tools')
  .option('--no-resize', 'Disable window resizing')
  .example('craft http://localhost:3000')
  .example('craft http://localhost:3000 --title "My App" --width 1200 --height 800')
  .example('craft http://localhost:3000 --frameless --transparent --always-on-top')
  .action(async (url?: string, options?: any) => {
    const args: string[] = []

    try {
      if (url) {
        args.push('--url', validateUrl(url))
      }

      if (options?.title) {
        const title = String(options.title)
        if (title.length > 256) throw new Error('--title must be 256 chars or fewer')
        args.push('--title', title)
      }
      if (options?.width !== undefined)
        args.push('--width', String(parseIntInRange('width', options.width, 100, 10_000)))
      if (options?.height !== undefined)
        args.push('--height', String(parseIntInRange('height', options.height, 100, 10_000)))
      if (options?.x !== undefined)
        args.push('--x', String(parseIntInRange('x', options.x, -100_000, 100_000)))
      if (options?.y !== undefined)
        args.push('--y', String(parseIntInRange('y', options.y, -100_000, 100_000)))

      if (options?.frameless) args.push('--frameless')
      if (options?.transparent) args.push('--transparent')
      if (options?.alwaysOnTop) args.push('--always-on-top')
      if (options?.fullscreen) args.push('--fullscreen')
      if (options?.darkMode) args.push('--dark-mode')
      if (options?.hotReload) args.push('--hot-reload')
      if (options?.devTools) args.push('--dev-tools')
      if (options?.noResize) args.push('--no-resize')
    }
    catch (validationError) {
      console.error(`Error: ${(validationError as Error).message}`)
      process.exit(2)
    }

    try {
      await runCraftBinary(args)
    }
    catch (error: any) {
      console.error('Error:', error.message)
      process.exit(1)
    }
  })

// Version command
cli
  .command('version', 'Show the version')
  .action(() => {
    console.log(`v${version}`)
  })

// Build command
cli
  .command('build', 'Build the Craft application')
  .option('--release', 'Build in release mode', { default: false })
  .option('--platform <platforms>', 'Target platforms (ios,android,macos,windows,linux)', { default: 'current' })
  .option('--config <path>', 'Path to craft.config.ts')
  .example('craft build')
  .example('craft build --release')
  .example('craft build --platform ios,android')
  .example('craft build --platform macos,windows,linux')
  .action(async (options?: any) => {
    const platforms = options?.platform === 'current'
      ? [process.platform === 'darwin' ? 'macos' : process.platform === 'win32' ? 'windows' : 'linux']
      : options?.platform.split(',').map((p: string) => p.trim())

    console.log('\n⚡ Craft Build\n')
    console.log(`Platforms: ${platforms.join(', ')}`)
    console.log(`Mode: ${options?.release ? 'Release' : 'Debug'}\n`)

    const { existsSync } = await import('node:fs')
    const { spawn } = await import('node:child_process')

    for (const platform of platforms) {
      console.log(`📦 Building for ${platform}...`)

      try {
        if (platform === 'ios') {
          if (process.platform !== 'darwin') {
            console.log(`   ⚠️  iOS builds require macOS`)
            continue
          }
          const iosDir = './ios'
          if (existsSync(iosDir)) {
            const buildType = options?.release ? 'Release' : 'Debug'
            await new Promise<void>((resolve, reject) => {
              const proc = spawn('xcodebuild', [
                '-project', `${iosDir}/App.xcodeproj`,
                '-scheme', 'App',
                '-configuration', buildType,
                '-sdk', 'iphoneos',
                'build'
              ], { stdio: 'inherit' })
              proc.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`Exit ${code}`)))
              proc.on('error', reject)
            })
            console.log(`   ✅ iOS ${buildType} build complete`)
          }
else {
            console.log(`   ⚠️  No iOS project found. Run: craft ios init`)
          }
        }

        else if (platform === 'android') {
          const androidDir = './android'
          if (existsSync(androidDir)) {
            const task = options?.release ? 'assembleRelease' : 'assembleDebug'
            await new Promise<void>((resolve, reject) => {
              const proc = spawn('./gradlew', [task], {
                cwd: androidDir,
                stdio: 'inherit'
              })
              proc.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`Exit ${code}`)))
              proc.on('error', reject)
            })
            console.log(`   ✅ Android ${options?.release ? 'Release' : 'Debug'} build complete`)
          }
else {
            console.log(`   ⚠️  No Android project found. Run: craft android init`)
          }
        }

        else if (platform === 'macos' || platform === 'windows' || platform === 'linux') {
          const zigDir = existsSync('./packages/zig') ? './packages/zig' : '.'
          const optimizeFlag = options?.release ? '-Doptimize=ReleaseSafe' : ''
          await new Promise<void>((resolve, reject) => {
            const args = ['build']
            if (optimizeFlag) args.push(optimizeFlag)
            const proc = spawn('zig', args, {
              cwd: zigDir,
              stdio: 'inherit'
            })
            proc.on('exit', (code) => code === 0 ? resolve() : reject(new Error(`Exit ${code}`)))
            proc.on('error', reject)
          })
          console.log(`   ✅ ${platform} build complete`)
        }

      }
catch (error: any) {
        console.error(`   ❌ ${platform} build failed: ${error.message}`)
      }
    }

    console.log('\n✨ Build complete\n')
  })

// Dev command - launch with hot reload and dev tools enabled
cli
  .command('dev [url]', 'Launch in development mode with hot reload')
  .option('--title <title>', 'Window title', { default: 'Craft Dev' })
  .option('--width <width>', 'Window width', { default: 1200 })
  .option('--height <height>', 'Window height', { default: 800 })
  .example('craft dev http://localhost:3000')
  .action(async (url?: string, options?: any) => {
    const args = [
      '--url',
      url || 'http://localhost:3000',
      '--title',
      options?.title || 'Craft Dev',
      '--width',
      String(options?.width || 1200),
      '--height',
      String(options?.height || 800),
      '--hot-reload',
      '--dev-tools',
      '--dark-mode',
    ]

    try {
      await runCraftBinary(args)
    }
    catch (error: any) {
      console.error('Error:', error.message)
      process.exit(1)
    }
  })

// Package command - create installers
cli
  .command('package', 'Create installers for your Craft application')
  .option('--name <name>', 'Application name')
  .option('--version <version>', 'Application version')
  .option('--binary <path>', 'Path to application binary')
  .option('--description <text>', 'Application description')
  .option('--author <name>', 'Author/Maintainer name')
  .option('--bundle-id <id>', 'Bundle identifier (macOS/iOS)')
  .option('--out <dir>', 'Output directory (default: ./dist)')
  .option('--icon <path>', 'Application icon path')
  .option('--platforms <list>', 'Comma-separated platforms (macos,windows,linux)')
  .option('--config <path>', 'Load config from JSON file')
  .option('--dmg', 'Create DMG installer (macOS)')
  .option('--pkg', 'Create PKG installer (macOS)')
  .option('--msi', 'Create MSI installer (Windows)')
  .option('--zip', 'Create ZIP archive (Windows)')
  .option('--deb', 'Create DEB package (Linux)')
  .option('--rpm', 'Create RPM package (Linux)')
  .option('--appimage', 'Create AppImage (Linux)')
  .example('craft package --name "My App" --version "1.0.0" --binary ./build/myapp')
  .example('craft package --config package.json')
  .example('craft package --name "My App" --version "1.0.0" --binary ./build/myapp --platforms macos,windows,linux')
  .action(async (options?: any) => {
    const packageModule = await import('../src/package.js')
    const { packageApp } = packageModule

    let config: any

    // Load config from file or CLI args
    if (options?.config) {
      if (!existsSync(options.config)) {
        console.error(`❌ Config file not found: ${options.config}`)
        process.exit(1)
      }

      const configContent = await Bun.file(options.config).text()
      config = JSON.parse(configContent)
    }
    else {
      // Build config from CLI options
      if (!options?.name) {
        console.error('❌ --name is required')
        process.exit(1)
      }
      if (!options?.version) {
        console.error('❌ --version is required')
        process.exit(1)
      }
      if (!options?.binary) {
        console.error('❌ --binary is required')
        process.exit(1)
      }

      config = {
        name: options.name,
        version: options.version,
        binaryPath: options.binary,
        description: options.description,
        author: options.author,
        bundleId: options.bundleId,
        outDir: options.out,
        iconPath: options.icon,
        platforms: options.platforms?.split(','),
      }

      // Platform-specific options
      if (options.dmg || options.pkg) {
        config.macos = {
          dmg: options.dmg,
          pkg: options.pkg,
        }
      }

      if (options.msi || options.zip) {
        config.windows = {
          msi: options.msi,
          zip: options.zip,
        }
      }

      if (options.deb || options.rpm || options.appimage) {
        config.linux = {
          deb: options.deb,
          rpm: options.rpm,
          appImage: options.appimage,
        }
      }
    }

    console.log('📦 Craft Packaging Tool\n')
    console.log(`Application: ${config.name} v${config.version}`)
    console.log(`Platforms: ${(config.platforms || ['current']).join(', ')}\n`)

    try {
      const results = await packageApp(config)

      console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
      console.log('📊 Packaging Results\n')

      for (const result of results) {
        const status = result.success ? '✅' : '❌'
        const format = result.format.toUpperCase()

        console.log(`${status} ${result.platform}/${format}`)

        if (result.success && result.outputPath) {
          console.log(`   📁 ${result.outputPath}`)
        }
        else if (result.error) {
          console.log(`   ⚠️  ${result.error}`)
        }
      }

      const successCount = results.filter(r => r.success).length
      const totalCount = results.length

      console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
      console.log(`\n✨ Complete: ${successCount}/${totalCount} packages created\n`)

      process.exit(successCount === totalCount ? 0 : 1)
    }
    catch (error: any) {
      console.error(`\n❌ Error: ${error.message}\n`)
      process.exit(1)
    }
  })

// iOS commands
cli
  .command('ios init <name>', 'Initialize a new iOS project')
  .option('--bundle-id <id>', 'Bundle identifier (e.g., com.example.app)')
  .option('--team-id <id>', 'Apple Developer Team ID')
  .option('-o, --output <dir>', 'Output directory', { default: './ios' })
  .example('craft ios init MyApp')
  .example('craft ios init MyApp --bundle-id com.example.myapp')
  .action(async (name: string, options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const iosModule = await import('../dist/ios/src/index.js')
    await iosModule.init({
      name,
      bundleId: options?.bundleId,
      teamId: options?.teamId,
      output: options?.output || './ios',
    })
  })

cli
  .command('ios build', 'Build iOS project')
  .option('--html-path <path>', 'Path to HTML file')
  .option('-d, --dev-server <url>', 'Development server URL')
  .option('-o, --output <dir>', 'iOS project directory', { default: './ios' })
  .option('-w, --watch', 'Watch for file changes and rebuild')
  .example('craft ios build')
  .example('craft ios build --html-path ./dist/index.html')
  .example('craft ios build --dev-server http://localhost:3456')
  .example('craft ios build --watch')
  .action(async (options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const iosModule = await import('../dist/ios/src/index.js')

    const doBuild = async () => {
      await iosModule.build({
        htmlPath: options?.htmlPath,
        devServer: options?.devServer,
        output: options?.output || './ios',
      })
    }

    await doBuild()

    if (options?.watch) {
      console.log('\n👀 Watching for changes...\n')
      const { watch } = await import('node:fs')
      const { dirname } = await import('node:path')

      const watchPath = options?.htmlPath ? dirname(options.htmlPath) : '.'
      watch(watchPath, { recursive: true }, async (event, filename) => {
        if (filename && (filename.endsWith('.html') || filename.endsWith('.js') || filename.endsWith('.css'))) {
          console.log(`\n📝 ${filename} changed, rebuilding...`)
          await doBuild()
        }
      })

      // Keep process running
      await new Promise(() => {})
    }
  })

cli
  .command('ios open', 'Open iOS project in Xcode')
  .option('-o, --output <dir>', 'iOS project directory', { default: './ios' })
  .action(async (options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const iosModule = await import('../dist/ios/src/index.js')
    await iosModule.open({
      output: options?.output || './ios',
    })
  })

cli
  .command('ios run', 'Build and run on iOS device or simulator')
  .option('-s, --simulator', 'Run on simulator instead of device')
  .option('-o, --output <dir>', 'iOS project directory', { default: './ios' })
  .example('craft ios run')
  .example('craft ios run --simulator')
  .action(async (options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const iosModule = await import('../dist/ios/src/index.js')
    await iosModule.run({
      simulator: options?.simulator || false,
      output: options?.output || './ios',
    })
  })

// Android commands
cli
  .command('android init <name>', 'Initialize a new Android project')
  .option('--package <name>', 'Package name (e.g., com.example.app)')
  .option('-o, --output <dir>', 'Output directory', { default: './android' })
  .example('craft android init MyApp')
  .example('craft android init MyApp --package com.example.myapp')
  .action(async (name: string, options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const androidModule = await import('../dist/android/src/index.js')
    await androidModule.init({
      name,
      packageName: options?.package,
      output: options?.output || './android',
    })
  })

cli
  .command('android build', 'Build Android project')
  .option('--html-path <path>', 'Path to HTML file')
  .option('-d, --dev-server <url>', 'Development server URL')
  .option('-o, --output <dir>', 'Android project directory', { default: './android' })
  .option('--release', 'Build release APK')
  .option('-w, --watch', 'Watch for file changes and rebuild')
  .example('craft android build')
  .example('craft android build --release')
  .example('craft android build --watch')
  .action(async (options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const androidModule = await import('../dist/android/src/index.js')

    const doBuild = async () => {
      await androidModule.build({
        htmlPath: options?.htmlPath,
        devServer: options?.devServer,
        output: options?.output || './android',
        release: options?.release || false,
      })
    }

    await doBuild()

    if (options?.watch) {
      console.log('\n👀 Watching for changes...\n')
      const { watch } = await import('node:fs')
      const { dirname } = await import('node:path')

      const watchPath = options?.htmlPath ? dirname(options.htmlPath) : '.'
      watch(watchPath, { recursive: true }, async (event, filename) => {
        if (filename && (filename.endsWith('.html') || filename.endsWith('.js') || filename.endsWith('.css'))) {
          console.log(`\n📝 ${filename} changed, rebuilding...`)
          await doBuild()
        }
      })

      // Keep process running
      await new Promise(() => {})
    }
  })

cli
  .command('android open', 'Open Android project in Android Studio')
  .option('-o, --output <dir>', 'Android project directory', { default: './android' })
  .action(async (options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const androidModule = await import('../dist/android/src/index.js')
    await androidModule.open({
      output: options?.output || './android',
    })
  })

cli
  .command('android run', 'Build and run on Android device or emulator')
  .option('-d, --device <id>', 'Target device ID')
  .option('-o, --output <dir>', 'Android project directory', { default: './android' })
  .example('craft android run')
  .example('craft android run --device emulator-5554')
  .action(async (options?: any) => {
    // @ts-ignore -- sibling package may not exist at typecheck time
    const androidModule = await import('../dist/android/src/index.js')
    await androidModule.run({
      device: options?.device,
      output: options?.output || './android',
    })
  })

// Preview command - preview app in browser
cli
  .command('preview [path]', 'Preview app in browser before building native')
  .option('-p, --port <port>', 'Port to serve on', { default: 3456 })
  .option('--host <host>', 'Host to bind to', { default: 'localhost' })
  .example('craft preview ./dist')
  .example('craft preview ./index.html --port 8080')
  .action(async (path?: string, options?: any) => {
    const servePath = path || '.'
    const port = options?.port || 3456
    const host = options?.host || 'localhost'

    console.log(`\n🌐 Starting preview server...`)
    console.log(`   Path: ${servePath}`)
    console.log(`   URL: http://${host}:${port}\n`)

    const { spawn } = await import('node:child_process')

    // Use bunx serve for simple static file serving
    const proc = spawn('bunx', ['--bun', 'serve', '-p', String(port), servePath], {
      stdio: 'inherit',
    })

    proc.on('error', () => {
      console.log('Falling back to python http.server...')
      spawn('python3', ['-m', 'http.server', String(port), '--directory', servePath], {
        stdio: 'inherit',
      })
    })
  })

// Publish command - publish to App Store / Play Store
cli
  .command('publish', 'Publish app to App Store or Play Store')
  .option('--ios', 'Publish to App Store (TestFlight)')
  .option('--android', 'Publish to Play Store')
  .option('--api-key <path>', 'App Store Connect API key path')
  .option('--service-account <path>', 'Google Play service account JSON')
  .option('-o, --output <dir>', 'Project directory', { default: '.' })
  .example('craft publish --ios')
  .example('craft publish --android')
  .action(async (options?: any) => {
    const { existsSync } = await import('node:fs')
    const { join } = await import('node:path')
    const { $ } = await import('bun')

    if (options?.ios) {
      console.log('\n📱 Publishing to App Store (TestFlight)...\n')

      const iosDir = join(options?.output || '.', 'ios')
      if (!existsSync(iosDir)) {
        console.error('❌ No iOS project found. Run: craft ios init')
        process.exit(1)
      }

      // Find xcarchive or build it
      console.log('1. Building archive...')
      try {
        await $`cd ${iosDir} && xcodebuild -scheme App -configuration Release -archivePath ./build/App.xcarchive archive`
        console.log('✅ Archive created')

        console.log('2. Exporting IPA...')
        await $`cd ${iosDir} && xcodebuild -exportArchive -archivePath ./build/App.xcarchive -exportPath ./build -exportOptionsPlist ExportOptions.plist`
        console.log('✅ IPA exported')

        console.log('3. Uploading to TestFlight...')
        if (options?.apiKey) {
          await $`xcrun altool --upload-app -f ${iosDir}/build/*.ipa --apiKey ${options.apiKey} --type ios`
        }
else {
          await $`xcrun altool --upload-app -f ${iosDir}/build/*.ipa --type ios`
        }
        console.log('✅ Uploaded to TestFlight!')
      }
catch (error) {
        console.error('❌ Publish failed. Make sure you have:')
        console.error('   - Valid signing certificates')
        console.error('   - App Store Connect API key (--api-key)')
        console.error('   - ExportOptions.plist in your ios directory')
      }
    }

    if (options?.android) {
      console.log('\n🤖 Publishing to Play Store...\n')

      const androidDir = join(options?.output || '.', 'android')
      if (!existsSync(androidDir)) {
        console.error('❌ No Android project found. Run: craft android init')
        process.exit(1)
      }

      console.log('1. Building release AAB...')
      try {
        await $`cd ${androidDir} && ./gradlew bundleRelease`
        console.log('✅ AAB created')

        const aabPath = join(androidDir, 'app/build/outputs/bundle/release/app-release.aab')

        if (options?.serviceAccount) {
          console.log('2. Uploading to Play Store...')
          // Would use Google Play Developer API here
          console.log('⚠️  Automatic Play Store upload requires fastlane or Google Play API integration.')
          console.log(`   AAB file: ${aabPath}`)
          console.log('   Upload manually via Play Console or use:')
          console.log('   fastlane supply --aab ' + aabPath)
        }
else {
          console.log('✅ Release AAB ready:')
          console.log(`   ${aabPath}`)
          console.log('')
          console.log('Upload manually via Play Console, or use fastlane:')
          console.log('  fastlane supply --aab ' + aabPath)
        }
      }
catch (error) {
        console.error('❌ Build failed. Make sure you have:')
        console.error('   - Valid signing key (keystore)')
        console.error('   - Release signing config in build.gradle.kts')
      }
    }

    if (!options?.ios && !options?.android) {
      console.log('Please specify a platform:')
      console.log('  craft publish --ios     # Publish to App Store')
      console.log('  craft publish --android # Publish to Play Store')
    }
  })

// Init command - initialize a new Craft project
cli
  .command('init <name>', 'Initialize a new Craft project')
  .option('--template <type>', 'Project template (blank, tabs, drawer, dashboard, desktop, ios, android, all)', { default: 'blank' })
  .option('--bundle-id <id>', 'Bundle identifier for mobile')
  .example('craft init MyApp')
  .example('craft init MyApp --template tabs')
  .example('craft init MyApp --template dashboard')
  .example('craft init MyApp --template all')
  .action(async (name: string, options?: any) => {
    console.log(`\n⚡ Creating new Craft project: ${name}\n`)

    const template = options?.template || 'blank'
    const bundleId = options?.bundleId || `com.example.${name.toLowerCase().replace(/[^a-z0-9]/g, '')}`
    const appNameSlug = name.toLowerCase().replace(/[^a-z0-9]/g, '-')

    const { mkdirSync, writeFileSync, existsSync, readdirSync, readFileSync, cpSync } = await import('node:fs')
    const { join, dirname } = await import('node:path')

    // Helper to replace template variables
    const replaceVars = (content: string): string => {
      return content
        .replace(/\{\{APP_NAME\}\}/g, name)
        .replace(/\{\{APP_NAME_SLUG\}\}/g, appNameSlug)
        .replace(/\{\{BUNDLE_ID\}\}/g, bundleId)
        .replace(/\{\{AUTHOR\}\}/g, 'Developer')
    }

    // Helper to copy template directory
    const copyTemplate = async (templateName: string, destDir: string) => {
      const templateDir = join(import.meta.dir, 'templates/projects', templateName)

      if (!existsSync(templateDir)) {
        console.log(`   ⚠️  Template '${templateName}' not found, using blank template`)
        return false
      }

      const copyRecursive = (src: string, dest: string) => {
        if (!existsSync(dest)) {
          mkdirSync(dest, { recursive: true })
        }

        const entries = readdirSync(src, { withFileTypes: true })

        for (const entry of entries) {
          const srcPath = join(src, entry.name)
          const destPath = join(dest, entry.name)

          if (entry.isDirectory()) {
            copyRecursive(srcPath, destPath)
          }
else {
            const content = readFileSync(srcPath, 'utf-8')
            const processedContent = replaceVars(content)
            writeFileSync(destPath, processedContent)
          }
        }
      }

      copyRecursive(templateDir, destDir)
      return true
    }

    // Create project from template
    if (['blank', 'tabs', 'drawer', 'dashboard'].includes(template)) {
      console.log(`📁 Creating ${template} project from template...`)

      if (!existsSync(name)) {
        mkdirSync(name, { recursive: true })
      }

      const copied = await copyTemplate(template, name)

      if (!copied) {
        // Fallback: create basic project inline
        mkdirSync(join(name, 'src'), { recursive: true })

        writeFileSync(join(name, 'index.html'), replaceVars(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{APP_NAME}}</title>
</head>
<body>
  <div id="app">
    <h1>{{APP_NAME}}</h1>
    <p>Built with Craft</p>
  </div>
</body>
</html>`))

        writeFileSync(join(name, 'package.json'), replaceVars(JSON.stringify({
          name: '{{APP_NAME_SLUG}}',
          version: '1.0.0',
          private: true,
          type: 'module',
          scripts: {
            dev: 'craft dev',
            build: 'craft build'
          },
          dependencies: {
            'craft-native': `^${version}`
          }
        }, null, 2)))
      }

      pinCraftNativeDependency(join(name, 'package.json'), version)

      console.log(`✅ ${template} project created`)
    }

    if (template === 'desktop' || template === 'all') {
      console.log('📁 Creating desktop project structure...')

      if (!existsSync(name)) {
        mkdirSync(name, { recursive: true })
      }

      // Create craft.config.ts
      const configContent = `import type { CraftConfig } from 'craft-native'

export default {
  name: '${name}',
  window: {
    title: '${name}',
    width: 1200,
    height: 800,
    darkMode: true,
  },
} satisfies CraftConfig
`
      writeFileSync(`${name}/craft.config.ts`, configContent)

      // Create index.html
      const htmlContent = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${name}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, system-ui, sans-serif;
      background: #1a1a2e;
      color: white;
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
    }
    .container { text-align: center; }
    h1 { font-size: 3rem; margin-bottom: 1rem; }
    p { opacity: 0.7; }
  </style>
</head>
<body>
  <div class="container">
    <h1>⚡ ${name}</h1>
    <p>Built with Craft</p>
  </div>
</body>
</html>
`
      writeFileSync(`${name}/index.html`, htmlContent)

      // Create package.json
      const packageJson = {
        name: appNameSlug,
        version: '0.1.0',
        private: true,
        scripts: {
          dev: 'craft dev http://localhost:3000',
          build: 'craft build',
          'ios:init': 'craft ios init ' + name,
          'ios:build': 'craft ios build',
          'ios:open': 'craft ios open',
        },
        devDependencies: {
          'craft-native': `^${version}`,
        },
      }
      writeFileSync(`${name}/package.json`, JSON.stringify(packageJson, null, 2))
      pinCraftNativeDependency(`${name}/package.json`, version)

      console.log('✅ Desktop project created')
    }

    if (template === 'ios' || template === 'all') {
      console.log('📱 Creating iOS project...')
      // @ts-ignore -- sibling package may not exist at typecheck time
    const iosModule = await import('../dist/ios/src/index.js')
      await iosModule.init({
        name,
        bundleId: options?.bundleId,
        output: template === 'all' ? `${name}/ios` : './ios',
      })
      console.log('✅ iOS project created')
    }

    if (template === 'android' || template === 'all') {
      console.log('🤖 Creating Android project...')
      // @ts-ignore -- sibling package may not exist at typecheck time
    const androidModule = await import('../dist/android/src/index.js')
      await androidModule.init({
        name,
        packageName: options?.bundleId,
        output: template === 'all' ? `${name}/android` : './android',
      })
      console.log('✅ Android project created')
    }

    console.log('')
    console.log('Next steps:')
    console.log(`  cd ${name}`)
    console.log('  bun install')
    if (template === 'desktop' || template === 'all') {
      console.log('  craft dev http://localhost:3000')
    }
    if (template === 'ios' || template === 'all') {
      console.log('  craft ios build')
      console.log('  craft ios open')
    }
    if (template === 'android' || template === 'all') {
      console.log('  craft android build')
      console.log('  craft android open')
    }
    console.log('')
  })

cli.version(version)
cli.help()
cli.parse()
