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

pub const menu = @import("bridge_menu.zig");
pub const shortcuts = @import("shortcut_registry.zig");
pub const prefs = @import("prefs.zig");
pub const prefs_actions = @import("bridge_prefs_actions.zig");
pub const capabilities = @import("bridge_capabilities.zig");
pub const registry = @import("capability_registry.zig");
