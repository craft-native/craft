const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");

const objc = macos.objc;

var installed: bool = false;

/// install() is currently a placeholder hook so the symbol exists for
/// `setupBridgeHandlers` to call. The actual drag session is initiated
/// from `handleMessage` in response to `dragOut/start` messages.
pub fn install() void {
    if (installed) return;
    if (builtin.target.os.tag != .macos) return;
    installed = true;
}

/// Dispatch handler for the `dragOut` bridge type.
///
/// JSON: `{"paths":["/abs/path1","/abs/path2"], "x": 100, "y": 50}`
///
/// We start a drag session on the WKWebView with NSURL-typed pasteboard
/// items so the OS treats it like a real Finder drag — the user can drop
/// onto Finder, Slack, mail composers, anywhere a file is accepted.
///
/// Limitation: WKWebView eats most mouse events, so we can't get a real
/// `NSEvent` to anchor the drag at the JS-supplied coordinates. We use
/// the current event from `[NSApp currentEvent]` which is "good enough"
/// for click+drag flows — the OS picks up the drag as soon as the cursor
/// moves a few pixels, which is the standard delay.
pub fn handleMessage(action: []const u8, data: []const u8) !void {
    if (builtin.target.os.tag != .macos) return;
    if (!std.mem.eql(u8, action, "start")) return;

    const paths = parsePaths(data) catch return;
    defer std.heap.c_allocator.free(paths);
    if (paths.len == 0) return;

    const webview = macos.getGlobalWebView() orelse return;

    // Build NSArray<NSDraggingItem*> — one per path, each backed by an
    // NSURL pasteboard writer. NSURL is the standard "promise this is a
    // file" type; receivers like Finder and Mail handle it natively.
    const NSDraggingItem = macos.getClass("NSDraggingItem");
    const NSURL = macos.getClass("NSURL");
    const NSMutableArray = macos.getClass("NSMutableArray");

    const items_arr = macos.msgSend0(NSMutableArray, "array");

    var i: usize = 0;
    while (i < paths.len) : (i += 1) {
        const path = paths[i];
        defer std.heap.c_allocator.free(path);

        const path_ns = macos.createNSString(path);
        const url = macos.msgSend1(NSURL, "fileURLWithPath:", path_ns);
        if (@intFromPtr(url) == 0) continue;

        const item = macos.msgSend1(macos.msgSend0(NSDraggingItem, "alloc"), "initWithPasteboardWriter:", url);
        if (@intFromPtr(item) == 0) continue;

        // Pull the file's actual icon via [NSWorkspace iconForFile:].
        // Earlier we passed nil here, which left an empty rectangle
        // floating with the cursor — terrible UX. Now the icon shown
        // in Finder follows the cursor during the drag.
        const NSWorkspace = macos.getClass("NSWorkspace");
        const ws = macos.msgSend0(NSWorkspace, "sharedWorkspace");
        const path_ns2 = macos.createNSString(path);
        const icon = macos.msgSend1(ws, "iconForFile:", path_ns2);

        const frame = macos.NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 64, .height = 64 },
        };
        const Fn = *const fn (objc.id, objc.SEL, macos.NSRect, objc.id) callconv(.c) void;
        const f: Fn = @ptrCast(&objc.objc_msgSend);
        f(item, macos.sel("setDraggingFrame:contents:"), frame, icon);

        _ = macos.msgSend1(items_arr, "addObject:", item);
    }

    // Need an event to anchor the drag. `[NSApp currentEvent]` is set by
    // AppKit during event dispatch and is the right thing for "drag from
    // wherever the user clicked." Outside an event loop, this returns nil
    // and the drag simply doesn't start.
    const NSApp = macos.getClass("NSApplication");
    const app = macos.msgSend0(NSApp, "sharedApplication");
    const event = macos.msgSend0(app, "currentEvent");
    if (@intFromPtr(event) == 0) {
        if (comptime builtin.mode == .Debug) {
            std.debug.print("[DragOut] No current event — drag not started\n", .{});
        }
        return;
    }

    // beginDraggingSessionWithItems:event:source: — webview acts as its
    // own NSDraggingSource. WKWebView provides a default source impl that
    // accepts most operations.
    _ = macos.msgSend3(webview, "beginDraggingSessionWithItems:event:source:", items_arr, event, webview);

    if (comptime builtin.mode == .Debug) {
        std.debug.print("[DragOut] Started session with {d} item(s)\n", .{paths.len});
    }
}

/// Pull `paths` array out of the JSON payload. Returns owned slice of
/// owned strings — caller frees the outer slice; this fn frees individual
/// strings as they're consumed in handleMessage above.
///
/// The early-return paths previously did `return &.{}` which the compiler
/// accepted but produced a slice of an empty *anyopaque-shaped* literal,
/// not a `[][]u8`. Use a proper typed empty slice instead.
fn parsePaths(data: []const u8) ![][]u8 {
    const allocator = std.heap.c_allocator;
    const empty: [][]u8 = &[_][]u8{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return empty;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return empty,
    };

    const paths_val = root.get("paths") orelse return empty;
    const arr = switch (paths_val) {
        .array => |a| a,
        else => return empty,
    };

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        // Free anything we already duped before the error — without
        // this, partial successes leak across errors deep in `try
        // append` (rare but real on OOM).
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    for (arr.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        const owned = try allocator.dupe(u8, s);
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}
