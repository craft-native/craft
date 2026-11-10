import { expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The hosts survive the media server restarting.
 *
 * `AVAudioSession.mediaServicesWereResetNotification` is the one audio signal
 * that is not an interruption and does not recover like one: every audio
 * object the process holds is orphaned. An orphaned `AVQueuePlayer` can be
 * told to play and produce nothing, never reaches the end of its item, and so
 * never reports anything; an orphaned `AVAudioEngine` can be started and pull
 * no graph, and posts no configuration-change notification for it either.
 *
 * Nothing in these templates observed it. A sound playing across a reset left
 * the script a handle that was silent forever, `pause`/`resume` answering
 * `true` about nothing, and a session claim that was never released — while
 * Android already surfaces the same loss, because `MediaPlayer` raises
 * `MEDIA_ERROR_SERVER_DIED` through the error listener the shell installs,
 * which removes the sound and emits `error`.
 *
 * The two hosts here recover differently, on purpose: a file player's
 * playhead does not survive the reset, so `CraftNativeSounds` releases the
 * handle and reports the loss, while a Web Audio graph is pure synthesis
 * holding no AVFoundation object, so `CraftWebAudio` gives every live context
 * a fresh source node on a fresh engine and keeps playing.
 *
 * Comments are stripped before scanning: a note about observing a
 * notification is not an observer.
 */
const strip = (source: string): string => source.replace(/^\s*\/\/[^\n]*$/gm, '').replace(/^\s*\/\/\/[^\n]*$/gm, '')
/** Only the sound service: the file holds several classes with an `init`. */
const servicesFile = strip(readFileSync(join(import.meta.dir, '../templates/CraftNativeServices.swift'), 'utf8'))
const soundsAt = servicesFile.indexOf('final class CraftNativeSounds {')
const services = servicesFile.slice(soundsAt, servicesFile.indexOf('\n// MARK:', soundsAt))
const webAudio = strip(readFileSync(join(import.meta.dir, '../templates/CraftWebAudio.swift'), 'utf8'))
const fixture = strip(readFileSync(join(import.meta.dir, '../fixtures/native-screen/NativeAudioUnitTests.swift'), 'utf8'))

/** The body of `name`, from its `func` line to the matching close brace. */
function body(source: string, name: string): string {
  const from = source.indexOf(name)
  expect(from, `${name} must exist`).toBeGreaterThan(0)
  const open = source.indexOf('{', from)
  let depth = 0
  for (let at = open; at < source.length; at++) {
    if (source[at] === '{') depth++
    else if (source[at] === '}' && --depth === 0) return source.slice(open, at + 1)
  }
  throw new Error(`${name} is unbalanced`)
}

test('the sound service observes the reset and the observer is actually registered', () => {
  expect(services).toContain('forName: AVAudioSession.mediaServicesWereResetNotification')
  expect(services).toContain('CraftNativeSounds.handleMediaReset()')
  // A `static let` observer is lazy. Without this line nothing ever touches
  // it, so it is never created and the notification is never delivered —
  // which looks exactly like having written the handler correctly.
  expect(body(services, 'init() {'), 'the lazy static observer must be forced in init')
    .toContain('_ = Self.mediaResetObserver')
})

test('the reset releases every sound and reports each one', () => {
  const handler = body(services, 'private static func handleMediaReset()')
  // Released, not merely paused: the player cannot be revived.
  expect(handler, 'every handle must be removed').toContain('service.remove(id')
  expect(handler, 'with an error rather than the stop/replace cancellation')
    .toContain('code: "AUDIO_ERROR"')
  // And the script told, because a silent handle reports nothing by itself.
  expect(handler).toContain('service.emit?(["id": id, "event": "error", "message": mediaResetMessage]')
  expect(handler, 'a pre-reset interruption went with the server').toContain('sessionInterrupted = false')
})

test('Web Audio rebuilds rather than restarting the orphans', () => {
  expect(webAudio).toContain('forName: AVAudioSession.mediaServicesWereResetNotification')
  const engineMade = body(webAudio, 'private func makeEngine()')
  // refreshEngine only starts the engine it already has, which is the thing
  // that no longer works. The reset must reach rebuildEngine.
  const reset = engineMade.slice(engineMade.indexOf('mediaServicesWereResetNotification'))
  expect(reset.slice(0, 200), 'the reset must rebuild, not refresh').toContain('rebuildEngine()')

  const rebuild = body(webAudio, 'private func rebuildEngine()')
  expect(rebuild, 'the orphaned source nodes must be detached').toContain('orphaned.detach(source)')
  expect(rebuild, 'and the orphaned engine dropped').toContain('engine = nil')
  expect(rebuild, 'a new engine built').toContain('let engine = makeEngine()')
  // Every context, derived from the dictionary rather than one of them.
  expect(rebuild, 'and every live context reattached').toContain('for context in contexts.values')
  expect(rebuild).toContain('attachSource(context, format: format, to: engine)')
  expect(rebuild, 'then started, or the rebuilt engine pulls nothing').toContain('refreshEngine()')
})

test('a rebuilt engine does not strand or duplicate its observers', () => {
  // The configuration notification is scoped to one engine object, so a
  // rebuild must replace it; the session ones are process-wide and must not
  // be registered twice, or one reset would rebuild twice.
  expect(webAudio).toContain('private var engineObserver: NSObjectProtocol?')
  expect(body(webAudio, 'private func makeEngine()'), 'session observers are registered once')
    .toContain('guard observers.isEmpty else { return engine }')
  const stop = body(webAudio, 'private func stopEngine()')
  expect(stop, 'closing must remove the engine observer too').toContain('removeObserver(engineObserver)')
  expect(stop).toContain('observers.removeAll()')
})

test('the host tests exercise the reset on both services', () => {
  expect(fixture, 'the fixture must post the real notification')
    .toContain('name: AVAudioSession.mediaServicesWereResetNotification')
  for (const name of [
    'testMediaServicesResetReleasesEverySoundAndTellsTheScript',
    'testASoundStartsAgainAfterTheMediaServicesReset',
    'testMediaServicesResetRebuildsTheLiveEngineAndKeepsTheContextRunning',
    'testClosingAfterAMediaServicesResetReleasesTheRebuiltEngine',
  ]) expect(fixture, `${name} must stay`).toContain(name)
  // The engine test is worth nothing if it only checks identity: a rebuild
  // that produced a dead engine would pass. The clock must be checked after.
  const engineTest = body(fixture, 'func testMediaServicesResetRebuildsTheLiveEngineAndKeepsTheContextRunning()')
  expect(engineTest).toContain('live.engineForTesting === engine')
  const afterReset = engineTest.slice(engineTest.indexOf('resetMediaServices()'))
  expect(afterReset, 'the rebuilt engine must be shown to render').toContain("page.evaluateScript(\"live.currentTime\").toDouble()")
})
