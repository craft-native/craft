//! The native sidebar's document marker.
//!
//! This used to also set `__craftCustomWindowControls` and
//! `__craftWebChromeControls`, and add a `has-custom-window-controls` class.
//! Nothing ever read them, and what they claimed was false: AppKit draws this
//! window's close/minimise/zoom buttons like any other, so a page acting on
//! "custom window controls" would draw a second, dead set beside the real one.
//! `window_chrome.zig` states the truth instead, on every window.

pub const script =
    \\window.__craftNativeSidebar = true;
    \\window.__craftSidebarWidth = window.__craftSidebarWidth || 286;
    \\window.craft = window.craft || {};
    \\window.craft._sidebarSelectHandler = window.craft._sidebarSelectHandler || function(event) {
    \\  console.log('[Craft] Sidebar navigation:', event);
    \\};
    \\(function() {
    \\  function markNativeSidebar() {
    \\    document.documentElement.classList.add('has-native-sidebar');
    \\    document.documentElement.setAttribute('data-craft-native-sidebar', 'true');
    \\    document.documentElement.style.background = 'transparent';
    \\    if (document.body) {
    \\      document.body.dataset.nativeSidebar = 'true';
    \\    }
    \\  }
    \\  markNativeSidebar();
    \\  document.addEventListener('DOMContentLoaded', markNativeSidebar);
    \\  window.dispatchEvent(new Event('craft:ready'));
    \\})();
;
