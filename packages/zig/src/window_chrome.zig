//! Where the platform put this window's close/minimise/zoom buttons, told to
//! the page.
//!
//! The buttons belong to the window server. On macOS every window Craft opens
//! that is not frameless gets real ones, and a page that draws its own puts six
//! circles in the corner — three live buttons and three that only look like
//! them: wrong shade, no hover glyphs, dead to the keyboard and to
//! accessibility. Yet web UIs drew them anyway, and the reason is that nothing
//! told them not to. A page cannot ask AppKit anything. A component that wants
//! to leave room has to hardcode a guess, and one that cannot tell a Craft
//! window from a browser tab draws replicas so the browser preview does not
//! look bare.
//!
//! So the host states it, at document-start and again whenever it changes:
//!
//!   window.craft.windowControls
//!   <html data-craft-window-controls="titlebar|overlay|custom|none">
//!   --craft-window-controls-width / -height / -inset-x / -inset-y
//!   --craft-window-controls-replicas
//!
//! ## Measured, not assumed
//!
//! Every number comes from `standardWindowButton:` on the live window,
//! converted into the web viewport's own coordinates. Nothing is a constant,
//! because none of it is constant: the buttons move between window styles, they
//! sit over a native sidebar rather than over the web content in a sidebar
//! window, they slide away in fullscreen, and Apple has changed their size and
//! spacing across releases. A measurement taken once and pasted into a source
//! file is wrong the first time any of that happens, and wrong silently.
//!
//! This module is the part with no Objective-C in it: given the block and the
//! viewport, it decides what the page is told. `macos.zig` does the measuring
//! and the publishing, which is where AppKit lives.
//!
//! ## The four answers
//!
//!   titlebar  Real buttons, in a titlebar of their own above the page.
//!             Nothing to draw, nothing to reserve.
//!   overlay   Real buttons, over the page's own top-left corner — a
//!             titlebar-hidden window, or one whose web content runs the full
//!             height. Nothing to draw; room to leave.
//!   custom    A frameless window. There are no buttons, and the page is the
//!             only thing that can offer any, so its own stand.
//!   none      No window chrome in this environment at all — iOS, Android.
//!             Nothing to draw and nothing to reserve; replicas there would be
//!             three fake macOS discs on a phone.
//!
//! `custom` is the single case where a page should draw its own, which is why
//! it is the single case that leaves `--craft-window-controls-replicas` unset.
//!
//! ## Other platforms
//!
//! macOS and iOS publish this. Windows, Linux and Android do not, and cannot
//! yet: none of them injects any Craft JavaScript at all — `windows.zig` and
//! `linux.zig` have an `injectScript` nobody calls, and `android.zig`'s
//! `evaluateJavaScript` is still a stub. There is nothing for this to attach
//! to, and publishing half a `window.craft` on those hosts would be worse than
//! silence: a page that tests for it would find a bridge that cannot send.
//!
//! When those hosts do get a JS pipeline, they want this same contract, and
//! nothing here is macOS-specific. Windows and Linux draw real window buttons,
//! so they measure their frames and call `classify` with `.platform`; Android
//! has no window chrome at all, so it seeds `.absent`, as iOS does.

const std = @import("std");

/// A rectangle in CSS pixels, y down, relative to the top-left of the web
/// viewport. A block above the viewport — a plain titlebar window — has a
/// negative `y`; one to the left of it — a window whose web content starts
/// after a native sidebar — has a negative `x`. Both are real answers, and both
/// mean "not over the page".
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    fn right(self: Rect) f64 {
        return self.x + self.width;
    }

    fn bottom(self: Rect) f64 {
        return self.y + self.height;
    }
};

/// The web viewport's size in CSS pixels.
pub const Size = struct {
    width: f64 = 0,
    height: f64 = 0,
};

/// Who, if anyone, drew window buttons for this window.
pub const Chrome = enum {
    /// A normal desktop window: the platform drew them.
    platform,
    /// A frameless window: nobody did, and the page may.
    page,
    /// A phone, a tablet — there is no window to control.
    absent,
};

pub const Style = enum {
    titlebar,
    overlay,
    custom,
    none,

    pub fn text(self: Style) []const u8 {
        return @tagName(self);
    }
};

/// What the page is told. Everything is in CSS pixels.
pub const State = struct {
    style: Style,
    /// The platform drew real buttons for this window.
    native: bool,
    /// ...and they are on screen right now. False in fullscreen, where macOS
    /// takes them into the auto-hiding titlebar.
    visible: bool,
    /// The block's true position relative to the viewport's top-left. Zeroed
    /// when there is nothing to place. This is the buttons and nothing else,
    /// so a page positioning against the real lights keeps a true number.
    buttons: Rect,
    /// The room to leave inside the page: the far edge of everything the host
    /// draws over it, or zero when none of it reaches into the page.
    ///
    /// Wider than `buttons` whenever the host draws chrome of its own beside
    /// them. On a web-sidebar window that is a row of three — the sidebar
    /// toggle and the two history arrows — reaching about 180pt past the close
    /// button, and a page that reserved only the buttons put its own content
    /// underneath them. They are real NSButtons on the theme frame, so
    /// whatever lands there is not merely overlapped but unreachable.
    reserve: Size,
    /// Where the block starts inside the page. Zero unless it overlaps.
    inset: Size,
    /// The page must not draw replicas — true wherever real buttons exist, and
    /// wherever there is no window to control.
    hide_replicas: bool,

    /// Whether two states say the same thing, so an update that changes nothing
    /// can be skipped instead of evaluated in the webview.
    pub fn eql(self: State, other: State) bool {
        return std.meta.eql(self, other);
    }
};

fn overlaps(block: Rect, viewport: Size) bool {
    return block.right() > 0 and block.bottom() > 0 and
        block.x < viewport.width and block.y < viewport.height;
}

/// The smallest rect covering both, or whichever one exists.
fn unite(a: Rect, b: ?Rect) Rect {
    const other = b orelse return a;
    const x = @min(a.x, other.x);
    const y = @min(a.y, other.y);
    return .{
        .x = x,
        .y = y,
        .width = @max(a.right(), other.right()) - x,
        .height = @max(a.bottom(), other.bottom()) - y,
    };
}

fn clamp(value: f64, limit: f64) f64 {
    if (value < 0) return 0;
    if (value > limit) return limit;
    return value;
}

/// Decide what to publish.
///
/// `block` is the union of the window buttons in viewport coordinates, or null
/// when there are none on screen. `host_chrome` is anything else the host draws
/// over the page in the same band — null when it draws nothing. `viewport` is
/// the web content's size.
///
/// The two are kept apart on purpose. `buttons` reports the first alone,
/// because a page aligning to the real lights needs their true position;
/// `reserve` spans both, because a page leaving room has to clear everything
/// that is actually there.
pub fn classify(chrome: Chrome, block: ?Rect, host_chrome: ?Rect, viewport: Size) State {
    switch (chrome) {
        .absent => return .{
            .style = .none,
            .native = false,
            .visible = false,
            .buttons = .{},
            .reserve = .{},
            .inset = .{},
            // Nothing to replicate: a phone has no window buttons for a replica
            // to stand in for, so three fake discs would be decoration
            // pretending to be controls.
            .hide_replicas = true,
        },
        .page => return .{
            .style = .custom,
            .native = false,
            .visible = false,
            .buttons = .{},
            .reserve = .{},
            .inset = .{},
            // The one case where the page's own controls are the real ones.
            .hide_replicas = false,
        },
        .platform => {},
    }

    const rect = block orelse return .{
        // Real buttons exist but are not on screen — fullscreen, most often.
        // Still `titlebar` rather than `custom`: this window has chrome, the
        // page must not grow its own, and there is nothing to leave room for
        // until the buttons come back.
        .style = .titlebar,
        .native = true,
        .visible = false,
        .buttons = .{},
        .reserve = .{},
        .inset = .{},
        .hide_replicas = true,
    };

    // Reserve spans the host's own chrome too; `buttons` deliberately does not.
    const covered = unite(rect, host_chrome);

    if (!overlaps(rect, viewport)) {
        // The buttons sit outside the page. The host may still draw beside them
        // into it, and that room is just as unusable, so it is still reserved —
        // but the style stays `titlebar`, because the *buttons* are not over the
        // page and `inset` describes where they start.
        const host_reaches = if (host_chrome) |host| overlaps(host, viewport) else false;
        return .{
            .style = .titlebar,
            .native = true,
            .visible = true,
            .buttons = rect,
            .reserve = if (host_reaches) .{
                .width = clamp(covered.right(), viewport.width),
                .height = clamp(covered.bottom(), viewport.height),
            } else .{},
            .inset = .{},
            .hide_replicas = true,
        };
    }

    return .{
        .style = .overlay,
        .native = true,
        .visible = true,
        .buttons = rect,
        .reserve = .{
            .width = clamp(covered.right(), viewport.width),
            .height = clamp(covered.bottom(), viewport.height),
        },
        .inset = .{
            .width = clamp(rect.x, viewport.width),
            .height = clamp(rect.y, viewport.height),
        },
        .hide_replicas = true,
    };
}

/// The state as the object literal `craft-window-chrome.js` consumes.
///
/// `replicas` is the `display` a replica should take, and it is `null` — not
/// `'flex'`, not omitted — in the one case where the page draws its own. The
/// client turns null into "remove the variable", so the page's own fallback
/// applies and Craft never dictates a layout it knows nothing about.
pub fn literal(state: State, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{{style:'{s}',native:{},visible:{}," ++
            "x:{d},y:{d},width:{d},height:{d}," ++
            "reserveWidth:{d},reserveHeight:{d},insetX:{d},insetY:{d}," ++
            "replicas:{s}}}",
        .{
            state.style.text(),
            state.native,
            state.visible,
            state.buttons.x,
            state.buttons.y,
            state.buttons.width,
            state.buttons.height,
            state.reserve.width,
            state.reserve.height,
            state.inset.width,
            state.inset.height,
            if (state.hide_replicas) "'none'" else "null",
        },
    );
}

const client = @embedFile("js/craft-window-chrome.js");

/// Room for the longest literal `literal` can print. Every field is a short
/// name and a number; f64 at its widest prints under 30 characters.
const literal_size = 512;

/// The document-start script: the client half, seeded with what the window
/// looks like right now.
///
/// Seeded rather than left to a later update, because the alternative flashes.
/// A script that arrives after first paint has already let a header lay itself
/// out for the wrong corner, and a replica has already been drawn on top of a
/// real button.
pub fn seedScript(state: State, buffer: []u8) ![]const u8 {
    var literal_buffer: [literal_size]u8 = undefined;
    const seed = try literal(state, &literal_buffer);

    return std.fmt.bufPrint(
        buffer,
        "window.__craftWindowControls = {s};\n{s}",
        .{ seed, client },
    );
}

/// The smallest buffer `seedScript` will always fit in.
pub const seed_script_size = client.len + literal_size + 64;

/// A later change — a resize, a fullscreen transition, a sidebar appearing —
/// handed to the already-installed client.
pub fn updateScript(state: State, buffer: []u8) ![]const u8 {
    var literal_buffer: [literal_size]u8 = undefined;
    const next = try literal(state, &literal_buffer);

    // Guarded because an update can reach a page that navigated a moment ago
    // and has not run its document-start script yet.
    return std.fmt.bufPrint(
        buffer,
        "window.craft&&window.craft._applyWindowControls&&window.craft._applyWindowControls({s})",
        .{next},
    );
}

/// The smallest buffer `updateScript` will always fit in.
pub const update_script_size = literal_size + 128;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// A comfortable window, so a test's numbers are about the buttons.
const window = Size{ .width = 1200, .height = 800 };

test "a plain titlebar window keeps its buttons above the page" {
    // Measured on a real window: the block sits above the web viewport,
    // because the titlebar is not part of it.
    const state = classify(.platform, .{ .x = 10, .y = -20, .width = 52, .height = 12 }, null, window);

    try testing.expectEqual(Style.titlebar, state.style);
    try testing.expect(state.native and state.visible);
    try testing.expectEqual(@as(f64, 0), state.reserve.width);
    try testing.expectEqual(@as(f64, 0), state.reserve.height);
    try testing.expect(state.hide_replicas);
}

test "a titlebar-hidden window asks the page for the corner" {
    const state = classify(.platform, .{ .x = 10, .y = 8, .width = 52, .height = 12 }, null, window);

    try testing.expectEqual(Style.overlay, state.style);
    try testing.expectEqual(@as(f64, 62), state.reserve.width);
    try testing.expectEqual(@as(f64, 20), state.reserve.height);
    try testing.expectEqual(@as(f64, 10), state.inset.width);
    try testing.expectEqual(@as(f64, 8), state.inset.height);
}

test "buttons over a native sidebar are not over the page" {
    // The web content starts after a native sidebar, so the block — measured
    // against the webview — is off its left edge entirely. Reserving room here
    // would indent the page away from buttons it never touches.
    const state = classify(.platform, .{ .x = -240, .y = 8, .width = 52, .height = 12 }, null, window);

    try testing.expectEqual(Style.titlebar, state.style);
    try testing.expectEqual(@as(f64, 0), state.reserve.width);
}

test "fullscreen takes the buttons away without handing the page their job" {
    const state = classify(.platform, null, null, window);

    try testing.expectEqual(Style.titlebar, state.style);
    try testing.expect(state.native);
    try testing.expect(!state.visible);
    try testing.expectEqual(@as(f64, 0), state.reserve.width);
    // The window still has chrome; the page must not grow a second set.
    try testing.expect(state.hide_replicas);
}

test "a frameless window is the one place a page draws its own" {
    const state = classify(.page, null, null, window);

    try testing.expectEqual(Style.custom, state.style);
    try testing.expect(!state.native);
    try testing.expect(!state.hide_replicas);
}

test "a phone has no window to control" {
    const state = classify(.absent, null, null, window);

    try testing.expectEqual(Style.none, state.style);
    try testing.expect(!state.native);
    // Not `custom`: there is no window chrome to stand in for.
    try testing.expect(state.hide_replicas);
}

test "the host's own chrome is reserved, and does not move the buttons" {
    // A web-sidebar window: the buttons, then Craft's row of three beside them
    // — sidebar toggle and two history arrows — reaching to 200.
    const state = classify(
        .platform,
        .{ .x = 20, .y = 9, .width = 54, .height = 15 },
        .{ .x = 88, .y = 8, .width = 112, .height = 28 },
        window,
    );

    try testing.expectEqual(Style.overlay, state.style);
    // Reserve clears everything drawn over the page, not just the lights.
    try testing.expectEqual(@as(f64, 200), state.reserve.width);
    try testing.expectEqual(@as(f64, 36), state.reserve.height);
    // The buttons still report where the buttons are: a page aligning to the
    // real lights would be thrown off by a widened block, which is why the two
    // are separate numbers.
    try testing.expectEqual(@as(f64, 20), state.buttons.x);
    try testing.expectEqual(@as(f64, 54), state.buttons.width);
    // Inset is about the buttons too.
    try testing.expectEqual(@as(f64, 20), state.inset.width);
}

test "no host chrome leaves the reserve exactly as it was" {
    const bare = classify(.platform, .{ .x = 20, .y = 9, .width = 54, .height = 15 }, null, window);

    try testing.expectEqual(@as(f64, 74), bare.reserve.width);
    try testing.expectEqual(@as(f64, 24), bare.reserve.height);
}

test "host chrome starting left of the buttons still reserves to its far edge" {
    // The union is taken on both edges, so a row that began before the buttons
    // would not shrink what is reserved past them.
    const state = classify(
        .platform,
        .{ .x = 20, .y = 9, .width = 54, .height = 15 },
        .{ .x = 4, .y = 8, .width = 30, .height = 28 },
        window,
    );

    try testing.expectEqual(@as(f64, 74), state.reserve.width);
    try testing.expectEqual(@as(f64, 36), state.reserve.height);
}

test "host chrome is bounded by the viewport like everything else" {
    const state = classify(
        .platform,
        .{ .x = 10, .y = 8, .width = 52, .height = 12 },
        .{ .x = 70, .y = 8, .width = 400, .height = 28 },
        .{ .width = 120, .height = 30 },
    );

    try testing.expectEqual(@as(f64, 120), state.reserve.width);
    try testing.expectEqual(@as(f64, 30), state.reserve.height);
}

test "buttons in a titlebar still reserve for host chrome that reaches the page" {
    // Not a shape macOS produces today — the row only exists on a
    // titlebar-hidden window — but the reserve is about what covers the page,
    // and answering zero here would be a hole waiting for the first host that
    // draws one.
    const state = classify(
        .platform,
        .{ .x = 10, .y = -20, .width = 52, .height = 12 },
        .{ .x = 80, .y = 4, .width = 100, .height = 24 },
        window,
    );

    // The buttons are still above the page, so the style does not change.
    try testing.expectEqual(Style.titlebar, state.style);
    try testing.expectEqual(@as(f64, 180), state.reserve.width);
    try testing.expectEqual(@as(f64, 28), state.reserve.height);
    // Inset describes where the buttons start, and they do not overlap.
    try testing.expectEqual(@as(f64, 0), state.inset.width);
}

test "the reserve never exceeds the viewport" {
    // A window narrower than the button block is absurd, and AppKit will not
    // produce one — but the reserve is a CSS length the page subtracts from its
    // own width, so it is bounded rather than trusted.
    const state = classify(
        .platform,
        .{ .x = 10, .y = 8, .width = 52, .height = 12 },
        null,
        .{ .width = 40, .height = 10 },
    );

    try testing.expectEqual(@as(f64, 40), state.reserve.width);
    try testing.expectEqual(@as(f64, 10), state.reserve.height);
}

test "the literal says none only where replicas are unwanted" {
    var buffer: [literal_size]u8 = undefined;

    const overlay = try literal(
        classify(.platform, .{ .x = 10, .y = 8, .width = 52, .height = 12 }, null, window),
        &buffer,
    );
    try testing.expect(std.mem.indexOf(u8, overlay, "replicas:'none'") != null);
    try testing.expect(std.mem.indexOf(u8, overlay, "style:'overlay'") != null);
    try testing.expect(std.mem.indexOf(u8, overlay, "reserveWidth:62") != null);

    var second: [literal_size]u8 = undefined;
    const custom = try literal(classify(.page, null, null, window), &second);
    try testing.expect(std.mem.indexOf(u8, custom, "replicas:null") != null);
}

test "the seed carries the client and its starting values" {
    var buffer: [seed_script_size]u8 = undefined;
    const script = try seedScript(
        classify(.platform, .{ .x = 10, .y = 8, .width = 52, .height = 12 }, null, window),
        &buffer,
    );

    try testing.expect(std.mem.startsWith(u8, script, "window.__craftWindowControls = {"));
    try testing.expect(std.mem.indexOf(u8, script, "_applyWindowControls") != null);
    try testing.expect(std.mem.indexOf(u8, script, "--craft-window-controls-replicas") != null);
}

test "an update is a call, not a redefinition" {
    var buffer: [update_script_size]u8 = undefined;
    const script = try updateScript(classify(.platform, null, null, window), &buffer);

    try testing.expect(std.mem.indexOf(u8, script, "_applyWindowControls({") != null);
    // The client is installed once, by the seed. Sending it again on every
    // resize would re-run its listeners and re-freeze its state object.
    try testing.expect(std.mem.indexOf(u8, script, "addEventListener") == null);
}

test "equal states are recognised so an update can be skipped" {
    const block = Rect{ .x = 10, .y = 8, .width = 52, .height = 12 };
    try testing.expect(classify(.platform, block, null, window).eql(classify(.platform, block, null, window)));
    try testing.expect(!classify(.platform, block, null, window).eql(classify(.platform, null, null, window)));
}
