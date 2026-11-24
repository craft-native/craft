// Names the synthesized touches the simulator dropped during an iOS UI test
// leg (#450), from backboardd's TouchEvents log. Diagnosis only: it always
// exits 0, so a leg passes or fails on its own tests.
//
//   bun scripts/mobile-e2e/dropped-taps.ts <backboard-touch.log>
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { droppedTapReport } from './protocol'

const path = process.argv[2]
if (!path || !existsSync(path)) {
  console.log(`No backboardd touch log at ${path ?? '(none given)'}; dropped touches can't be named for this leg (#450)`)
}
else {
  const report = droppedTapReport(readFileSync(path, 'utf8'), path)
  if (!report) {
    console.log(`backboardd delivered every synthesized touch in ${path} (#450)`)
  }
  else {
    console.log(`::warning title=Simulator dropped a synthesized touch (#450)::${report}`)
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `- ${report}\n`)
  }
}
