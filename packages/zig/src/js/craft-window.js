// Craft Window Control JavaScript API
// Comprehensive window management for desktop applications

window.craft = window.craft || {};

// Event listeners storage
window.__craft_window_listeners = window.__craft_window_listeners || {};

window.craft.window = {
  // Internal helper for sending messages
  _send(action, data) {
    return new Promise((resolve, reject) => {
      try {
        window.webkit.messageHandlers.craft.postMessage({
          type: 'window',
          action,
          data
        });
        resolve();
      }
catch (error) {
        reject(new Error(`Window ${action} failed: ${error.message}`));
      }
    });
  },

  // ========== Visibility Controls ==========

  /** Show the window */
  async show() { return this._send('show'); },

  /** Hide the window */
  async hide() { return this._send('hide'); },

  /** Toggle window visibility */
  async toggle() { return this._send('toggle'); },

  /** Focus the window */
  async focus() { return this._send('focus'); },

  /** Blur the window */
  async blur() { return this._send('blur'); },

  // ========== Window State ==========

  /** Minimize the window */
  async minimize() { return this._send('minimize'); },

  /** Maximize the window */
  async maximize() { return this._send('maximize'); },

  /** Unmaximize the window */
  async unmaximize() { return this._send('unmaximize'); },

  /** Restore window from minimized/maximized */
  async restore() { return this._send('restore'); },

  /** Close the window */
  async close() { return this._send('close'); },

  /** Enter/exit fullscreen */
  async setFullscreen(fullscreen = true) { return this._send('setFullscreen', { fullscreen }); },

  /** Toggle fullscreen */
  async toggleFullscreen() { return this._send('toggleFullscreen'); },

  // ========== Window Properties ==========

  /** Set window title */
  async setTitle(title) { return this._send('setTitle', { title }); },

  /** Set window size */
  async setSize(width, height, animate) { return this._send('setSize', { width, height, animate }); },

  /** Set window position */
  async setPosition(x, y, animate) { return this._send('setPosition', { x, y, animate }); },

  /** Set window bounds */
  async setBounds(bounds, animate) { return this._send('setBounds', { ...bounds, animate }); },

  /** Center window on screen */
  async center() { return this._send('center'); },

  /** Set always on top */
  async setAlwaysOnTop(alwaysOnTop, level) { return this._send('setAlwaysOnTop', { alwaysOnTop, level }); },

  /** Set window resizable */
  async setResizable(resizable) { return this._send('setResizable', { resizable }); },

  /** Set window opacity */
  async setOpacity(opacity) { return this._send('setOpacity', { opacity: Math.max(0, Math.min(1, opacity)) }); },

  /** Set background color */
  async setBackgroundColor(color) { return this._send('setBackgroundColor', { color }); },

  /** Set minimum size */
  async setMinimumSize(width, height) { return this._send('setMinimumSize', { width, height }); },

  /** Set maximum size */
  async setMaximumSize(width, height) { return this._send('setMaximumSize', { width, height }); },

  // ========== macOS Specific ==========

  /** Set vibrancy effect (macOS) */
  async setVibrancy(vibrancy) { return this._send('setVibrancy', { vibrancy }); },

  /**
   * Pin the window to 'light' or 'dark', or hand it back to the OS with
   * 'system' (macOS).
   *
   * Anything native drawn behind or around the page — a material backdrop,
   * a vibrancy view, the window buttons — resolves against the window's
   * appearance, not the page's. An app with its own light/dark control has to
   * say which one it picked, or the two disagree.
   */
  async setAppearance(appearance) { return this._send('setAppearance', { appearance }); },

  /** Set traffic light position (macOS) */
  async setTrafficLightPosition(position) { return this._send('setTrafficLightPosition', position); },

  /** Set window shadow (macOS) */
  async setHasShadow(hasShadow) { return this._send('setHasShadow', { hasShadow }); },

  // ========== Windows Specific ==========

  /** Set background material (Windows 11) */
  async setBackgroundMaterial(material) { return this._send('setBackgroundMaterial', { material }); },

  /** Flash window in taskbar (Windows) */
  async flashFrame(flash) { return this._send('flashFrame', { flash }); },

  // ========== Content ==========

  /** Load HTML content */
  async loadHTML(html) { return this._send('loadHTML', { html }); },

  /** Load URL */
  async loadURL(url) { return this._send('loadURL', { url }); },

  /** Reload content */
  async reload() { return this._send('reload'); },

  // ========== Event Handling ==========

  /**
   * Register an event handler
   * @param {string} event - Event type (show, hide, focus, blur, resize, move, close, etc.)
   * @param {Function} handler - Event handler function
   * @returns {Function} Unsubscribe function
   */
  on(event, handler) {
    if (!window.__craft_window_listeners[event]) {
      window.__craft_window_listeners[event] = new Set();
    }
    window.__craft_window_listeners[event].add(handler);

    return () => {
      window.__craft_window_listeners[event]?.delete(handler);
    };
  },

  /**
   * Register a one-time event handler
   */
  once(event, handler) {
    const wrapper = (data) => {
      window.__craft_window_listeners[event]?.delete(wrapper);
      handler(data);
    };
    return this.on(event, wrapper);
  },

  /**
   * Remove an event handler
   */
  off(event, handler) {
    window.__craft_window_listeners[event]?.delete(handler);
  },

  /**
   * Internal: Emit event (called from native)
   */
  _emit(event, data) {
    const listeners = window.__craft_window_listeners[event];
    if (listeners) {
      listeners.forEach(fn => {
        try {
          fn(data);
        }
catch (e) {
          console.error('[Craft] Window event handler error:', e);
        }
      });
    }
  }
};

// Global function for native to call
window.__craftWindowEvent = function(event, data) {
  window.craft.window._emit(event, data);
  // Also dispatch as CustomEvent for TypeScript API
  window.dispatchEvent(new CustomEvent(`craft:window:${event}`, { detail: data }));
};

console.log('[Craft] Window control API loaded');
