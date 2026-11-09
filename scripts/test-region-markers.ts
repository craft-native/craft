/**
 * Keep a test's region boundaries pointing at something.
 *
 * Many tests in this repository assert against one function rather than a
 * whole generated file, by slicing between two markers:
 *
 * ```ts
 * const body = bridge.slice(bridge.indexOf('fun openPDF('), bridge.indexOf('// ==== Contacts Picker'))
 * ```
 *
 * `indexOf` answers -1 for a marker that is no longer there, and
 * `slice(start, -1)` is not an error — it means "to the last character". So a
 * renamed or deleted boundary silently widens the region to the rest of the
 * file, and the assertions stop being about the function at all. The test goes
 * on passing, satisfied by anything that happens to appear later.
 *
 * Both instances found by this check were exactly that. `openPDF`'s region was
 * 845 lines instead of 42, because the generated bridge spells its next
 * section `Contacts Picker` and the test said `Contact Picker`; the tail it
 * wrongly swallowed held 3 and 38 further occurrences of the two guards it was
 * meant to be proving. `receivePushToken`'s region ended at
 * `receiveNotificationResponse`, a function another test in the same file
 * asserts has been deliberately removed.
 *
 * Only slice boundaries are checked, not every `indexOf` in a test: comparing
 * two positions is a legitimate use of -1, and building a marker string to
 * assert on is not a boundary at all.
 */
import { blankLiterals } from './test-deadline-budgets'

/** A string literal used to locate one end of a sliced region. */
export interface RegionMarker {
  file: string
  marker: string
}

/**
 * Markers passed to `indexOf`/`lastIndexOf` inside a `.slice(…)` call.
 *
 * Paren matching runs over the source with string and comment contents
 * blanked, because the markers themselves contain unbalanced parens — a
 * boundary like `'private fun updateImage('` otherwise runs the counter away
 * and swallows the rest of the file, which is the same defect in the scanner
 * as the one it is looking for.
 */
export function readRegionMarkers(file: string, source: string, maxArgumentLength = 600): RegionMarker[] {
  const code = blankLiterals(source)
  const markers: RegionMarker[] = []
  for (const call of code.matchAll(/\.slice\(/g)) {
    const open = call.index + '.slice('.length
    let depth = 0, end = -1
    for (let index = open; index < code.length; index++) {
      if (code[index] === '(') depth++
      else if (code[index] === ')') {
        if (depth === 0) { end = index; break }
        depth--
      }
    }
    if (end < 0) continue
    const args = source.slice(open, end)
    // A runaway match is not a boundary list; skip rather than guess at it.
    if (args.length > maxArgumentLength) continue
    for (const found of args.matchAll(/(?:lastIndexOf|indexOf)\((['"])((?:\\.|(?!\1).)*?)\1/g)) {
      const marker = found[2]!.replace(/\\'/g, '\'').replace(/\\"/g, '"').replace(/\\\\/g, '\\').replace(/\\n/g, '\n')
      // Short markers collide by accident; interpolated ones are not literals.
      if (marker.length < 6 || marker.includes('${')) continue
      markers.push({ file, marker })
    }
  }
  return markers
}

/** Markers that no longer appear in `corpus`, so their region is degenerate. */
export function findStaleRegionMarkers(markers: readonly RegionMarker[], corpus: string): RegionMarker[] {
  return markers.filter(entry => !corpus.includes(entry.marker))
}

/** One line per stale marker, naming the file and what it was looking for. */
export function describeStaleMarker(entry: RegionMarker): string {
  return `${entry.file}: ${JSON.stringify(entry.marker)} matches nothing, so its slice runs to the end of the file instead of bounding the region.`
}
