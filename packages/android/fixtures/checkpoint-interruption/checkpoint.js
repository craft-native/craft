// Authored probe input for the public native-screen bridge. No WebView.
(function () {
  const name = 'craft-interrupted-checkpoint'
  const session = `${Date.now()}-${Math.random()}`
  const acknowledgements = []
  let pending = 0
  let pulse = 0
  let next = 0
  let failure = ''
  const bridge = globalThis.__stxNativeBridge
  function value(generation) {
    return { generation, payload: String(generation).repeat(262144) }
  }
  function recovered() {
    const saved = craft.snapshots.get(name)
    if (saved === null) return 'Checkpoint absent'
    if (![1, 2, 3].includes(saved.generation) || saved.payload !== value(saved.generation).payload)
      return 'Checkpoint corrupt'
    return `Recovered complete generation ${saved.generation}`
  }
  function text(key, contents) {
    return { type: 'Text', props: { key }, children: [contents] }
  }
  function render() {
    bridge.postMessage(JSON.stringify({
      id: `render-${++next}`, type: 'RENDER',
      payload: { document: { type: 'View', style: { padding: 24 }, children: [
        text('status', failure || (pending ? `Saving generation ${pending}` : recovered())),
        text('session', `Session ${session}`),
        text('acknowledgements', `Acknowledgements ${acknowledgements.join(',') || 'none'}`),
        text('pulse', `Pulse ${pulse}`),
        ...[1, 2, 3].map(generation => ({
          type: 'Button', props: { key: `save-${generation}` },
          events: { onPress: `save-${generation}` }, children: [`Save generation ${generation}`],
        })),
        { type: 'Button', props: { key: 'pulse-button' }, events: { onPress: 'pulse' }, children: ['Pulse UI'] },
      ] } },
    }))
  }
  bridge.onMessage(function (raw) {
    const message = JSON.parse(raw)
    if (message.type !== 'EVENT') return
    const handler = message.payload.handlerName
    if (handler === 'pulse') { pulse++; render(); return }
    if (!/^save-[123]$/.test(handler) || pending) return
    const generation = Number(handler.slice(-1))
    pending = generation
    render()
    craft.snapshots.set(name, value(generation)).then(() => {
      acknowledgements.push(generation)
      pending = 0
      render()
    }, error => {
      pending = 0
      failure = `Checkpoint failed: ${error}`
      render()
    })
  })
  render()
})()
