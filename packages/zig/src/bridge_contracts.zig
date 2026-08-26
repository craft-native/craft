//! The native halves of the JS bridge contracts, in one place.
//!
//! `test/injected_js_test.zig` drives the real injected JavaScript and then
//! decodes what it posted with the very code the bridge dispatches to — which
//! is the only kind of test that can catch a JS side and a native side that
//! are each individually correct and disagree with each other. #27 (menu action
//! names), #47 (shortcut payload shape), #51 (preference value tags) and #49
//! (a capability manifest that describes nothing) were all exactly that.
//!
//! They arrive through one aggregate rather than as separate named modules
//! because several of them reach `bridge_error.zig`, and a file may belong to
//! only one module per compilation. A test module also cannot `@import` outside
//! its own directory, so this has to live here beside the code it re-exports
//! rather than in `test/`.

/// The reply formatter. `test/injected_js_test.zig` answers the page with the
/// very string `sendResultToJS` evaluates, rather than a hand-written copy of
/// it that cannot notice when the two drift apart.
pub const errors = @import("bridge_error.zig");
pub const menu = @import("bridge_menu.zig");
pub const shortcuts = @import("shortcut_registry.zig");
pub const prefs = @import("prefs.zig");
pub const prefs_actions = @import("bridge_prefs_actions.zig");
/// Pure: the manifest types and renderer, with no bridge behind them.
pub const capabilities = @import("capabilities.zig");
/// Pure: just the action-name constants the capabilities bridge dispatches on.
///
/// Deliberately not the registry. The registry reaches every declared bridge
/// and through them the whole native graph, and a test about the shape of a
/// JSON message has no business compiling the tray — on Linux it does not even
/// compile, because of stale-API code in branches macOS never analyses.
/// `test/capabilities_test.zig` is where the real registry is checked against
/// the real dispatch chain.
pub const capabilities_actions = @import("bridge_capabilities_actions.zig");
