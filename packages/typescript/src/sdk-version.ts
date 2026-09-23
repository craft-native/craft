import { version } from '../package.json'

// Bundlers embed the value, so both ESM and CJS work after the build checkout
// disappears. Source consumers still read the same package manifest.
export const SDK_VERSION: string = version
