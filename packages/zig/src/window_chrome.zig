//! What the platform draws in the window's top-left corner, told to the page.
//!
//! macOS draws the close/minimise/zoom buttons itself, for every window style
//! Craft creates — a plain titlebar window, a titlebar-hidden one, a native
//! sidebar window. The web layer never has to draw them, and must not: replicas
//! next to the real ones put six circles in the corner, three of which only
//! look like buttons.
//!
//! The reason web UIs kept drawing their own anyway is that nothing told them
//! otherwise. A page has no way to ask AppKit where the buttons are, so a
//! component that wants to leave room for them has to hardcode a guess, and a
//! component that cannot tell a Craft window from a browser tab draws replicas
//! so the browser preview does not look bare.
//!
//! So the host states it, at document-start, on every window:
//!
//!   window.craft.windowControls   { style, native, x, y, width, height }
//!   <html data-craft-window-controls="titlebar|overlay|none">
//!   --craft-window-controls-width / -height / -inset-x / -inset-y
//!   --craft-window-controls-replicas
//!
//! The first group is the room to leave inside the page, which is why it is
//! zero for a `titlebar` window: there the buttons sit in the titlebar, above
//! the web content, and nothing in the page overlaps them.
//!
//! `--craft-window-controls-replicas` is for the other half of the problem — a
//! UI shared between a Craft window and a browser, which wants its mock lights
//! in the browser and must not draw them here. It is the `display` value a
//! replica should take, set to `none` wherever the platform drew real buttons
//! and left unset in a frameless window, where the page really does own its
//! chrome. A page writes it as a fallback and needs no JavaScript to adapt:
//!
//!     .traffic-lights { display: var(--craft-window-controls-replicas, flex); }
//!
//! Geometry is AppKit's own placement, measured on a titlebar-hidden Craft
//! window at 2x: 12pt discs, 20pt apart, the leftmost 10pt from the window's
//! left edge and 8pt below its top — so the block spans x 10..62, y 8..20.

const std = @import("std");

/// Where the platform's window buttons sit relative to the web content.
pub const WindowControls = enum {
    /// A standard titlebar owns them; the page starts below it.
    titlebar,
    /// The content view runs full-height, so they float over the page and the
    /// page has to keep its top-left corner clear.
    overlay,
    /// Frameless: no buttons at all.
    none,
};

/// Left edge of the button block, in CSS px from the window's left edge.
const inset_x = "10";
/// Top edge of the button block, in CSS px from the window's top edge.
const inset_y = "8";
/// Window's left edge to the right edge of the block.
const block_width = "62";
/// A comfortable strip height around the 12pt discs — the drag region a page
/// should keep clear, not the discs themselves.
const block_height = "28";

fn make(
    comptime style: []const u8,
    comptime native: []const u8,
    comptime reserve_w: []const u8,
    comptime reserve_h: []const u8,
    comptime hide_replicas: bool,
) []const u8 {
    const replicas = if (hide_replicas)
        "    el.style.setProperty('--craft-window-controls-replicas', 'none');\n"
    else
        "";
    return "window.craft = window.craft || {};\n" ++
        "window.craft.windowControls = Object.freeze({\n" ++
        "  style: '" ++ style ++ "',\n" ++
        "  native: " ++ native ++ ",\n" ++
        "  x: " ++ inset_x ++ ", y: " ++ inset_y ++ ",\n" ++
        "  width: " ++ block_width ++ ", height: " ++ block_height ++ "\n" ++
        "});\n" ++
        "(function() {\n" ++
        "  function apply() {\n" ++
        "    var el = document.documentElement;\n" ++
        "    if (!el) return;\n" ++
        "    el.setAttribute('data-craft-window-controls', '" ++ style ++ "');\n" ++
        "    el.style.setProperty('--craft-window-controls-width', '" ++ reserve_w ++ "px');\n" ++
        "    el.style.setProperty('--craft-window-controls-height', '" ++ reserve_h ++ "px');\n" ++
        "    el.style.setProperty('--craft-window-controls-inset-x', '" ++ inset_x ++ "px');\n" ++
        "    el.style.setProperty('--craft-window-controls-inset-y', '" ++ inset_y ++ "px');\n" ++
        replicas ++
        "  }\n" ++
        "  apply();\n" ++
        "  document.addEventListener('DOMContentLoaded', apply);\n" ++
        "})();\n";
}

/// The document-start script for a window with these controls.
pub fn scriptFor(controls: WindowControls) []const u8 {
    return switch (controls) {
        .titlebar => comptime make("titlebar", "true", "0", "0", true),
        .overlay => comptime make("overlay", "true", block_width, block_height, true),
        // A frameless window has no buttons to be replicas *of*, so the page
        // keeps whatever chrome it draws.
        .none => comptime make("none", "false", "0", "0", false),
    };
}

test "every window style announces itself" {
    const testing = std.testing;
    for ([_]WindowControls{ .titlebar, .overlay, .none }) |controls| {
        const script = scriptFor(controls);
        try testing.expect(std.mem.indexOf(u8, script, "window.craft.windowControls") != null);
        try testing.expect(std.mem.indexOf(u8, script, "--craft-window-controls-width") != null);
    }
}

test "only an overlay window asks the page to leave room" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, scriptFor(.overlay), "'62px'") != null);
    try testing.expect(std.mem.indexOf(u8, scriptFor(.titlebar), "'62px'") == null);
    try testing.expect(std.mem.indexOf(u8, scriptFor(.none), "'62px'") == null);
}

test "replicas are suppressed wherever the platform drew real buttons" {
    const testing = std.testing;
    const marker = "'--craft-window-controls-replicas', 'none'";
    try testing.expect(std.mem.indexOf(u8, scriptFor(.titlebar), marker) != null);
    try testing.expect(std.mem.indexOf(u8, scriptFor(.overlay), marker) != null);
    // Frameless: nothing to duplicate, so a page's own chrome stands.
    try testing.expect(std.mem.indexOf(u8, scriptFor(.none), marker) == null);
}

test "a frameless window says the platform draws nothing" {
    const testing = std.testing;
    try testing.expect(std.mem.indexOf(u8, scriptFor(.none), "native: false") != null);
    try testing.expect(std.mem.indexOf(u8, scriptFor(.titlebar), "native: true") != null);
    try testing.expect(std.mem.indexOf(u8, scriptFor(.overlay), "native: true") != null);
}
