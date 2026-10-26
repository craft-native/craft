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
  let pageIndex = 0

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
    if (pagerMode) { renderPager(); return }
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
                props: { key: 'scroll-switch' },
                events: { onValueChange: 'changeSwitch' },
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
            { id: 'native-switch', type: 'Switch', props: { key: 'native-switch' }, events: { onValueChange: 'changeSwitch' } },
            { id: 'switch-result', type: 'Text', props: { key: 'switch-result' }, children: [switchResult] },
            { id: 'open-pager', type: 'Button', props: { key: 'open-pager' }, events: { onPress: 'openPager' }, children: ['Open pager'] },
          ],
        },
      },
    }))
  }

  globalThis.__stxNativeBridge.onMessage(function (raw) {
    const message = JSON.parse(raw)
    if (message.type !== 'EVENT') return
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
    if (message.payload.handlerName === 'changeSwitch') {
      switchResult = message.payload.nativeEvent.value ? 'Switch on' : 'Switch off'
      mutate([{ op: 'updateNode', id: 'switch-result', patch: { children: [switchResult] } }])
    }
  })
  render()
})()
