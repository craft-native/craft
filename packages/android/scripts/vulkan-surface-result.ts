/** Required native display/lifecycle outcomes, read from the installed test APK. */
export interface NativeVulkanResult {
  status: 'passed'
  nativeActivities: 2
  nativeSessions: number
  actualGpuFrames: number
  nativeInputEvents: 2
  nativeCaptures: 5
  fullDisplayedPixelsMatched: true
  webViewUsed: false
  disposed: true
}

export function nativeVulkanResult(value: unknown): NativeVulkanResult {
  const invalid = (): never => { throw new Error('Native Android acceptance did not complete every pixel, lifecycle, input and disposal gate') }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return invalid()
  const result = value as Record<string, unknown>
  const count = (key: string, minimum: number): boolean => typeof result[key] === 'number' && Number.isSafeInteger(result[key]) && result[key] >= minimum
  if (result.status !== 'passed' || result.nativeActivities !== 2 || !count('actualGpuFrames', 370) || !count('nativeSessions', 4)
    || result.nativeInputEvents !== 2 || result.nativeCaptures !== 5 || result.fullDisplayedPixelsMatched !== true || result.webViewUsed !== false || result.disposed !== true) return invalid()
  return result as unknown as NativeVulkanResult
}
