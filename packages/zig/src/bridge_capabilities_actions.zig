//! The `capabilities` bridge's action names, alone.
//!
//! Split out of `bridge_capabilities.zig` so the JS-contract test can reference
//! the same constants the bridge dispatches on without importing the registry —
//! which reaches every declared bridge and, through them, the whole native
//! graph. A test about the shape of a JSON message should not need to compile
//! the tray.

/// Namespace-qualified, like the prefs bridge and for the same reason: the
/// pending-reply queue is keyed by action name alone.
pub const get = "capabilities:get";

/// What an unrecognised action is reported under. Never the bytes that arrived:
/// the action is interpolated into a JS literal unescaped, and `craft.invoke`
/// lets a page choose it.
pub const unknown = "capabilities:unknownAction";
