/** Public AVFoundation CMTime values, kept rational through extraction. */
export interface VideoPTS {
  value: number
  timescale: number
}

export interface HeldVideoWindow {
  recordSpawnWall: number
  recordingStartedObservedWall: number
  synthesisWall: number
  releasedWall: number
}

export interface HeldVideoFrameTiming extends HeldVideoWindow {
  firstPTS: VideoPTS
  selectedPTS: VideoPTS
  actualPTS: VideoPTS
}

function seconds(time: VideoPTS): number {
  if (!time || !Number.isSafeInteger(time.value) || !Number.isSafeInteger(time.timescale) || time.timescale <= 0)
    throw new Error('Expected an exact rational decoded video PTS')
  return time.value / time.timescale
}

/** The synthesized hold the fixture performs, before synthesis overhead. */
export const HELD_GESTURE_SECONDS = 6

/**
 * Whether a first-frame anchor could ever place a frame inside the hold.
 *
 * `validateHeldVideoFrame` brackets every frame as `[spawn + offset,
 * ready + offset]`, so each candidate's interval is exactly as wide as
 * `ready - spawn`, whatever PTS is chosen. The whole interval has to sit
 * strictly inside the hold, so unless that bracket is narrower than the hold
 * itself, no sample can qualify - there is nothing to select.
 *
 * Checking it at readiness stops the run before it synthesizes a six-second
 * gesture and records a few hundred megabytes that provably cannot answer the
 * question. Measuring against the nominal gesture rather than the observed
 * hold is deliberate: a bracket wider than the gesture can only be rescued by
 * synthesis overhead stretching the hold past it, which is luck rather than
 * evidence.
 */
export function anchorCanQualify(spawnWall: number, readyWall: number, holdSeconds: number = HELD_GESTURE_SECONDS): boolean {
  if (![spawnWall, readyWall, holdSeconds].every(value => Number.isFinite(value) && value > 0) || spawnWall > readyWall)
    throw new Error('Expected an ordered first-frame bracket and a positive hold')
  return readyWall - spawnWall < holdSeconds
}

/** PNG encoding time does not determine when its source frame was captured. */
export function validateHeldVideoFrame(input: HeldVideoFrameTiming): {
  frameWallEarliest: number
  frameWallLatest: number
  frameOffsetFromFirstPTS: number
} {
  const { recordSpawnWall: spawn, recordingStartedObservedWall: ready, synthesisWall: synthesis, releasedWall: end } = input
  if (![spawn, ready, synthesis, end].every(value => Number.isFinite(value) && value > 0)
    || spawn > ready || ready > synthesis || end - synthesis < 5.5)
    throw new Error('Recording must acknowledge its first frame before the six-second synthesized hold')
  const first = seconds(input.firstPTS), selected = seconds(input.selectedPTS)
  seconds(input.actualPTS)
  if (BigInt(input.actualPTS.value) * BigInt(input.selectedPTS.timescale)
    !== BigInt(input.selectedPTS.value) * BigInt(input.actualPTS.timescale))
    throw new Error('Extracted actual PTS differs from the selected decoded frame')
  const offset = selected - first
  const earliest = spawn + offset, latest = ready + offset
  if (offset < 0 || earliest <= synthesis || latest >= end)
    throw new Error('The whole frame capture interval must be strictly inside the synthesized hold')
  return { frameWallEarliest: earliest, frameWallLatest: latest, frameOffsetFromFirstPTS: offset }
}

/** Select actual decoded samples; a requested playback timestamp is insufficient. */
export function selectHeldVideoFrame(window: HeldVideoWindow, decodedPTS: readonly VideoPTS[]): VideoPTS {
  if (!decodedPTS.length) throw new Error('The recording has no decoded video frames')
  const firstPTS = decodedPTS.reduce((a, b) => seconds(a) <= seconds(b) ? a : b)
  const candidates = decodedPTS.flatMap((selectedPTS) => {
    try {
      const timing = validateHeldVideoFrame({ ...window, firstPTS, selectedPTS, actualPTS: selectedPTS })
      const midpoint = (timing.frameWallEarliest + timing.frameWallLatest) / 2
      return [{ selectedPTS, distance: Math.abs(midpoint - (window.synthesisWall + window.releasedWall) / 2) }]
    }
    catch { return [] }
  }).sort((a, b) => a.distance - b.distance)
  if (!candidates[0]) throw new Error('No decoded frame has its whole capture interval inside the hold')
  return candidates[0].selectedPTS
}
