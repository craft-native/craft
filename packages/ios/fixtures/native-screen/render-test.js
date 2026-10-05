// Small JavaScriptCore fixture for the UIKit reconciliation simulator tests.
// The .stx compiler is exercised separately; this keeps renderer regressions
// independent of a sibling stx checkout on CI.
(function () {
  let count = 0
  let name = ''
  let nextMessage = 0
  let revision = 0

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

  function render() {
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
              }],
            },
            { id: 'count', type: 'Text', props: { key: 'count' }, children: [`Count: ${count}`] },
            { id: 'increment', type: 'Button', props: { key: 'increment' }, events: { onPress: 'increment' }, children: ['Increment'] },
            { id: 'name-input', type: 'TextInput', props: { key: 'name-input', placeholder: 'Type your name' }, events: { onChange: 'changeName' } },
            { id: 'name', type: 'Text', props: { key: 'name' }, children: [`Hello ${name}`] },
          ],
        },
      },
    }))
  }

  globalThis.__stxNativeBridge.onMessage(function (raw) {
    const message = JSON.parse(raw)
    if (message.type !== 'EVENT') return
    if (message.payload.handlerName === 'increment') {
      count += 1
      mutate([{ op: 'updateNode', id: 'count', patch: { children: [`Count: ${count}`] } }])
    }
    if (message.payload.handlerName === 'changeName') {
      name = message.payload.nativeEvent.text
      mutate([{ op: 'updateNode', id: 'name', patch: { children: [`Hello ${name}`] } }])
    }
  })
  render()
})()
