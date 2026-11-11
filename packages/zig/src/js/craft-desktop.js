// Craft desktop bridge additions for Windows and Linux.
//
// Injected at document start, right after craft-bridge.js, by windows.zig and
// linux.zig. macOS does not load this file: there the same two surfaces come
// from craft-native-ui.js and from the AppKit drop hook.
//
// Both halves exist so app code is identical on every desktop platform:
//
//   craft.nativeUI.showContextMenu({ items, x, y })  // same call, same reply
//   craft.onFileDrop(({ paths }) => { … })           // same event
(function () {
  'use strict'

  if (!window.craft || window.__craftDesktopInstalled) return
  window.__craftDesktopInstalled = true

  // -------------------------------------------------------------------------
  // Context menus. The request and the reply are the ones craft-native-ui.js
  // uses on macOS: resolves with { id, targetId, targetType } once the menu
  // closes, id null when it was dismissed.
  // -------------------------------------------------------------------------
  if (!window.craft.nativeUI) {
    window.craft.nativeUI = {
      showContextMenu: function (o) {
        if (!o || !o.items || !o.items.length) throw new Error('showContextMenu requires items array')
        return window.craft.invoke('nativeUI.showContextMenu', {
          targetId: o.targetId || '',
          targetType: o.targetType || 'general',
          x: o.x || 0,
          y: o.y || 0,
          items: o.items,
        })
      },
      // Every context menu's outcome, whoever opened it. Returns an unsubscribe.
      onContextMenuAction: function (cb) {
        const h = function (e) { cb((e && e.detail) || {}) }
        window.addEventListener('craft:contextmenu:action', h)
        return function () { window.removeEventListener('craft:contextmenu:action', h) }
      },
    }
    window.craft.components = window.craft.components || window.craft.nativeUI
  }

  // -------------------------------------------------------------------------
  // File drop on Windows. WebView2 gives a page the dropped File objects but
  // never their paths; only the host can read those, from the same objects
  // sent back with postMessageWithAdditionalObjects. Native answers through
  // __craftDeliverFileDrop, which craft-bridge.js turns into craft.onFileDrop.
  //
  // A `drop` event only fires where `dragover` was cancelled, so both are
  // handled here, in the capture phase, and only for drags that carry files.
  // The page's own handlers still run. One side effect is deliberate: a file
  // dropped on a page that handles nothing no longer navigates the window to
  // that file.
  //
  // Linux needs none of this. GTK reports the paths natively (linux_desktop.zig).
  // -------------------------------------------------------------------------
  const webview2 = window.chrome && window.chrome.webview
  if (webview2 && typeof webview2.postMessageWithAdditionalObjects === 'function') {
    const carriesFiles = function (e) {
      const types = e.dataTransfer && e.dataTransfer.types
      return !!types && Array.prototype.indexOf.call(types, 'Files') >= 0
    }
    window.addEventListener('dragover', function (e) {
      if (carriesFiles(e)) e.preventDefault()
    }, true)
    window.addEventListener('drop', function (e) {
      if (!carriesFiles(e)) return
      e.preventDefault()
      const files = e.dataTransfer.files
      if (!files || files.length === 0) return
      try { webview2.postMessageWithAdditionalObjects({ t: 'fileDrop', a: 'files', d: '' }, files) }
      catch (error) {
        if (typeof console !== 'undefined' && console.warn) console.warn('[craft] file drop could not be reported:', error && error.message)
      }
    }, true)
  }
})()
