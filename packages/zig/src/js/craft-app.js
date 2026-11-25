// Craft App Control JavaScript API
// Application lifecycle, configuration, and system integration

window.craft = window.craft || {};

// Event listeners storage
window.__craft_app_listeners = window.__craft_app_listeners || {};
window.__craft_shortcuts = window.__craft_shortcuts || {};

window.craft.app = {
  // Internal helper for sending messages
  _send(action, data) {
    return new Promise((resolve, reject) => {
      try {
        window.webkit.messageHandlers.craft.postMessage({
          type: 'app',
          action,
          data
        });
        resolve();
      }
catch (error) {
        reject(new Error(`App ${action} failed: ${error.message}`));
      }
    });
  },

  // ========== App Lifecycle ==========

  /** Quit the application */
  async quit() { return this._send('quit'); },

  /** Exit with code */
  async exit(code = 0) { return this._send('exit', { code }); },

  /** Relaunch the application */
  async relaunch(options) { return this._send('relaunch', options); },

  /** Hide the application (macOS) */
  async hide() { return this._send('hide'); },

  /** Show the application (macOS) */
  async show() { return this._send('show'); },

  /** Focus the application */
  async focus() { return this._send('focus'); },

  // ========== Dock Icon (macOS) ==========

  /** Hide dock icon */
  async hideDockIcon() { return this._send('hideDockIcon'); },

  /** Show dock icon */
  async showDockIcon() { return this._send('showDockIcon'); },

  /** Set dock badge */
  async setBadge(badge) { return this._send('setBadge', { badge: badge?.toString() ?? '' }); },

  /** Bounce dock icon */
  async bounce(type = 'informational') { return this._send('bounce', { type }); },

  /** Set dock icon */
  async setDockIcon(icon) { return this._send('setDockIcon', { icon }); },

  // ========== App Information ==========

  /** Get application info */
  async getInfo() { return this._send('getInfo'); },

  /** Get app name */
  async getName() { return this._send('getName'); },

  /** Get app version */
  async getVersion() { return this._send('getVersion'); },

  /** Get path */
  async getPath(name) { return this._send('getPath', { name }); },

  // ========== System Preferences ==========

  /** Check if dark mode is enabled */
  isDarkMode() {
    if (window.matchMedia) {
      return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    return false;
  },

  /** Check if reduced motion is enabled */
  isReducedMotion() {
    if (window.matchMedia) {
      return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    }
    return false;
  },

  /** Get system locale */
  getLocale() {
    return navigator.language || 'en-US';
  },

  // ========== Notifications ==========

  /** Send a notification */
  async notify(options) {
    // Try native Notification API first
    if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
      new Notification(options.title, {
        body: options.body,
        icon: options.icon,
        silent: options.silent,
        tag: options.tag
      });
      return;
    }
    return this._send('notify', options);
  },

  /** Request notification permission */
  async requestNotificationPermission() {
    if (typeof Notification !== 'undefined') {
      return Notification.requestPermission();
    }
    return 'denied';
  },

  // ========== Global Shortcuts ==========

  /**
   * Register a global shortcut
   * @param {string} accelerator - Shortcut (e.g., 'Cmd+Shift+N')
   * @param {Function} handler - Callback function
   */
  async registerShortcut(accelerator, handler) {
    window.__craft_shortcuts[accelerator] = handler;
    return this._send('registerShortcut', { accelerator });
  },

  /** Unregister a global shortcut */
  async unregisterShortcut(accelerator) {
    delete window.__craft_shortcuts[accelerator];
    return this._send('unregisterShortcut', { accelerator });
  },

  /** Unregister all shortcuts */
  async unregisterAllShortcuts() {
    window.__craft_shortcuts = {};
    return this._send('unregisterAllShortcuts');
  },

  // ========== Appearance ==========

  /** Set app appearance */
  async setAppearance(appearance) { return this._send('setAppearance', { appearance }); },

  // ========== Power Management ==========

  /** Start power save blocker */
  async startPowerSaveBlocker(type) { return this._send('startPowerSaveBlocker', { type }); },

  /** Stop power save blocker */
  async stopPowerSaveBlocker(id) { return this._send('stopPowerSaveBlocker', { id }); },

  /** Get system idle time */
  async getIdleTime() { return this._send('getIdleTime'); },

  // ========== Login Items ==========

  /** Start at login, or stop (macOS 13+). Served by craft.autoLaunch (#588); only openAtLogin is supported. */
  async setLoginItemSettings(options) {
    if (options && (options.openAsHidden || options.path !== undefined || options.args !== undefined))
      throw new Error('setLoginItemSettings supports only openAtLogin: SMAppService registers this app as it is, with no hidden launch, path or arguments');
    const ok = await (options && options.openAtLogin ? window.craft.autoLaunch.enable() : window.craft.autoLaunch.disable());
    if (!ok) throw new Error('macOS did not ' + (options && options.openAtLogin ? 'register' : 'unregister') + ' the login item');
  },

  /** Whether the app starts at login. The other three fields are always false under SMAppService. */
  async getLoginItemSettings() {
    return { openAtLogin: await window.craft.autoLaunch.isEnabled(), openAsHidden: false, wasOpenedAtLogin: false, wasOpenedAsHidden: false };
  },

  // ========== Event Handling ==========

  /**
   * Register an event handler
   * @param {string} event - Event type
   * @param {Function} handler - Event handler
   * @returns {Function} Unsubscribe function
   */
  on(event, handler) {
    if (!window.__craft_app_listeners[event]) {
      window.__craft_app_listeners[event] = new Set();
    }
    window.__craft_app_listeners[event].add(handler);

    return () => {
      window.__craft_app_listeners[event]?.delete(handler);
    };
  },

  /** Register one-time event handler */
  once(event, handler) {
    const wrapper = (data) => {
      window.__craft_app_listeners[event]?.delete(wrapper);
      handler(data);
    };
    return this.on(event, wrapper);
  },

  /** Remove event handler */
  off(event, handler) {
    window.__craft_app_listeners[event]?.delete(handler);
  },

  /** Internal: Emit event */
  _emit(event, data) {
    const listeners = window.__craft_app_listeners[event];
    if (listeners) {
      listeners.forEach(fn => {
        try {
          fn(data);
        }
catch (e) {
          console.error('[Craft] App event handler error:', e);
        }
      });
    }
  }
};

// Theme change detection
if (typeof window !== 'undefined' && window.matchMedia) {
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
    window.craft.app._emit('theme-changed', { theme: e.matches ? 'dark' : 'light' });
    window.dispatchEvent(new CustomEvent('craft:app:theme-changed', {
      detail: { theme: e.matches ? 'dark' : 'light' }
    }));
  });
}

// Global function for native to call
window.__craftAppEvent = function(event, data) {
  window.craft.app._emit(event, data);
  window.dispatchEvent(new CustomEvent(`craft:app:${event}`, { detail: data }));
};

// Global function for shortcut events
window.__craftShortcut = function(accelerator) {
  const handler = window.__craft_shortcuts[accelerator];
  if (handler) {
    try {
      handler();
    }
catch (e) {
      console.error('[Craft] Shortcut handler error:', e);
    }
  }
  window.dispatchEvent(new CustomEvent('craft:shortcut', { detail: { accelerator } }));
};

console.log('[Craft] App control API loaded');
