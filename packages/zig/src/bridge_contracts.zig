//! The native halves of the JS bridge contracts, in one place.
//!
//! `test/injected_js_test.zig` drives the real injected JavaScript and then
//! decodes what it posted with the very code the bridge dispatches to — which
//! is the only kind of test that can catch a JS side and a native side that
//! are each individually correct and disagree with each other. Both #27 (menu
//! action names) and #47 (shortcut payload shape) were exactly that.
//!
//! They arrive through one aggregate rather than as two named modules because
//! both reach `bridge_error.zig`, and a file may belong to only one module per
//! compilation. A test module also cannot `@import` outside its own directory,
//! so this has to live here beside the code it re-exports rather than in
//! `test/`.

pub const menu = @import("bridge_menu.zig");
pub const shortcuts = @import("shortcut_registry.zig");
