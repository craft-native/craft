import { mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

/** Destination of the XCTest bundle while the native test process runs. */
export function nativeTestResultBundle(workspace: string, evidencePath?: string, name = 'TestResults.xcresult'): string {
  const result = evidencePath ? resolve(evidencePath) : join(workspace, name)
  // xcodebuild creates the bundle itself and refuses an existing destination.
  mkdirSync(dirname(result), { recursive: true })
  return result
}
