import { expect, test } from 'bun:test'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createTempDir, removeTempDir } from '../../typescript/src/temp-dir'

test.skipIf(process.platform !== 'darwin')('observes one switch gesture without retrying the tap', async () => {
  const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
  const start = template.indexOf('    func switchFlipped(')
  const end = template.indexOf('    func press(', start)
  expect(start).toBeGreaterThan(0)
  expect(end).toBeGreaterThan(start)
  // One tap is one gesture. Observe its result without hiding a dropped event.
  expect(template).toContain('flipped = switchFlipped(from: before, to: target.value as? String)')
  expect(template).toContain('check(flipped, "tapid \\(arg) flips the switch")')
  const tapid = template.slice(template.indexOf('case "tapid":'), template.indexOf('case "longpressid":'))
  expect(tapid).not.toContain('for _ in')
  expect(tapid.match(/press\(target\)/g)?.length).toBe(2)
  const dir = createTempDir('craft-driver-switch-')
  try {
    const source = join(dir, 'main.swift')
    writeFileSync(source, `import Foundation
${template.slice(start, end)}
// HQ's agreement switch took a tap and stayed off (ReviewOS job 7570).
precondition(!switchFlipped(from: "0", to: "0"))
precondition(switchFlipped(from: "0", to: "1"))
precondition(switchFlipped(from: "1", to: "0"))
// Missing/non-Boolean evidence cannot prove a flip, even if a tap was delivered.
for before in [nil, "", "On", "unknown", "0", "1"] as [String?] {
    for after in [nil, "", "On", "unknown", "0", "1"] as [String?] {
        let expected = (before == "0" && after == "1") || (before == "1" && after == "0")
        precondition(switchFlipped(from: before, to: after) == expected)
    }
}
print("driver switch tap passed")
`)
    const child = Bun.spawn(['swift', source], { stdout: 'pipe', stderr: 'pipe' })
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited])
    expect(code, stdout + stderr).toBe(0)
    expect(stdout).toContain('driver switch tap passed')
  }
  finally { removeTempDir(dir) }
}, 60_000)

const template = readFileSync(join(import.meta.dir, '../templates/testing/DriverTests.swift.template'), 'utf8')
/** The driver's source with comments stripped: prose is not behaviour. */
const driver = template.replace(/^\s*\/\/[^\n]*$/gm, '')
const tapidCase = driver.slice(driver.indexOf('case "tapid":'), driver.indexOf('case "longpressid":'))

test('the switch gesture aims at a control that has stopped moving', () => {
  // A journey that flicks the page (`swipe up` is `app.swipeUp()`, which
  // unlike `scrollto` and `drag` does not end with a hold) leaves the scroll
  // view decelerating. A touch landing on a decelerating scroll view stops
  // the scroll instead of reaching the control, which is the shape of HQ
  // agreement job 7570: first switch after the flick dropped, second one
  // seconds later fine (#449).
  expect(tapidCase, 'the frame must be read once it is stable').toContain('settledFrame(target)')
  // Waiting is allowed; a second gesture is not. Both still hold.
  expect(tapidCase).not.toContain('for _ in')
  expect(tapidCase.match(/press\(target\)/g)?.length).toBe(2)
})

test('settling only ever waits', () => {
  const start = driver.indexOf('    func settledFrame(')
  expect(start, 'the driver must be able to wait for a control to come to rest').toBeGreaterThan(0)
  const body = driver.slice(start, driver.indexOf('\n    }', start))
  // The one thing this helper must never do.
  for (const gesture of ['.tap()', 'press(', 'swipe', 'coordinate(']) {
    expect(body, `settledFrame must not ${gesture}`).not.toContain(gesture)
  }
  // It returns as soon as two consecutive reads agree, rather than always
  // spending its budget.
  expect(body).toContain('if next.equalTo(frame) { return frame }')
})

test('the observation can tell a moving control from an ignored tap', () => {
  // frameBefore alone cannot: a control that was still in flight when it was
  // tapped and one that sat still and dropped the touch look identical.
  expect(tapidCase).toContain('"frameBefore"')
  expect(tapidCase).toContain('"frameAfter"')
  // Read after the settle window, so it reflects where the control came to
  // rest rather than where it was when the gesture was synthesised.
  const after = tapidCase.indexOf('let frameAfter = target.frame')
  const settleLoop = tapidCase.indexOf('} while !flipped && Date() < settle')
  expect(after, 'frameAfter must be read after the settle loop').toBeGreaterThan(settleLoop)
})
