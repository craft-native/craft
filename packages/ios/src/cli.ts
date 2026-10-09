#!/usr/bin/env bun
/**
 * Craft iOS CLI
 *
 * Build native iOS apps from web content using Craft's iOS template.
 *
 * Usage:
 *   craft-ios init <name>     - Initialize a new iOS project
 *   craft-ios build           - Build web assets and generate Xcode project
 *   craft-ios open            - Open Xcode project
 *   craft-ios run             - Build and run on simulator
 */

import { parseArgs } from 'util'
import { init, build, open, run } from './index'

const { values, positionals } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    help: { type: 'boolean', short: 'h' },
    version: { type: 'boolean', short: 'v' },
    name: { type: 'string', short: 'n' },
    'bundle-id': { type: 'string', short: 'b' },
    'team-id': { type: 'string', short: 't' },
    renderer: { type: 'string' },
    'html-path': { type: 'string' },
    'native-bundle': { type: 'string' },
    'dev-server': { type: 'string', short: 'd' },
    output: { type: 'string', short: 'o' },
    simulator: { type: 'boolean', short: 's' },
  },
  allowPositionals: true,
})

const command = positionals[0]

if (values.help || !command) {
  console.log(`
Craft iOS - Build native iOS apps with web technologies

Usage:
  craft-ios <command> [options]

Commands:
  init <name>     Initialize a new iOS project
  build           Build web assets and generate Xcode project
  open            Open Xcode project
  run             Build and run on simulator

Options:
  -n, --name <name>         App name
  -b, --bundle-id <id>      Bundle identifier (e.g., com.example.app)
  -t, --team-id <id>        Apple Developer Team ID
  --renderer <kind>         iOS renderer: web (default) or native
  --html-path <path>        Path to HTML file or directory
  --native-bundle <path>    JavaScript bundle from \`stx native compile\`
  -d, --dev-server <url>    Development server URL
  -o, --output <dir>        Output directory (default: ./ios)
  -s, --simulator           Run on simulator instead of device
  -h, --help                Show help
  -v, --version             Show version

Examples:
  craft-ios init MyApp
  craft-ios build --html-path ./dist/index.html
  craft-ios init MyApp --renderer native
  craft-ios build --native-bundle ./screen.js
  craft-ios build --dev-server http://localhost:3456
  craft-ios run --simulator
`)
  process.exit(0)
}

if (values.version) {
  console.log('craft-ios v0.1.0')
  process.exit(0)
}

async function main() {
  try {
    switch (command) {
      case 'init':
        await init({
          name: positionals[1] || values.name || 'CraftApp',
          bundleId: values['bundle-id'],
          teamId: values['team-id'],
          output: values.output || './ios',
          config: values.renderer ? { renderer: values.renderer as 'web' | 'native' } : undefined,
        })
        break

      case 'build':
        await build({
          htmlPath: values['html-path'],
          nativeBundlePath: values['native-bundle'],
          devServer: values['dev-server'],
          output: values.output || './ios',
        })
        break

      case 'open':
        await open({
          output: values.output || './ios',
        })
        break

      case 'run':
        await run({
          simulator: values.simulator || false,
          output: values.output || './ios',
        })
        break

      default:
        console.error(`Unknown command: ${command}`)
        console.log('Run craft-ios --help for usage')
        process.exit(1)
    }
  }
catch (error) {
    console.error('Error:', error instanceof Error ? error.message : error)
    process.exit(1)
  }
}

main()
