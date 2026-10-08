import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'bun:test'

const root = join(import.meta.dir, '..')
const ios = readFileSync(join(root, 'packages/ios/templates/CraftNativeScreen.swift'), 'utf8')
const android = readFileSync(join(root, 'packages/android/templates/MainActivityNative.kt.template'), 'utf8')

/** One host-neutral vocabulary, asserted against every generated renderer. */
const COMPONENTS: Array<[string, string, string]> = [
  ['Text', 'case "Text":', '"Text" ->'],
  ['Button', 'case "Button", "Link":', '"Button" ->'],
  ['Link', 'case "Button", "Link":', '"Link" ->'],
  ['Switch', 'case "Switch":', '"Switch" ->'],
  ['TextInput', 'case "TextInput":', '"TextInput" ->'],
  ['Image', 'case "Image":', '"Image" ->'],
  ['ScrollView', 'case "ScrollView":', '"ScrollView" ->'],
  ['FlatList', 'case "FlatList":', '"FlatList" ->'],
]

describe('native renderer component contract', () => {
  it('keeps the same host-neutral controls on iOS and Android', () => {
    for (const [name, iosMarker, androidMarker] of COMPONENTS) {
      expect(ios, `${name} missing from iOS renderer`).toContain(iosMarker)
      expect(android, `${name} missing from Android renderer`).toContain(androidMarker)
    }
  })

  it('keeps native capability and WebView fallback gates intact', () => {
    expect(ios).toContain('mutationProtocolVersion: 1')
    expect(android).toContain('mutationProtocolVersion: 1')
    expect(ios).toContain('Missing dist/native-screen.js')
    expect(android).toContain('Missing native-screen.js')
  })
})
