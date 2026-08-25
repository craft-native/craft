const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");
const io_context = @import("io_context.zig");
const json_utils = @import("json_utils.zig");

const BridgeError = bridge_error.BridgeError;

/// File watcher entry
const WatchEntry = struct {
    id: []const u8,
    path: []const u8,
    callback_id: []const u8,
    recursive: bool,
};

/// File system bridge for file operations
pub const FSBridge = struct {
    allocator: std.mem.Allocator,
    watchers: std.StringHashMap(WatchEntry),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .watchers = std.StringHashMap(WatchEntry).init(allocator),
        };
    }

    /// Free the watcher map and every owned slice it holds. Call this when
    /// the bridge is being torn down — without it, every restart leaks the
    /// per-watcher allocations.
    pub fn deinit(self: *Self) void {
        var it = self.watchers.iterator();
        while (it.next()) |entry| {
            const watcher = entry.value_ptr.*;
            self.allocator.free(watcher.id);
            self.allocator.free(watcher.path);
            self.allocator.free(watcher.callback_id);
            // The hashmap key was duped from `watcher.id` at insert time;
            // freeing `watcher.id` above already covers it. (If a future
            // change ever duplicates the key separately, also free
            // `entry.key_ptr.*` here.)
        }
        self.watchers.deinit();
    }

    /// Handle file system-related messages from JavaScript
    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        self.handleMessageInternal(action, data) catch |err| {
            self.reportError(action, err);
        };
    }

    fn handleMessageInternal(self: *Self, action: []const u8, data: []const u8) !void {
        if (std.mem.eql(u8, action, "readFile")) {
            try self.readFile(data);
        } else if (std.mem.eql(u8, action, "writeFile")) {
            try self.writeFile(data);
        } else if (std.mem.eql(u8, action, "appendFile")) {
            try self.appendFile(data);
        } else if (std.mem.eql(u8, action, "deleteFile")) {
            try self.deleteFile(data);
        } else if (std.mem.eql(u8, action, "exists")) {
            try self.exists(data);
        } else if (std.mem.eql(u8, action, "stat")) {
            try self.stat(data);
        } else if (std.mem.eql(u8, action, "readDir")) {
            try self.readDir(data);
        } else if (std.mem.eql(u8, action, "mkdir")) {
            try self.mkdir(data);
        } else if (std.mem.eql(u8, action, "rmdir")) {
            try self.rmdir(data);
        } else if (std.mem.eql(u8, action, "copy")) {
            try self.copy(data);
        } else if (std.mem.eql(u8, action, "move")) {
            try self.move(data);
        } else if (std.mem.eql(u8, action, "watch")) {
            try self.watch(data);
        } else if (std.mem.eql(u8, action, "unwatch")) {
            try self.unwatch(data);
        } else if (std.mem.eql(u8, action, "getHomeDir")) {
            try self.getHomeDir();
        } else if (std.mem.eql(u8, action, "getTempDir")) {
            try self.getTempDir();
        } else if (std.mem.eql(u8, action, "getAppDataDir")) {
            try self.getAppDataDir();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn reportError(self: *Self, action: []const u8, err: anyerror) void {
        const bridge_err: BridgeError = switch (err) {
            BridgeError.MissingData => BridgeError.MissingData,
            BridgeError.InvalidJSON => BridgeError.InvalidJSON,
            BridgeError.NotFound => BridgeError.NotFound,
            BridgeError.PermissionDenied => BridgeError.PermissionDenied,
            else => BridgeError.NativeCallFailed,
        };
        bridge_error.sendErrorToJS(self.allocator, action, bridge_err);
    }

    /// Read file contents
    /// JSON: {"path": "/path/to/file", "encoding": "utf8", "callbackId": "cb1"}
    fn readFile(self: *Self, data: []const u8) !void {
        // Use the shared JSON helper — it handles `\"` inside string values.
        // Previously each bridge field was parsed by `indexOfPos(..., "\"")`
        // which truncated at the first backslash-escaped quote.
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] readFile: {s}\n", .{path});

        // Read file
        const file = std.Io.Dir.cwd().openFile(io_context.get(), path, .{}) catch |err| {
            self.sendFSError(callback_id, "readFile", path, err);
            return;
        };
        defer file.close(io_context.get());

        // Get file size
        const file_stat = file.stat(io_context.get()) catch |err| {
            self.sendFSError(callback_id, "readFile", path, err);
            return;
        };
        const size = file_stat.size;

        // Allocate and read using readPositional
        const content = self.allocator.alloc(u8, size) catch |err| {
            self.sendFSError(callback_id, "readFile", path, err);
            return;
        };
        defer self.allocator.free(content);

        const bytes_read = file.readPositional(io_context.get(), &.{content}, 0) catch |err| {
            self.sendFSError(callback_id, "readFile", path, err);
            return;
        };

        // Only send the bytes we actually read. Previously we sent the full
        // `content` allocation, so any short read would leak uninitialized
        // memory past the file's end into the webview.
        self.sendFSResult(callback_id, "readFile", content[0..bytes_read]);
    }

    /// Write file contents
    /// JSON: {"path": "/path/to/file", "content": "data", "callbackId": "cb1"}
    fn writeFile(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const content = json_utils.getString(data, "content") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] writeFile: {s} ({d} bytes)\n", .{ path, content.len });

        // Write file
        const file = std.Io.Dir.cwd().createFile(io_context.get(), path, .{}) catch |err| {
            self.sendFSError(callback_id, "writeFile", path, err);
            return;
        };
        defer file.close(io_context.get());

        file.writeStreamingAll(io_context.get(), content) catch |err| {
            self.sendFSError(callback_id, "writeFile", path, err);
            return;
        };

        self.sendFSSuccess(callback_id, "writeFile");
    }

    /// Append to file
    /// JSON: {"path": "/path/to/file", "content": "data", "callbackId": "cb1"}
    fn appendFile(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const content = json_utils.getString(data, "content") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] appendFile: {s}\n", .{path});

        const file = std.Io.Dir.cwd().openFile(io_context.get(), path, .{ .mode = .write_only }) catch |err| {
            self.sendFSError(callback_id, "appendFile", path, err);
            return;
        };
        defer file.close(io_context.get());

        // Seek to end before writing so `appendFile` actually appends.
        // Previously `writeStreamingAll` started at offset 0 and overwrote
        // the existing file prefix — a silent data-loss bug.
        const file_stat = file.stat(io_context.get()) catch |err| {
            self.sendFSError(callback_id, "appendFile", path, err);
            return;
        };
        _ = file.writePositional(io_context.get(), &.{content}, file_stat.size) catch |err| {
            self.sendFSError(callback_id, "appendFile", path, err);
            return;
        };

        self.sendFSSuccess(callback_id, "appendFile");
    }

    /// Delete file
    /// JSON: {"path": "/path/to/file", "callbackId": "cb1"}
    fn deleteFile(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] deleteFile: {s}\n", .{path});

        std.Io.Dir.cwd().deleteFile(io_context.get(), path) catch |err| {
            self.sendFSError(callback_id, "deleteFile", path, err);
            return;
        };

        self.sendFSSuccess(callback_id, "deleteFile");
    }

    /// Check if path exists
    /// JSON: {"path": "/path/to/check", "callbackId": "cb1"}
    fn exists(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        // Only treat `FileNotFound` as "does not exist". Previously ANY error
        // (permissions, IO, etc.) was reported as non-existent, which mis-led
        // callers that were actually being rejected by the OS.
        const file_exists = if (std.Io.Dir.cwd().access(io_context.get(), path, .{}))
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => {
                self.sendFSError(callback_id, "exists", path, err);
                return;
            },
        };

        self.sendFSBool(callback_id, "exists", file_exists);
    }

    /// Get file stats
    /// JSON: {"path": "/path/to/file", "callbackId": "cb1"}
    fn stat(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        const file_stat = std.Io.Dir.cwd().statFile(io_context.get(), path, .{}) catch |err| {
            self.sendFSError(callback_id, "stat", path, err);
            return;
        };

        const is_dir = file_stat.kind == .directory;
        const is_file = file_stat.kind == .file;
        const size = file_stat.size;
        // In Zig 0.16, mtime type changed - use 0 as placeholder
        const mtime: i64 = 0;

        const bridge = @import("bridge.zig");

        // Escape the user-supplied callback_id before embedding in the JS.
        var cb_buf: [128]u8 = undefined;
        const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

        var buf: [512]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftFSCallback)window.__craftFSCallback('{s}','stat',{{
            \\"isDirectory":{},
            \\"isFile":{},
            \\"size":{d},
            \\"mtime":{d}
            \\}});
        , .{ cb_esc, is_dir, is_file, size, mtime }) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for stat callback: {}", .{err});
        };
    }

    /// Read directory contents
    /// JSON: {"path": "/path/to/dir", "callbackId": "cb1"}
    fn readDir(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] readDir: {s}\n", .{path});

        var dir = std.Io.Dir.cwd().openDir(io_context.get(), path, .{ .iterate = true }) catch |err| {
            self.sendFSError(callback_id, "readDir", path, err);
            return;
        };
        defer dir.close(io_context.get());

        // Build JSON array of entries. Filenames are escaped inline so that
        // names containing `"`, `\`, or control bytes don't produce invalid
        // JSON the webview then fails to parse.
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;
        if (pos + 1 > buf.len) return;
        buf[pos] = '[';
        pos += 1;

        var first = true;
        var iter = dir.iterate();
        while (iter.next(io_context.get()) catch null) |entry| {
            if (!first) {
                if (pos + 1 > buf.len) break;
                buf[pos] = ',';
                pos += 1;
            }
            first = false;

            const is_dir = entry.kind == .directory;
            // Emit the `{"name":"` prefix, then the escaped filename, then
            // the closing `","isDirectory":…}` suffix — all with bounds
            // checks so a long name aborts the entry rather than overflowing.
            const prefix = "{\"name\":\"";
            if (pos + prefix.len > buf.len) break;
            @memcpy(buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;

            var name_overflowed = false;
            for (entry.name) |c| {
                const esc: []const u8 = switch (c) {
                    '"' => "\\\"",
                    '\\' => "\\\\",
                    '\n' => "\\n",
                    '\r' => "\\r",
                    '\t' => "\\t",
                    else => blk: {
                        if (c < 0x20) {
                            // Control byte → \u00XX
                            var hex_tmp: [6]u8 = undefined;
                            const hex_slice = std.fmt.bufPrint(&hex_tmp, "\\u{x:0>4}", .{c}) catch {
                                name_overflowed = true;
                                break :blk "";
                            };
                            // Write the formatted bytes through the block.
                            if (pos + hex_slice.len > buf.len) {
                                name_overflowed = true;
                                break :blk "";
                            }
                            @memcpy(buf[pos..][0..hex_slice.len], hex_slice);
                            pos += hex_slice.len;
                            break :blk "";
                        }
                        break :blk &[_]u8{c};
                    },
                };
                if (esc.len == 0) {
                    if (name_overflowed) break;
                    continue;
                }
                if (pos + esc.len > buf.len) {
                    name_overflowed = true;
                    break;
                }
                @memcpy(buf[pos..][0..esc.len], esc);
                pos += esc.len;
            }
            if (name_overflowed) break;

            const suffix = if (is_dir) "\",\"isDirectory\":true}" else "\",\"isDirectory\":false}";
            if (pos + suffix.len > buf.len) break;
            @memcpy(buf[pos..][0..suffix.len], suffix);
            pos += suffix.len;
        }

        if (pos + 1 > buf.len) return;
        buf[pos] = ']';
        pos += 1;

        const bridge = @import("bridge.zig");

        var cb_buf: [128]u8 = undefined;
        const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;

        var js_buf: [8500]u8 = undefined;
        const js = std.fmt.bufPrint(&js_buf,
            \\if(window.__craftFSCallback)window.__craftFSCallback('{s}','readDir',{s});
        , .{ cb_esc, buf[0..pos] }) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for readDir callback: {}", .{err});
        };
    }

    /// Create directory
    /// JSON: {"path": "/path/to/dir", "recursive": true, "callbackId": "cb1"}
    fn mkdir(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";
        const recursive = json_utils.getBool(data, "recursive") orelse false;

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] mkdir: {s} (recursive={})\n", .{ path, recursive });

        if (recursive) {
            std.Io.Dir.cwd().createDirPath(io_context.get(), path) catch |err| {
                self.sendFSError(callback_id, "mkdir", path, err);
                return;
            };
        } else {
            std.Io.Dir.cwd().createDir(io_context.get(), path, .default_dir) catch |err| {
                self.sendFSError(callback_id, "mkdir", path, err);
                return;
            };
        }

        self.sendFSSuccess(callback_id, "mkdir");
    }

    /// Remove directory
    /// JSON: {"path": "/path/to/dir", "callbackId": "cb1"}
    fn rmdir(self: *Self, data: []const u8) !void {
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] rmdir: {s}\n", .{path});

        std.Io.Dir.cwd().deleteDir(io_context.get(), path) catch |err| {
            self.sendFSError(callback_id, "rmdir", path, err);
            return;
        };

        self.sendFSSuccess(callback_id, "rmdir");
    }

    /// Copy file
    /// JSON: {"src": "/path/from", "dest": "/path/to", "callbackId": "cb1"}
    fn copy(self: *Self, data: []const u8) !void {
        const src = json_utils.getString(data, "src") orelse "";
        const dest = json_utils.getString(data, "dest") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (src.len == 0 or dest.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] copy: {s} -> {s}\n", .{ src, dest });

        // In Zig 0.16, copyFile uses dest_dir parameter
        const d = std.Io.Dir.cwd();
        std.Io.Dir.copyFile(d, src, d, dest, io_context.get(), .{}) catch |err| {
            self.sendFSError(callback_id, "copy", src, err);
            return;
        };

        self.sendFSSuccess(callback_id, "copy");
    }

    /// Move/rename file
    /// JSON: {"src": "/path/from", "dest": "/path/to", "callbackId": "cb1"}
    fn move(self: *Self, data: []const u8) !void {
        const src = json_utils.getString(data, "src") orelse "";
        const dest = json_utils.getString(data, "dest") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";

        if (src.len == 0 or dest.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] move: {s} -> {s}\n", .{ src, dest });

        const d = std.Io.Dir.cwd();
        std.Io.Dir.rename(d, src, d, dest, io_context.get()) catch |err| {
            self.sendFSError(callback_id, "move", src, err);
            return;
        };

        self.sendFSSuccess(callback_id, "move");
    }

    /// Watch a file or directory for changes
    /// JSON: {"id": "watch1", "path": "/path/to/watch", "recursive": false, "callbackId": "cb1"}
    fn watch(self: *Self, data: []const u8) !void {
        const id = json_utils.getString(data, "id") orelse "";
        const path = json_utils.getString(data, "path") orelse "";
        const callback_id = json_utils.getString(data, "callbackId") orelse "";
        const recursive = json_utils.getBool(data, "recursive") orelse false;

        if (id.len == 0 or path.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] watch: {s} -> {s} (recursive={})\n", .{ id, path, recursive });

        // Store watcher entry. Each dupe has its own errdefer so an OOM
        // partway through doesn't leak the earlier allocations. Previously
        // a failing `path_owned`/`callback_owned`/`put` would leak every
        // buffer allocated so far.
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const path_owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_owned);
        const callback_owned = try self.allocator.dupe(u8, callback_id);
        errdefer self.allocator.free(callback_owned);

        try self.watchers.put(id_owned, WatchEntry{
            .id = id_owned,
            .path = path_owned,
            .callback_id = callback_owned,
            .recursive = recursive,
        });

        // Note: Actual file system watching would require FSEvents on macOS
        // For now, this just registers the intent to watch
        self.sendFSSuccess(callback_id, "watch");
    }

    /// Stop watching
    /// JSON: {"id": "watch1"}
    fn unwatch(self: *Self, data: []const u8) !void {
        const id = json_utils.getString(data, "id") orelse "";

        if (id.len == 0) return BridgeError.MissingData;

        if (comptime builtin.mode == .debug)
            std.debug.print("[FSBridge] unwatch: {s}\n", .{id});

        if (self.watchers.fetchRemove(id)) |kv| {
            self.allocator.free(kv.value.id);
            self.allocator.free(kv.value.path);
            self.allocator.free(kv.value.callback_id);
        }
    }

    /// An environment variable as a slice, or null when it is unset.
    ///
    /// libc rather than std: this build links libc everywhere, and `std.posix`
    /// has no `getenv` in this compiler version.
    fn envOrEmpty(name: [*:0]const u8) ?[]const u8 {
        const raw = std.c.getenv(name) orelse return null;
        return std.mem.span(raw);
    }

    /// Get home directory
    fn getHomeDir(self: *Self) !void {
        _ = self;
        const bridge = @import("bridge.zig");

        if (comptime builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // Get home directory using NSFileManager
            const NSHomeDirectory = macos.getClass("NSFileManager");
            const fm = macos.msgSend0(NSHomeDirectory, "defaultManager");
            const home_url = macos.msgSend0(fm, "homeDirectoryForCurrentUser");
            const home_path = macos.msgSend0(home_url, "path");

            if (home_path) |path_obj| {
                const cstr = macos.msgSend0(path_obj, "UTF8String");
                if (cstr) |c| {
                    const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(c)));

                    // Escape — a username containing `'` (possible on macOS)
                    // would otherwise close the JS string literal and allow
                    // injection via `/Users/evil';alert(1)//`.
                    var path_buf: [1024]u8 = undefined;
                    const path_esc = bridge_error.escapeJsSingleQuoted(&path_buf, path_str) catch return;

                    var buf: [1280]u8 = undefined;
                    const js = std.fmt.bufPrint(&buf,
                        \\if(window.__craftFSCallback)window.__craftFSCallback('','getHomeDir','{s}');
                    , .{path_esc}) catch return;

                    bridge.evalJS(js) catch |err| {
                        std.log.debug("JS eval failed for getHomeDir callback: {}", .{err});
                    };
                }
            }
        } else {
            // Cross-platform: use HOME env var (Linux/Windows).
            //
            // `std.c.getenv`, not `std.posix.getenv` — the latter does not
            // exist in this Zig at all (`@hasDecl(std.posix, "getenv")` is
            // false even on macOS). It compiled only because this branch is
            // dead on macOS and Zig never analysed it; the moment anything
            // compiled the file for another target it failed.
            const home = envOrEmpty("HOME") orelse
                (if (comptime builtin.os.tag == .windows) envOrEmpty("USERPROFILE") orelse "" else "");

            if (home.len > 0) {
                // Same escape as above — env vars can contain any bytes.
                var path_buf: [1024]u8 = undefined;
                const home_esc = bridge_error.escapeJsSingleQuoted(&path_buf, home) catch return;

                var buf: [1280]u8 = undefined;
                const js = std.fmt.bufPrint(&buf,
                    \\if(window.__craftFSCallback)window.__craftFSCallback('','getHomeDir','{s}');
                , .{home_esc}) catch return;

                bridge.evalJS(js) catch |err| {
                    std.log.debug("JS eval failed for getHomeDir callback: {}", .{err});
                };
            }
        }
    }

    /// Get temp directory
    fn getTempDir(self: *Self) !void {
        _ = self;
        const bridge = @import("bridge.zig");

        if (comptime builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            const NSFileManager = macos.getClass("NSFileManager");
            const fm = macos.msgSend0(NSFileManager, "defaultManager");
            const temp_url = macos.msgSend0(fm, "temporaryDirectory");
            const temp_path = macos.msgSend0(temp_url, "path");

            if (temp_path) |path_obj| {
                const cstr = macos.msgSend0(path_obj, "UTF8String");
                if (cstr) |c| {
                    const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(c)));

                    // Escape path before injecting into JS string literal.
                    var path_buf: [1024]u8 = undefined;
                    const path_esc = bridge_error.escapeJsSingleQuoted(&path_buf, path_str) catch return;

                    var buf: [1280]u8 = undefined;
                    const js = std.fmt.bufPrint(&buf,
                        \\if(window.__craftFSCallback)window.__craftFSCallback('','getTempDir','{s}');
                    , .{path_esc}) catch return;

                    bridge.evalJS(js) catch |err| {
                        std.log.debug("JS eval failed for getTempDir callback: {}", .{err});
                    };
                }
            }
        } else {
            // Cross-platform: use TMPDIR or /tmp
            const tmp = std.posix.getenv("TMPDIR") orelse
                if (comptime builtin.os.tag == .windows) std.posix.getenv("TEMP") orelse "C:\\Temp" else "/tmp";

            // Windows default uses a backslash which Zig reads as a JS escape
            // in the string literal — escape before embedding.
            var path_buf: [1024]u8 = undefined;
            const tmp_esc = bridge_error.escapeJsSingleQuoted(&path_buf, tmp) catch return;

            var buf: [1280]u8 = undefined;
            const js = std.fmt.bufPrint(&buf,
                \\if(window.__craftFSCallback)window.__craftFSCallback('','getTempDir','{s}');
            , .{tmp_esc}) catch return;

            bridge.evalJS(js) catch |err| {
                std.log.debug("JS eval failed for getTempDir callback: {}", .{err});
            };
        }
    }

    /// Get app data directory (Application Support)
    fn getAppDataDir(self: *Self) !void {
        _ = self;
        const bridge = @import("bridge.zig");

        if (comptime builtin.os.tag == .macos) {
            const macos = @import("macos.zig");

            // NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
            const NSFileManager = macos.getClass("NSFileManager");
            const fm = macos.msgSend0(NSFileManager, "defaultManager");

            // Use URLsForDirectory:inDomains:
            // NSApplicationSupportDirectory = 14, NSUserDomainMask = 1
            const urls = macos.msgSend2(fm, "URLsForDirectory:inDomains:", @as(c_ulong, 14), @as(c_ulong, 1));
            if (urls) |url_array| {
                const first_url = macos.msgSend1(url_array, "firstObject", @as(?*anyopaque, null));
                if (first_url) |url| {
                    const path_obj = macos.msgSend0(url, "path");
                    if (path_obj) |p| {
                        const cstr = macos.msgSend0(p, "UTF8String");
                        if (cstr) |c| {
                            const path_str = std.mem.span(@as([*:0]const u8, @ptrCast(c)));

                            var esc_buf: [1024]u8 = undefined;
                            const path_esc = bridge_error.escapeJsSingleQuoted(&esc_buf, path_str) catch return;

                            var buf: [1280]u8 = undefined;
                            const js = std.fmt.bufPrint(&buf,
                                \\if(window.__craftFSCallback)window.__craftFSCallback('','getAppDataDir','{s}');
                            , .{path_esc}) catch return;

                            bridge.evalJS(js) catch |err| {
                                std.log.debug("JS eval failed for getAppDataDir callback: {}", .{err});
                            };
                        }
                    }
                }
            }
        } else if (comptime builtin.os.tag == .linux) {
            // XDG Base Directory: ~/.local/share or $XDG_DATA_HOME
            const app_data = std.posix.getenv("XDG_DATA_HOME") orelse "";
            var path_buf: [512]u8 = undefined;
            const app_data_path = if (app_data.len > 0)
                app_data
            else blk: {
                const home = std.posix.getenv("HOME") orelse "";
                if (home.len == 0) break :blk "";
                break :blk std.fmt.bufPrint(&path_buf, "{s}/.local/share", .{home}) catch "";
            };

            if (app_data_path.len > 0) {
                var esc_buf: [1024]u8 = undefined;
                const path_esc = bridge_error.escapeJsSingleQuoted(&esc_buf, app_data_path) catch return;

                var buf: [1280]u8 = undefined;
                const js = std.fmt.bufPrint(&buf,
                    \\if(window.__craftFSCallback)window.__craftFSCallback('','getAppDataDir','{s}');
                , .{path_esc}) catch return;

                bridge.evalJS(js) catch |err| {
                    std.log.debug("JS eval failed for getAppDataDir callback: {}", .{err});
                };
            }
        } else if (comptime builtin.os.tag == .windows) {
            // Windows: %APPDATA% contains backslashes which are JS escapes —
            // must be escaped before embedding in the string literal.
            const app_data = std.posix.getenv("APPDATA") orelse "";

            if (app_data.len > 0) {
                var esc_buf: [1024]u8 = undefined;
                const path_esc = bridge_error.escapeJsSingleQuoted(&esc_buf, app_data) catch return;

                var buf: [1280]u8 = undefined;
                const js = std.fmt.bufPrint(&buf,
                    \\if(window.__craftFSCallback)window.__craftFSCallback('','getAppDataDir','{s}');
                , .{path_esc}) catch return;

                bridge.evalJS(js) catch |err| {
                    std.log.debug("JS eval failed for getAppDataDir callback: {}", .{err});
                };
            }
        }
    }

    /// Send success callback
    fn sendFSSuccess(_: *Self, callback_id: []const u8, action: []const u8) void {
        const bridge = @import("bridge.zig");

        // Escape callback_id/action — see `sendFSError` for rationale.
        var cb_buf: [128]u8 = undefined;
        var act_buf: [64]u8 = undefined;
        const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
        const act_esc = bridge_error.escapeJsSingleQuoted(&act_buf, action) catch return;

        var buf: [512]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftFSCallback)window.__craftFSCallback('{s}','{s}',{{success:true}});
        , .{ cb_esc, act_esc }) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for FS success callback: {}", .{err});
        };
    }

    /// Send boolean result callback
    fn sendFSBool(_: *Self, callback_id: []const u8, action: []const u8, value: bool) void {
        const bridge = @import("bridge.zig");

        var cb_buf: [128]u8 = undefined;
        var act_buf: [64]u8 = undefined;
        const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
        const act_esc = bridge_error.escapeJsSingleQuoted(&act_buf, action) catch return;

        var buf: [512]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftFSCallback)window.__craftFSCallback('{s}','{s}',{});
        , .{ cb_esc, act_esc, value }) catch return;

        bridge.evalJS(js) catch |err| {
            std.log.debug("JS eval failed for FS bool callback: {}", .{err});
        };
    }

    /// Send file content result (base64 encoded for safety)
    fn sendFSResult(_: *Self, callback_id: []const u8, action: []const u8, content: []const u8) void {
        const bridge = @import("bridge.zig");

        // For text content, escape and send directly
        // In production, would want to base64 encode binary files
        var buf: [65536]u8 = undefined;
        var pos: usize = 0;

        // Escape callback_id and action before placing them in the JS
        // prefix — previously only the content payload was escaped, which
        // left the prefix vulnerable to injection via crafted IDs.
        var cb_buf: [128]u8 = undefined;
        var act_buf: [64]u8 = undefined;
        const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
        const act_esc = bridge_error.escapeJsSingleQuoted(&act_buf, action) catch return;

        const prefix = std.fmt.bufPrint(buf[pos..],
            \\if(window.__craftFSCallback)window.__craftFSCallback('{s}','{s}','
        , .{ cb_esc, act_esc }) catch return;
        pos += prefix.len;

        // Escape content for JS string
        for (content) |c| {
            if (pos >= buf.len - 10) break;
            switch (c) {
                '\n' => {
                    buf[pos] = '\\';
                    pos += 1;
                    buf[pos] = 'n';
                    pos += 1;
                },
                '\r' => {
                    buf[pos] = '\\';
                    pos += 1;
                    buf[pos] = 'r';
                    pos += 1;
                },
                '\t' => {
                    buf[pos] = '\\';
                    pos += 1;
                    buf[pos] = 't';
                    pos += 1;
                },
                '\\' => {
                    buf[pos] = '\\';
                    pos += 1;
                    buf[pos] = '\\';
                    pos += 1;
                },
                '\'' => {
                    buf[pos] = '\\';
                    pos += 1;
                    buf[pos] = '\'';
                    pos += 1;
                },
                else => {
                    buf[pos] = c;
                    pos += 1;
                },
            }
        }

        const suffix = "');";
        @memcpy(buf[pos .. pos + suffix.len], suffix);
        pos += suffix.len;

        bridge.evalJS(buf[0..pos]) catch |eval_err| {
            std.log.debug("JS eval failed for FS result callback: {}", .{eval_err});
        };
    }

    /// Send error callback
    fn sendFSError(_: *Self, callback_id: []const u8, action: []const u8, path: []const u8, err: anyerror) void {
        const bridge = @import("bridge.zig");

        const err_msg = switch (err) {
            error.FileNotFound => "File not found",
            error.AccessDenied => "Access denied",
            error.IsDir => "Is a directory",
            error.NotDir => "Not a directory",
            error.PathAlreadyExists => "Path already exists",
            else => "Operation failed",
        };

        // Escape every field before embedding in the JS call. Without this,
        // filenames or callback IDs containing `'` / `\` / `\n` would break
        // the string literal and inject arbitrary JS into the webview.
        var cb_buf: [128]u8 = undefined;
        var act_buf: [64]u8 = undefined;
        var path_buf: [256]u8 = undefined;
        var msg_buf: [128]u8 = undefined;
        const cb_esc = bridge_error.escapeJsSingleQuoted(&cb_buf, callback_id) catch return;
        const act_esc = bridge_error.escapeJsSingleQuoted(&act_buf, action) catch return;
        const path_esc = bridge_error.escapeJsSingleQuoted(&path_buf, path) catch return;
        const msg_esc = bridge_error.escapeJsSingleQuoted(&msg_buf, err_msg) catch return;

        var buf: [1024]u8 = undefined;
        const js = std.fmt.bufPrint(&buf,
            \\if(window.__craftFSError)window.__craftFSError('{s}','{s}','{s}','{s}');
        , .{ cb_esc, act_esc, path_esc, msg_esc }) catch return;

        bridge.evalJS(js) catch |eval_err| {
            std.log.debug("JS eval failed for FS error callback: {}", .{eval_err});
        };
    }
};

const global_state = @import("global_state.zig");

/// Global accessors for the singleton FS bridge.
///
/// NOTE: these are **not** safe against concurrent mutation — swapping the
/// bridge while another thread is mid-call races with the reader. In practice
/// the bridge is installed once at startup (from the main thread) before any
/// worker submits FS messages; if you need to replace it at runtime, guard
/// the mutation with a higher-level lock.
pub fn getGlobalFSBridge() ?*FSBridge {
    return global_state.instance.getFsBridge();
}

pub fn setGlobalFSBridge(bridge: *FSBridge) void {
    global_state.instance.setFsBridge(bridge);
}
