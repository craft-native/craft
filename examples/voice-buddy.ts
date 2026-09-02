#!/usr/bin/env bun
/**
 * Buddy - Voice AI Code Assistant
 *
 * A voice-controlled AI assistant for coding tasks.
 * Built with STX and Craft for native desktop experience.
 *
 * Run with: bun examples/voice-buddy.ts
 *
 * Features:
 * - Voice recognition for commands
 * - Multiple AI driver support (Claude, OpenAI, Ollama)
 * - GitHub integration
 * - Repository management
 * - System tray support
 */

import { createApp } from '../packages/typescript/src/index.ts'
import { readFileSync } from 'node:fs'

// Path to the STX file
const stxPath = '/Users/glennmichaeltorregosa/Documents/Projects/stx/examples/voice-buddy.stx'

// Read the STX file content (it's HTML)
let html: string
try {
  html = readFileSync(stxPath, 'utf-8')
  console.log('✅ Loaded voice-buddy.stx')
}
catch (e) {
  console.error(`❌ Failed to load STX file: ${stxPath}`)
  console.error('   Make sure the file exists at the specified path.')
  process.exit(1)
}

async function main() {
  console.log('🤖 Starting Buddy - Voice AI Code Assistant...')
  console.log('')
  console.log('📋 Features:')
  console.log('  • Voice recognition (hold mic button or Space)')
  console.log('  • Text input fallback')
  console.log('  • Multiple AI drivers (Claude, OpenAI, Ollama)')
  console.log('  • GitHub integration')
  console.log('  • Repository cloning & management')
  console.log('')
  console.log('🎤 Voice Commands:')
  console.log('  • "Update the README..."')
  console.log('  • "Fix the bug in..."')
  console.log('  • "Add a new feature..."')
  console.log('  • "Refactor the code..."')
  console.log('')

  const app = createApp({
    html,
    window: {
      title: 'Buddy - Voice AI Code Assistant',
      width: 1000,
      height: 800,
      resizable: true,
      systemTray: true,
      darkMode: true,
      hotReload: true,
      devTools: true,
    },
  })

  try {
    await app.show()
    console.log('\n✅ Buddy closed')
  }
catch (error) {
    console.error('\n❌ Error:', error)
    process.exit(1)
  }
}

main()
