const std = @import("std");
const builtin = @import("builtin");
const macos = @import("macos.zig");
const capabilities = @import("capabilities.zig");

const objc = macos.objc;

// Stash of the original WKWebView -performDragOperation: implementation.
// Set on first install(); read by the hook so we can call through.
var original_perform_drag_imp: objc.IMP = null;
var swizzled: bool = false;

const PerformDragFn = *const fn (objc.id, objc.SEL, objc.id) callconv(.c) c_char;

/// Install our `performDragOperation:` hook on WKWebView.
///
/// WKWebView already accepts file drops natively — its built-in handler
/// extracts the dragged content and dispatches a JS `drop` event with a
/// populated `dataTransfer.files` list. The browser/WebKit layer never
/// surfaces the absolute file URLs to JS for security reasons (it strips
/// to filename + bytes only), so apps that need the real filesystem path
/// have no way to recover it.
///
/// We fix that by hooking the message at the AppKit boundary, before
/// WebKit erases it: pull `NSFilenamesPboardType` (legacy) or
/// `NSPasteboardTypeFileURL` (modern) entries out of the dragging
/// pasteboard, then post them to JS via `evaluateJavaScript:`. The JS
/// bridge receives them as `window.__craftDeliverFileDrop([...paths])`,
/// which dispatches a `craft:fileDrop` CustomEvent for app code to
/// listen on. After we've captured paths we forward to the original
/// implementation so the standard JS `drop` event still fires (apps
/// that don't want native paths can keep using the web API verbatim).
///
/// Idempotent — safe to call from every window create. macOS-only.
pub fn install() void {
    _ = capabilities.registerEmitter(.filedrop);
    if (swizzled) return;
    if (builtin.target.os.tag != .macos) return;

    const WKWebView = macos.getClass("WKWebView") orelse return;
    const sel_perform = macos.sel("performDragOperation:");

    // Save the original IMP. If WKWebView doesn't override the method
    // itself, this returns the inherited NSView impl, which is still
    // safe to call as the "super" path.
    const original = objc.class_getMethodImplementation(WKWebView, sel_perform);
    original_perform_drag_imp = original;

    const our_imp: objc.IMP = @ptrCast(@constCast(&craft_perform_drag_operation));

    // class_replaceMethod adds the method on WKWebView if it isn't there
    // directly, or replaces it if it is — either way our hook wins for
    // any WKWebView instance, and the saved `original` lets us forward.
    _ = objc.class_replaceMethod(WKWebView, sel_perform, our_imp, "c@:@");
    swizzled = true;

    if (comptime builtin.mode == .debug) {
        std.debug.print("[FileDrop] Installed performDragOperation: hook on WKWebView\n", .{});
    }
}

/// Hooked WKWebView -performDragOperation:. Captures file paths, posts
/// them to JS, then chains to the original implementation so WebKit's
/// own drop dispatch still happens.
export fn craft_perform_drag_operation(
    self: objc.id,
    selector: objc.SEL,
    draggingInfo: objc.id,
) callconv(.c) c_char {
    extractAndPostPaths(self, draggingInfo);

    if (original_perform_drag_imp) |imp_ptr| {
        const fp: PerformDragFn = @ptrCast(@alignCast(imp_ptr));
        return fp(self, selector, draggingInfo);
    }
    // No original IMP found — accept the drop so the user's gesture
    // doesn't visually fail, even though WebKit won't see it.
    return 1;
}

fn extractAndPostPaths(webview: objc.id, draggingInfo: objc.id) void {
    const pasteboard = macos.msgSend0(draggingInfo, "draggingPasteboard");
    if (@intFromPtr(pasteboard) == 0) return;

    var paths_buf: [64][]u8 = undefined;
    var paths_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < paths_count) : (i += 1) std.heap.c_allocator.free(paths_buf[i]);
    }

    collectLegacyFilenames(pasteboard, &paths_buf, &paths_count);
    if (paths_count == 0) collectFileURLs(pasteboard, &paths_buf, &paths_count);
    if (paths_count == 0) return;

    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(std.heap.c_allocator);
    json.append(std.heap.c_allocator, '[') catch return;
    var i: usize = 0;
    while (i < paths_count) : (i += 1) {
        if (i > 0) json.append(std.heap.c_allocator, ',') catch return;
        json.append(std.heap.c_allocator, '"') catch return;
        appendJsonString(&json, paths_buf[i]) catch return;
        json.append(std.heap.c_allocator, '"') catch return;
    }
    json.append(std.heap.c_allocator, ']') catch return;

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    // The bridge JS defines `__craftDeliverFileDrop`. Falling through to
    // a no-op if it's missing keeps us safe on early page loads.
    script.appendSlice(std.heap.c_allocator, "if (window.__craftDeliverFileDrop) window.__craftDeliverFileDrop(") catch return;
    script.appendSlice(std.heap.c_allocator, json.items) catch return;
    script.appendSlice(std.heap.c_allocator, ");") catch return;
    script.append(std.heap.c_allocator, 0) catch return;

    const NSString = macos.getClass("NSString");
    const js_str = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(script.items.ptr)));
    _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js_str, @as(?*anyopaque, null));

    if (comptime builtin.mode == .debug) {
        std.debug.print("[FileDrop] Posted {d} path(s) to JS\n", .{paths_count});
    }
}

/// Read the legacy NSFilenamesPboardType (NSArray<NSString*>* of paths).
/// Still populated by Finder on every modern macOS for backwards compat.
fn collectLegacyFilenames(pasteboard: objc.id, out: *[64][]u8, count: *usize) void {
    const nameType = macos.createNSString("NSFilenamesPboardType");
    const filenames = macos.msgSend1(pasteboard, "propertyListForType:", nameType);
    if (@intFromPtr(filenames) == 0) return;

    const getCount = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_ulong,
        @ptrCast(&objc.objc_msgSend),
    );
    const total = getCount(filenames, macos.sel("count"));
    var idx: c_ulong = 0;
    while (idx < total and count.* < out.len) : (idx += 1) {
        const name = macos.msgSend1(filenames, "objectAtIndex:", idx);
        if (@intFromPtr(name) == 0) continue;
        const utf8 = macos.msgSend0(name, "UTF8String");
        if (@intFromPtr(utf8) == 0) continue;
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
        const owned = std.heap.c_allocator.dupe(u8, slice) catch return;
        out[count.*] = owned;
        count.* += 1;
    }
}

/// Read NSURLs via -readObjectsForClasses:options: with the modern
/// NSPasteboardTypeFileURL UTI. Necessary on apps that ONLY put the
/// modern type on their drag pasteboard (rare from Finder, but real).
fn collectFileURLs(pasteboard: objc.id, out: *[64][]u8, count: *usize) void {
    const NSURL_class = macos.getClass("NSURL");
    const NSArray = macos.getClass("NSArray");
    const class_arr = macos.msgSend1(NSArray, "arrayWithObject:", NSURL_class);
    const NSDictionary = macos.getClass("NSDictionary");
    const empty = macos.msgSend0(NSDictionary, "dictionary");
    const objs = macos.msgSend2(pasteboard, "readObjectsForClasses:options:", class_arr, empty);
    if (@intFromPtr(objs) == 0) return;

    const getCount = @as(
        *const fn (objc.id, objc.SEL) callconv(.c) c_ulong,
        @ptrCast(&objc.objc_msgSend),
    );
    const total = getCount(objs, macos.sel("count"));
    var idx: c_ulong = 0;
    while (idx < total and count.* < out.len) : (idx += 1) {
        const url = macos.msgSend1(objs, "objectAtIndex:", idx);
        if (@intFromPtr(url) == 0) continue;
        if (!macos.msgSendBool(url, "isFileURL")) continue;
        const path = macos.msgSend0(url, "path");
        if (@intFromPtr(path) == 0) continue;
        const utf8 = macos.msgSend0(path, "UTF8String");
        if (@intFromPtr(utf8) == 0) continue;
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
        const owned = std.heap.c_allocator.dupe(u8, slice) catch return;
        out[count.*] = owned;
        count.* += 1;
    }
}

fn appendJsonString(out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |b| {
        switch (b) {
            '\\' => try out.appendSlice(std.heap.c_allocator, "\\\\"),
            '"' => try out.appendSlice(std.heap.c_allocator, "\\\""),
            '\n' => try out.appendSlice(std.heap.c_allocator, "\\n"),
            '\r' => try out.appendSlice(std.heap.c_allocator, "\\r"),
            '\t' => try out.appendSlice(std.heap.c_allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{b}) catch continue;
                try out.appendSlice(std.heap.c_allocator, written);
            },
            else => try out.append(std.heap.c_allocator, b),
        }
    }
}
