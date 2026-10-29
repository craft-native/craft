// Small JavaScriptCore fixture for the UIKit reconciliation simulator tests.
// The .stx compiler is exercised separately; this keeps renderer regressions
// independent of a sibling stx checkout on CI.
(function () {
  let count = 0
  let name = ''
  let notes = ''
  let switchResult = 'Switch off'
  let scrollPresses = 0
  let nextMessage = 0
  let revision = 0
  let pagerMode = false
  let solidMode = false
  let solidChanges = 0
  let pageIndex = 0
  let checkpointMode = false
  let pickerMode = globalThis.__stxNativeRoute === 'picker-retry'
  let pickerAnswers = 0
  let pickerRequest = ''
  let checkpointBackgroundArmed = false
  const checkpointName = 'craft-ui-checkpoint-recovery'
  const checkpointSession = `${Date.now()}-${Math.random()}`

  function checkpointValue(generation, source) {
    return { generation, source, payload: String(generation % 10).repeat(65536) }
  }

  function checkpointRead() {
    const value = craft.snapshots.get(checkpointName)
    if (value === null) return 'Checkpoint absent'
    if (!Number.isInteger(value.generation) || value.payload !== checkpointValue(value.generation).payload)
      return 'Checkpoint corrupt'
    return `Recovered: ${value.generation} (${value.source})`
  }

  function checkpointStatus(text) {
    mutate([{ op: 'updateNode', id: 'checkpoint-status', patch: { children: [text] } }])
  }

  function renderCheckpoint() {
    globalThis.craftNativePostMessage(JSON.stringify({
      id: `render-${++nextMessage}`, type: 'RENDER',
      payload: { document: { type: 'View', style: { padding: 16 }, children: [
        { id: 'checkpoint-status', type: 'Text', props: { key: 'checkpoint-status' }, children: [checkpointRead()] },
        { type: 'Text', props: { key: 'checkpoint-session' }, children: [checkpointSession] },
        { type: 'Button', props: { key: 'checkpoint-reset' }, events: { onPress: 'resetCheckpoint' }, children: ['Delete checkpoint'] },
        { type: 'Button', props: { key: 'checkpoint-save' }, events: { onPress: 'saveCheckpoint' }, children: ['Queue 32 saves and arm background save'] },
      ] } },
    }))
  }

  function mutate(operations) {
    const baseRevision = revision
    revision += 1
    globalThis.craftNativePostMessage(JSON.stringify({
      id: `mutation-${++nextMessage}`,
      type: 'MUTATE',
      payload: {
        version: 1,
        batchId: `mutation-${revision}`,
        baseRevision,
        revision,
        operations,
      },
    }))
  }

  function renderPager() {
    globalThis.craftNativePostMessage(JSON.stringify({
      id: `render-${++nextMessage}`,
      type: 'RENDER',
      payload: { document: { type: 'View', style: { padding: 16 }, children: [
        { id: 'pager-status', type: 'Text', props: { key: 'pager-status' }, children: ['Page 1 of 3'] },
        { id: 'native-pager', type: 'ScrollView', props: { key: 'native-pager', testID: 'native-pager', horizontal: true, pagingEnabled: true, pageIndex },
          style: { height: 240, width: '100%' }, events: { onPageSelected: 'selectPage' },
          children: Array.from({ length: 3 }, (_, index) => ({
            id: `pager-slot-${index}`, type: 'View', props: { key: `pager-slot-${index}` },
            style: { width: 37, backgroundColor: ['#dbeafe', '#dcfce7', '#fef3c7'][index] },
            children: [{ id: `pager-page-${index}`, type: 'Text', props: { key: `pager-page-${index}` }, children: [`Page ${index + 1} content`] }],
          })),
        },
        { id: 'pager-last', type: 'Button', props: { key: 'pager-last' }, events: { onPress: 'selectLastPage' }, children: ['Select last page'] },
      ] } },
    }))
  }

  function render() {
    if (pickerMode) {
      globalThis.craftNativePostMessage(JSON.stringify({
        id: `render-${++nextMessage}`, type: 'RENDER',
        payload: { document: { type: 'View', style: { padding: 16 }, children: [
          { id: 'picker-status', type: 'Text', props: { key: 'picker-status' }, children: ['Picker ready'] },
          { type: 'Text', props: { key: 'picker-session' }, children: [checkpointSession] },
          ...['file', 'video', 'abort', 'replace', 'photo', 'library-video', 'photo-abort', 'library-video-replace'].map(mode => ({
            type: 'Button', props: { key: `picker-${mode}` }, events: { onPress: `pick-${mode}` }, children: [`Pick ${mode}`],
          })),
        ] } },
      }))
      return
    }
    if (checkpointMode) { renderCheckpoint(); return }
    if (pagerMode) { renderPager(); return }
    if (solidMode) {
      globalThis.craftNativePostMessage(JSON.stringify({
        id: `render-${++nextMessage}`, type: 'RENDER',
        payload: { document: { type: 'View', style: { padding: 16 }, children: [
          { type: 'ScrollView', style: { height: 120 }, children: [
            { id: 'solid-switch', type: 'Switch', props: { key: 'solid-switch', ios_solid: true, value: false, accessibilityLabel: 'Solid consent' }, events: { onValueChange: 'changeSolid' } },
            { id: 'solid-result', type: 'Text', props: { key: 'solid-result' }, children: ['Solid off: 0'] },
          ] },
          { type: 'Button', props: { key: 'disable-solid' }, events: { onPress: 'disableSolid' }, children: ['Disable switch'] },
          { type: 'Button', props: { key: 'restore-native' }, events: { onPress: 'restoreNative' }, children: ['Use UIKit switch'] },
        ] } },
      }))
      return
    }
    globalThis.craftNativePostMessage(JSON.stringify({
      id: `render-${++nextMessage}`,
      type: 'RENDER',
      payload: {
        document: {
          type: 'View',
          style: { padding: 16 },
          children: [
            {
              type: 'ScrollView',
              props: { key: 'native-scroll' },
              style: { height: 72 },
              children: [{
                type: 'Image',
                props: {
                  key: 'native-image',
                  source: { uri: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' },
                  accessibilityLabel: 'Native pixel',
                  accessibilityRole: 'image',
                },
                style: { width: 24, height: 24, resizeMode: 'cover' },
              }, {
                id: 'scroll-switch',
                type: 'Switch',
                props: { key: 'scroll-switch', value: false },
                events: { onValueChange: 'changeScrollSwitch' },
              }],
            },
            {
              // Rows of buttons in a short scroll view: a drag that starts on
              // a button has to scroll it, the way a page of buttons does.
              type: 'ScrollView',
              props: { key: 'button-scroll', testID: 'button-scroll' },
              style: { height: 132 },
              children: Array.from({ length: 10 }, (_, index) => ({
                id: `scroll-button-${index}`,
                type: 'Button',
                props: { key: `scroll-button-${index}`, testID: `scroll-button-${index}` },
                style: { height: 44 },
                events: { onPress: 'pressScrollButton' },
                children: [`Row ${index}`],
              })),
            },
            { id: 'scroll-presses', type: 'Text', props: { key: 'scroll-presses' }, children: [`Scroll presses: ${scrollPresses}`] },
            { id: 'count', type: 'Text', props: { key: 'count' }, children: [`Count: ${count}`] },
            { id: 'increment', type: 'Button', props: { key: 'increment' }, events: { onPress: 'increment' }, children: ['Increment'] },
            { id: 'name-input', type: 'TextInput', props: { key: 'name-input', placeholder: 'Type your name' }, events: { onChange: 'changeName' } },
            { id: 'name', type: 'Text', props: { key: 'name' }, children: [`Hello ${name}`] },
            { id: 'notes-input', type: 'TextInput', props: { key: 'notes-input', multiline: true, placeholder: 'Notes' }, style: { height: 80 }, events: { onChange: 'changeNotes' } },
            { id: 'notes', type: 'Text', props: { key: 'notes' }, children: [`Notes: ${notes}`] },
            { id: 'native-switch', type: 'Switch', props: { key: 'native-switch', value: false }, events: { onValueChange: 'changeSwitch' } },
            { id: 'switch-result', type: 'Text', props: { key: 'switch-result' }, children: [switchResult] },
            { id: 'open-pager', type: 'Button', props: { key: 'open-pager' }, events: { onPress: 'openPager' }, children: ['Open pager'] },
            { type: 'Button', props: { key: 'open-solid' }, events: { onPress: 'openSolid' }, children: ['Solid switch'] },
            { type: 'Button', props: { key: 'open-checkpoint' }, events: { onPress: 'openCheckpoint' }, children: ['Checkpoint recovery'] },
            { type: 'Button', props: { key: 'open-picker' }, events: { onPress: 'openPicker' }, children: ['Document picker lifecycle'] },
          ],
        },
      },
    }))
  }

  globalThis.__stxNativeBridge.onMessage(function (raw) {
    const message = JSON.parse(raw)
    if (['API_RESPONSE', 'API_ERROR'].includes(message.type) && message.payload.requestId === pickerRequest) {
      pickerAnswers += 1
      const result = message.type === 'API_ERROR' ? message.payload.code : JSON.stringify(message.payload.data)
      mutate([{ op: 'updateNode', id: 'picker-status', patch: { children: [`Answer ${pickerAnswers}: ${result}`] } }])
    }
    if (message.type === 'APP_STATE' && message.payload.state === 'background' && checkpointBackgroundArmed) {
      checkpointBackgroundArmed = false
      craft.snapshots.set(checkpointName, checkpointValue(33, 'background')).then(
        () => checkpointStatus(checkpointRead()),
        error => checkpointStatus(`Background save failed: ${error}`),
      )
    }
    if (message.type !== 'EVENT') return
    if (message.payload.handlerName === 'openPicker') { pickerMode = true; render(); return }
    if (message.payload.handlerName.startsWith('pick-')) {
      const mode = message.payload.handlerName.slice(5)
      pickerRequest = `picker-request-${++nextMessage}`
      const requestId = pickerRequest
      const library = mode.includes('photo') || mode.includes('library-video')
      globalThis.craftNativePostMessage(JSON.stringify({
        id: requestId, type: 'API_REQUEST',
        payload: { version: 1, module: 'Files', method: mode.includes('photo') ? 'pickImage' : mode.includes('video') ? 'pickVideo' : 'pickFile', args: [{ source: library ? 'library' : 'files' }], untimed: true },
      }))
      if (mode.endsWith('abort') || mode.endsWith('replace')) {
        // Exercise the real bridge while the system UI is on top. The replace
        // path disposes this runtime; no fixture-only native cancellation hook.
        setTimeout(() => {
          globalThis.craftNativePostMessage(JSON.stringify(mode.endsWith('replace')
            ? { type: 'NAVIGATE_REPLACE', payload: { screen: 'picker-retry' } }
            : { type: 'API_CANCEL', payload: { requestId } }))
          if (mode.endsWith('abort'))
            mutate([{ op: 'updateNode', id: 'picker-status', patch: { children: [`Aborted; answers ${pickerAnswers}`] } }])
        }, 8000)
      }
      return
    }
    if (message.payload.handlerName === 'openCheckpoint') { checkpointMode = true; render(); return }
    if (message.payload.handlerName === 'resetCheckpoint') {
      checkpointBackgroundArmed = false
      craft.snapshots.set(checkpointName, null).then(
        () => checkpointStatus(checkpointRead()),
        error => checkpointStatus(`Delete failed: ${error}`),
      )
    }
    if (message.payload.handlerName === 'saveCheckpoint') {
      checkpointStatus('Saving checkpoints')
      const completed = []
      Promise.all(Array.from({ length: 32 }, (_, index) => {
        const generation = index + 1
        return craft.snapshots.set(checkpointName, checkpointValue(generation, 'burst')).then(() => completed.push(generation))
      })).then(() => {
        if (!completed.every((generation, index) => generation === index + 1)) {
          checkpointStatus('Completion order mismatch')
          return
        }
        checkpointBackgroundArmed = true
        checkpointStatus(checkpointRead())
      }, error => checkpointStatus(`Save failed: ${error}`))
    }
    if (message.payload.handlerName === 'openSolid') { solidMode = true; render(); return }
    if (message.payload.handlerName === 'changeSolid') {
      const value = message.payload.nativeEvent.value
      solidChanges += 1
      mutate([
        { op: 'updateNode', id: 'solid-switch', patch: { props: { value } } },
        { op: 'updateNode', id: 'solid-result', patch: { children: [`Solid ${value ? 'on' : 'off'}: ${solidChanges}`] } },
      ])
    }
    if (message.payload.handlerName === 'disableSolid') {
      mutate([{ op: 'updateNode', id: 'solid-switch', patch: { props: { disabled: true } } }])
    }
    if (message.payload.handlerName === 'restoreNative') {
      mutate([{ op: 'updateNode', id: 'solid-switch', patch: { props: { ios_solid: false, disabled: false } } }])
    }
    if (message.payload.handlerName === 'openPager') { pagerMode = true; render(); return }
    if (message.payload.handlerName === 'selectPage') {
      const page = message.payload.nativeEvent
      pageIndex = page.index
      mutate([
        { op: 'updateNode', id: 'native-pager', patch: { props: { pageIndex } } },
        { op: 'updateNode', id: 'pager-status', patch: { children: [`Page ${page.index + 1} of ${page.count}`] } },
      ])
    }
    if (message.payload.handlerName === 'selectLastPage') {
      mutate([{ op: 'updateNode', id: 'native-pager', patch: { props: { pageIndex: 2 } } }])
    }
    if (message.payload.handlerName === 'increment') {
      count += 1
      mutate([{ op: 'updateNode', id: 'count', patch: { children: [`Count: ${count}`] } }])
    }
    if (message.payload.handlerName === 'pressScrollButton') {
      scrollPresses += 1
      mutate([{ op: 'updateNode', id: 'scroll-presses', patch: { children: [`Scroll presses: ${scrollPresses}`] } }])
    }
    if (message.payload.handlerName === 'changeNotes') {
      notes = message.payload.nativeEvent.text
      mutate([{ op: 'updateNode', id: 'notes', patch: { children: [`Notes: ${notes}`] } }])
    }
    if (message.payload.handlerName === 'changeName') {
      name = message.payload.nativeEvent.text
      mutate([{ op: 'updateNode', id: 'name', patch: { children: [`Hello ${name}`] } }])
    }
    if (message.payload.handlerName === 'changeSwitch' || message.payload.handlerName === 'changeScrollSwitch') {
      const value = message.payload.nativeEvent.value
      const id = message.payload.handlerName === 'changeSwitch' ? 'native-switch' : 'scroll-switch'
      switchResult = value ? 'Switch on' : 'Switch off'
      // Echo the controlled value through the same mutation as a bound signal,
      // while UIKit is still animating the physical tap.
      mutate([
        { op: 'updateNode', id, patch: { props: { value } } },
        { op: 'updateNode', id: 'switch-result', patch: { children: [switchResult] } },
      ])
    }
  })
  render()
})()
