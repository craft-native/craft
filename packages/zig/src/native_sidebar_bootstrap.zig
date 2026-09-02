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

/// How far the native material behind this page reaches.
///
/// `data-craft-native-sidebar` says only that *something* native is back
/// there. A stylesheet needs the shape as well: a `sidebar` window has an
/// opaque content pane to paint on and a `window` one does not, so a page that
/// guesses either paints over the material it asked for or leaves its content
/// column see-through. Written at document-start on every navigation, like the
/// marker above, so the first frame is already laid out correctly.
pub fn spanMarker(span: enum { sidebar, window }) []const u8 {
    return switch (span) {
        .sidebar => marker("sidebar"),
        .window => marker("window"),
    };
}

fn marker(comptime span: []const u8) []const u8 {
    return "document.documentElement.setAttribute('data-craft-web-material','" ++ span ++ "');";
}
