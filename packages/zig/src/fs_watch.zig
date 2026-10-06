//! Native file watching behind `craft.fs.watch`: one FSEvents stream per watch.
//!
//! `bridge_fs.zig` owns the watch table and the page; this file owns the
//! stream. A watch is started with a path, a `recursive` flag and a `Sink`, and
//! from then on every change FSEvents reports under that path is folded onto
//! one of the four `type`s the page's contract names, filtered to what the
//! caller asked to watch, and handed to the sink as `(id, type, path)`.
//!
//! ## Delivery
//!
//! Streams are scheduled on the main dispatch queue, so the callback runs on
//! the main thread, where AppKit's run loop drains that queue. The bridge
//! messages that start and stop watches arrive there too (WebKit delivers
//! `WKScriptMessageHandler` callbacks on the main thread), so a watch is never
//! touched from two threads, and a page event is dispatched from the thread
//! `evaluateJavaScript:` must be called on, with no hop.
//!
//! ## What FSEvents cannot do, and how it is made to
//!
//! FSEvents watches directory trees, always recursively, and reports real
//! paths — `/private/tmp/x` for a watch on `/tmp`. So:
//!
//!  - the path is resolved with `realpath` when the watch starts, events are
//!    compared against that, and each reported path is rewritten back onto the
//!    spelling the caller used;
//!  - a non-recursive watch keeps only the directory's direct children;
//!  - a watch on a single file streams its parent directory and keeps only
//!    events for that file.
//!
//! ## Teardown
//!
//! `stop` stops, invalidates and releases the stream, then frees the watch.
//! That order is safe because both ends run on the main thread: invalidating
//! unschedules the stream from the main queue, and no callback can be running
//! while `stop` is, so none can arrive afterwards. The context passes no
//! retain/release pair for the same reason — with one, FSEvents frees its hold
//! on the watch from a later turn of the main queue, which leaves the watch
//! alive for as long as nothing drains that queue.

const std = @import("std");
const builtin = @import("builtin");
const io_context = @import("io_context.zig");

/// What the page is told happened, as `detail.type` of `craft:fs:change`.
pub const ChangeType = enum {
    create,
    modify,
    delete,
    rename,

    pub fn text(self: ChangeType) []const u8 {
        return @tagName(self);
    }
};

/// `FSEventStreamEventFlags`, from `FSEvents.h`.
pub const Flag = struct {
    pub const must_scan_sub_dirs: u32 = 0x00000001;
    pub const user_dropped: u32 = 0x00000002;
    pub const kernel_dropped: u32 = 0x00000004;
    pub const item_created: u32 = 0x00000100;
    pub const item_removed: u32 = 0x00000200;
    pub const item_inode_meta_mod: u32 = 0x00000400;
    pub const item_renamed: u32 = 0x00000800;
    pub const item_modified: u32 = 0x00001000;
    pub const item_finder_info_mod: u32 = 0x00002000;
    pub const item_change_owner: u32 = 0x00004000;
    pub const item_xattr_mod: u32 = 0x00008000;
    pub const item_cloned: u32 = 0x00400000;
};

/// `kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents`.
///
/// File events, so a change names the file rather than only its directory.
/// No-defer, so the first change after a quiet spell is delivered at once and
/// only a burst waits out `latency_seconds`.
const create_flags: u32 = 0x00000002 | 0x00000010;

/// `kFSEventStreamEventIdSinceNow`: no history, only what happens from here.
const since_now: u64 = 0xFFFFFFFFFFFFFFFF;

/// How long FSEvents may hold a burst to coalesce it.
const latency_seconds: f64 = 0.05;

/// What a watch knows about a path when an event for it arrives.
pub const PathState = struct {
    /// Whether the path is there now.
    exists: bool,
    /// Whether the watch already knew it as a live path: it has reported it
    /// since, or the file was born before the watch started.
    known: bool,
};

/// Fold one event's flags onto a `ChangeType`, or `null` for an event that is
/// not about an item at all.
///
/// FSEvents flags are history, not news. One event can carry bits from every
/// change within the latency window, and fseventsd keeps `ItemCreated` on a
/// recently created file's later events too — a file written twice reports
/// `created | modified` the second time. So the bits alone cannot tell a write
/// from a creation, and the fold asks two things of the watch instead: is the
/// path there now, and did the watch already know it?
///
///  - **Dropped or must-rescan → modify.** FSEvents lost detail under the
///    path; the page should re-read it, and `modify` says exactly that.
///  - **Removed, and gone → delete.** Ahead of rename, because `ItemRenamed`
///    is sticky too: a file renamed into place and later deleted reports
///    `renamed | removed`, and that is a delete.
///  - **Renamed → rename.** Both ends of a rename report it, the old name and
///    the new; the page can tell them apart by whether the path exists.
///  - **Created, and new to the watch → create.** That includes a file that
///    was deleted and comes back (an editor replacing it on save), since the
///    delete made it unknown again.
///  - **Anything else that touched the item → modify**: contents, metadata,
///    ownership, extended attributes, a clone — and a sticky `ItemCreated` on
///    a path the watch already knew.
pub fn changeType(flags: u32, state: PathState) ?ChangeType {
    if (flags & (Flag.must_scan_sub_dirs | Flag.user_dropped | Flag.kernel_dropped) != 0) return .modify;
    if (flags & Flag.item_removed != 0 and !state.exists) return .delete;
    if (flags & Flag.item_renamed != 0) return .rename;
    if (flags & Flag.item_created != 0 and !state.known) return .create;
    const touched = Flag.item_created | Flag.item_modified | Flag.item_inode_meta_mod | Flag.item_finder_info_mod |
        Flag.item_change_owner | Flag.item_xattr_mod | Flag.item_cloned | Flag.item_removed;
    if (flags & touched != 0) return .modify;
    return null;
}

/// What a watch was started on.
pub const Scope = enum { file, directory };

/// `path` with any trailing `/` removed. `/` itself becomes `""`, so that
/// appending `"/" ++ name` to it always yields an absolute path.
pub fn trimSlash(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, "/");
}

/// Whether an event for `path` belongs to a watch on `base` (a real path,
/// already trimmed).
///
///  - A file watch keeps only the file.
///  - A directory watch keeps what is under it — everything when recursive,
///    direct children otherwise. The directory itself is kept only when it
///    went away (deleted or renamed): its own metadata changes every time a
///    child is added, and passing that on would pair every `create` with a
///    `modify` of the parent.
pub fn accepts(base: []const u8, scope: Scope, recursive: bool, path: []const u8, change: ChangeType) bool {
    switch (scope) {
        .file => return std.mem.eql(u8, path, base),
        .directory => {
            if (std.mem.eql(u8, path, base)) return change == .delete or change == .rename;
            if (path.len <= base.len + 1) return false;
            if (!std.mem.startsWith(u8, path, base) or path[base.len] != '/') return false;
            if (recursive) return true;
            return std.mem.indexOfScalar(u8, path[base.len + 1 ..], '/') == null;
        },
    }
}

/// `path`, an event's real path under `real_base`, spelled from `base`, the
/// path the caller watched — so a watch on `/tmp/project` reports
/// `/tmp/project/a.ts`, not `/private/tmp/project/a.ts`. Caller owns it.
pub fn displayPath(allocator: std.mem.Allocator, base: []const u8, real_base: []const u8, scope: Scope, path: []const u8) ![]u8 {
    if (scope == .file or path.len < real_base.len) return allocator.dupe(u8, if (base.len == 0) "/" else base);
    if (path.len == real_base.len) return allocator.dupe(u8, if (base.len == 0) "/" else base);
    return std.mem.concat(allocator, u8, &.{ base, path[real_base.len..] });
}

/// The script that dispatches one change into a page as `craft:fs:change`.
pub fn eventScript(allocator: std.mem.Allocator, id: []const u8, change: ChangeType, path: []const u8) ![]u8 {
    const detail = try std.json.Stringify.valueAlloc(allocator, .{ .id = id, .type = change.text(), .path = path }, .{});
    defer allocator.free(detail);
    return std.mem.concat(allocator, u8, &.{
        "if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('craft:fs:change',{detail:",
        detail,
        "}));",
    });
}

/// Where a watch's changes go.
pub const Sink = struct {
    context: ?*anyopaque = null,
    deliver: *const fn (context: ?*anyopaque, id: []const u8, change: ChangeType, path: []const u8) void,
    /// Called once, when the watch is freed. Nothing is delivered after it.
    release: ?*const fn (context: ?*anyopaque) void = null,
};

pub const Error = error{
    UnsupportedPlatform,
    FileNotFound,
    AccessDenied,
    NativeCallFailed,
    OutOfMemory,
};

pub const Watch = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    /// The caller's path, trimmed: what reported paths are spelled from.
    base: []const u8,
    /// The same path through `realpath`, trimmed: what events are matched on.
    real_base: []const u8,
    scope: Scope,
    recursive: bool,
    sink: Sink,
    stream: ?*anyopaque = null,
    /// Set first thing in `stop`, and checked between the events of one batch.
    stopped: bool = false,
    /// When the watch started, against which a file's birth time says whether
    /// it was already there.
    started: Timespec = .{ .sec = 0, .nsec = 0 },
    /// Real paths the watch has reported alive, so a sticky `ItemCreated` on
    /// a later write reads as the write it is. Bounded by `seen_limit`.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    /// Past this many live paths the set is emptied rather than grown. Files
    /// born before the watch are still told apart by birth time; what is lost
    /// is only that a file created during the watch, then written, may report
    /// `create` once more.
    const seen_limit = 4096;

    fn destroy(self: *Watch) void {
        if (self.sink.release) |release| release(self.sink.context);
        self.forgetAll();
        self.seen.deinit(self.allocator);
        self.allocator.free(self.id);
        self.allocator.free(self.base);
        self.allocator.free(self.real_base);
        self.allocator.destroy(self);
    }

    fn forgetAll(self: *Watch) void {
        var it = self.seen.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.seen.clearRetainingCapacity();
    }

    fn remember(self: *Watch, path: []const u8) void {
        if (self.seen.contains(path)) return;
        if (self.seen.count() >= seen_limit) self.forgetAll();
        const owned = self.allocator.dupe(u8, path) catch return;
        self.seen.put(self.allocator, owned, {}) catch self.allocator.free(owned);
    }

    fn forget(self: *Watch, path: []const u8) void {
        if (self.seen.fetchRemove(path)) |kv| self.allocator.free(kv.key);
    }

    /// One reported path, through the fold and the filter, to the sink.
    fn handle(self: *Watch, raw: [*:0]const u8, flags: u32) void {
        const path = trimSlash(std.mem.span(raw));
        var st: std.c.Stat = undefined;
        const exists = std.c.stat(raw, &st) == 0;
        const born_before = exists and earlier(st.birthtime(), self.started);
        const change = changeType(flags, .{
            .exists = exists,
            .known = born_before or self.seen.contains(path),
        }) orelse return;
        if (!accepts(self.real_base, self.scope, self.recursive, path, change)) return;

        if (exists and change != .delete) self.remember(path) else self.forget(path);

        const shown = displayPath(self.allocator, self.base, self.real_base, self.scope, path) catch return;
        defer self.allocator.free(shown);
        self.sink.deliver(self.sink.context, self.id, change, shown);
    }
};

/// `std.c.timespec` where there is one; Windows has none, and never starts a
/// stream, but still compiles the type.
const Timespec = if (builtin.os.tag == .windows) struct { sec: i64, nsec: i64 } else std.c.timespec;

fn earlier(a: Timespec, b: Timespec) bool {
    return a.sec < b.sec or (a.sec == b.sec and a.nsec < b.nsec);
}

/// Start watching `path`. The sink is released when the watch is freed, which
/// is also what happens to it if starting fails.
pub fn start(allocator: std.mem.Allocator, id: []const u8, path: []const u8, recursive: bool, sink: Sink) Error!*Watch {
    if (comptime builtin.os.tag != .macos) {
        if (sink.release) |release| release(sink.context);
        return error.UnsupportedPlatform;
    }

    const watch = allocator.create(Watch) catch |err| {
        if (sink.release) |release| release(sink.context);
        return err;
    };
    watch.* = .{
        .allocator = allocator,
        .id = "",
        .base = "",
        .real_base = "",
        .scope = .directory,
        .recursive = recursive,
        .sink = sink,
    };
    errdefer watch.destroy();

    _ = std.c.clock_gettime(.REALTIME, &watch.started);
    watch.id = try allocator.dupe(u8, id);
    watch.base = try allocator.dupe(u8, trimSlash(path));

    const io = io_context.get();
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        else => error.NativeCallFailed,
    };
    defer allocator.free(real);
    watch.real_base = try allocator.dupe(u8, trimSlash(real));

    const stat = std.Io.Dir.cwd().statFile(io, real, .{}) catch return error.NativeCallFailed;
    watch.scope = if (stat.kind == .directory) .directory else .file;

    // FSEvents watches directories. A file is watched through its parent.
    const streamed = if (watch.scope == .directory)
        (if (watch.real_base.len == 0) "/" else watch.real_base)
    else
        (std.fs.path.dirname(watch.real_base) orelse "/");

    const cf_path = CFStringCreateWithBytes(null, streamed.ptr, @intCast(streamed.len), cf_string_encoding_utf8, false) orelse
        return error.NativeCallFailed;
    defer CFRelease(cf_path);
    var values = [_]?*const anyopaque{cf_path};
    const paths = CFArrayCreate(null, &values, 1, &kCFTypeArrayCallBacks) orelse return error.NativeCallFailed;
    defer CFRelease(paths);

    const context = FSEventStreamContext{ .info = watch };
    const stream = FSEventStreamCreate(null, onEvents, &context, paths, since_now, latency_seconds, create_flags) orelse
        return error.NativeCallFailed;
    watch.stream = stream;
    FSEventStreamSetDispatchQueue(stream, &_dispatch_main_q);
    if (FSEventStreamStart(stream) == 0) {
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        watch.stream = null;
        return error.NativeCallFailed;
    }
    return watch;
}

/// Stop a watch for good. Nothing reaches the sink after this returns.
pub fn stop(watch: *Watch) void {
    watch.stopped = true;
    if (comptime builtin.os.tag == .macos) {
        if (watch.stream) |stream| {
            FSEventStreamStop(stream);
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            watch.stream = null;
        }
    }
    watch.destroy();
}

/// `FSEventStreamCallback`. Without `kFSEventStreamCreateFlagUseCFTypes`,
/// `event_paths` is a C array of C strings.
fn onEvents(
    _: ?*const anyopaque,
    info: ?*anyopaque,
    count: usize,
    event_paths: ?*anyopaque,
    flags: [*]const u32,
    _: [*]const u64,
) callconv(.c) void {
    const watch: *Watch = @ptrCast(@alignCast(info orelse return));
    const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(event_paths orelse return));
    for (0..count) |index| {
        if (watch.stopped) return;
        watch.handle(paths[index], flags[index]);
    }
}

// =============================================================================
// CoreServices (FSEvents) and CoreFoundation
// =============================================================================

const CFIndex = isize;
const cf_string_encoding_utf8: u32 = 0x08000100;

const FSEventStreamContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque,
    retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque = null,
    release: ?*const fn (?*const anyopaque) callconv(.c) void = null,
    copy_description: ?*const fn (?*const anyopaque) callconv(.c) ?*anyopaque = null,
};

const FSEventStreamCallback = *const fn (?*const anyopaque, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;

extern "c" fn FSEventStreamCreate(
    allocator: ?*anyopaque,
    callback: FSEventStreamCallback,
    context: *const FSEventStreamContext,
    paths_to_watch: *anyopaque,
    since_when: u64,
    latency: f64,
    flags: u32,
) ?*anyopaque;
extern "c" fn FSEventStreamSetDispatchQueue(stream: *anyopaque, queue: ?*anyopaque) void;
extern "c" fn FSEventStreamStart(stream: *anyopaque) u8;
extern "c" fn FSEventStreamStop(stream: *anyopaque) void;
extern "c" fn FSEventStreamInvalidate(stream: *anyopaque) void;
extern "c" fn FSEventStreamRelease(stream: *anyopaque) void;

extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, external: bool) ?*anyopaque;
extern "c" fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*const anyopaque, count: CFIndex, callbacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern const kCFTypeArrayCallBacks: anyopaque;
extern var _dispatch_main_q: anyopaque;

// =============================================================================
// Tests — the pure parts. The stream itself is exercised end to end in
// `bridge_fs_test.zig`, whose binary links CoreServices; this file's tests ride
// along in binaries that link only libc.
// =============================================================================

const testing = std.testing;

const new: PathState = .{ .exists = true, .known = false };
const known: PathState = .{ .exists = true, .known = true };
const gone: PathState = .{ .exists = false, .known = true };

test "each FSEvents flag folds onto the type it means" {
    try testing.expectEqual(ChangeType.create, changeType(Flag.item_created, new).?);
    try testing.expectEqual(ChangeType.modify, changeType(Flag.item_modified, known).?);
    try testing.expectEqual(ChangeType.delete, changeType(Flag.item_removed, gone).?);
    try testing.expectEqual(ChangeType.rename, changeType(Flag.item_renamed, known).?);
    try testing.expectEqual(ChangeType.rename, changeType(Flag.item_renamed, gone).?);
    inline for (.{ Flag.item_inode_meta_mod, Flag.item_finder_info_mod, Flag.item_change_owner, Flag.item_xattr_mod, Flag.item_cloned }) |flag| {
        try testing.expectEqual(ChangeType.modify, changeType(flag, known).?);
    }
}

test "a sticky ItemCreated on a path the watch knows is a write, not a creation" {
    // What fseventsd really reports for the second write to a new file
    // (`created | inode-meta | modified | xattr | is-file`), seen in the
    // end-to-end test.
    const second_write: u32 = 0x00019500;
    try testing.expectEqual(ChangeType.modify, changeType(second_write, known).?);
    try testing.expectEqual(ChangeType.create, changeType(second_write, new).?);
    try testing.expectEqual(ChangeType.modify, changeType(Flag.item_created, known).?);
}

test "coalesced flags resolve by priority, and existence settles a removal" {
    // Created then written within the latency window: still a creation.
    try testing.expectEqual(ChangeType.create, changeType(Flag.item_created | Flag.item_modified, new).?);
    // Created then removed: what the page needs to know is that it is gone.
    try testing.expectEqual(ChangeType.delete, changeType(Flag.item_created | Flag.item_removed, .{ .exists = false, .known = false }).?);
    // Removed and back again — an editor replacing the file — after the
    // delete made it unknown: a creation, not a delete.
    try testing.expectEqual(ChangeType.create, changeType(Flag.item_removed | Flag.item_created, new).?);
    try testing.expectEqual(ChangeType.modify, changeType(Flag.item_removed | Flag.item_modified, known).?);
    // A rename outranks a write to the name...
    try testing.expectEqual(ChangeType.rename, changeType(Flag.item_renamed | Flag.item_modified, gone).?);
    try testing.expectEqual(ChangeType.rename, changeType(Flag.item_renamed | Flag.item_removed, known).?);
    // ...but not its removal. `rm` on a file that was renamed into place
    // reports the sticky rename with it, as the headless run showed.
    try testing.expectEqual(ChangeType.delete, changeType(Flag.item_renamed | Flag.item_removed, gone).?);
}

test "lost detail asks the page to re-read, and an event about nothing is dropped" {
    try testing.expectEqual(ChangeType.modify, changeType(Flag.must_scan_sub_dirs, known).?);
    try testing.expectEqual(ChangeType.modify, changeType(Flag.user_dropped, new).?);
    try testing.expectEqual(ChangeType.modify, changeType(Flag.kernel_dropped | Flag.item_removed, gone).?);
    // No item bits at all: history-done, a mount, the event-id wrap.
    try testing.expect(changeType(0, known) == null);
    try testing.expect(changeType(0x00000010 | 0x00000040, known) == null);
}

test "a recursive directory watch keeps everything under it" {
    const base = "/w";
    try testing.expect(accepts(base, .directory, true, "/w/a.txt", .modify));
    try testing.expect(accepts(base, .directory, true, "/w/sub/deep/b.txt", .create));
    try testing.expect(!accepts(base, .directory, true, "/wx/a.txt", .create));
    try testing.expect(!accepts(base, .directory, true, "/other/a.txt", .create));
    try testing.expect(!accepts(base, .directory, true, "/w/", .create));
}

test "a non-recursive directory watch keeps only direct children" {
    const base = "/w";
    try testing.expect(accepts(base, .directory, false, "/w/a.txt", .modify));
    try testing.expect(accepts(base, .directory, false, "/w/sub", .create));
    try testing.expect(!accepts(base, .directory, false, "/w/sub/b.txt", .create));
    try testing.expect(!accepts(base, .directory, false, "/w/sub/deep/c.txt", .delete));
    try testing.expect(!accepts(base, .directory, false, "/wx", .create));
}

test "the watched directory itself is reported only when it goes away" {
    for ([_]bool{ true, false }) |recursive| {
        try testing.expect(accepts("/w", .directory, recursive, "/w", .delete));
        try testing.expect(accepts("/w", .directory, recursive, "/w", .rename));
        try testing.expect(!accepts("/w", .directory, recursive, "/w", .modify));
        try testing.expect(!accepts("/w", .directory, recursive, "/w", .create));
    }
}

test "a file watch keeps only that file" {
    const base = "/w/a.txt";
    for ([_]bool{ true, false }) |recursive| {
        try testing.expect(accepts(base, .file, recursive, "/w/a.txt", .modify));
        try testing.expect(accepts(base, .file, recursive, "/w/a.txt", .delete));
        try testing.expect(!accepts(base, .file, recursive, "/w/b.txt", .modify));
        try testing.expect(!accepts(base, .file, recursive, "/w/a.txt.swp", .create));
        try testing.expect(!accepts(base, .file, recursive, "/w", .modify));
    }
}

test "a watch on / keeps absolute paths under it" {
    // `trimSlash("/")` is "", so the prefix check is a leading `/`.
    try testing.expectEqualStrings("", trimSlash("/"));
    try testing.expect(accepts("", .directory, true, "/etc/hosts", .modify));
    try testing.expect(accepts("", .directory, false, "/tmp", .create));
    try testing.expect(!accepts("", .directory, false, "/tmp/x", .create));
}

test "reported paths are spelled the way the caller watched them" {
    const alloc = testing.allocator;
    const cases = [_]struct { base: []const u8, real: []const u8, scope: Scope, path: []const u8, want: []const u8 }{
        // `/tmp` is a symlink to `/private/tmp`; the page watched `/tmp`.
        .{ .base = "/tmp/p", .real = "/private/tmp/p", .scope = .directory, .path = "/private/tmp/p/a.ts", .want = "/tmp/p/a.ts" },
        .{ .base = "rel/dir", .real = "/home/u/rel/dir", .scope = .directory, .path = "/home/u/rel/dir/s/b", .want = "rel/dir/s/b" },
        .{ .base = "/tmp/p", .real = "/private/tmp/p", .scope = .directory, .path = "/private/tmp/p", .want = "/tmp/p" },
        .{ .base = "/tmp/a.txt", .real = "/private/tmp/a.txt", .scope = .file, .path = "/private/tmp/a.txt", .want = "/tmp/a.txt" },
        .{ .base = "", .real = "", .scope = .directory, .path = "/etc/hosts", .want = "/etc/hosts" },
    };
    for (cases) |case| {
        const shown = try displayPath(alloc, case.base, case.real, case.scope, case.path);
        defer alloc.free(shown);
        try testing.expectEqualStrings(case.want, shown);
    }
    try testing.expectEqualStrings("/tmp/p", trimSlash("/tmp/p/"));
}

test "the event script carries the detail the page routes on, escaped" {
    const alloc = testing.allocator;
    const script = try eventScript(alloc, "fsw-1", .create, "/tmp/say \"hi\"\n.txt");
    defer alloc.free(script);
    try testing.expectEqualStrings(
        \\if(window.dispatchEvent)window.dispatchEvent(new CustomEvent('craft:fs:change',{detail:{"id":"fsw-1","type":"create","path":"/tmp/say \"hi\"\n.txt"}}));
    , script);
}

test "off macOS a watch refuses, and still releases its sink" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    const Counter = struct {
        var released: usize = 0;
        fn deliver(_: ?*anyopaque, _: []const u8, _: ChangeType, _: []const u8) void {}
        fn release(_: ?*anyopaque) void {
            released += 1;
        }
    };
    try testing.expectError(error.UnsupportedPlatform, start(testing.allocator, "w", ".", false, .{
        .deliver = Counter.deliver,
        .release = Counter.release,
    }));
    try testing.expectEqual(@as(usize, 1), Counter.released);
}
