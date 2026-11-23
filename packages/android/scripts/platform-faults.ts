// #593: which logcat lines invalidate an Android acceptance run.
//
// Any crash or fatal signal still fails it, from any process. An ANR fails it
// too, unless it is a broadcast timeout in some other app: the emulator image's
// stock apps (Google Messages on CARRIER_CONFIG_CHANGED) time out on background
// broadcasts during boot. Android shows no dialog for a background ANR, so it
// can't cover the fixture's UI or touch its process. Those lines are recorded,
// not fatal. An ANR the line format doesn't let us attribute stays fatal.

export interface PlatformFaults {
  fatal: string[]
  tolerated: string[]
}

// am_anr  : [user,pid,process,flags,reason]
const anrLine = /\bam_anr\b\s*:\s*\[\d+,\d+,([^,\]]+),\d+,(.*)\]\s*$/
// Processes whose ANR means the platform itself is unwell.
const platformProcesses = new Set(['system_server', 'system', 'android', 'com.android.systemui', 'com.android.launcher3', 'com.android.phone'])

export function classifyPlatformFaults(log: string, packageName: string): PlatformFaults {
  const fatal: string[] = [], tolerated: string[] = []
  for (const line of log.split('\n')) {
    if (/\bam_crash\b|FATAL EXCEPTION|Fatal signal/.test(line)) { fatal.push(line); continue }
    if (!/\bam_anr\b/.test(line)) continue
    const [, process, reason] = line.match(anrLine) ?? []
    const owner = process?.split(':')[0]
    const background = reason?.startsWith('Broadcast of Intent') === true
    if (owner && background && owner !== packageName && !platformProcesses.has(owner)) tolerated.push(line)
    else fatal.push(line)
  }
  return { fatal, tolerated }
}
