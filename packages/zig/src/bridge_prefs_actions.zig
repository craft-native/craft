//! The `prefs` bridge's action names, alone.
//!
//! Split out of `bridge_prefs.zig` so the JS-contract test can reference the
//! same constants the bridge dispatches on without dragging in the CoreFoundation
//! backend — a rename on either side then fails the build rather than silently
//! producing a namespace that answers nothing.
//!
//! Namespace-qualified on purpose; see `bridge_prefs.zig` for why a bare `get`
//! would be drained by another bridge's pending replies.

pub const get = "prefs:get";
pub const set = "prefs:set";
pub const delete = "prefs:delete";
pub const clear = "prefs:clear";
pub const keys = "prefs:keys";
pub const info = "prefs:info";

/// What an unrecognised action is reported under. Never the bytes that arrived.
pub const unknown = "prefs:unknownAction";
