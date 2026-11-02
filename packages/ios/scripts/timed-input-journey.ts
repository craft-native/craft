import { serializeSimulatorSteps } from '../src/testing'

/** One canonical timed-input acceptance journey for CI and owned simulators. */
export function timedInputAcceptanceJourney(): { tabs: string[], script: string } {
  const tabs = ['One', 'Two', 'Three', 'Four']
  const inputSequence = Array.from({ length: 24 }, (_, index) => tabs[index % 4]!)
  const script = serializeSimulatorSteps([
    { command: 'launch' }, { command: 'labelid', id: 'received-taps', text: 'none' },
    { command: 'touches', paths: inputSequence.map((tab, index) => [
      { tab, at: index * 0.08 }, { tab, at: index * 0.08 + 0.025 },
    ]) },
    // Capture what the independent receiver actually received before any
    // assertion can abort the journey. The scheduled paths alone cannot say
    // whether a missing callback was lost in delivery or receiver state.
    { command: 'tree', name: 'timed-input-receiver-immediate' },
    { command: 'valueid', id: 'native-touch-counts', text: 'began=24;ended=24;cancelled=0' },
    { command: 'valueid', id: 'received-callbacks', text: inputSequence.join(',') },
    // Playback completion is not receiver acknowledgement. Preserve the
    // immediate observation, then analyze this same attempt after delivery.
    { command: 'tree', name: 'timed-input-receiver' },
    { command: 'labelid', id: 'received-taps', text: inputSequence.join(',') },
    { command: 'selected', text: 'Four' },
    { command: 'scrollto', text: 'End of scroll fixture' },
    { command: 'expectid', text: 'driver-scroll-end' },
    { command: 'scrollto', text: 'Start of scroll fixture' },
    { command: 'expectid', text: 'driver-scroll-start' },
  ])
  return { tabs, script }
}
