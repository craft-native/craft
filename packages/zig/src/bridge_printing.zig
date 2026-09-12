const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// Bridge for printing the current WKWebView's contents.
///
/// macOS path: `[webview printOperationWithPrintInfo:]` — returns an
/// `NSPrintOperation` we then run modally for the window. This shows
/// the standard system print sheet (with PDF preview, save-to-file,
/// page-range selectors, etc).
///
/// PDF generation reuses the same flow with `NSPrintInfo` configured
/// to spool to a file via `setJobDisposition:` = `NSPrintSaveJob` and
/// `NSPrintSavePath` set to the destination.
pub const PrintingBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "print")) {
            try self.print();
        } else if (std.mem.eql(u8, action, "printToPDF")) {
            try self.printToPDF(data);
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn print(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "print", "{\"ok\":false,\"reason\":\"not supported on this OS\"}");
            return;
        }
        const macos = @import("macos.zig");
        const webview = macos.getMessageWebView() orelse {
            bridge_error.sendResultToJS(self.allocator, "print", "{\"ok\":false,\"reason\":\"no webview\"}");
            return;
        };

        // -[WKWebView printOperationWithPrintInfo:] — pass [NSPrintInfo
        // sharedPrintInfo] so the system uses the user's defaults.
        const NSPrintInfo = macos.getClass("NSPrintInfo");
        const print_info = macos.msgSend0(NSPrintInfo, "sharedPrintInfo");

        const op = macos.msgSend1(webview, "printOperationWithPrintInfo:", print_info);
        if (@intFromPtr(op) == 0) {
            bridge_error.sendResultToJS(self.allocator, "print", "{\"ok\":false}");
            return;
        }
        _ = macos.msgSend1(op, "setShowsPrintPanel:", @as(c_int, 1));
        _ = macos.msgSend1(op, "setShowsProgressPanel:", @as(c_int, 1));

        // Run the operation modally with the webview's own window as
        // sheet parent. -runOperation triggers the modal sheet.
        _ = macos.msgSend0(op, "runOperation");

        bridge_error.sendResultToJS(self.allocator, "print", "{\"ok\":true}");
    }

    fn printToPDF(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "printToPDF", "{\"ok\":false,\"reason\":\"not supported on this OS\"}");
            return;
        }
        const macos = @import("macos.zig");
        const webview = macos.getMessageWebView() orelse {
            bridge_error.sendResultToJS(self.allocator, "printToPDF", "{\"ok\":false,\"reason\":\"no webview\"}");
            return;
        };

        const path = parsePath(data) orelse {
            bridge_error.sendErrorToJS(self.allocator, "printToPDF", BridgeError.MissingData);
            return;
        };

        // Configure NSPrintInfo to write a PDF to disk.
        //
        // -[NSPrintInfo dictionary] returns the *underlying* mutable
        // dictionary on macOS (despite the unsuffixed name), but we
        // can't rely on that — the Apple docs only guarantee an
        // NSDictionary-typed return. Calling `setObject:forKey:` on an
        // immutable dict crashes silently with "unrecognized selector"
        // in many releases.
        //
        // Build an NSMutableDictionary explicitly with the keys we need
        // and pass it to `-initWithDictionary:` — that's the documented
        // way to construct an NSPrintInfo with custom keys.
        const NSMutableDictionary = macos.getClass("NSMutableDictionary");
        const dict = macos.msgSend0(NSMutableDictionary, "dictionary");
        _ = macos.msgSend2(dict, "setObject:forKey:", macos.createNSString("NSPrintSaveJob"), macos.createNSString("NSPrintJobDisposition"));
        _ = macos.msgSend2(dict, "setObject:forKey:", macos.createNSString(path), macos.createNSString("NSPrintSavePath"));

        const NSPrintInfo = macos.getClass("NSPrintInfo");
        const info_alloc = macos.msgSend0(NSPrintInfo, "alloc");
        const info = macos.msgSend1(info_alloc, "initWithDictionary:", dict);

        const op = macos.msgSend1(webview, "printOperationWithPrintInfo:", info);
        if (@intFromPtr(op) == 0) {
            bridge_error.sendResultToJS(self.allocator, "printToPDF", "{\"ok\":false}");
            return;
        }
        _ = macos.msgSend1(op, "setShowsPrintPanel:", @as(c_int, 0));
        _ = macos.msgSend1(op, "setShowsProgressPanel:", @as(c_int, 0));
        _ = macos.msgSend0(op, "runOperation");

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"ok\":true,\"path\":\"");
        for (path) |b| {
            switch (b) {
                '"' => try buf.appendSlice(self.allocator, "\\\""),
                '\\' => try buf.appendSlice(self.allocator, "\\\\"),
                else => try buf.append(self.allocator, b),
            }
        }
        try buf.appendSlice(self.allocator, "\"}");
        const owned = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned);
        bridge_error.sendResultToJS(self.allocator, "printToPDF", owned);
    }
};

fn parsePath(data: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, data, "\"path\":\"") orelse return null;
    const start = idx + 8;
    const end = std.mem.indexOfPos(u8, data, start, "\"") orelse return null;
    return data[start..end];
}
