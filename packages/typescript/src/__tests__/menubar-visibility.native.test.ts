import assert from 'node:assert/strict'
import { test } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { macOSRuntimeExecutablePath, packageApp } from '../package'

const standardGroupingTest = process.platform === 'darwin' && process.env.CRAFT_NATIVE_TEST_BIN ? test : test.skip

standardGroupingTest('packaged positional grouping keeps its reveal indicator visible across repeated collapse', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'craft-positional-group-'))
  const bundleId = `org.craft-native.positional-group.p${process.pid}.t${Date.now()}`
  const states: Record<string, any> = {}
  const script = `(async () => {
    await craft.tray.setTitle('C');
    await craft.menubar.init({backend:'legacy'});
    await craft.timers.sleep(700);
    await craft.menubar.collapse();
    await craft.menubar.expand();
    await craft.timers.sleep(500);
    await fetch('/cancelled',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
    for (let cycle=0;cycle<4;cycle++) {
      await craft.menubar.collapse();
      let settled=await craft.menubar.getState();
      for (let attempt=0;settled.busy && attempt<80;attempt++) {
        await craft.timers.sleep(100);
        settled=await craft.menubar.getState();
      }
      await fetch('/collapsed'+cycle,{method:'POST',body:JSON.stringify(settled)});
      await craft.timers.sleep(1000);
      await fetch('/held'+cycle,{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
      await craft.menubar.expand();
      await fetch('/expanded'+cycle,{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
      await craft.timers.sleep(100);
    }
    await craft.menubar.destroy();
    await fetch('/destroyed',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
    await craft.menubar.init({backend:'legacy'});
    await craft.timers.sleep(700);
    await craft.menubar.collapse();
    let restarted=await craft.menubar.getState();
    for (let attempt=0;restarted.busy && attempt<80;attempt++) {
      await craft.timers.sleep(100);
      restarted=await craft.menubar.getState();
    }
    await fetch('/reinitialized',{method:'POST',body:JSON.stringify(restarted)});
    await craft.menubar.expand();
    await craft.menubar.destroy();
    await fetch('/cleaned',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
  })().catch(async error => fetch('/error',{method:'POST',body:JSON.stringify({error:String(error)})}));`
  const server = Bun.serve({ hostname:'127.0.0.1',port:0,async fetch(request) {
    const stage = new URL(request.url).pathname.slice(1)
    if (request.method === 'POST') {
      states[stage] = await request.json()
      return new Response('ok')
    }
    return new Response(`<script>${script}</script>`,{headers:{'content-type':'text/html'}})
  }})
  let proc: ReturnType<typeof Bun.spawn> | undefined
  let stderr: Promise<string> | undefined
  let passed = false
  try {
    const result = await packageApp({
      name:'PositionalGroup',version:'1.0.0',bundleId,binaryPath:'/usr/bin/true',outDir:dir,platforms:['macos'],
      macos:{nativeRuntimePath:process.env.CRAFT_NATIVE_TEST_BIN!,dmg:false,signIdentity:'-'},
    })
    assert.equal(result[0].success,true,result[0].error)
    // An existing widening separator may be parked in native overflow. The
    // new compact control must not inherit that retired placement identity.
    const seeded = Bun.spawnSync(['/usr/bin/defaults','write',`${bundleId}.runtime`,'NSStatusItem Preferred Position craft_menubar_marker','-float','100000'])
    assert.equal(seeded.exitCode,0)
    const launched = Bun.spawn([macOSRuntimeExecutablePath(result[0].outputPath!),'--headless','--system-tray','--log-level','debug','--url',server.url.toString()],{
      env:{...process.env,__CFBundleIdentifier:`${bundleId}.runtime`},stdout:'ignore',stderr:'pipe',
    })
    proc = launched
    stderr = new Response(launched.stderr).text()
    const deadline = Date.now()+45000
    while (!states.cleaned && !states.error && proc.exitCode === null && Date.now()<deadline) await Bun.sleep(50)
    assert(!states.error,JSON.stringify(states.error))
    assert.equal(states.cancelled?.collapsed,false)
    assert.equal(states.cancelled?.busy,false)
    assert.equal(states.cancelled?.markerWidth,20)
    for (let cycle=0;cycle<4;cycle++) {
      assert.equal(states[`collapsed${cycle}`]?.backend,'legacy')
      assert.equal(states[`collapsed${cycle}`]?.collapsed,true,JSON.stringify(states))
      assert.equal(states[`collapsed${cycle}`]?.busy,false)
      assert.equal(states[`collapsed${cycle}`]?.markerWidth,20,'the reveal control must never widen with the spacer')
      assert.equal(states[`held${cycle}`]?.markerWidth,20)
      assert.equal(states[`expanded${cycle}`]?.markerWidth,20)
      assert.equal(states[`held${cycle}`]?.collapsed,true,'a collapse must retain a visible trailing reveal indicator')
      assert.equal(states[`expanded${cycle}`]?.collapsed,false)
    }
    assert.equal(states.destroyed?.initialized,false)
    assert.equal(states.destroyed?.collapsed,false)
    assert.equal(states.destroyed?.busy,false)
    assert.equal(states.destroyed?.markerWidth,0)
    assert.equal(states.reinitialized?.collapsed,true,JSON.stringify(states.reinitialized))
    assert.equal(states.reinitialized?.busy,false)
    assert.equal(states.reinitialized?.markerWidth,20)
    assert.equal(states.cleaned?.initialized,false)
    assert.equal(states.cleaned?.markerWidth,0)
    passed = true
  }
  finally {
    if (proc && proc.exitCode === null) {
      proc.kill('SIGTERM')
      await Promise.race([proc.exited,Bun.sleep(500)])
      if (proc.exitCode === null) proc.kill('SIGKILL')
      await proc.exited
    }
    if (stderr) {
      const output = await stderr
      if (!passed && output) console.error(output)
    }
    server.stop(true)
    await rm(dir,{recursive:true,force:true})
    Bun.spawnSync(['/usr/bin/defaults','delete',`${bundleId}.runtime`],{stdout:'ignore',stderr:'ignore'})
  }
}, 50000)

// Opt-in real private-API acceptance on macOS 27 with existing Accessibility
// authorization. CI's default native tests cover unavailability and cancellation
// without requesting grants or changing security settings.
const nativeVisibilityTest = process.platform === 'darwin'
  && process.env.CRAFT_NATIVE_TEST_BIN && process.env.CRAFT_NATIVE_VISIBILITY_E2E === '1' ? test : test.skip

nativeVisibilityTest('packaged native visibility preserves other icons or releases its macOS assertion', async () => {
  const runtime = process.env.CRAFT_NATIVE_TEST_BIN!
  const dir = await mkdtemp(join(tmpdir(), 'craft-visibility-packaged-'))
  const stages: Record<string, any> = {}
  let releaseTarget: () => void = () => {}
  const targetReady = new Promise<void>(resolve => { releaseTarget = resolve })
  const controllerScript = `(async () => {
    await craft.tray.setIcon('cup.and.saucer.fill');
    await craft.tray.setTooltip('Native visibility verification controller');
    await craft.menubar.init({backend:'nativeVisibility'});
    await fetch('/stage/initialized', {method:'POST',body:JSON.stringify(await craft.menubar.getState())});
    await fetch('/target-ready');
    await craft.timers.sleep(700);
    await craft.menubar.collapse();
    let collapsed;
    for (let i=0;i<100;i++) {
      collapsed=await craft.menubar.getState();
      if (!collapsed.busy) break;
      await craft.timers.sleep(100);
    }
    await fetch('/stage/collapsed',{method:'POST',body:JSON.stringify(collapsed)});
    await fetch('/stage/controller',{method:'POST',body:JSON.stringify(await craft.tray.getState())});
    await craft.menubar.expand();
    await fetch('/stage/expanded',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
    await craft.menubar.destroy();
    await fetch('/stage/destroyed',{method:'POST',body:JSON.stringify(await craft.menubar.getState())});
    craft.app.quit();
  })().catch(async error => { await fetch('/stage/error',{method:'POST',body:JSON.stringify({error:String(error)})}); craft.app.quit(); });`
  const targetScript = `(async () => { await craft.tray.setIcon('star.fill'); await craft.tray.setTitle('B·TEST'); await craft.tray.setTooltip('Native visibility verification target'); await fetch('/stage/target',{method:'POST',body:JSON.stringify(await craft.tray.getState())}); })();`
  const server = Bun.serve({ hostname:'127.0.0.1',port:0, async fetch(request) {
    const path = new URL(request.url).pathname
    if (path.startsWith('/stage/')) {
      const stage = path.slice('/stage/'.length)
      stages[stage] = await request.json()
      if (stage === 'target') releaseTarget()
      return new Response('ok')
    }
    if (path === '/target-ready') { await targetReady; return new Response('ready') }
    return new Response(`<script>${path === '/target' ? targetScript : controllerScript}</script>`,{headers:{'content-type':'text/html'}})
  }})
  const processes: ReturnType<typeof Bun.spawn>[] = []
  const logs: Promise<string>[] = []
  const watchdog = setTimeout(() => {
    for (const proc of processes) if (proc.exitCode === null) proc.kill('SIGTERM')
  }, 35000)
  async function bundle(name:string) {
    const id = `org.craft-native.visibility-e2e.${name.toLowerCase()}.${process.pid}`
    const result = await packageApp({
      name, version:'1.0.0', bundleId:id, binaryPath:'/usr/bin/true', outDir:dir, platforms:['macos'],
      macos:{nativeRuntimePath:runtime,dmg:false,signIdentity:'-'},
    })
    assert.equal(result[0].success,true,result[0].error)
    const proc = Bun.spawn([macOSRuntimeExecutablePath(result[0].outputPath!),'--headless','--system-tray','--title',name,'--url',`http://127.0.0.1:${server.port}/${name === 'Target' ? 'target' : ''}`],{stdout:'ignore',stderr:'pipe'})
    processes.push(proc)
    logs.push(new Response(proc.stderr).text())
    return proc
  }
  async function until(stage:string) {
    const deadline = Date.now()+30000
    while (!stages[stage] && !stages.error && Date.now()<deadline) await Bun.sleep(50)
    assert(!stages.error,JSON.stringify(stages.error))
    assert(stages[stage],`Missing native stage: ${stage}`)
    return stages[stage]
  }
  try {
    const controller = await bundle('Controller')
    const initialized = await until('initialized')
    assert.equal(initialized.backend,'nativeVisibility')
    assert.equal(initialized.available,true)
    assert.equal(initialized.authorized,true,'Native verification needs pre-existing Accessibility authorization; this test never requests it')
    assert.equal(initialized.markerWidth,20)
    await bundle('Target')
    const collapsed = await until('collapsed')
    // AppKit owns placement; newly created agent icons may land on either side
    // of the control. Never move real user icons or assume a nonempty group.
    if (collapsed.hiddenAppCount === 0) {
      assert(['emptyGroup','visibilityMismatch'].includes(collapsed.error),JSON.stringify(collapsed))
      assert.equal(collapsed.collapsed,false)
    }
    else {
      assert.equal(collapsed.error,null,JSON.stringify(collapsed))
      assert.equal(collapsed.collapsed,true)
    }
    assert.equal(collapsed.markerWidth,20)
    const ownTray = await until('controller')
    assert.equal(ownTray.visible,true,'The controller must remain visible while its group is hidden')
    const expanded = await until('expanded')
    assert.equal(expanded.collapsed,false)
    assert.equal(expanded.hiddenAppCount,0)
    assert.equal(expanded.markerWidth,20)
    const destroyed = await until('destroyed')
    assert.equal(destroyed.initialized,false)
    assert.equal(await controller.exited,0)
    const evidence = {observedAt:new Date().toISOString(),runtime,initialized,collapsed,expanded,destroyed}
    console.log(JSON.stringify(evidence,null,2))
  }
  finally {
    clearTimeout(watchdog)
    for (const proc of processes) if (proc.exitCode === null) proc.kill('SIGTERM')
    await Promise.all(processes.map(proc=>proc.exited))
    for (const output of await Promise.all(logs)) if (output) console.error(output)
    server.stop(true)
    await rm(dir,{recursive:true,force:true})
  }
}, 40000)
