//! The desktop fs bridge end to end: a payload as `craft.fs.*` posts it, the
//! file it leaves behind, read back.
//!
//! Its own root, not tests inside `bridge_fs.zig`. That file is reached from
//! `global_state.zig`, so any test there rides along in every binary that
//! touches global state — `log.zig`'s and `bridge_log.zig`'s among them, which
//! link only libc. These handlers reply through `bridge.evalJS`, which reaches
//! the platform's webview code, and an unlinked binary cannot resolve it.

const std = @import("std");
const bridge_fs = @import("bridge_fs.zig");

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
    // which `testing.allocator` reports as a leak.
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
