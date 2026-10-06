//! The desktop fs bridge end to end: a payload as `craft.fs.*` posts it, the
//! file it leaves behind, read back.
//!
//! Its own root, not tests inside `bridge_fs.zig`. That file is reached from
//! `global_state.zig`, so any test there rides along in every binary that
//! touches global state — `log.zig`'s and `bridge_log.zig`'s among them, which
//! link only libc. These handlers reply through `bridge.evalJS`, which reaches
//! the platform's webview code, and an unlinked binary cannot resolve it.

const std = @import("std");
const builtin = @import("builtin");
const bridge_fs = @import("bridge_fs.zig");
const fs_watch = @import("fs_watch.zig");

const FSBridge = bridge_fs.FSBridge;
const testing = std.testing;

/// A scratch directory under `.zig-cache/tmp`, and its path as the bridge
/// takes one: relative to the working directory, which is where both look.
const Scratch = struct {
    tmp: testing.TmpDir,
    path: []const u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Scratch) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn read(self: *Scratch, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(4096));
    }

    fn mkdir(self: *Scratch, name: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, name);
    }

    fn write(self: *Scratch, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }
};

/// Run `action` with `fmt`'s `{[dir]s}` filled in by the scratch path, as the
/// dispatcher would — minus the reply, which has no webview to land in.
fn send(bridge: *FSBridge, action: []const u8, comptime fmt: []const u8, scratch: *const Scratch) !void {
    const payload = try std.fmt.allocPrint(testing.allocator, fmt, .{ .dir = scratch.path });
    defer testing.allocator.free(payload);
    try bridge.handleMessage(action, payload);
}

test "writeFile writes the decoded string, not its JSON escapes" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // Byte for byte what `craft.fs.writeFile(p, 'line one\nline two …')`
    // posts as `d`. Every escape used to reach the file as written here.
    try send(&bridge, "writeFile",
        \\{{"path":"{[dir]s}/out.txt","data":"line one\nline \"two\"\tC:\\dir caf\u00e9 \ud83d\ude00"}}
    , &scratch);
    const written = try scratch.read("out.txt");
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("line one\nline \"two\"\tC:\\dir caf\u{e9} \u{1F600}", written);
}

test "writeFile decodes the legacy content field too" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    try send(&bridge, "writeFile",
        \\{{"path":"{[dir]s}/legacy.txt","content":"a\nb"}}
    , &scratch);
    const written = try scratch.read("legacy.txt");
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("a\nb", written);
}

test "appendFile appends the decoded string" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    try send(&bridge, "writeFile",
        \\{{"path":"{[dir]s}/log.txt","data":"first\n"}}
    , &scratch);
    try send(&bridge, "appendFile",
        \\{{"path":"{[dir]s}/log.txt","data":"\"second\" \\ \u00fc\n"}}
    , &scratch);
    const written = try scratch.read("log.txt");
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("first\n\"second\" \\ \u{fc}\n", written);
}

test "paths are decoded before they reach the filesystem" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // A `\u` escape and an escaped `/` in every path. Undecoded, the first
    // named a directory called `caf\u00e9` and the second a `\` directory, so
    // each call failed or landed somewhere the page never asked for. (No quote
    // or backslash in a name: Windows runs this too, and allows neither.)
    try send(&bridge, "mkdir",
        \\{{"path":"{[dir]s}\/caf\u00e9\/sub","recursive":true}}
    , &scratch);
    try send(&bridge, "writeFile",
        \\{{"path":"{[dir]s}/caf\u00e9/sub/note\u0020one.txt","data":"x"}}
    , &scratch);
    try send(&bridge, "copy",
        \\{{"from":"{[dir]s}/caf\u00e9/sub/note one.txt","to":"{[dir]s}\/caf\u00e9\/copied.txt"}}
    , &scratch);
    try send(&bridge, "move",
        \\{{"from":"{[dir]s}/caf\u00e9/copied.txt","to":"{[dir]s}/caf\u00e9/moved \u00f1.txt"}}
    , &scratch);

    const moved = try scratch.read("caf\u{e9}/moved \u{f1}.txt");
    defer testing.allocator.free(moved);
    try testing.expectEqualStrings("x", moved);

    try send(&bridge, "deleteFile",
        \\{{"path":"{[dir]s}/caf\u00e9/sub/note\u0020one.txt"}}
    , &scratch);
    try send(&bridge, "rmdir",
        \\{{"path":"{[dir]s}\/caf\u00e9\/sub"}}
    , &scratch);
    try testing.expectError(error.FileNotFound, scratch.tmp.dir.access(testing.io, "caf\u{e9}/sub", .{}));
}

test "watch stores the decoded id and path, and unwatch finds it by them" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // On macOS a watch is a real FSEvents stream, and the path must exist.
    // (Not created elsewhere: Windows allows no `"` in a name.)
    if (builtin.os.tag == .macos) try scratch.mkdir("a\"b");
    try send(&bridge, "watch",
        \\{{"id":"w\u00e9","path":"{[dir]s}/a\"b","recursive":true}}
    , &scratch);
    const entry = bridge.watchers.get("w\u{e9}") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, entry.path, "/a\"b"));
    try testing.expect(entry.recursive);

    try bridge.handleMessage("unwatch", "{\"id\":\"w\\u00e9\"}");
    try testing.expectEqual(@as(usize, 0), bridge.watchers.count());
}

test "a second watch under a live id replaces the first rather than leaking it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // The page names watches, so a reload that restarts its counter can send an
    // id native still holds. `put` alone orphaned the old entry's strings,
    // which `testing.allocator` reports as a leak — and on macOS, the first
    // entry's stream with them.
    try scratch.mkdir("first");
    try scratch.mkdir("second");
    try send(&bridge, "watch",
        \\{{"id":"w1","path":"{[dir]s}/first"}}
    , &scratch);
    try send(&bridge, "watch",
        \\{{"id":"w1","path":"{[dir]s}/second","recursive":true}}
    , &scratch);
    try testing.expectEqual(@as(usize, 1), bridge.watchers.count());
    const entry = bridge.watchers.get("w1") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, entry.path, "/second"));
    try testing.expect(entry.recursive);
}

test "a watch without an id is refused, not registered" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // What `craft.fs.watch` used to post. Reported to the page as MISSING_DATA
    // by `handleMessage`; here, all there is to see is that nothing was kept.
    try send(&bridge, "watch",
        \\{{"path":"{[dir]s}","callbackId":"cb1"}}
    , &scratch);
    try testing.expectEqual(@as(usize, 0), bridge.watchers.count());
}

test "copy and move still take the legacy src and dest spelling" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    try send(&bridge, "writeFile",
        \\{{"path":"{[dir]s}/a.txt","data":"a"}}
    , &scratch);
    try send(&bridge, "copy",
        \\{{"src":"{[dir]s}/a.txt","dest":"{[dir]s}/b.txt"}}
    , &scratch);
    try send(&bridge, "move",
        \\{{"src":"{[dir]s}/b.txt","dest":"{[dir]s}/c.txt"}}
    , &scratch);
    const moved = try scratch.read("c.txt");
    defer testing.allocator.free(moved);
    try testing.expectEqualStrings("a", moved);
}

test "every action answers an empty or partial payload without failing the dispatch" {
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // `handleMessage` reports a bad payload to the page; it must never return
    // an error to the dispatcher, crash, or leak doing so.
    const actions = [_][]const u8{
        "readFile", "writeFile",  "appendFile", "deleteFile",    "exists",       "stat",
        "readDir",  "mkdir",      "rmdir",      "copy",          "move",         "watch",
        "unwatch",  "getHomeDir", "getTempDir", "getAppDataDir", "noSuchAction",
    };
    const payloads = [_][]const u8{ "", "{}", "{\"callbackId\":\"cb1\"}", "{\"id\":\"w1\"}", "not json" };
    for (actions) |action| {
        for (payloads) |payload| try bridge.handleMessage(action, payload);
    }
    try testing.expectEqual(@as(usize, 0), bridge.watchers.count());
}

test "on macOS a watch on a path that does not exist is refused, not registered" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var scratch = try Scratch.init();
    defer scratch.deinit();
    var bridge = FSBridge.init(testing.allocator);
    defer bridge.deinit();

    // FSEvents would stream a missing path without complaint and never report
    // anything; the page is told NOT_FOUND instead, as `node:fs.watch` says
    // ENOENT.
    try send(&bridge, "watch",
        \\{{"id":"w1","path":"{[dir]s}/missing"}}
    , &scratch);
    try testing.expectEqual(@as(usize, 0), bridge.watchers.count());
}

/// What a test watch heard, and whether its sink was let go.
const Heard = struct {
    events: std.ArrayListUnmanaged(Event) = .empty,
    released: usize = 0,

    const Event = struct { change: fs_watch.ChangeType, path: []u8 };

    fn sink(self: *Heard) fs_watch.Sink {
        return .{ .context = self, .deliver = deliver, .release = release };
    }

    fn deliver(context: ?*anyopaque, id: []const u8, change: fs_watch.ChangeType, path: []const u8) void {
        const self: *Heard = @ptrCast(@alignCast(context.?));
        std.debug.assert(std.mem.eql(u8, id, "e2e"));
        const owned = testing.allocator.dupe(u8, path) catch return;
        self.events.append(testing.allocator, .{ .change = change, .path = owned }) catch testing.allocator.free(owned);
    }

    fn release(context: ?*anyopaque) void {
        const self: *Heard = @ptrCast(@alignCast(context.?));
        self.released += 1;
    }

    fn deinit(self: *Heard) void {
        for (self.events.items) |event| testing.allocator.free(event.path);
        self.events.deinit(testing.allocator);
    }

    /// Whether a `change` for a path ending in `suffix` has arrived.
    fn saw(self: *const Heard, change: fs_watch.ChangeType, suffix: []const u8) bool {
        for (self.events.items) |event| {
            if (event.change == change and std.mem.endsWith(u8, event.path, suffix)) return true;
        }
        return false;
    }

    fn sawPath(self: *const Heard, suffix: []const u8) bool {
        for (self.events.items) |event| {
            if (std.mem.endsWith(u8, event.path, suffix)) return true;
        }
        return false;
    }

    /// Run the main run loop, which drains the main dispatch queue FSEvents
    /// delivers on, until `change` for `suffix` arrives or five seconds pass.
    fn waitFor(self: *const Heard, change: fs_watch.ChangeType, suffix: []const u8) bool {
        var waited: usize = 0;
        while (waited < 100) : (waited += 1) {
            if (self.saw(change, suffix)) return true;
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 1);
        }
        return self.saw(change, suffix);
    }
};

extern "c" fn CFRunLoopRunInMode(mode: ?*anyopaque, seconds: f64, return_after_source_handled: u8) i32;
extern const kCFRunLoopDefaultMode: ?*anyopaque;
extern "c" fn pthread_main_np() c_int;

test "a native watch hears a file appear, change, move and go, and nothing after it stops" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // The stream delivers on the main queue, which only the main thread's run
    // loop drains. A runner that called this from another thread could never
    // hear anything, so that is a skip, not a failure.
    if (pthread_main_np() == 0) return error.SkipZigTest;

    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.mkdir("sub");

    var heard: Heard = .{};
    defer heard.deinit();
    // Non-recursive, on the path as the test spells it (relative), so the
    // reported paths must come back spelled that way too, not as realpaths.
    const watch = try fs_watch.start(testing.allocator, "e2e", scratch.path, false, heard.sink());
    var stopped = false;
    defer if (!stopped) fs_watch.stop(watch);

    try scratch.write("sub/deep.txt", "below the watch");
    try scratch.write("new.txt", "one");
    try testing.expect(heard.waitFor(.create, "/new.txt"));
    // Written first, so had it been delivered it would have arrived first.
    try testing.expect(!heard.sawPath("/sub/deep.txt"));
    for (heard.events.items) |event| try testing.expect(std.mem.startsWith(u8, event.path, scratch.path));

    // A quiet spell, so the write is its own event rather than coalesced into
    // the creation.
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, 0);
    try scratch.write("new.txt", "two");
    try testing.expect(heard.waitFor(.modify, "/new.txt"));

    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, 0);
    try std.Io.Dir.rename(scratch.tmp.dir, "new.txt", scratch.tmp.dir, "moved.txt", testing.io);
    try testing.expect(heard.waitFor(.rename, "/moved.txt"));

    // `ItemRenamed` sticks to the new name, and must not hide its deletion.
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, 0);
    try scratch.tmp.dir.deleteFile(testing.io, "moved.txt");
    try testing.expect(heard.waitFor(.delete, "/moved.txt"));

    fs_watch.stop(watch);
    stopped = true;
    try testing.expectEqual(@as(usize, 1), heard.released);

    const before = heard.events.items.len;
    try scratch.write("after.txt", "unheard");
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, 0);
    try testing.expectEqual(before, heard.events.items.len);
}

test "a native watch on one file hears only that file" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (pthread_main_np() == 0) return error.SkipZigTest;

    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.write("watched.txt", "a");

    const file = try std.fmt.allocPrint(testing.allocator, "{s}/watched.txt", .{scratch.path});
    defer testing.allocator.free(file);

    var heard: Heard = .{};
    defer heard.deinit();
    const watch = try fs_watch.start(testing.allocator, "e2e", file, true, heard.sink());
    defer fs_watch.stop(watch);

    try scratch.write("neighbour.txt", "b");
    try scratch.write("watched.txt", "changed");
    try testing.expect(heard.waitFor(.modify, "/watched.txt"));
    try testing.expect(!heard.sawPath("/neighbour.txt"));
    for (heard.events.items) |event| try testing.expectEqualStrings(file, event.path);
}
