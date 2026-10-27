//! The JS backend backed by zig-js.
//!
//! This is the point of the exercise: craft's own JavaScript runs on a
//! first-party engine rather than on whatever the platform ships. It is not a
//! replacement for the page's JavaScript — that executes inside WebKit's
//! WebContent process, which craft does not own — but everything else craft
//! wants to evaluate no longer needs a webview to do it.
//!
//! Concretely, a menubar-only app had no way to run JavaScript at all short of
//! creating a hidden WKWebView: a whole WebContent process, tens of megabytes
//! and a few hundred milliseconds, to call one function.

const std = @import("std");
const js = @import("js");

pub const available = true;
pub const hosting = @import("js_host_zigjs.zig");

pub const Error = error{ OutOfMemory, Unavailable, Throw, Parse };

pub const Context = struct {
    inner: *js.Context,
    // Kept so `destroy` can free the wrapper it allocated. Without it the
    // wrapper leaked on every evaluation.
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) Error!*Context {
        const inner = js.Context.create(allocator) catch return Error.OutOfMemory;
        errdefer inner.destroy();

        const self = allocator.create(Context) catch return Error.OutOfMemory;
        self.* = .{ .inner = inner, .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Context) void {
        const allocator = self.allocator;
        self.inner.destroy();
        allocator.destroy(self);
    }

    /// Snapshot engine-owned data only. Never perform JS [[Get]], walk a
    /// prototype, stringify an object, or invoke a proxy/accessor for diagnostics.
    pub fn copyExceptionText(self: *Context, arena: std.mem.Allocator) Error!?[]const u8 {
        const value = self.inner.exception orelse return null;
        var buffer: [8192]u8 = undefined;
        var bounded = std.heap.FixedBufferAllocator.init(&buffer);
        const alloc = bounded.allocator();
        const text: []const u8 = switch (value.kind()) {
            .string => try diagnosticString(value, alloc),
            .number => value.toString(alloc) catch return error.OutOfMemory,
            .boolean => if (value.asBool()) "true" else "false",
            .null => "null",
            .undefined => "undefined",
            .object => blk: {
                const object = value.asObj();
                if (object.proxyHandler() != null or object.proxy_revoked) break :blk "[thrown proxy]";
                if (!object.behavior.is_error) break :blk "[thrown object]";
                const name = object.errorName();
                const label = if (name.len > 0 and name.len <= 128) name else "Error";
                const message = switch (object.namedOwnPropertySnapshot("message")) {
                    .data => |data| if (data.value.isString()) try diagnosticString(data.value, alloc) else "[non-string message]",
                    .accessor => "[accessor message omitted]",
                    .absent => "",
                };
                break :blk if (message.len == 0) label else std.fmt.allocPrint(alloc, "{s}: {s}", .{ label, message }) catch return error.OutOfMemory;
            },
        };
        // The caller owns this copy after the engine context is destroyed.
        return arena.dupe(u8, text) catch error.OutOfMemory;
    }

    fn diagnosticString(value: js.Value, allocator: std.mem.Allocator) Error![]const u8 {
        // Check before encoding Latin-1 into WTF-8; diagnostic formatting must
        // not allocate in proportion to an attacker-controlled thrown string.
        if (value.asStr().len > 1024) return "[string exceeds diagnostic limit]";
        return value.asWtf8(allocator) catch error.OutOfMemory;
    }

    /// Evaluate and render the result as text.
    ///
    /// `arena` rather than a general allocator: zig-js's `toString` allocates
    /// internally and the slice it returns is not a single freeable
    /// allocation, so freeing it individually aborts on invalid free.
    pub fn evalToString(self: *Context, arena: std.mem.Allocator, source: []const u8) Error![]const u8 {
        const value = self.inner.evaluate(source) catch |err| return switch (err) {
            error.OutOfMemory => Error.OutOfMemory,
            // A JS-level throw and a parse failure are different problems for
            // the caller: one is the script's logic, the other is its syntax.
            error.Throw => Error.Throw,
            else => Error.Parse,
        };
        return value.toString(arena) catch Error.OutOfMemory;
    }
};
