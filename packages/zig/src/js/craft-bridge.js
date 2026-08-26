/* eslint-disable pickier/no-unused-vars */
// Craft JS bridge — runs at document-start in every Craft window.
//
// This file is the single source of truth for what `window.craft.*` looks
// like to user code. It's embedded into the binary via @embedFile and
// injected via WKUserScript / inline <script>, so it must be:
//
//   1. **Self-contained** — no imports, no transpiler, ES5-friendly
//      (avoid arrow functions, const/let are fine in modern WebKit).
//   2. **Idempotent** — may run twice if the page reloads.
//   3. **Defensive** — `webkit.messageHandlers.craft` may not exist (e.g.
//      when served outside a Craft window). Don't throw at module load.
//
// The native side dispatches messages by `t` (type) and answers async ones
// via `window.__craftBridgeResult(action, payload, id)`, where `id` is the
// `i` this file put on the outgoing message. Replies are matched by that id,
// so concurrent calls to the same action — and to the same action name on two
// different bridges — resolve their own callers and nobody else's.

;(function () {
  if (window.craft && window.craft.__craft_bridge_loaded) return
  window.craft = window.craft || {}
  window.craft.__craft_bridge_loaded = true

  // -------------------------------------------------------------------------
  // Core: pending-call queue, result/error delivery, send helpers.
  // -------------------------------------------------------------------------

  // Calls in flight, queued per action name.
  //
  // Kept as the fallback for replies that arrive without an id. This file is
  // `@embedFile`d into the binary and injected at document-start, so the page's
  // bridge and the native side always ship together and cannot disagree about
  // the protocol — the fallback is not for version skew. It is for replies
  // raised outside any dispatch, where there is no request to name: a handler
  // that answers from a callback after its message returned, or an error the
  // bridge raises on its own behalf. Matching by name in order is the best
  // guess available then, and it is exactly what this file did before ids.
  window.__craftBridgePending = window.__craftBridgePending || {}

  // Calls in flight, indexed by the id native echoes back. This is the
  // correlation that actually holds, and the one used whenever native gives us
  // an id to use.
  window.__craftBridgeById = window.__craftBridgeById || {}

  // Monotonic, starting at 1, so `if (id)` is never true for a real call and
  // zero is free to mean nothing at all.
  window.__craftBridgeSeq = window.__craftBridgeSeq || 0
  function _nextId() {
    window.__craftBridgeSeq += 1
    return window.__craftBridgeSeq
  }

  // Drop an entry from both tables. Both, always: an entry left in `byId`
  // holds its resolver forever, and one left in the action queue shifts every
  // later fallback reply onto the wrong caller.
  function _forget(entry) {
    if (!entry) return
    if (entry.id) delete window.__craftBridgeById[entry.id]
    const q = window.__craftBridgePending[entry.action]
    if (Array.isArray(q)) {
      const i = q.indexOf(entry)
      if (i !== -1) q.splice(i, 1)
      if (q.length === 0) delete window.__craftBridgePending[entry.action]
    }
  }

  // Native's answer to one call. `id` is the `i` we sent, echoed back; a reply
  // raised outside any dispatch has none and falls back to the action queue.
  window.__craftBridgeResult = function (action, payload, id) {
    if (id !== undefined && id !== null) {
      const e = window.__craftBridgeById[id]
      // An id we don't recognise is a call that has already settled — it timed
      // out, or native answered it twice. Drop it. The old code had no id to
      // check, so it shifted the action queue and handed this payload to
      // whoever was at the head: another call's answer, delivered as that
      // call's own, with nothing to indicate anything had gone wrong.
      if (!e) return
      _forget(e)
      if (e.resolve) e.resolve(payload || {})
      return
    }

    // No id to match on. Match by action name, in order, exactly as this file
    // did before ids existed.
    const q = window.__craftBridgePending[action]
    if (!q || q.length === 0) return
    const e = q[0]
    _forget(e)
    if (e.resolve) e.resolve(payload || {})
  }

  // Native calls this when an action fails.
  //
  // `err.id` names the exact call that failed, so exactly that caller is
  // rejected. That matters more than it sounds: six action names are served by
  // two or three bridges each (`get` by keychain and tags, `isEnabled` by
  // autoLaunch, bluetooth and crashReporter, and four more), and rejecting by
  // action name hands one bridge's failure to a caller waiting on a different
  // bridge — `craft.bluetooth.isEnabled()` failing would reject an in-flight
  // `craft.autoLaunch.isEnabled()` with bluetooth's error.
  //
  // Without an id, the old behaviour stands: drain that action's queue, or the
  // whole table if the error does not even name an action, since an error that
  // cannot be attributed is most likely the bridge itself being in trouble.
  //
  // Fire-and-forget calls (`_send`) carry an id but register no pending entry:
  // native acknowledges nothing on success, so there is nothing to wait on and
  // the promise resolved the moment the message was posted. Those have no
  // caller left to reject, so they are reported to the console instead —
  // otherwise the only trace is in the native log, which is not where anyone
  // writing a web page is looking.
  window.__craftBridgeError = function (err) {
    const pending = window.__craftBridgePending || {}
    const action = err && err.action
    const id = err && err.id
    let rejected = 0

    const report = function () {
      if (typeof console !== 'undefined' && console.error) {
        console.error(
          '[craft] bridge call failed: ' + (action || '(unnamed action)'),
          (err && err.code) || '', (err && err.message) || '',
        )
      }
    }

    if (id !== undefined && id !== null) {
      const e = window.__craftBridgeById[id]
      // No entry means the call already settled, or it was a `_send` that
      // never registered one. Nobody to tell — say so, rather than rejecting
      // some other caller who is still waiting and would have succeeded.
      if (!e) { report(); return }
      _forget(e)
      if (e.reject) e.reject(err)
      return
    }

    const drain = function (key) {
      const q = pending[key]
      if (!Array.isArray(q)) return
      while (q.length > 0) {
        const e = q.shift()
        if (e) {
          if (e.id) delete window.__craftBridgeById[e.id]
          if (e.reject) { e.reject(err); rejected++ }
        }
      }
      delete pending[key]
    }

    if (action) drain(action)
    else Object.keys(pending).forEach(drain)

    if (rejected === 0) report()
  }

  // `i` is the call id. Every message carries one, fire-and-forget included:
  // a failure has to be able to name the exact call it came from, and native
  // reads it back out of the envelope in `handleBridgeMessageJSON`.
  function _post(t, a, d, i) {
    try {
      const msg = { t: t, a: a, d: d || '' }
      if (i) msg.i = i
      window.webkit.messageHandlers.craft.postMessage(msg)
      return true
    }
    catch (e) {
      // Silent failure made debugging painful — surface the cause exactly
      // once per session so devs see it without spamming the console for
      // the (legitimate) every-call-on-non-Craft-host pattern.
      if (!window.__craftBridgeWarned) {
        window.__craftBridgeWarned = true
        if (typeof console !== 'undefined' && console.warn) {
          console.warn('[craft] bridge unavailable — running outside Craft window?', e && e.message)
        }
      }
      return false
    }
  }

  // Fire-and-forget. Returns a Promise that resolves once the message is
  // posted (no native ack) — preserves the existing `_m` shape so callers
  // can still `await craft.window.show()` without surprises.
  function _send(t, a, d) {
    return new Promise(function (ok, no) {
      if (_post(t, a, d, _nextId())) ok()
      else no(new Error('craft bridge unavailable'))
    })
  }

  // Request-with-response. Native must call sendResultToJS(action, json)
  // exactly once for each in-flight call; the dispatcher stamps the reply with
  // the `i` this call sent, and that id is what resolves the promise.
  //
  // The call is registered in both tables: by id, which is exact, and on the
  // action-name queue, which catches a reply that reaches us without one.
  // Whichever settles it, `_forget` clears both.
  //
  // Each call is reaped after `__craftBridgeRequestTimeoutMs` (default
  // 30s) so a misbehaving native side can't strand callers forever.
  // Apps with legitimate long-running calls (modal dialogs) can bump
  // this knob globally before the call.
  const DEFAULT_TIMEOUT_MS = 30000
  function _req(t, a, d, timeoutMs) {
    return new Promise(function (ok, no) {
      const id = _nextId()
      const q = (window.__craftBridgePending[a] = window.__craftBridgePending[a] || [])
      const entry = { id: id, action: a, resolve: ok, reject: no }
      q.push(entry)
      window.__craftBridgeById[id] = entry

      const timeout = (typeof window.__craftBridgeRequestTimeoutMs === 'number')
        ? window.__craftBridgeRequestTimeoutMs
        : (typeof timeoutMs === 'number' ? timeoutMs : DEFAULT_TIMEOUT_MS)
      const timer = (timeout > 0)
        ? setTimeout(function () {
            // Only ever our own entry, from both tables. A late reply then
            // finds no entry under this id and is dropped, rather than being
            // handed to whichever caller has since taken our place at the head
            // of the action queue.
            _forget(entry)
            no(new Error('craft bridge timed out for ' + t + '/' + a))
          }, timeout)
        : null

      // Wrap resolve/reject so we always clear the timer.
      entry.resolve = function (v) { if (timer) clearTimeout(timer); ok(v) }
      entry.reject  = function (e) { if (timer) clearTimeout(timer); no(e) }

      if (!_post(t, a, d, id)) {
        _forget(entry)
        if (timer) clearTimeout(timer)
        no(new Error('craft bridge unavailable'))
      }
    })
  }

  function _evt(name) {
    return function (cb) {
      const h = function (e) { cb((e && e.detail) || {}) }
      window.addEventListener(name, h)
      return function () { window.removeEventListener(name, h) }
    }
  }

  // `menu.addItem` takes the item in the shape the rest of the menu API uses
  // — `{ id, label, shortcut }` — while the native side reads a flat payload
  // keyed `itemId`/`menuId` with the index alongside. Translate here rather
  // than asking callers to know both spellings.
  function _menuItemPayload(menuId, item) {
    const it = item || {}
    const payload = {
      menuId: String(menuId),
      itemId: String(it.id == null ? '' : it.id),
      label: String(it.label == null ? '' : it.label),
      // -1 appends, which is what a caller who did not say where means.
      index: typeof it.index === 'number' ? it.index : -1,
    }
    if (it.shortcut != null) payload.shortcut = String(it.shortcut)
    if (it.icon != null) payload.icon = String(it.icon)
    return payload
  }

  function _stringify(d) {
    if (d == null) return ''
    if (typeof d === 'string') return d
    try { return JSON.stringify(d) }
    catch (e) {
      // Earlier we silently returned '' here, which made circular-
      // reference bugs invisible — the bridge call would still post,
      // native would parse `''` as empty data, and the user got a
      // mysterious "missing data" error far from the actual cause.
      // Surface in the console (one shot per process via the same
      // gate as _post's warning) so devs can find it.
      if (!window.__craftStringifyWarned) {
        window.__craftStringifyWarned = true
        if (typeof console !== 'undefined' && console.warn) {
          console.warn('[craft] failed to JSON.stringify bridge payload:', e && e.message)
        }
      }
      return ''
    }
  }

  // Framework adapters use a generic dotted method contract. Route it
  // through the same request transport as the typed facade below.
  window.craft.invoke = function (method, params) {
    if (typeof method !== 'string' || method.length === 0)
      return Promise.reject(new TypeError('craft.invoke requires a dotted method name'))
    const separator = method.indexOf('.')
    if (separator <= 0 || separator === method.length - 1)
      return Promise.reject(new TypeError('craft.invoke method must be in the form "namespace.action"'))
    return _req(method.slice(0, separator), method.slice(separator + 1), _stringify(params))
  }

  // -------------------------------------------------------------------------
  // Legacy per-bridge result channel translators.
  //
  // Several native bridges (fs, system, shell, power, network, bluetooth,
  // menu) use per-bridge callback functions instead of the unified
  // __craftBridgeResult, and they pass result payloads as bare values
  // (booleans, strings, numbers, arrays) rather than the
  // `{key:value}` envelope the JS facades expect. We normalize here so
  // that facades stay uniform — every facade just calls `_req` and gets
  // back a `{value|level|address|state|...}` envelope.
  //
  // The `wrap*` helpers below pick the right envelope key per action.
  // Any unrecognised action falls back to `{value: payload}` which is
  // safe — facades default-extract from `r.value` when no field matches.
  // -------------------------------------------------------------------------

  function _wrapWith(key) { return function (v) { var o = {}; o[key] = v; return o } }
  function _passthrough(v) { return (v && typeof v === 'object') ? v : { value: v } }

  // Coerce-to-finite-non-negative-integer for window geometry knobs.
  // NaN/Infinity/negative all collapse to the supplied default.
  function _finite(v, fallback) {
    var n = Math.round(Number(v))
    return Number.isFinite(n) && n >= 0 ? n : fallback
  }
  function _finiteSigned(v, fallback) {
    var n = Math.round(Number(v))
    return Number.isFinite(n) ? n : fallback
  }

  // Helpers for shape adapters that need to do real work.
  function _rgbToHex(c) {
    if (!c || typeof c !== 'object') return ''
    function _hex(n) {
      const i = Math.round(Math.max(0, Math.min(1, Number(n) || 0)) * 255)
      var s = i.toString(16)
      return s.length < 2 ? '0' + s : s
    }
    return '#' + _hex(c.r) + _hex(c.g) + _hex(c.b)
  }

  // Per-bridge action → wrapper map. Adding a new action without an
  // entry just delivers `{value: payload}` via _passthrough, which the
  // facade can either accept or override.
  const _wrappers = {
    fs: {
      readFile:        _wrapWith('data'),
      // bridge_fs.zig sends a bare `[{name,isDirectory},...]` array.
      // Wrap into the {entries} envelope our facade expects.
      readDir:         function (v) { return { entries: Array.isArray(v) ? v : [] } },
      // Native shape uses `mtime` (legacy unix int); facade wants
      // `modifiedAt` in ms. Normalize both timestamp form and field name.
      stat:            function (v) {
        if (!v || typeof v !== 'object') return v
        var mt = v.mtime != null ? v.mtime : (v.modifiedAt != null ? v.modifiedAt : 0)
        if (mt < 1e12 && mt > 0) mt = mt * 1000
        return {
          isFile: !!v.isFile,
          isDirectory: !!v.isDirectory,
          isSymlink: !!v.isSymlink,
          size: Number(v.size) || 0,
          modifiedAt: mt,
        }
      },
      exists:          _wrapWith('exists'),
      getHomeDir:      _wrapWith('path'),
      getTempDir:      _wrapWith('path'),
      getAppDataDir:   _wrapWith('path'),
    },
    system: {
      // Accent + highlight come back as `{r,g,b}` floats 0..1 from
      // bridge_system.zig — convert to a hex string here so callers get
      // a value they can drop into CSS without further work.
      getAccentColor:        function (v) { return { color: _rgbToHex(v) } },
      getHighlightColor:     function (v) { return { color: _rgbToHex(v) } },
      getLanguage:           _wrapWith('language'),
      getLocale:             _wrapWith('locale'),
      getTimezone:           _wrapWith('timezone'),
      getSystemVersion:      _wrapWith('version'),
      getHostname:           _wrapWith('hostname'),
      getUsername:           _wrapWith('username'),
      is24HourTime:          _wrapWith('value'),
      getReduceMotion:       _wrapWith('value'),
      getReduceTransparency: _wrapWith('value'),
      getIncreaseContrast:   _wrapWith('value'),
    },
    shell: {
      getEnv:                _wrapWith('value'),
    },
    power: {
      isCharging:            _wrapWith('value'),
      isPluggedIn:           _wrapWith('value'),
      isLowPowerMode:        _wrapWith('value'),
      getBatteryLevel:       _wrapWith('level'),
      getBatteryState:       _wrapWith('state'),
      getTimeRemaining:      _wrapWith('minutes'),
      getThermalState:       _wrapWith('state'),
      getUptimeSeconds:      _wrapWith('seconds'),
    },
    network: {
      isConnected:           _wrapWith('value'),
      getConnectionType:     _wrapWith('type'),
      getWiFiSSID:           _wrapWith('ssid'),
      getWiFiSignalStrength: _wrapWith('dBm'),
      getIPAddress:          _wrapWith('address'),
      getMACAddress:         _wrapWith('address'),
      getNetworkInterfaces:  function (v) { return { interfaces: Array.isArray(v) ? v : [] } },
      isVPNConnected:        _wrapWith('value'),
      getProxySettings:      _passthrough,
    },
    bluetooth: {
      isEnabled:             _wrapWith('value'),
      isAvailable:           _wrapWith('value'),
      isDiscovering:         _wrapWith('value'),
      getPowerState:         _wrapWith('state'),
      getConnectedDevices:   function (v) { return { devices: Array.isArray(v) ? v : ((v && v.devices) || []) } },
      getPairedDevices:      function (v) { return { devices: Array.isArray(v) ? v : ((v && v.devices) || []) } },
    },
  }

  function _legacyResult(ns, action, payload) {
    const wrapper = (_wrappers[ns] && _wrappers[ns][action]) || _passthrough
    var envelope
    try { envelope = wrapper(payload) }
    catch (e) { envelope = _passthrough(payload) }
    if (typeof window.__craftBridgeResult === 'function') {
      window.__craftBridgeResult(action, envelope)
    }
  }

  window.__craftFSCallback        = function (_cb, a, p) { _legacyResult('fs', a, p) }
  window.__craftSystemCallback    = function (_cb, a, p) { _legacyResult('system', a, p) }
  window.__craftShellCallback     = function (_cb, a, p) { _legacyResult('shell', a, p) }
  window.__craftPowerCallback     = function (_cb, a, p) { _legacyResult('power', a, p) }
  window.__craftNetworkCallback   = function (_cb, a, p) { _legacyResult('network', a, p) }
  window.__craftBluetoothCallback = function (_cb, a, p) { _legacyResult('bluetooth', a, p) }

  // The menu callback is fundamentally different — bridge_menu.zig fires
  // it with a single `(action_id)` arg when the user clicks a menu item.
  // We re-emit as a `craft:menu:action` event for `craft.menu.onAction`.
  window.__craftMenuCallback = function (id) {
    if (typeof id === 'string' && id.length > 0) {
      window.dispatchEvent(new CustomEvent('craft:menu:action', { detail: { id: id } }))
    }
  }

  // The default App-menu Settings… item — and any `role: 'settings'` item an
  // app declares — fires this. Its own event, not `craft:menu:action`: an app
  // that never calls craft.menu.set() should not have to subscribe to a menu
  // API it does not use, and a "reserved" menu id would be indistinguishable
  // from an app-declared item that happened to pick the same string.
  window.__craftSettingsListeners = window.__craftSettingsListeners || 0
  window.__craftSettingsOpen = function () {
    // The one genuinely silent case: an enabled Cmd+, in a page with no
    // handler. Saying so once beats leaving it a mystery, and it is why the
    // item can ship always-present rather than opt-in.
    if (window.__craftSettingsListeners === 0 && typeof console !== 'undefined' && console.info) {
      console.info('[craft] Settings… was chosen but nothing is listening. Subscribe with craft.settings.onOpen(() => { … }).')
    }
    window.dispatchEvent(new CustomEvent('craft:settings:open', { detail: { source: 'menu' } }))
  }

  // -------------------------------------------------------------------------
  // window — full surface from bridge_window.zig
  // -------------------------------------------------------------------------
  window.craft.window = {
    show:         function ()         { return _send('window', 'show') },
    hide:         function ()         { return _send('window', 'hide') },
    toggle:       function ()         { return _send('window', 'toggle') },
    focus:        function ()         { return _send('window', 'focus') },
    minimize:     function ()         { return _send('window', 'minimize') },
    maximize:     function ()         { return _send('window', 'maximize') },
    close:        function ()         { return _send('window', 'close') },
    center:       function ()         { return _send('window', 'center') },
    reload:       function ()         { return _send('window', 'reload') },
    toggleFullscreen: function ()     { return _send('window', 'toggleFullscreen') },
    setFullscreen: function (on)      { return _send('window', 'setFullscreen', _stringify({ value: !!on })) },
    setTitle:     function (title)    { return _send('window', 'setTitle', _stringify({ title: String(title) })) },
    // Earlier these accepted NaN/Infinity — the native bridge would
    // either silently use defaults (best case) or write garbage geometry
    // values into AppKit (worst case, only seen in DEBUG builds). Coerce
    // to a finite, non-negative integer at the JS boundary so app code
    // that does math doesn't have to remember.
    setSize:      function (w, h)     { return _send('window', 'setSize', _stringify({ width: _finite(w, 800), height: _finite(h, 600) })) },
    setPosition:  function (x, y)     { return _send('window', 'setPosition', _stringify({ x: _finiteSigned(x, 100), y: _finiteSigned(y, 100) })) },
    moveBy:       function (dx, dy)   { return _send('window', 'moveBy', _stringify({ dx: Number(dx) || 0, dy: Number(dy) || 0 })) },
    setMinSize:   function (w, h)     { return _send('window', 'setMinSize', _stringify({ width: _finite(w, 0), height: _finite(h, 0) })) },
    setMaxSize:   function (w, h)     { return _send('window', 'setMaxSize', _stringify({ width: _finite(w, 0), height: _finite(h, 0) })) },
    setAspectRatio: function (w, h)   { return _send('window', 'setAspectRatio', _stringify({ width: _finite(w, 1), height: _finite(h, 1) })) },
    setOpacity:   function (op)       { return _send('window', 'setOpacity', _stringify({ value: op })) },
    setAlwaysOnTop: function (on)     { return _send('window', 'setAlwaysOnTop', _stringify({ value: !!on })) },
    setResizable: function (on)       { return _send('window', 'setResizable', _stringify({ value: !!on })) },
    setMovable:   function (on)       { return _send('window', 'setMovable', _stringify({ value: !!on })) },
    startDrag:    function ()         { return _send('window', 'startDrag') },
    setHasShadow: function (on)       { return _send('window', 'setHasShadow', _stringify({ value: !!on })) },
    setBackgroundColor: function (c)  { return _send('window', 'setBackgroundColor', _stringify({ color: String(c) })) },
    setVibrancy:  function (mat)      { return _send('window', 'setVibrancy', _stringify({ material: String(mat || '') })) },
    setWebSidebarCollapsed: function (on) { return _send('window', 'setWebSidebarCollapsed', _stringify({ collapsed: !!on })) },
  }

  // -------------------------------------------------------------------------
  // app — process-level controls + metadata
  // -------------------------------------------------------------------------
  window.craft.app = {
    hideDockIcon: function () { return _send('app', 'hideDockIcon') },
    showDockIcon: function () { return _send('app', 'showDockIcon') },
    quit:         function () { return _send('app', 'quit') },
    // Bundle / process metadata for About panels and log paths.
    getInfo:      function () { return _req('app', 'getInfo') },
    notify:       function (opts) { return _send('app', 'notify', _stringify(opts || {})) },
    setBadge:     function (n)    { return _send('app', 'setBadge', _stringify({ count: Number(n) || 0 })) },
    bounce:       function (type) { return _send('app', 'bounce', _stringify({ type: String(type || 'informational') })) },
  }

  // -------------------------------------------------------------------------
  // window — events (focus/blur/resize/move/close, etc).
  // The event payload arrives via __craftDeliverWindowEvent from the
  // native NSWindowDelegate; we re-emit as `craft:window:<name>` events.
  // -------------------------------------------------------------------------
  window.__craftDeliverWindowEvent = function (name, detail) {
    if (typeof name !== 'string' || name.length === 0) return
    window.dispatchEvent(new CustomEvent('craft:window:' + name, { detail: detail || {} }))
  }
  // Add event subscribers as a sibling object — keeps the action API
  // (`craft.window.show()`) and the event API distinct.
  window.craft.window.onFocus    = _evt('craft:window:focus')
  window.craft.window.onBlur     = _evt('craft:window:blur')
  window.craft.window.onResize   = _evt('craft:window:resize')
  window.craft.window.onMove     = _evt('craft:window:move')
  window.craft.window.onClose    = _evt('craft:window:close')
  window.craft.window.onMinimize = _evt('craft:window:minimize')
  window.craft.window.onRestore  = _evt('craft:window:restore')

  // -------------------------------------------------------------------------
  // dialog — file pickers + alerts
  // -------------------------------------------------------------------------
  window.craft.dialog = {
    showOpenDialog: function (opts) {
      opts = opts || {}
      // Single vs multi vs folder map to distinct native actions because
      // each one configures NSOpenPanel differently and reports under a
      // different result key.
      if (opts.properties && opts.properties.indexOf('openDirectory') >= 0) {
        return _req('dialog', 'openFolder', _stringify(opts))
      }
      if (opts.properties && opts.properties.indexOf('multiSelections') >= 0) {
        return _req('dialog', 'openFiles', _stringify(opts))
      }
      return _req('dialog', 'openFile', _stringify(opts))
    },
    showSaveDialog: function (opts)  { return _req('dialog', 'saveFile', _stringify(opts || {})) },
    showMessageBox: function (opts) {
      opts = opts || {}
      // showAlert is a single-button info banner. showConfirm is OK/cancel
      // with a boolean response. Anything beyond two buttons isn't yet
      // wired natively; callers should use showAlert and detect.
      const isConfirm = (opts.buttons && opts.buttons.length >= 2) || opts.type === 'question'
      return _req('dialog', isConfirm ? 'showConfirm' : 'showAlert', _stringify(opts))
    },
    // Convenience helpers that match Electron-ish semantics.
    showAlert:   function (msg, opts) { return _req('dialog', 'showAlert', _stringify(Object.assign({ message: String(msg) }, opts || {}))) },
    showConfirm: function (msg, opts) { return _req('dialog', 'showConfirm', _stringify(Object.assign({ message: String(msg) }, opts || {}))) },
  }

  // -------------------------------------------------------------------------
  // clipboard — text + html (image read/write are stubbed natively)
  // -------------------------------------------------------------------------
  window.craft.clipboard = {
    writeText: function (text)        { return _send('clipboard', 'writeText', _stringify({ text: String(text) })) },
    readText:  function ()            { return _req('clipboard', 'readText').then(function (r) { return (r && r.text) || '' }) },
    writeHTML: function (html)        { return _send('clipboard', 'writeHTML', _stringify({ html: String(html) })) },
    readHTML:  function ()            { return _req('clipboard', 'readHTML').then(function (r) { return (r && r.html) || '' }) },
    clear:     function ()            { return _send('clipboard', 'clear') },
    hasText:   function ()            { return _req('clipboard', 'hasText').then(function (r) { return !!(r && r.value) }) },
    hasHTML:   function ()            { return _req('clipboard', 'hasHTML').then(function (r) { return !!(r && r.value) }) },
    hasImage:  function ()            { return _req('clipboard', 'hasImage').then(function (r) { return !!(r && r.value) }) },
  }

  // -------------------------------------------------------------------------
  // notifications — banner / badge
  // -------------------------------------------------------------------------
  window.craft.notifications = {
    show: function (opts) {
      // Convenience wrapper around schedule with no triggerAt.
      const o = Object.assign({}, opts || {})
      if (typeof o.title !== 'string' || o.title.length === 0) {
        return Promise.reject(new Error('notification title is required'))
      }
      return _send('notification', 'schedule', _stringify(o))
    },
    schedule:          function (opts) { return _send('notification', 'schedule', _stringify(opts || {})) },
    cancel:            function (id)   { return _send('notification', 'cancel', _stringify({ id: String(id) })) },
    cancelAll:         function ()     { return _send('notification', 'cancelAll') },
    setBadge:          function (n)    { return _send('notification', 'setBadge', _stringify({ count: Number(n) || 0 })) },
    clearBadge:        function ()     { return _send('notification', 'clearBadge') },
    requestPermission: function ()     { return _req('notification', 'requestPermission').then(function (r) { return (r && r.granted) === true }) },
  }

  // -------------------------------------------------------------------------
  // fs — read/write/etc; values come back keyed by action.
  // -------------------------------------------------------------------------
  window.craft.fs = {
    readFile:   function (path)             { return _req('fs', 'readFile', _stringify({ path: String(path) })) },
    writeFile:  function (path, data)       { return _send('fs', 'writeFile', _stringify({ path: String(path), data: String(data) })) },
    appendFile: function (path, data)       { return _send('fs', 'appendFile', _stringify({ path: String(path), data: String(data) })) },
    deleteFile: function (path)             { return _send('fs', 'deleteFile', _stringify({ path: String(path) })) },
    exists:     function (path)             { return _req('fs', 'exists', _stringify({ path: String(path) })).then(function (r) { return !!(r && r.exists) }) },
    stat:       function (path)             { return _req('fs', 'stat', _stringify({ path: String(path) })) },
    readDir:    function (path)             { return _req('fs', 'readDir', _stringify({ path: String(path) })) },
    mkdir:      function (path, opts)       { return _send('fs', 'mkdir', _stringify(Object.assign({ path: String(path) }, opts || {}))) },
    rmdir:      function (path, opts)       { return _send('fs', 'rmdir', _stringify(Object.assign({ path: String(path) }, opts || {}))) },
    copy:       function (from, to)         { return _send('fs', 'copy', _stringify({ from: String(from), to: String(to) })) },
    move:       function (from, to)         { return _send('fs', 'move', _stringify({ from: String(from), to: String(to) })) },
    watch:      function (path, callbackId) { return _send('fs', 'watch', _stringify({ path: String(path), callbackId: String(callbackId || '') })) },
    unwatch:    function (id)               { return _send('fs', 'unwatch', _stringify({ id: String(id) })) },
    onChange:   _evt('craft:fs:change'),
    homeDir:    function ()                 { return _req('fs', 'getHomeDir').then(function (r) { return (r && r.path) || '' }) },
    tempDir:    function ()                 { return _req('fs', 'getTempDir').then(function (r) { return (r && r.path) || '' }) },
    appDataDir: function ()                 { return _req('fs', 'getAppDataDir').then(function (r) { return (r && r.path) || '' }) },
  }

  // -------------------------------------------------------------------------
  // shell — open URLs + spawn processes
  // -------------------------------------------------------------------------
  window.craft.shell = {
    openExternal: function (url)              { return _send('shell', 'openUrl', _stringify({ url: String(url) })) },
    openPath:     function (path)             { return _send('shell', 'openPath', _stringify({ path: String(path) })) },
    showInFinder: function (path)             { return _send('shell', 'showInFinder', _stringify({ path: String(path) })) },
    spawn:        function (id, cmd, args, opts) {
      return _send('shell', 'spawn', _stringify(Object.assign({
        id: String(id), command: String(cmd), args: args || [],
      }, opts || {})))
    },
    kill:         function (id)               { return _send('shell', 'kill', _stringify({ id: String(id) })) },
    getEnv:       function (name)             { return _req('shell', 'getEnv', _stringify({ name: String(name) })).then(function (r) { return r && r.value }) },
    setEnv:       function (name, value)      { return _send('shell', 'setEnv', _stringify({ name: String(name), value: String(value) })) },
  }

  // -------------------------------------------------------------------------
  // shortcuts — global hotkeys
  // -------------------------------------------------------------------------
  // `register` is fire-and-forget by necessity, not by choice: `_req` keys its
  // pending queue by action name alone, and `register`/`enable`/`disable` are
  // action names other bridges use too, so making these requests would mix
  // replies between namespaces. `onError` is how a refused registration —
  // the key already belongs to another app, or to the system — still reaches
  // the caller. Registering a hotkey and never hearing that you did not get it
  // is the bug this whole namespace was rewritten to fix (#47).
  window.craft.shortcuts = {
    register:       function (id, accelerator, opts) {
      return _send('shortcuts', 'register', _stringify(Object.assign({
        id: String(id), accelerator: String(accelerator),
      }, opts || {})))
    },
    unregister:     function (id) { return _send('shortcuts', 'unregister', _stringify({ id: String(id) })) },
    unregisterAll:  function ()   { return _send('shortcuts', 'unregisterAll') },
    enable:         function (id) { return _send('shortcuts', 'enable', _stringify({ id: String(id) })) },
    disable:        function (id) { return _send('shortcuts', 'disable', _stringify({ id: String(id) })) },
    isRegistered:   function (id) { return _req('shortcuts', 'isRegistered', _stringify({ id: String(id) })).then(function (r) { return !!(r && r.value) }) },
    list:           function ()   { return _req('shortcuts', 'list').then(function (r) { return (r && r.shortcuts) || [] }) },
    on:             _evt('craft:shortcut'),
    onError:        _evt('craft:shortcut:error'),
  }

  // -------------------------------------------------------------------------
  // settings — the Cmd+, convention
  // -------------------------------------------------------------------------
  // craft's default App menu ships a Settings… item; this is where its click
  // arrives. `open()` is page-local, so a gear button in your own toolbar
  // reaches the same handler without duplicating it.
  window.craft.settings = {
    onOpen: function (cb) {
      window.__craftSettingsListeners++
      const off = _evt('craft:settings:open')(cb)
      let released = false
      return function () {
        if (released) return
        released = true
        window.__craftSettingsListeners--
        off()
      }
    },
    open: function (source) {
      window.dispatchEvent(new CustomEvent('craft:settings:open',
        { detail: { source: String(source || 'app') } }))
      return Promise.resolve()
    },
  }

  // -------------------------------------------------------------------------
  // prefs — a small scalar preference store (macOS: CFPreferences)
  // -------------------------------------------------------------------------
  // Stores string, number and boolean, and nothing else on purpose. The
  // preferences API raises an Objective-C exception for a non-property-list
  // value, and Zig cannot catch one — so refusing containers here is what makes
  // that crash unreachable rather than merely unlikely. Serialise structure
  // yourself: prefs.set(k, JSON.stringify(v)).
  //
  // Wire actions are namespace-qualified (`prefs:get`, never a bare `get`)
  // because the pending-reply queue is keyed by action name alone. A bare
  // `get` would be drained by keychain.get and tags.get; a bare
  // `set`/`delete`/`clear` would be *resolved* by other bridges that emit a
  // result under those names without their own facades ever waiting for one.
  const PREFS_KEY_RE = /^[a-z0-9][\w.-]{0,63}$/i
  const PREFS_MAX_VALUE_BYTES = 8192
  // A local plist read that has not answered in two seconds is not going to;
  // the 30-second default is for things like modal dialogs.
  const PREFS_TIMEOUT_MS = 2000

  function _prefsErr(Ctor, code, message) {
    const e = new Ctor(message)
    e.code = code
    return e
  }

  function _prefsKey(fn, key) {
    if (typeof key === 'string' && PREFS_KEY_RE.test(key)) return null
    return _prefsErr(TypeError, 'PREFS_BAD_KEY', `craft.prefs.${fn}: invalid key ${_stringify(key)} — keys must match /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/`)
  }

  function _prefsUtf8Len(s) {
    if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(s).length
    return unescape(encodeURIComponent(s)).length
  }

  function _prefsEncode(key, value) {
    const q = JSON.stringify(key)
    const t = typeof value

    if (t === 'string') {
      const bytes = _prefsUtf8Len(value)
      if (bytes > PREFS_MAX_VALUE_BYTES) {
        return { err: _prefsErr(RangeError, 'PREFS_VALUE_TOO_LARGE', `craft.prefs.set(${q}): value is ${bytes} bytes, limit is ${PREFS_MAX_VALUE_BYTES} — write data this size with craft.fs, not prefs.`) }
      }
      return { d: { k: key, t: 's', s: value } }
    }

    if (t === 'boolean') return { d: { k: key, t: 'b', b: value } }

    if (t === 'number') {
      if (!isFinite(value)) {
        return { err: _prefsErr(TypeError, 'PREFS_NON_FINITE', `craft.prefs.set(${q}): ${String(value)} cannot be stored — prefs holds finite numbers only.`) }
      }
      if (Number.isInteger(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER)
        return { d: { k: key, t: 'i', i: value } }
      return { d: { k: key, t: 'd', n: value } }
    }

    const kind = value === null
      ? 'null'
      : Array.isArray(value)
        ? 'array'
        : t === 'object' ? ((value.constructor && value.constructor.name) || 'object') : t

    let msg = `craft.prefs.set(${q}): prefs stores string, number and boolean only — got ${kind}. `
      + `Serialise it yourself: craft.prefs.set(${q}, JSON.stringify(value)) and JSON.parse(await craft.prefs.get(${q}, "null")).`
    if (value === null || t === 'undefined')
      msg += ` To remove a key, call craft.prefs.delete(${q}).`
    return { err: _prefsErr(TypeError, 'PREFS_UNSUPPORTED_VALUE', msg) }
  }

  window.craft.prefs = {
    get: function (key, fallback) {
      const bad = _prefsKey('get', key)
      if (bad) return Promise.reject(bad)
      return _req('prefs', 'prefs:get', _stringify({ k: key }), PREFS_TIMEOUT_MS).then(function (r) {
        const tag = r && r.t
        if (tag === 'none') return fallback
        if (tag === 'other') {
          throw _prefsErr(TypeError, 'PREFS_FOREIGN_VALUE', `craft.prefs.get(${JSON.stringify(key)}): the stored value is a ${r.cf || 'non-scalar'}, `
            + `which craft.prefs cannot represent. Something outside craft wrote it (e.g. \`defaults write\`). `
            + `craft.prefs.delete(${JSON.stringify(key)}) removes it.`)
        }
        let v
        if (tag === 's') v = r.s
        else if (tag === 'i') v = r.i
        else if (tag === 'd') v = r.n
        else if (tag === 'b') v = !!r.b
        else return fallback
        // A fallback also declares the expected type, so a value left behind by
        // an older build of the app hands back the default rather than a
        // surprise. Call get(key) with no fallback to read whatever is stored.
        if (fallback !== undefined && typeof v !== typeof fallback) return fallback
        return v
      })
    },

    set: function (key, value) {
      const bad = _prefsKey('set', key)
      if (bad) return Promise.reject(bad)
      const enc = _prefsEncode(key, value)
      if (enc.err) return Promise.reject(enc.err)
      // A request, not fire-and-forget: a resolved set() has to mean the bytes
      // are on disk, and fire-and-forget has no rejection channel at all.
      return _req('prefs', 'prefs:set', _stringify(enc.d), PREFS_TIMEOUT_MS)
        .then(function () { return undefined })
    },

    delete: function (key) {
      const bad = _prefsKey('delete', key)
      if (bad) return Promise.reject(bad)
      return _req('prefs', 'prefs:delete', _stringify({ k: key }), PREFS_TIMEOUT_MS)
        .then(function (r) { return !!(r && r.existed) })
    },

    clear: function () {
      return _req('prefs', 'prefs:clear', '{}', PREFS_TIMEOUT_MS)
        .then(function (r) { return (r && r.removed) || 0 })
    },

    keys: function () {
      return _req('prefs', 'prefs:keys', '{}', PREFS_TIMEOUT_MS)
        .then(function (r) { return (r && r.keys) || [] })
    },

    // Which preferences domain is actually in use, and the command to read it.
    // An unbundled dev binary writes to a domain named after the executable and
    // a packaged .app writes to its bundle id, so preferences set in
    // development can appear to vanish once the app is packaged. This makes
    // that a question with an answer.
    info: function () { return _req('prefs', 'prefs:info', '{}', PREFS_TIMEOUT_MS) },
  }

  // -------------------------------------------------------------------------
  // capabilities — what the native side actually serves
  // -------------------------------------------------------------------------
  // This script is one blob, injected whole into every craft window, whatever
  // the binary behind it implements. So `typeof craft.tray.destroy === 'function'`
  // has never been evidence that anything is behind it — and three shipped bugs
  // came from exactly that assumption. Ask instead.
  //
  //   const caps = await craft.capabilities()
  //   caps.namespaces.updater.status   // 'unavailable'
  //   caps.namespaces.updater.reason   // 'the Sparkle framework is not linked…'
  //   caps.channels['craft:fs:change'] // 'live' | 'unknown'
  //
  // A namespace craft has not audited reports `undeclared`, which means exactly
  // that: craft will not claim anything either way. Treat it as "try it and
  // handle failure", not as "missing". Channels answer 'live' or 'unknown' for
  // the same reason — there is no 'dead', because craft cannot prove a channel
  // has no emitter.
  window.craft.capabilities = function () {
    return _req('capabilities', 'capabilities:get', '{}', 5000).then(function (manifest) {
      window.__craftCapabilities = manifest
      return manifest
    })
  }

  // The last answer, or null if nothing has asked yet. For code that cannot
  // await — a synchronous feature check during startup.
  window.craft.capabilitiesSync = function () {
    return window.__craftCapabilities || null
  }

  // Convenience: is this exact surface known to work?
  //
  // Answers false for an unavailable surface and true for an undeclared one.
  // That asymmetry is deliberate — failing open is the only safe default for a
  // mechanism that describes itself, and an older binary with no capabilities
  // support at all must not make working code stop calling.
  window.craft.supports = function (path) {
    const caps = window.__craftCapabilities
    if (!caps || !caps.namespaces) return true
    const parts = String(path).split('.')
    const ns = caps.namespaces[parts[0]]
    if (!ns) return true
    if (ns.status === 'unavailable' || ns.status === 'unrouted') return false
    if (parts.length < 2 || !ns.actions) return ns.status !== 'unavailable'
    const action = ns.actions[parts[1]]
    if (!action) return ns.status !== 'declared'
    return action.status !== 'unavailable'
  }

  // -------------------------------------------------------------------------
  // theme — system appearance
  // -------------------------------------------------------------------------
  // Native side delivers `craft:theme` with `{appearance:'dark'|'light'}`
  // via __craftDeliverTheme on app boot and on every appearance change.
  window.__craftDeliverTheme = function (info) {
    if (!info) return
    window.__craftCurrentTheme = info
    window.dispatchEvent(new CustomEvent('craft:theme', { detail: info }))
  }
  window.craft.theme = {
    get:        function () { return window.__craftCurrentTheme || { appearance: 'light' } },
    onChange:   _evt('craft:theme'),
  }

  // -------------------------------------------------------------------------
  // dragOut — start a native drag from a DOM element so the user can drag
  // a file *out* of the window onto Finder / Slack / etc.
  // -------------------------------------------------------------------------
  // Usage:
  //   craft.dragOut.start(['/Users/me/export.png'], { event: mouseEvent })
  // The second arg is optional but improves drag preview alignment when
  // the caller can pass the originating event.
  window.craft.dragOut = {
    start: function (paths, opts) {
      const arr = Array.isArray(paths) ? paths : [paths]
      const filtered = arr.filter(function (p) { return typeof p === 'string' && p.length > 0 })
      if (filtered.length === 0) return Promise.reject(new Error('dragOut: at least one path required'))
      const o = opts || {}
      return _send('dragOut', 'start', _stringify({
        paths: filtered,
        x: typeof o.x === 'number' ? o.x : (o.event ? o.event.clientX : 0),
        y: typeof o.y === 'number' ? o.y : (o.event ? o.event.clientY : 0),
      }))
    },
  }

  // -------------------------------------------------------------------------
  // deepLink — receive `myapp://...` URLs from the OS
  // -------------------------------------------------------------------------
  // Native side delivers via __craftDeliverDeepLink('myapp://path').
  window.__craftDeliverDeepLink = function (url) {
    if (typeof url !== 'string' || url.length === 0) return
    window.__craftPendingDeepLink = url
    window.dispatchEvent(new CustomEvent('craft:deepLink', { detail: { url: url } }))
  }
  window.craft.deepLink = {
    onUrl: _evt('craft:deepLink'),
    // If the OS launched the app *because* of a URL, that URL may be
    // delivered before the page is ready. Subscribers added late can
    // still get it via this getter.
    getInitialUrl: function () { return window.__craftPendingDeepLink || null },
  }

  // -------------------------------------------------------------------------
  // power — battery + sleep prevention
  // -------------------------------------------------------------------------
  window.craft.power = {
    isCharging:        function () { return _req('power', 'isCharging').then(function (r) { return !!(r && r.value) }) },
    isPluggedIn:       function () { return _req('power', 'isPluggedIn').then(function (r) { return !!(r && r.value) }) },
    isLowPowerMode:    function () { return _req('power', 'isLowPowerMode').then(function (r) { return !!(r && r.value) }) },
    // The native bridge has both getBatteryLevel (numeric 0..1) and
    // getBatteryState (string like "charged"|"unplugged"). Earlier this
    // facade called the wrong action; calling getBatteryLevel here.
    batteryLevel:      function () { return _req('power', 'getBatteryLevel').then(function (r) { return (r && r.level != null) ? r.level : null }) },
    batteryState:      function () { return _req('power', 'getBatteryState').then(function (r) { return (r && r.state) || 'unknown' }) },
    timeRemaining:     function () { return _req('power', 'getTimeRemaining').then(function (r) { return (r && r.minutes != null) ? r.minutes : null }) },
    thermalState:      function () { return _req('power', 'getThermalState').then(function (r) { return (r && r.state) || 'nominal' }) },
    uptimeSeconds:     function () { return _req('power', 'getUptimeSeconds').then(function (r) { return (r && r.seconds) || 0 }) },
    preventSleep:      function (reason) { return _send('power', 'preventSleep', _stringify({ reason: String(reason || '') })) },
    allowSleep:        function () { return _send('power', 'allowSleep') },
    onSleep:           _evt('craft:powerSleep'),
    onWake:            _evt('craft:powerWake'),
  }

  // -------------------------------------------------------------------------
  // network — reachability + interface info
  // -------------------------------------------------------------------------
  window.craft.network = {
    connectionType:    function () { return _req('network', 'getConnectionType').then(function (r) { return (r && r.type) || 'unknown' }) },
    wifiSSID:          function () { return _req('network', 'getWiFiSSID').then(function (r) { return r && r.ssid }) },
    wifiSignalStrength:function () { return _req('network', 'getWiFiSignalStrength').then(function (r) { return r && r.dBm }) },
    ipAddress:         function () { return _req('network', 'getIPAddress').then(function (r) { return (r && r.address) || '' }) },
    macAddress:        function () { return _req('network', 'getMACAddress').then(function (r) { return (r && r.address) || '' }) },
    interfaces:        function () { return _req('network', 'getNetworkInterfaces').then(function (r) { return (r && r.interfaces) || [] }) },
    isVPNConnected:    function () { return _req('network', 'isVPNConnected').then(function (r) { return !!(r && r.value) }) },
    proxySettings:     function () { return _req('network', 'getProxySettings') },
    openPreferences:   function () { return _send('network', 'openNetworkPreferences') },
    onChange:          _evt('craft:networkChange'),
  }

  // -------------------------------------------------------------------------
  // updater — Sparkle / WinSparkle / custom feed
  // -------------------------------------------------------------------------
  window.craft.updater = {
    checkForUpdates:           function ()       { return _send('updater', 'checkForUpdates') },
    checkInBackground:         function ()       { return _send('updater', 'checkForUpdatesInBackground') },
    setAutomaticChecks:        function (on)     { return _send('updater', 'setAutomaticChecks', _stringify({ value: !!on })) },
    setCheckInterval:          function (sec)    { return _send('updater', 'setCheckInterval', _stringify({ seconds: Number(sec) || 0 })) },
    setFeedURL:                function (url)    { return _send('updater', 'setFeedURL', _stringify({ url: String(url) })) },
    getLastUpdateCheckDate:    function ()       { return _req('updater', 'getLastUpdateCheckDate').then(function (r) { return r && r.date }) },
    getUpdateInfo:             function ()       { return _req('updater', 'getUpdateInfo') },
    onAvailable:               _evt('craft:updateAvailable'),
    onDownloaded:              _evt('craft:updateDownloaded'),
  }

  // -------------------------------------------------------------------------
  // system — host machine info (locale, timezone, accessibility flags)
  // -------------------------------------------------------------------------
  window.craft.system = {
    accentColor:      function () { return _req('system', 'getAccentColor').then(function (r) { return (r && r.color) || '' }) },
    highlightColor:   function () { return _req('system', 'getHighlightColor').then(function (r) { return (r && r.color) || '' }) },
    language:         function () { return _req('system', 'getLanguage').then(function (r) { return (r && r.language) || '' }) },
    locale:           function () { return _req('system', 'getLocale').then(function (r) { return (r && r.locale) || '' }) },
    timezone:         function () { return _req('system', 'getTimezone').then(function (r) { return (r && r.timezone) || '' }) },
    is24HourTime:     function () { return _req('system', 'is24HourTime').then(function (r) { return !!(r && r.value) }) },
    reduceMotion:     function () { return _req('system', 'getReduceMotion').then(function (r) { return !!(r && r.value) }) },
    reduceTransparency:function(){ return _req('system', 'getReduceTransparency').then(function (r) { return !!(r && r.value) }) },
    increaseContrast: function () { return _req('system', 'getIncreaseContrast').then(function (r) { return !!(r && r.value) }) },
    systemVersion:    function () { return _req('system', 'getSystemVersion').then(function (r) { return (r && r.version) || '' }) },
    hostname:         function () { return _req('system', 'getHostname').then(function (r) { return (r && r.hostname) || '' }) },
    username:         function () { return _req('system', 'getUsername').then(function (r) { return (r && r.username) || '' }) },
    openPreferences:  function () { return _send('system', 'openSystemPreferences') },
  }

  // -------------------------------------------------------------------------
  // menu — application menubar (the macOS top-of-screen menu)
  // -------------------------------------------------------------------------
  //
  // Every payload here is keyed the way `bridge_menu.zig` reads it, which is
  // `itemId` and `menuId` — not `id` and `parent`. The two drifted apart, and
  // because the native item handlers scan for their key and fall back to an
  // empty string, a wrong key does not raise anything: the lookup just misses
  // and the call returns as if it had worked. Same reason the action below is
  // `setAppMenu` and not `setApplicationMenu`, which no dispatcher ever had.
  window.craft.menu = {
    set:                  function (options)           { return _send('menu', 'setAppMenu', _stringify(options || {})) },
    setDock:              function (options)           { return _send('menu', 'setDockMenu', _stringify(options || {})) },
    addItem:              function (menuId, item)      { return _send('menu', 'addMenuItem', _stringify(_menuItemPayload(menuId, item))) },
    removeItem:           function (itemId)            { return _send('menu', 'removeMenuItem', _stringify({ itemId: String(itemId) })) },
    enableItem:           function (itemId)            { return _send('menu', 'enableMenuItem', _stringify({ itemId: String(itemId) })) },
    disableItem:          function (itemId)            { return _send('menu', 'disableMenuItem', _stringify({ itemId: String(itemId) })) },
    checkItem:            function (itemId)            { return _send('menu', 'checkMenuItem', _stringify({ itemId: String(itemId) })) },
    uncheckItem:          function (itemId)            { return _send('menu', 'uncheckMenuItem', _stringify({ itemId: String(itemId) })) },
    setItemLabel:         function (itemId, label)     { return _send('menu', 'setMenuItemLabel', _stringify({ itemId: String(itemId), label: String(label) })) },
    clearDock:            function ()                  { return _send('menu', 'clearDockMenu') },
    onAction:             _evt('craft:menu:action'),
  }

  // -------------------------------------------------------------------------
  // screen — display info (multi-monitor)
  // -------------------------------------------------------------------------
  window.craft.screen = {
    getDisplays: function () { return _req('screen', 'getDisplays').then(function (r) { return (r && r.displays) || [] }) },
    getPrimary:  function () { return _req('screen', 'getPrimary') },
    onChange:    _evt('craft:screen:change'),
  }

  // -------------------------------------------------------------------------
  // keychain — secure secret storage (macOS Keychain / Win Credential
  // Manager / Linux Secret Service via DBus)
  // -------------------------------------------------------------------------
  window.craft.keychain = {
    set:    function (service, account, password) {
      return _send('keychain', 'set', _stringify({ service: String(service), account: String(account), password: String(password) }))
    },
    get:    function (service, account) {
      return _req('keychain', 'get', _stringify({ service: String(service), account: String(account) }))
        .then(function (r) { return r && r.value })
    },
    delete: function (service, account) {
      return _send('keychain', 'delete', _stringify({ service: String(service), account: String(account) }))
    },
    has:    function (service, account) {
      return _req('keychain', 'has', _stringify({ service: String(service), account: String(account) }))
        .then(function (r) { return !!(r && r.value) })
    },
  }

  // -------------------------------------------------------------------------
  // permissions — runtime privacy gates (camera, mic, screen recording)
  // -------------------------------------------------------------------------
  window.craft.permissions = {
    check:        function (name) { return _req('permissions', 'check',   _stringify({ name: String(name) })).then(function (r) { return (r && r.status) || 'undetermined' }) },
    request:      function (name) { return _req('permissions', 'request', _stringify({ name: String(name) })).then(function (r) { return (r && r.status) || 'undetermined' }) },
    openSettings: function (name) { return _send('permissions', 'openSettings', _stringify({ name: String(name || '') })) },
  }

  // -------------------------------------------------------------------------
  // printing — print page / generate PDF
  // -------------------------------------------------------------------------
  window.craft.printing = {
    print:      function ()       { return _req('printing', 'print') },
    printToPDF: function (path)   { return _req('printing', 'printToPDF', _stringify({ path: String(path) })) },
  }

  // -------------------------------------------------------------------------
  // autoLaunch — start at login (SMAppService on macOS Ventura+)
  // -------------------------------------------------------------------------
  window.craft.autoLaunch = {
    enable:    function () { return _req('autoLaunch', 'enable').then(function (r) { return !!(r && r.ok) }) },
    disable:   function () { return _req('autoLaunch', 'disable').then(function (r) { return !!(r && r.ok) }) },
    isEnabled: function () { return _req('autoLaunch', 'isEnabled').then(function (r) { return !!(r && r.value) }) },
  }

  // -------------------------------------------------------------------------
  // touchbar — Touch Bar items (legacy macOS hardware)
  // -------------------------------------------------------------------------
  window.craft.touchbar = {
    addItem:        function (item)         { return _send('touchbar', 'addItem', _stringify(item || {})) },
    removeItem:     function (id)           { return _send('touchbar', 'removeItem', _stringify({ id: String(id) })) },
    updateItem:     function (id, props)    { return _send('touchbar', 'updateItem', _stringify(Object.assign({ id: String(id) }, props || {}))) },
    setLabel:       function (id, label)    { return _send('touchbar', 'setItemLabel', _stringify({ id: String(id), label: String(label) })) },
    setIcon:        function (id, icon)     { return _send('touchbar', 'setItemIcon', _stringify({ id: String(id), icon: String(icon) })) },
    setEnabled:     function (id, enabled)  { return _send('touchbar', 'setItemEnabled', _stringify({ id: String(id), enabled: !!enabled })) },
    setSliderValue: function (id, value)    { return _send('touchbar', 'setSliderValue', _stringify({ id: String(id), value: Number(value) || 0 })) },
    clear:          function ()             { return _send('touchbar', 'clear') },
    show:           function ()             { return _send('touchbar', 'show') },
    hide:           function ()             { return _send('touchbar', 'hide') },
    onAction:       _evt('craft:touchbar:action'),
  }

  // -------------------------------------------------------------------------
  // bluetooth — discovery + pairing (delegates to bridge_bluetooth)
  // -------------------------------------------------------------------------
  window.craft.bluetooth = {
    isEnabled:           function () { return _req('bluetooth', 'isEnabled').then(function (r) { return !!(r && r.value) }) },
    powerState:          function () { return _req('bluetooth', 'getPowerState').then(function (r) { return (r && r.state) || 'unknown' }) },
    connectedDevices:    function () { return _req('bluetooth', 'getConnectedDevices').then(function (r) { return (r && r.devices) || [] }) },
    pairedDevices:       function () { return _req('bluetooth', 'getPairedDevices').then(function (r) { return (r && r.devices) || [] }) },
    startDiscovery:      function ()       { return _send('bluetooth', 'startDiscovery') },
    stopDiscovery:       function ()       { return _send('bluetooth', 'stopDiscovery') },
    isDiscovering:       function ()       { return _req('bluetooth', 'isDiscovering').then(function (r) { return !!(r && r.value) }) },
    connect:             function (id)     { return _send('bluetooth', 'connectDevice', _stringify({ id: String(id) })) },
    disconnect:          function (id)     { return _send('bluetooth', 'disconnectDevice', _stringify({ id: String(id) })) },
    openPreferences:     function ()       { return _send('bluetooth', 'openBluetoothPreferences') },
    onDeviceFound:       _evt('craft:bluetooth:deviceFound'),
    onDeviceConnected:   _evt('craft:bluetooth:deviceConnected'),
    onDeviceDisconnected:_evt('craft:bluetooth:deviceDisconnected'),
  }

  // -------------------------------------------------------------------------
  // speech — text-to-speech via AVSpeechSynthesizer
  // -------------------------------------------------------------------------
  window.craft.speech = {
    speak: function (text, opts) {
      const o = Object.assign({ text: String(text) }, opts || {})
      return _req('speech', 'speak', _stringify(o))
    },
    stop:        function () { return _send('speech', 'stop') },
    pause:       function () { return _send('speech', 'pause') },
    resume:      function () { return _send('speech', 'resume') },
    isSpeaking:  function () { return _req('speech', 'isSpeaking').then(function (r) { return !!(r && r.value) }) },
    getVoices:   function () { return _req('speech', 'getVoices').then(function (r) { return (r && r.voices) || [] }) },
  }

  // -------------------------------------------------------------------------
  // crashReporter — capture and queue exceptions for later forwarding
  // -------------------------------------------------------------------------
  window.craft.crashReporter = {
    report: function (entry) {
      // Convenience: accept an Error or a plain object. Both get
      // normalized to the {severity, message, source, stack} shape
      // the native side stores.
      const e = entry instanceof Error
        ? { severity: 'error', message: entry.message, source: 'js', stack: entry.stack || '' }
        : Object.assign({ severity: 'error', source: 'js', message: '', stack: '' }, entry || {})
      return _req('crashReporter', 'report', _stringify(e))
    },
    flush:        function () { return _req('crashReporter', 'flush').then(function (r) { return (r && r.entries) || [] }) },
    clear:        function () { return _send('crashReporter', 'clear') },
    setEnabled:   function (on) { return _send('crashReporter', 'setEnabled', _stringify({ value: !!on })) },
    setUser:      function (id) { return _send('crashReporter', 'setUser', _stringify({ id: String(id || '') })) },
    setAppVersion:function (v)  { return _send('crashReporter', 'setAppVersion', _stringify({ version: String(v || '') })) },
    isEnabled:    function () { return _req('crashReporter', 'isEnabled').then(function (r) { return !!(r && r.value) }) },
    /**
     * Auto-attach: hook `window.onerror` and `unhandledrejection` so
     * every uncaught failure routes through `report()` automatically.
     * Returns an `off()` to detach. Call this once early in your app's
     * boot — after that you can lazily flush the queue on a timer.
     */
    attachGlobalHandlers: function () {
      const errH = function (msg, src, line, col, err) {
        const stack = (err && err.stack) || (msg + '\n  at ' + src + ':' + line + ':' + col)
        return window.craft.crashReporter.report({ severity: 'error', message: String(msg), source: 'js', stack: String(stack) })
      }
      const rejH = function (e) {
        const r = e && e.reason
        const msg = r ? (r.message || String(r)) : 'unhandledrejection'
        const stack = (r && r.stack) || ''
        return window.craft.crashReporter.report({ severity: 'error', message: msg, source: 'js', stack: stack })
      }
      window.addEventListener('error', function (e) { errH(e.message, e.filename, e.lineno, e.colno, e.error) })
      window.addEventListener('unhandledrejection', rejH)
      return function () {
        window.removeEventListener('error', errH)
        window.removeEventListener('unhandledrejection', rejH)
      }
    },
  }

  // -------------------------------------------------------------------------
  // iap — In-App Purchases (basic StoreKit shape)
  // -------------------------------------------------------------------------
  window.craft.iap = {
    isAvailable:        function () { return _req('iap', 'isAvailable').then(function (r) { return !!(r && r.value) }) },
    getProducts:        function (ids) { return _req('iap', 'getProducts', _stringify({ ids: Array.isArray(ids) ? ids : [String(ids)] })).then(function (r) { return (r && r.products) || [] }) },
    purchase:           function (productId) { return _req('iap', 'purchase', _stringify({ productId: String(productId) })) },
    restorePurchases:   function () { return _req('iap', 'restorePurchases') },
    finishTransaction:  function (transactionId) { return _send('iap', 'finishTransaction', _stringify({ transactionId: String(transactionId) })) },
    getReceiptData:     function () { return _req('iap', 'getReceiptData').then(function (r) { return r && r.receipt }) },
    onPurchased:        _evt('craft:iap:purchased'),
    onFailed:           _evt('craft:iap:failed'),
    onRestored:         _evt('craft:iap:restored'),
    onProductsLoaded:   _evt('craft:iap:productsLoaded'),
  }

  // -------------------------------------------------------------------------
  // location — CoreLocation
  // -------------------------------------------------------------------------
  window.craft.location = {
    requestPermission:  function (mode) { return _req('location', 'requestPermission', _stringify({ mode: String(mode || 'whenInUse') })).then(function (r) { return (r && r.status) || 'undetermined' }) },
    getAuthorization:   function () { return _req('location', 'getAuthorization').then(function (r) { return (r && r.status) || 'undetermined' }) },
    getCurrentLocation: function () { return _req('location', 'getCurrentLocation') },
    startWatching:      function (opts) { return _req('location', 'startWatching', _stringify(opts || {})).then(function (r) { return !!(r && r.ok) }) },
    stopWatching:       function () { return _send('location', 'stopWatching') },
    onUpdate:           _evt('craft:location:update'),
    onError:            _evt('craft:location:error'),
    onAuthChanged:      _evt('craft:location:authChanged'),
  }

  // -------------------------------------------------------------------------
  // screenCapture — programmatic screenshots via CGWindowList
  // -------------------------------------------------------------------------
  window.craft.screenCapture = {
    captureScreen: function () { return _req('screenCapture', 'captureScreen').then(function (r) { return r && r.image }) },
    captureWindow: function (id) { return _req('screenCapture', 'captureWindow', _stringify({ id: Number(id) })).then(function (r) { return r && r.image }) },
    listWindows:   function () { return _req('screenCapture', 'listWindows').then(function (r) { return (r && r.windows) || [] }) },
  }

  // -------------------------------------------------------------------------
  // focus — Do Not Disturb / Focus status (read) and control (via Shortcuts)
  // -------------------------------------------------------------------------
  window.craft.focus = {
    getStatus:            function () { return _req('focus', 'getStatus') },
    requestAuthorization: function () { return _req('focus', 'requestAuthorization').then(function (r) { return (r && r.authorization) || 'notDetermined' }) },
    setEnabled:           function (enabled, opts) {
      const o = Object.assign({ enabled: !!enabled }, opts || {})
      return _req('focus', 'setEnabled', _stringify(o))
    },
    runShortcut:          function (name) { return _req('focus', 'runShortcut', _stringify({ name: String(name) })) },
    listShortcuts:        function () { return _req('focus', 'listShortcuts').then(function (r) { return (r && r.shortcuts) || [] }) },
    // Full result, including `canList` — false inside the App Sandbox, where
    // enumeration is impossible and an empty array would read as "none".
    listShortcutsResult:  function () { return _req('focus', 'listShortcuts') },
  }

  // -------------------------------------------------------------------------
  // screenSharing — is the screen being shared or recorded right now?
  // -------------------------------------------------------------------------
  window.craft.screenSharing = {
    getState: function () { return _req('screenSharing', 'getState') },
    watch:    function (intervalMs) { return _req('screenSharing', 'watch', _stringify({ intervalMs: Number(intervalMs) || 2000 })) },
    unwatch:  function () { return _req('screenSharing', 'unwatch') },
    onChange: _evt('craft:screenSharing:change'),
  }

  // -------------------------------------------------------------------------
  // localServer — minimal HTTP listener for OAuth callbacks
  // -------------------------------------------------------------------------
  window.craft.localServer = {
    start:   function (port, host) { return _req('localServer', 'start', _stringify({ port: Number(port) || 0, host: String(host || '127.0.0.1') })) },
    stop:    function () { return _send('localServer', 'stop') },
    respond: function (opts) { return _send('localServer', 'respond', _stringify(opts || { status: 200, body: 'OK' })) },
    onRequest: _evt('craft:localServer:request'),
  }

  // -------------------------------------------------------------------------
  // biometric — TouchID / FaceID via LAContext
  // -------------------------------------------------------------------------
  window.craft.biometric = {
    isAvailable:     function () { return _req('biometric', 'isAvailable').then(function (r) { return !!(r && r.value) }) },
    getBiometryType: function () { return _req('biometric', 'getBiometryType').then(function (r) { return (r && r.type) || 'none' }) },
    evaluate:        function (reason, opts) {
      const o = Object.assign({ reason: String(reason || 'Authenticate to continue') }, opts || {})
      return _req('biometric', 'evaluate', _stringify(o)).then(function (r) { return r || { success: false } })
    },
  }

  // -------------------------------------------------------------------------
  // audio — NSSound playback + AVAudioRecorder recording
  // -------------------------------------------------------------------------
  window.craft.audio = {
    play:            function (path, opts) {
      const o = Object.assign({ path: String(path) }, opts || {})
      return _req('audio', 'play', _stringify(o)).then(function (r) { return !!(r && r.ok) })
    },
    playSystemSound: function (name) { return _req('audio', 'playSystemSound', _stringify({ name: String(name) })).then(function (r) { return !!(r && r.ok) }) },
    stop:            function () { return _send('audio', 'stop') },
    isPlaying:       function () { return _req('audio', 'isPlaying').then(function (r) { return !!(r && r.value) }) },
    startRecording:  function (path, opts) {
      const o = Object.assign({ path: String(path) }, opts || {})
      return _req('audio', 'startRecording', _stringify(o)).then(function (r) { return !!(r && r.ok) })
    },
    stopRecording:   function () { return _send('audio', 'stopRecording') },
    isRecording:     function () { return _req('audio', 'isRecording').then(function (r) { return !!(r && r.value) }) },
  }

  // -------------------------------------------------------------------------
  // appleScript — NSAppleScript executor
  // -------------------------------------------------------------------------
  window.craft.appleScript = {
    execute: function (source) { return _req('appleScript', 'execute', _stringify({ source: String(source) })) },
  }

  // -------------------------------------------------------------------------
  // fileAssociations — LaunchServices default-handler controls
  // -------------------------------------------------------------------------
  window.craft.fileAssociations = {
    getDefault: function (uti) { return _req('fileAssociations', 'getDefault', _stringify({ uti: String(uti) })).then(function (r) { return r && r.bundleId }) },
    setDefault: function (uti, bundleId) { return _req('fileAssociations', 'setDefault', _stringify({ uti: String(uti), bundleId: String(bundleId) })).then(function (r) { return !!(r && r.ok) }) },
  }

  // -------------------------------------------------------------------------
  // tags — Finder colour tags via xattr
  // -------------------------------------------------------------------------
  window.craft.tags = {
    get:   function (path) { return _req('tags', 'get', _stringify({ path: String(path) })).then(function (r) { return (r && r.tags) || [] }) },
    set:   function (path, tags) { return _req('tags', 'set', _stringify({ path: String(path), tags: Array.isArray(tags) ? tags : [String(tags)] })).then(function (r) { return !!(r && r.ok) }) },
    clear: function (path) { return _req('tags', 'clear', _stringify({ path: String(path) })).then(function (r) { return !!(r && r.ok) }) },
  }

  // -------------------------------------------------------------------------
  // pdf — PDFKit text extraction + page count
  // -------------------------------------------------------------------------
  window.craft.pdf = {
    countPages:  function (path) { return _req('pdf', 'countPages', _stringify({ path: String(path) })).then(function (r) { return (r && r.pages) || 0 }) },
    extractText: function (path) { return _req('pdf', 'extractText', _stringify({ path: String(path) })).then(function (r) { return (r && r.text) || '' }) },
  }

  // -------------------------------------------------------------------------
  // log — unified system log
  // -------------------------------------------------------------------------
  window.craft.log = {
    debug: function (m) { return _send('log', 'log', _stringify({ level: 'debug', message: String(m) })) },
    info:  function (m) { return _send('log', 'log', _stringify({ level: 'info', message: String(m) })) },
    warn:  function (m) { return _send('log', 'log', _stringify({ level: 'warn', message: String(m) })) },
    error: function (m) { return _send('log', 'log', _stringify({ level: 'error', message: String(m) })) },
  }

  // -------------------------------------------------------------------------
  // bonjour — service discovery (NWBrowser stub)
  // -------------------------------------------------------------------------
  window.craft.bonjour = {
    browse:    function (serviceType) { return _req('bonjour', 'browse', _stringify({ type: String(serviceType) })) },
    stop:      function () { return _send('bonjour', 'stop') },
    onFound:   _evt('craft:bonjour:found'),
    onLost:    _evt('craft:bonjour:lost'),
  }

  // -------------------------------------------------------------------------
  // spotlight — CSSearchableIndex
  // -------------------------------------------------------------------------
  window.craft.spotlight = {
    index:     function (items) { return _req('spotlight', 'index', _stringify({ items: items || [] })) },
    indexItems:function (items) { return _req('spotlight', 'indexItems', _stringify({ items: items || [] })) },
    remove:    function (ids)   { return _req('spotlight', 'remove', _stringify({ ids: ids || [] })) },
    deleteItems:function (ids)  { return _req('spotlight', 'deleteItems', _stringify({ identifiers: ids || [] })) },
    deleteItemsInDomain:function (domainIdentifier) { return _req('spotlight', 'deleteItemsInDomain', _stringify({ domainIdentifier: String(domainIdentifier) })) },
    removeAll: function ()      { return _req('spotlight', 'removeAll') },
    deleteAllItems:function ()  { return _req('spotlight', 'deleteAllItems') },
    getIndexingStatus:function () { return Promise.resolve({ isIndexing: false, itemCount: 0 }) },
  }

  // -------------------------------------------------------------------------
  // speechRecognition — SFSpeechRecognizer (stub)
  // -------------------------------------------------------------------------
  window.craft.speechRecognition = {
    isAvailable: function () { return _req('speechRecognition', 'isAvailable').then(function (r) { return !!(r && r.value) }) },
    start:       function (opts) { return _req('speechRecognition', 'start', _stringify(opts || {})) },
    stop:        function () { return _send('speechRecognition', 'stop') },
    onPartial:   _evt('craft:speechRecognition:partial'),
    onFinal:     _evt('craft:speechRecognition:final'),
  }

  // -------------------------------------------------------------------------
  // vision — OCR / face detection / barcode (stub)
  // -------------------------------------------------------------------------
  window.craft.vision = {
    recognizeText:  function (path) { return _req('vision', 'recognizeText', _stringify({ path: String(path) })).then(function (r) { return (r && r.results) || [] }) },
    detectFaces:    function (path) { return _req('vision', 'detectFaces', _stringify({ path: String(path) })).then(function (r) { return (r && r.results) || [] }) },
    detectBarcodes: function (path) { return _req('vision', 'detectBarcodes', _stringify({ path: String(path) })).then(function (r) { return (r && r.results) || [] }) },
  }

  // -------------------------------------------------------------------------
  // midi — CoreMIDI endpoint enumeration + send/receive
  // -------------------------------------------------------------------------
  window.craft.midi = {
    listSources:      function () { return _req('midi', 'listSources').then(function (r) { return (r && r.endpoints) || [] }) },
    listDestinations: function () { return _req('midi', 'listDestinations').then(function (r) { return (r && r.endpoints) || [] }) },
    send:        function (destinationIndex, data) { return _req('midi', 'send', _stringify({ index: Number(destinationIndex), data: Array.from(data || []) })) },
    subscribe:   function (sourceIndex) { return _req('midi', 'subscribe', _stringify({ index: Number(sourceIndex) })) },
    unsubscribe: function (sourceIndex) { return _req('midi', 'unsubscribe', _stringify({ index: Number(sourceIndex) })) },
    onMessage:   _evt('craft:midi:message'),
  }

  // -------------------------------------------------------------------------
  // coreml — load + run CoreML models on-device
  // -------------------------------------------------------------------------
  window.craft.coreml = {
    loadModel:   function (id, path) { return _req('coreml', 'loadModel', _stringify({ id: String(id), path: String(path) })).then(function (r) { return !!(r && r.loaded) }) },
    unloadModel: function (id)       { return _send('coreml', 'unloadModel', _stringify({ id: String(id) })) },
    predict:     function (id, input) { return _req('coreml', 'predict', _stringify({ id: String(id), input: input || {} })) },
  }

  // -------------------------------------------------------------------------
  // continuityCamera — list paired iPhone cameras
  // -------------------------------------------------------------------------
  window.craft.continuityCamera = {
    listCameras: function () { return _req('continuityCamera', 'listCameras').then(function (r) { return (r && r.cameras) || [] }) },
  }

  // -------------------------------------------------------------------------
  // serviceMenu — register handlers for the macOS Services submenu
  // -------------------------------------------------------------------------
  window.craft.serviceMenu = {
    register:   function (name) { return _req('serviceMenu', 'register', _stringify({ name: String(name) })) },
    unregister: function (name) { return _send('serviceMenu', 'unregister', _stringify({ name: String(name) })) },
    onInvoked:  _evt('craft:serviceMenu:invoked'),
  }

  // -------------------------------------------------------------------------
  // serial — serial-port I/O (IoT / Arduino)
  // -------------------------------------------------------------------------
  window.craft.serial = {
    list:  function () { return _req('serial', 'list').then(function (r) { return (r && r.ports) || [] }) },
    open:  function (path, baud) { return _req('serial', 'open', _stringify({ path: String(path), baud: Number(baud) || 9600 })) },
    write: function (id, data)   { return _req('serial', 'write', _stringify({ id: String(id), data: String(data) })) },
    read:  function (id, maxBytes) { return _req('serial', 'read', _stringify({ id: String(id), maxBytes: Number(maxBytes) || 4096 })) },
    close: function (id)         { return _send('serial', 'close', _stringify({ id: String(id) })) },
    onData: _evt('craft:serial:data'),
  }

  // -------------------------------------------------------------------------
  // handoff — NSUserActivity broadcast across the user's Apple devices
  // -------------------------------------------------------------------------
  // Native side delivers incoming handoffs via __craftDeliverHandoff;
  // re-emit as `craft:handoff:incoming` for app subscribers.
  window.__craftDeliverHandoff = function (info) {
    if (!info) return
    window.dispatchEvent(new CustomEvent('craft:handoff:incoming', { detail: info }))
  }
  window.craft.handoff = {
    startActivity: function (type, opts) {
      const o = Object.assign({ type: String(type) }, opts || {})
      return _req('handoff', 'startActivity', _stringify(o)).then(function (r) { return !!(r && r.ok) })
    },
    updateActivity: function (opts) { return _req('handoff', 'updateActivity', _stringify(opts || {})).then(function (r) { return !!(r && r.ok) }) },
    stopActivity:        function () { return _send('handoff', 'stopActivity') },
    getCurrentActivity:  function () { return _req('handoff', 'getCurrentActivity').then(function (r) { return r && r.activity }) },
    onIncoming:          _evt('craft:handoff:incoming'),
  }

  // -------------------------------------------------------------------------
  // tray — system menubar item (only meaningful when `system_tray: true`)
  // -------------------------------------------------------------------------
  window.craft.tray = {
    setTitle:   function (t) {
      // 20-char cap mirrors NSStatusItem behavior — anything past it gets
      // visually clipped, so we truncate eagerly to keep the JS-side
      // intent and the rendered title in sync.
      const s = String(t == null ? '' : t)
      return _send('tray', 'setTitle', s.length > 20 ? s.substring(0, 20) : s)
    },
    setTooltip: function (t)        { return _send('tray', 'setTooltip', String(t == null ? '' : t)) },
    setIcon:    function (icon)     { return _send('tray', 'setIcon', _stringify({ icon: String(icon) })) },
    setMenu:    function (items)    { return _send('tray', 'setMenu', _stringify(items || [])) },
    destroy:    function ()         { return _send('tray', 'destroy') },
    onClick:    function (cb) {
      const h = function (e) {
        cb({
          button:    (e.detail && e.detail.button) || 'left',
          timestamp: (e.detail && e.detail.timestamp) || Date.now(),
          modifiers: (e.detail && e.detail.modifiers) || {},
        })
      }
      window.addEventListener('craft:tray:click', h)
      return function () { window.removeEventListener('craft:tray:click', h) }
    },
    onClickToggleWindow: function () {
      return this.onClick(function () { window.craft.window.toggle() })
    },
    onMenuAction: _evt('craft:tray:menuAction'),
  }
  // Native side calls this when the status item is left-clicked. Right clicks
  // open the menu in AppKit and never come through here.
  window.__craftDeliverTrayClick = function (button) {
    window.dispatchEvent(new CustomEvent('craft:tray:click', {
      detail: { button: button || 'left', timestamp: Date.now(), modifiers: {} },
    }))
  }
  window.__craftDeliverAction = function (a) {
    if (a && a.length > 0) {
      window.dispatchEvent(new CustomEvent('craft:tray:menuAction', { detail: { action: a } }))
    }
  }

  // -------------------------------------------------------------------------
  // menubar — collapse/expand (only meaningful in tray mode)
  // -------------------------------------------------------------------------
  window.craft.menubar = {
    init:                  function ()      { return _send('menubarCollapse', 'init') },
    collapse:              function ()      { return _send('menubarCollapse', 'collapse') },
    expand:                function ()      { return _send('menubarCollapse', 'expand') },
    toggle:                function ()      { return _send('menubarCollapse', 'toggle') },
    // Was a hand-rolled pending entry queued under the reply key native used
    // to invent for it, `menubarCollapse:getState` — with no timeout, so a
    // call native never answered held its resolver until the page went away.
    // Native answers by request id now, so the key carries no meaning and this
    // is an ordinary request. `getState` is also served by screenSharing; the
    // id is what keeps the two apart.
    getState:              function ()      { return _req('menubarCollapse', 'getState') },
    // Seconds to wait before tidying up again, or 0 to leave the bar alone.
    // The native side parses this as a number: coercing it to a boolean here
    // sent "true", which parsed as 0 and quietly switched the feature off.
    setAutoCollapse:       function (s)     { return _send('menubarCollapse', 'setAutoCollapse', String(Math.max(0, Math.trunc(Number(s) || 0)))) },
    setSeparatorHidden:    function (h)     { return _send('menubarCollapse', 'setSeparatorHidden', h ? 'true' : 'false') },
    onStateChange:         _evt('craft:menubar:stateChange'),
  }

  // -------------------------------------------------------------------------
  // onFileDrop — file paths from native drag-drop (set from macos_file_drop)
  // -------------------------------------------------------------------------
  window.__craftDeliverFileDrop = function (paths) {
    if (!Array.isArray(paths) || paths.length === 0) return
    window.dispatchEvent(new CustomEvent('craft:fileDrop', { detail: { paths: paths } }))
  }
  window.craft.onFileDrop = _evt('craft:fileDrop')

  // -------------------------------------------------------------------------
  // Ready event + opt-in tray polling.
  // -------------------------------------------------------------------------
  function fireReady() {
    window.dispatchEvent(new CustomEvent('craft:ready'))
    if (typeof window.initializeCraftApp === 'function') window.initializeCraftApp()
  }
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', fireReady)
  else
    fireReady()

  // The full bridge enables tray + menubar polling via this flag, set by
  // the Zig side BEFORE this script is injected. Polling is a stopgap
  // until we have a proper native→JS push channel for these channels.
  if (window.__craftEnableTrayPolling) {
    setInterval(function () { _post('tray', 'pollActions', '') }, 100)
    setInterval(function () { _post('menubarCollapse', 'poll', '') }, 1000)
  }
})()
