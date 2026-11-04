/**
 * Browser-safe Craft mobile runtime.
 *
 * Import this entrypoint from code that is bundled into an STX, web, or mobile
 * application. The root SDK also contains desktop packaging and process APIs,
 * which intentionally target Bun and must not enter a browser bundle.
 */
export * from './api/mobile.js'

export { matchNativePath, normalizeNativePath } from './native-routing.js'
export type { NativePathMatch, NativeParameterConstraint, NativeRouteConstraints } from './native-routing.js'
