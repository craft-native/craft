import { afterAll, expect, test } from 'bun:test'
import { existsSync, rmSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { createTempDir, removeAllTempDirs } from '../packages/typescript/src/temp-dir'

// Every scratch directory this file made goes when the file is done (#357).
afterAll(removeAllTempDirs)

const root = resolve(import.meta.dir, '..')
const adapterDir = join(root, 'packages/ts-maps')
const tsc = join(root, 'packages/typescript/scripts/tsc.ts')

// The adapter's public declarations import and re-export `ts-maps`, so a
// consumer that installs only the adapter must get it too (#455). This packs
// the adapter as npm would, installs it on its own outside the workspace, and
// type-checks a consumer that names nothing but the adapter.
//
// `ts-maps`'s own published declarations carry three defects that no consumer
// setting other than skipLibCheck hides. They are allowed here, and only
// these, so that one appearing in the adapter's files or the consumer's still
// fails, and a new one upstream is noticed.
const upstreamDefects = [
  /^node_modules\/ts-maps\/dist\/core-map\/geo\/projection\/Projection\.(Spherical)?Mercator\.d\.ts\(\d+,\d+\): error TS2304: Cannot find name 'ProjectionLike'\.$/,
  /^node_modules\/ts-maps\/dist\/core-map\/pmtiles\/PMTiles\.d\.ts\(\d+,\d+\): error TS1221: Generators are not allowed in an ambient context\.$/,
]

const consumer = `
import {
  LatLng,
  createMap,
  createMapView,
  latLngToCraftCoord,
  craftCoordToLatLng,
  type Coordinate,
  type MapCamera,
} from '@craft-native/ts-maps'

// Re-exported straight from ts-maps.
const point: LatLng = new LatLng(51.5, -0.12)
void createMap
// The adapter's own surface, in terms of ts-maps' types.
const coord: Coordinate = latLngToCraftCoord(point)
const back: LatLng = craftCoordToLatLng(coord)
const camera: MapCamera | undefined = undefined
void [back, camera, createMapView]

// @ts-expect-error a Craft coordinate's latitude is a number
const wrong: string = coord.latitude
// @ts-expect-error the adapter takes a ts-maps LatLng, not a bare pair
latLngToCraftCoord([51.5, -0.12])
void wrong
`

function run(args: string[], cwd: string): { code: number, output: string } {
  const result = Bun.spawnSync([process.execPath, ...args], { cwd, stdout: 'pipe', stderr: 'pipe' })
  return { code: result.exitCode, output: `${result.stdout}${result.stderr}` }
}

function must(args: string[], cwd: string): void {
  const { code, output } = run(args, cwd)
  if (code !== 0) throw new Error(`${args.join(' ')} failed:\n${output}`)
}

function typeCheck(cwd: string, skipLibCheck: boolean): string[] {
  const { output } = run([
    tsc, 'consumer.ts', '--noEmit', '--strict', '--skipLibCheck', String(skipLibCheck),
    '--module', 'esnext', '--moduleResolution', 'bundler', '--target', 'esnext',
    '--lib', 'esnext,dom', '--types', '', '--ignoreConfig',
  ], cwd)
  return output.split('\n').map(line => line.trim()).filter(line => line.includes('error TS'))
}

test('the packed maps adapter type-checks on its own, with ts-maps arriving as its dependency', () => {
  const temp = createTempDir('craft-ts-maps-package-')
  try {
    must(['run', 'build'], adapterDir)
    must(['pm', 'pack', '--filename', join(temp, 'adapter.tgz')], adapterDir)
    writeFileSync(join(temp, 'package.json'), JSON.stringify({
      private: true,
      type: 'module',
      dependencies: { '@craft-native/ts-maps': `file:${join(temp, 'adapter.tgz')}` },
    }))
    must(['install'], temp)
    must(['install', '--frozen-lockfile'], temp)
    // Nothing but the adapter was asked for, so ts-maps is there only because
    // the adapter depends on it.
    expect(existsSync(join(temp, 'node_modules/ts-maps/package.json'))).toBe(true)

    writeFileSync(join(temp, 'consumer.ts'), consumer)

    const strict = typeCheck(temp, false)
    const ours = strict.filter(line => !upstreamDefects.some(defect => defect.test(line)))
    expect(ours).toEqual([])

    // With skipLibCheck, as most consumers build, nothing is reported at all.
    expect(typeCheck(temp, true)).toEqual([])
  }
  finally {
    rmSync(temp, { recursive: true, force: true })
  }
}, 180_000)
