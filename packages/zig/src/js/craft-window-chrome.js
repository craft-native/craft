// window.craft.windowControls — where the platform put the window buttons.
//
// Runs at document-start in every Craft window, and on iOS, where the answer is
// "there is no window". Same rules as craft-bridge.js: self-contained,
// ES5-friendly, idempotent, and it must not throw on a page that was opened in
// a browser instead.
//
// The close/minimise/zoom buttons belong to the window server on every desktop
// window Craft opens that is not frameless. A page cannot ask the window server
// anything, so it either guesses where they are or draws its own beside them —
// six circles in the corner, three of which only look like buttons. The host
// measures the real ones and states the answer here, before the document is
// parsed, and again whenever it changes.
//
// Three surfaces, because the three consumers are different:
//
//   window.craft.windowControls              layout that has to compute
//   <html data-craft-window-controls="...">  CSS that branches on the mode
//   --craft-window-controls-*                CSS that just needs the numbers
//
// The same file also states whether the window is the active one, because that
// is the other thing about the window's chrome a page cannot ask and gets
// visibly wrong. AppKit desaturates a background window's accent-coloured
// controls for free; every native app on the platform does it, so a web UI that
// keeps its buttons saturated blue behind another window is the one thing on
// screen insisting it is focused when it is not.
//
// `:focus-within` is not this — it is about the page's own focus and stays true
// while the whole window sits in the background. There is no CSS media feature
// for window activation, so the host has to say so:
//
//   <html data-craft-window-active="true|false">   CSS that restyles
//   window.craft.windowActive                      JS that has to branch
//   craft:windowactive                             work that must run on change
//
// The variables are the room to leave *inside the page*, so they are zero
// whenever the buttons are not over it — a window with a titlebar of its own, a
// window whose web content starts after a native sidebar, a fullscreen window
// whose titlebar has slid away. A page writes them as fallbacks and gets the
// browser's answer for free:
//
//   .titlebar { padding-left: var(--craft-window-controls-width, 0px) }
//   .replica  { display: var(--craft-window-controls-replicas, flex) }
//
// The reserve spans the host's own chrome row as well as the buttons, because
// a page clearing one has to clear the other. A page that is only *under* the
// buttons — a narrow icon rail, say, that the toolbar row beside them
// overhangs — needs the buttons alone, so those are published too:
//
//   --craft-window-buttons-x / -y / -width / -height
//
// Same coordinates, same zero-when-not-over-the-page rule. Reserving the union
// there would push the rail's first item down by the difference between a
// 14pt button and a 30pt toolbar row, for a row that never reaches it.
//
// `--craft-window-controls-replicas` is the `display` a replica should take. It
// is `none` wherever real buttons exist and wherever there is no window to
// control at all, and it is *absent* in a frameless window — the one case where
// the page's own controls are the real ones, and so the one case where this
// stays out of the way instead of dictating a layout it knows nothing about.
;(function () {
  window.craft = window.craft || {}
  if (window.craft._applyWindowControls) return

  // [variable, field]. Flat rather than nested so the loop below stays ES5.
  const VARIABLES = [
    '--craft-window-controls-width', 'reserveWidth',
    '--craft-window-controls-height', 'reserveHeight',
    '--craft-window-controls-inset-x', 'insetX',
    '--craft-window-controls-inset-y', 'insetY',
    '--craft-window-buttons-x', 'x',
    '--craft-window-buttons-y', 'y',
    '--craft-window-buttons-width', 'width',
    '--craft-window-buttons-height', 'height',
  ]

  let applied = null

  function paint(state) {
    // A document-start script normally has a root element already, but a host
    // publishing mid-navigation can arrive between documents, and a page can
    // replace its own root. Re-applied on DOMContentLoaded either way, so a
    // miss here costs nothing.
    const root = document.documentElement
    if (!root) return false

    root.setAttribute('data-craft-window-controls', state.style)

    for (let i = 0; i < VARIABLES.length; i += 2)
      root.style.setProperty(VARIABLES[i], state[VARIABLES[i + 1]] + 'px')

    if (state.replicas === null)
      root.style.removeProperty('--craft-window-controls-replicas')
    else
      root.style.setProperty('--craft-window-controls-replicas', state.replicas)

    return true
  }

  function differs(next) {
    if (!applied) return true

    for (const key in next) {
      if (applied[key] !== next[key]) return true
    }

    return false
  }

  // Called by the host: once with the seed at the bottom of this file, then on
  // every change — a resize, a fullscreen transition, a new document.
  //
  // The event is for layout CSS cannot express: a canvas, a measured scroller.
  // It fires only on a real change and never on the seed, so a listener added
  // at DOMContentLoaded has not already missed one, and a host that re-states
  // the same answer does not wake every listener on the page.
  window.craft._applyWindowControls = function (next) {
    const first = applied === null
    const changed = differs(next)

    window.craft.windowControls = Object.freeze(next)
    if (paint(next)) applied = next

    if (!first && changed && typeof CustomEvent === 'function') {
      window.dispatchEvent(new CustomEvent('craft:windowcontrols', {
        detail: window.craft.windowControls,
      }))
    }
  }

  // ---------------------------------------------------------------------
  // Window activation.
  // ---------------------------------------------------------------------

  let active = null

  function paintActive(next) {
    const root = document.documentElement
    if (!root) return false

    root.setAttribute('data-craft-window-active', next ? 'true' : 'false')
    return true
  }

  // Called on every transition, and once to seed. Idempotent, so the host may
  // restate the current answer without waking a single listener.
  window.craft._applyWindowActive = function (next) {
    next = !!next

    const first = active === null
    const changed = active !== next

    active = next
    window.craft.windowActive = next
    paintActive(next)

    if (!first && changed && typeof CustomEvent === 'function') {
      window.dispatchEvent(new CustomEvent('craft:windowactive', {
        detail: { active: next },
      }))
    }
  }

  // The seed, and why it is not the host's to give.
  //
  // The document-start scripts are installed once, when the webview is built —
  // before the window has been ordered in front, so at that moment no window is
  // key and a seed baked in there would say "inactive" for every app that ever
  // launches. It would also be a lie again after the first reload.
  //
  // `document.hasFocus()` is the same question asked at the only moment that
  // can answer it: whenever this document actually starts. It is synchronous,
  // so nothing paints before it, and it is re-read at DOMContentLoaded because
  // a document-start script can run before the window server has settled who is
  // key. The host's focus/blur events correct it from there.
  window.craft._applyWindowActive(
    typeof document !== 'undefined' && document.hasFocus ? document.hasFocus() : true,
  )

  // Dispatched by craft-bridge.js off the native NSWindowDelegate. Listening
  // rather than being called keeps this file free of any load-order dependency
  // on the bridge: the events cannot fire until long after both have run.
  if (typeof window.addEventListener === 'function') {
    window.addEventListener('craft:window:focus', function () {
      window.craft._applyWindowActive(true)
    })
    window.addEventListener('craft:window:blur', function () {
      window.craft._applyWindowActive(false)
    })
  }

  if (window.__craftWindowControls)
    window.craft._applyWindowControls(window.__craftWindowControls)

  if (typeof document !== 'undefined' && document.addEventListener) {
    document.addEventListener('DOMContentLoaded', function () {
      if (window.craft.windowControls) paint(window.craft.windowControls)

      // Re-read rather than re-paint: between document-start and here the
      // window may have become key, and unlike the controls state there is a
      // truthful local answer to consult.
      if (document.hasFocus) window.craft._applyWindowActive(document.hasFocus())
      else paintActive(active)
    })
  }
})()
