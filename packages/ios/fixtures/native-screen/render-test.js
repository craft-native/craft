// Small JavaScriptCore fixture for the UIKit reconciliation simulator tests.
// The .stx compiler is exercised separately; this keeps renderer regressions
// independent of a sibling stx checkout on CI.
(function () {
  let count = 0
  let name = ''
  let nextMessage = 0

  function render() {
    globalThis.craftNativePostMessage(JSON.stringify({
      id: `render-${++nextMessage}`,
      type: 'RENDER',
      payload: {
        document: {
          type: 'View',
          style: { padding: 16 },
          children: [
            { type: 'Text', props: { key: 'count' }, children: [`Count: ${count}`] },
            { type: 'Button', props: { key: 'increment' }, events: { onPress: 'increment' }, children: ['Increment'] },
            { type: 'TextInput', props: { key: 'name-input', placeholder: 'Type your name' }, events: { onChange: 'changeName' } },
            { type: 'Text', props: { key: 'name' }, children: [`Hello ${name}`] },
          ],
        },
      },
    }))
  }

  globalThis.__stxNativeBridge.onMessage(function (raw) {
    const message = JSON.parse(raw)
    if (message.type !== 'EVENT') return
    if (message.payload.handlerName === 'increment') count += 1
    if (message.payload.handlerName === 'changeName') name = message.payload.nativeEvent.text
    render()
  })
  render()
})()
