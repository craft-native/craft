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
// The variables are the room to leave *inside the page*, so they are zero
// whenever the buttons are not over it — a window with a titlebar of its own, a
// window whose web content starts after a native sidebar, a fullscreen window
// whose titlebar has slid away. A page writes them as fallbacks and gets the
// browser's answer for free:
//
//   .titlebar { padding-left: var(--craft-window-controls-width, 0px) }
//   .replica  { display: var(--craft-window-controls-replicas, flex) }
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

  if (window.__craftWindowControls)
    window.craft._applyWindowControls(window.__craftWindowControls)

  if (typeof document !== 'undefined' && document.addEventListener) {
    document.addEventListener('DOMContentLoaded', function () {
      if (window.craft.windowControls) paint(window.craft.windowControls)
    })
  }
})()
