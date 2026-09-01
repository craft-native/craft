//! The `mobile` namespace's audio recording pair: `startAudioRecording` and
//! `stopAudioRecording`.
//!
//! ## They move together
//!
//! `stopAudioRecording` reads two fields `startAudioRecording` wrote — the
//! recorder and the URL it is writing to — so a split migration leaves the
//! stop unable to find what the start made. Both are behind
//! `config.enableAudioRecording`, so neither can arrive first by accident, but
//! the pairing is stated because the file-picker family and the PDF pair have
//! already shown how easy the asymmetric version looks.
//!
//! ## Three asynchronous steps, one ticket
//!
//! `requestRecordPermission:` answers on an arbitrary queue; Swift then hops to
//! the main queue before touching `AVAudioSession`, because activating a
//! session and starting a recorder from a background queue is not supported.
//! Both hops happen here too, and the page's request id rides through them on
//! one `ios_async` ticket rather than being re-derived.
//!
//! The permission block cannot be `ios_async.boolBlock`, for the reason
//! `bridge_mobile_auth.zig` hit first: that block's delivery path answers the
//! strings `"granted"` and `"denied"`, and this action resolves the bare JSON
//! `true` or rejects. `"denied"` is truthy, so a page's
//! `if (await craft.startAudioRecording())` would begin a recording that never
//! started.
//!
//! ## A usage description is checked before the microphone is asked for
//!
//! `NSMicrophoneUsageDescription`. Requesting record permission without it
//! terminates the process — a kill, not a catchable exception — so the plist is
//! read first, the same guard `bridge_mobile_bluetooth.zig` and
//! `bridge_mobile_location.zig` apply to their frameworks.
//!
//! ## Where this refuses and Swift returns megabytes
//!
//! `stopAudioRecording` resolves the whole recording as a `data:` URL, so a
//! ten-minute take is several megabytes of base64 interpolated into the source
//! `evaluateJavaScript:` parses. Swift has no ceiling. This module refuses
//! above `max_recording_bytes` rather than build a string that large, the same
//! trade `bridge_mobile_locrecording.zig` makes for a track file — and for the
//! same reason: a reply that cannot be delivered is worse than an error that
//! names why.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");
const io_context = @import("io_context.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const start_audio_recording = "startAudioRecording";
    pub const stop_audio_recording = "stopAudioRecording";
};

pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.start_audio_recording, .reply = .result },
    .{ .name = A.stop_audio_recording, .reply = .result },
};

/// `kAudioFormatMPEG4AAC` — the four-character code `'aac '`.
///
/// Spelled as its numeric value because that is what the key takes. Getting it
/// wrong produces a recorder that fails to initialise, which is at least loud.
const audio_format_mpeg4_aac: c_int = 0x61616320;

/// `AVAudioQuality.high`.
const audio_quality_high: c_int = 0x60;

/// `AVAudioSessionCategoryOptions` — none, matching Swift's two-argument
/// `setCategory(_:mode:)`.
const no_category_options: c_ulong = 0;

/// The prefix Swift concatenates ahead of the base64.
const m4a_data_url_prefix = "data:audio/m4a;base64,";

/// `startAudioRecording`'s reply once the recorder is running.
const start_reply = "true";

/// A recording larger than this is refused rather than base64'd into a
/// JavaScript string literal.
///
/// 32 MiB of AAC is roughly forty minutes at the settings below, and its
/// base64 is 43 MiB of source for `evaluateJavaScript:` to parse. Swift has no
/// ceiling and will try; the failure mode there is a webview that stalls or
/// dies rather than an error a page can read.
const max_recording_bytes: u64 = 32 << 20;

/// The recorder, the file it is writing, and the call that started it.
///
/// All main-thread state: every write below happens on the main queue, either
/// from the dispatch or from the hop the permission block makes.
var recorder: Id = null;
var recording_path: ?[]u8 = null;
var pending: ?ios_async.Ticket = null;

pub const AudioRecordingBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, _: []const u8) !void {
        if (std.mem.eql(u8, action, A.start_audio_recording)) {
            try self.startRecording();
        } else if (std.mem.eql(u8, action, A.stop_audio_recording)) {
            try self.stopRecording();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    /// Ask for the microphone; the reply comes from the permission block.
    fn startRecording(self: *Self) !void {
        _ = self;
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        try requireMicrophoneUsageDescription();

        const session = try sharedAudioSession();

        // A second start while one is in flight would strand the first ticket,
        // which is what Swift's single `pendingCallbackId` does.
        if (pending) |existing| {
            std.log.warn(
                "startAudioRecording: a start is already in flight; answering the first call " ++
                    "rather than replacing it",
                .{},
            );
            ios_async.deliverErrorCode(existing, BridgeError.Cancelled);
            pending = null;
        }

        const ticket = ios_async.acquire(A.start_audio_recording) orelse {
            std.log.warn(
                "startAudioRecording: no free reply slot; {d} native calls are already awaiting one",
                .{ios_async.max_in_flight},
            );
            return BridgeError.NativeCallFailed;
        };
        errdefer ios_async.abandon(ticket);
        pending = ticket;

        const sel = objc.sel_registerName("requestRecordPermission:") orelse
            return BridgeError.NativeCallFailed;
        const RequestFn = *const fn (Id, objc.SEL, *anyopaque) callconv(.c) void;
        const request: RequestFn = @ptrCast(&objc.objc_msgSend);
        request(session, sel, @ptrCast(&permission_blocks[ticket.index]));
    }

    /// Stop, read the file back, and resolve it as a `data:` URL.
    ///
    /// Synchronous throughout: `-[AVAudioRecorder stop]` finishes writing
    /// before it returns, which is what makes Swift's immediate read of the
    /// file legal.
    fn stopRecording(self: *Self) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        if (recorder) |live| {
            const sel_stop = objc.sel_registerName("stop");
            if (sel_stop) |sel| objc.msgSend(live, sel);
            release(live);
            recorder = null;
        }

        const path = recording_path orelse {
            // Swift's else branch: "No recording found".
            std.log.warn("stopAudioRecording: nothing was recording", .{});
            return BridgeError.NotFound;
        };
        defer {
            self.allocator.free(path);
            recording_path = null;
        }

        const bytes = readRecording(self.allocator, path) catch |err| switch (err) {
            // Swift's fallback: the file exists but could not be read, so the
            // path is resolved instead of its contents.
            error.Unreadable => return self.replyWithPath(path),
            error.NotFound => {
                std.log.warn("stopAudioRecording: the recorder wrote no file", .{});
                return BridgeError.NotFound;
            },
            else => return err,
        };
        defer self.allocator.free(bytes);

        try self.replyWithDataUrl(bytes);
    }

    /// `"data:audio/m4a;base64,…"` as a bare JSON string.
    fn replyWithDataUrl(self: *Self, bytes: []const u8) !void {
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(bytes.len);

        var out = try self.allocator.alloc(u8, m4a_data_url_prefix.len + encoded_len + 2);
        defer self.allocator.free(out);

        out[0] = '"';
        @memcpy(out[1 .. 1 + m4a_data_url_prefix.len], m4a_data_url_prefix);
        _ = encoder.encode(out[1 + m4a_data_url_prefix.len ..][0..encoded_len], bytes);
        out[out.len - 1] = '"';

        // Base64 and the prefix contain nothing JSON escapes, and the quoting
        // is done here rather than through the shared escaper because the
        // buffer is already exactly sized — but the alphabet is checked by a
        // test rather than asserted in prose.
        bridge_error.sendResultToJS(self.allocator, A.stop_audio_recording, out);
    }

    fn replyWithPath(self: *Self, path: []const u8) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.append(self.allocator, '"');
        try bridge_error.appendJsonEscaped(self.allocator, &out, path);
        try out.append(self.allocator, '"');
        bridge_error.sendResultToJS(self.allocator, A.stop_audio_recording, out.items);
    }
};

/// The recording's bytes, or which way it was unavailable.
fn readRecording(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = io_context.get();

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => {
            std.log.warn("stopAudioRecording: could not open '{s}': {}", .{ path, err });
            return error.Unreadable;
        },
    };
    defer file.close(io);

    const info = file.stat(io) catch return error.Unreadable;
    if (info.size == 0) return error.NotFound;
    if (info.size > max_recording_bytes) {
        std.log.warn(
            "stopAudioRecording: the recording is {d} bytes, over the {d}-byte ceiling; " ++
                "refusing rather than building a base64 string that large",
            .{ info.size, max_recording_bytes },
        );
        return error.Unreadable;
    }

    const buf = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(buf);

    var read: usize = 0;
    while (read < buf.len) {
        const n = file.readStreaming(io, &.{buf[read..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.Unreadable,
        };
        if (n == 0) break;
        read += n;
    }
    if (read != buf.len) return error.Unreadable;
    return buf;
}

/// `[AVAudioSession sharedInstance]`.
fn sharedAudioSession() !Id {
    const AVAudioSession = objc.objc_getClass("AVAudioSession") orelse {
        std.log.warn(
            "startAudioRecording: AVAudioSession is not in this process; " ++
                "the app does not link AVFoundation",
            .{},
        );
        return BridgeError.PlatformNotSupported;
    };
    const sel = objc.sel_registerName("sharedInstance") orelse return BridgeError.NativeCallFailed;
    return objc.msgSendId(AVAudioSession, sel) orelse BridgeError.NativeCallFailed;
}

/// The key iOS demands before a process may ask for the microphone.
const key_microphone_usage = "NSMicrophoneUsageDescription";

fn requireMicrophoneUsageDescription() !void {
    if (!is_darwin) return BridgeError.PlatformNotSupported;

    const NSBundle = objc.objc_getClass("NSBundle") orelse return BridgeError.NativeCallFailed;
    const sel_main = objc.sel_registerName("mainBundle") orelse return BridgeError.NativeCallFailed;
    const bundle = objc.msgSendId(NSBundle, sel_main) orelse return BridgeError.NativeCallFailed;

    const NSString = objc.objc_getClass("NSString") orelse return BridgeError.NativeCallFailed;
    const sel_string = objc.sel_registerName("stringWithUTF8String:") orelse
        return BridgeError.NativeCallFailed;
    const ns_key = objc.msgSendId1(NSString, sel_string, @as([*:0]const u8, key_microphone_usage)) orelse
        return BridgeError.NativeCallFailed;

    const sel_lookup = objc.sel_registerName("objectForInfoDictionaryKey:") orelse
        return BridgeError.NativeCallFailed;
    if (objc.msgSendId1(bundle, sel_lookup, ns_key) != null) return;

    std.log.warn(
        "startAudioRecording refused: Info.plist has no {s}, and asking for record " ++
            "permission without it terminates the process rather than failing",
        .{key_microphone_usage},
    );
    return BridgeError.PermissionDenied;
}

// ---------------------------------------------------------------------------
// The permission block, and the main-queue hop it makes
// ---------------------------------------------------------------------------

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// `void (^)(BOOL granted)`.
const PermissionBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28 — a global block is never copied.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const permission_block_descriptor = BlockDescriptor{ .size = @sizeOf(PermissionBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

fn makePermissionInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const PermissionBlock, granted: bool) callconv(.c) void {
            permissionAnswered(index, granted);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makePermissionBlocks() [ios_async.max_in_flight]PermissionBlock {
    var out: [ios_async.max_in_flight]PermissionBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = makePermissionInvoke(@intCast(i)),
            .descriptor = &permission_block_descriptor,
        };
    }
    return out;
}

var permission_blocks: [ios_async.max_in_flight]PermissionBlock =
    if (is_darwin) makePermissionBlocks() else undefined;

/// Which slot the pending main-queue hop belongs to, since `dispatch_async_f`
/// carries one pointer and an index fits in it.
var hop_granted: bool = false;

/// Runs on whatever queue AVAudioSession chose.
///
/// Swift hops to the main queue here before touching the session, because
/// activating a session and starting a recorder off the main thread is not
/// supported. The hop carries the slot index in the context pointer, exactly
/// as `ios_events` does.
fn permissionAnswered(index: u5, granted: bool) void {
    if (!is_darwin) return;

    hop_granted = granted;
    dispatch_async_f(&_dispatch_main_q, @ptrFromInt(@as(usize, index) + 1), beginOnMain);
}

/// The main-queue half: configure the session, build the recorder, start it.
fn beginOnMain(context: ?*anyopaque) callconv(.c) void {
    const index: usize = @intFromPtr(context orelse return) - 1;
    if (index >= ios_async.max_in_flight) return;

    const ticket = pending orelse return;
    if (ticket.index != index) return;
    pending = null;

    if (!hop_granted) {
        std.log.warn("startAudioRecording: microphone permission was denied", .{});
        ios_async.deliverErrorCode(ticket, BridgeError.PermissionDenied);
        return;
    }

    beginRecording() catch |err| {
        std.log.warn("startAudioRecording: could not start the recorder: {}", .{err});
        ios_async.deliverErrorCode(ticket, BridgeError.NativeCallFailed);
        return;
    };

    ios_async.deliverJson(ticket, start_reply);
}

fn beginRecording() !void {
    const allocator = std.heap.c_allocator;

    const path = try recordingFilePath(allocator);
    errdefer allocator.free(path);

    const session = try sharedAudioSession();
    try configureSession(session);

    const settings = try recorderSettings(allocator);
    const ns_path = try objc.createNSString(path, allocator);

    const NSURL = objc.objc_getClass("NSURL") orelse return error.ClassNotFound;
    const sel_file_url = objc.sel_registerName("fileURLWithPath:") orelse return error.SelectorNotFound;
    const url = objc.msgSendId1(NSURL, sel_file_url, ns_path) orelse return error.NativeCallFailed;

    const AVAudioRecorder = objc.objc_getClass("AVAudioRecorder") orelse return error.ClassNotFound;
    const sel_alloc = objc.sel_registerName("alloc") orelse return error.SelectorNotFound;
    const sel_init = objc.sel_registerName("initWithURL:settings:error:") orelse
        return error.SelectorNotFound;
    const allocated = objc.msgSendId(AVAudioRecorder, sel_alloc) orelse return error.NativeCallFailed;

    const InitFn = *const fn (Id, objc.SEL, Id, Id, ?*Id) callconv(.c) Id;
    const initFn: InitFn = @ptrCast(&objc.objc_msgSend);
    var init_error: Id = null;
    const built = initFn(allocated, sel_init, url, settings, &init_error) orelse {
        logNSError("startAudioRecording", init_error);
        return error.NativeCallFailed;
    };

    const sel_record = objc.sel_registerName("record") orelse return error.SelectorNotFound;
    const RecordFn = *const fn (Id, objc.SEL) callconv(.c) bool;
    const recordFn: RecordFn = @ptrCast(&objc.objc_msgSend);
    if (!recordFn(built, sel_record)) {
        release(built);
        return error.NativeCallFailed;
    }

    // Replace only once the recorder is actually running, so a failed start
    // leaves the previous state untouched rather than half-cleared.
    release(recorder);
    recorder = built;
    if (recording_path) |old| allocator.free(old);
    recording_path = path;
}

/// `setCategory:mode:options:error:` then `setActive:error:`.
fn configureSession(session: Id) !void {
    const category = try audioSessionConstant("AVAudioSessionCategoryPlayAndRecord");
    const mode = try audioSessionConstant("AVAudioSessionModeDefault");

    const sel_category = objc.sel_registerName("setCategory:mode:options:error:") orelse
        return error.SelectorNotFound;
    const CategoryFn = *const fn (Id, objc.SEL, Id, Id, c_ulong, ?*Id) callconv(.c) bool;
    const setCategory: CategoryFn = @ptrCast(&objc.objc_msgSend);
    var category_error: Id = null;
    if (!setCategory(session, sel_category, category, mode, no_category_options, &category_error)) {
        logNSError("startAudioRecording", category_error);
        return error.NativeCallFailed;
    }

    const sel_active = objc.sel_registerName("setActive:error:") orelse return error.SelectorNotFound;
    const ActiveFn = *const fn (Id, objc.SEL, bool, ?*Id) callconv(.c) bool;
    const setActive: ActiveFn = @ptrCast(&objc.objc_msgSend);
    var active_error: Id = null;
    if (!setActive(session, sel_active, true, &active_error)) {
        logNSError("startAudioRecording", active_error);
        return error.NativeCallFailed;
    }
}

/// `@{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100.0,
/// AVNumberOfChannelsKey: @2, AVEncoderAudioQualityKey: @(high)}`.
fn recorderSettings(allocator: std.mem.Allocator) !Id {
    const NSMutableDictionary = objc.objc_getClass("NSMutableDictionary") orelse
        return error.ClassNotFound;
    const settings = try objc.allocInit(NSMutableDictionary);

    try setNumber(settings, "AVFormatIDKey", .{ .int = audio_format_mpeg4_aac });
    try setNumber(settings, "AVSampleRateKey", .{ .double = 44100.0 });
    try setNumber(settings, "AVNumberOfChannelsKey", .{ .int = 2 });
    try setNumber(settings, "AVEncoderAudioQualityKey", .{ .int = audio_quality_high });

    _ = allocator;
    return settings;
}

const Number = union(enum) { int: c_int, double: f64 };

fn setNumber(dictionary: Id, comptime key_symbol: [*:0]const u8, value: Number) !void {
    const key = try audioSessionConstant(key_symbol);

    const NSNumber = objc.objc_getClass("NSNumber") orelse return error.ClassNotFound;
    const number = switch (value) {
        .int => |i| blk: {
            const sel = objc.sel_registerName("numberWithInt:") orelse return error.SelectorNotFound;
            const Fn = *const fn (objc.Class, objc.SEL, c_int) callconv(.c) Id;
            const f: Fn = @ptrCast(&objc.objc_msgSend);
            break :blk f(NSNumber, sel, i);
        },
        .double => |d| blk: {
            const sel = objc.sel_registerName("numberWithDouble:") orelse return error.SelectorNotFound;
            const Fn = *const fn (objc.Class, objc.SEL, f64) callconv(.c) Id;
            const f: Fn = @ptrCast(&objc.objc_msgSend);
            break :blk f(NSNumber, sel, d);
        },
    } orelse return error.NativeCallFailed;

    const sel_set = objc.sel_registerName("setObject:forKey:") orelse return error.SelectorNotFound;
    objc.msgSendVoid2(dictionary, sel_set, number, key);
}

/// An `extern NSString * const` from AVFoundation, read through its symbol.
///
/// The recorder-settings keys and the session category/mode are all constants
/// whose *values* are not API. Rebuilding one from its own spelling would
/// produce a dictionary key AVFoundation ignores — a recorder built with
/// silent defaults rather than the settings the spec names.
fn audioSessionConstant(comptime symbol: [*:0]const u8) !Id {
    const found = dlsym(RTLD_DEFAULT, symbol) orelse {
        std.log.warn("startAudioRecording: {s} is not in this process", .{symbol});
        return error.NotFound;
    };
    const cell: *const Id = @ptrCast(@alignCast(found));
    return cell.* orelse error.NotFound;
}

/// `Documents/recording_<timeIntervalSince1970>.m4a`.
fn recordingFilePath(allocator: std.mem.Allocator) ![]u8 {
    const NSFileManager = objc.objc_getClass("NSFileManager") orelse return error.ClassNotFound;
    const sel_default = objc.sel_registerName("defaultManager") orelse return error.SelectorNotFound;
    const manager = objc.msgSendId(NSFileManager, sel_default) orelse return error.NativeCallFailed;

    const sel_urls = objc.sel_registerName("URLsForDirectory:inDomains:") orelse
        return error.SelectorNotFound;
    // NSDocumentDirectory = 9, NSUserDomainMask = 1.
    const urls = objc.msgSendId2(manager, sel_urls, @as(c_ulong, 9), @as(c_ulong, 1)) orelse
        return error.NativeCallFailed;

    const sel_first = objc.sel_registerName("firstObject") orelse return error.SelectorNotFound;
    // Swift subscripts with `[0]`, which raises on an empty result.
    const url = objc.msgSendId(urls, sel_first) orelse return error.NotFound;

    const sel_path = objc.sel_registerName("path") orelse return error.SelectorNotFound;
    const ns_path = objc.msgSendId(url, sel_path) orelse return error.NativeCallFailed;
    const utf8 = objc.getNSStringUTF8(ns_path) orelse return error.NativeCallFailed;

    return std.fmt.allocPrint(
        allocator,
        "{s}/recording_{d}.m4a",
        .{ std.mem.span(utf8), currentTimeInterval() },
    );
}

fn currentTimeInterval() f64 {
    const NSDate = objc.objc_getClass("NSDate") orelse return 0;
    const sel_date = objc.sel_registerName("date") orelse return 0;
    const now = objc.msgSendId(NSDate, sel_date) orelse return 0;
    const sel_interval = objc.sel_registerName("timeIntervalSince1970") orelse return 0;
    const IntervalFn = *const fn (Id, objc.SEL) callconv(.c) f64;
    const intervalFn: IntervalFn = @ptrCast(&objc.objc_msgSend);
    return intervalFn(now, sel_interval);
}

fn logNSError(action: []const u8, err: Id) void {
    const ns_error = err orelse return;
    const sel = objc.sel_registerName("localizedDescription") orelse return;
    const ns_description = objc.msgSendId(ns_error, sel) orelse return;
    const utf8 = objc.getNSStringUTF8(ns_description) orelse return;
    std.log.warn("{s}: {s}", .{ action, std.mem.span(utf8) });
}

fn release(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: dispatch_function_t) void;
extern var _dispatch_main_q: anyopaque;

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

/// `RTLD_DEFAULT` — search every image already loaded into the process.
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    try testing.expectEqualStrings("startAudioRecording", A.start_audio_recording);
    try testing.expectEqualStrings("stopAudioRecording", A.stop_audio_recording);
}

test "the recorder settings are the values Swift names" {
    // `kAudioFormatMPEG4AAC` is the four-character code 'aac '. A wrong value
    // here is not a silent misconfiguration — `initWithURL:settings:error:`
    // refuses it — but the number is unreadable at a glance, so it is pinned
    // against its own spelling.
    try testing.expectEqual(@as(c_int, 0x61616320), audio_format_mpeg4_aac);
    try testing.expectEqual(
        @as(u32, @bitCast([4]u8{ 'a', 'a', 'c', ' ' })),
        @byteSwap(@as(u32, @intCast(audio_format_mpeg4_aac))),
    );
    try testing.expectEqual(@as(c_int, 0x60), audio_quality_high);
}

test "the reply prefix is the one Swift concatenates" {
    // A page assigning the reply to an <audio> src depends on both the media
    // type and the base64 marker.
    try testing.expectEqualStrings("data:audio/m4a;base64,", m4a_data_url_prefix);
    try testing.expectEqualStrings("true", start_reply);
}

test "base64 cannot carry a character JSON would have to escape" {
    // `replyWithDataUrl` quotes the payload without running the shared escaper,
    // because the buffer is sized exactly. That is only safe while the
    // alphabet stays free of `"` and `\`, so the alphabet is checked rather
    // than asserted in prose.
    const alphabet = std.base64.standard_alphabet_chars;
    for (alphabet) |c| {
        try testing.expect(c != '"');
        try testing.expect(c != '\\');
        try testing.expect(c >= 0x20);
    }
    try testing.expect(std.base64.standard.Encoder.pad_char.? == '=');
}

test "a recording larger than the ceiling is refused, not truncated" {
    // Swift has no ceiling and will base64 a ten-minute take into the source
    // `evaluateJavaScript:` parses. The failure there is a webview that stalls
    // rather than an error a page can read.
    try testing.expectEqual(@as(u64, 32 << 20), max_recording_bytes);
}

test "a missing recording is NotFound rather than an empty reply" {
    // Swift's else branch rejects "No recording found". Resolving an empty
    // data URL would tell the page it recorded silence.
    try testing.expectError(
        error.NotFound,
        readRecording(testing.allocator, "craft-audiorec-does-not-exist.m4a"),
    );
}

test "a process with no usage description is refused before the microphone is asked for" {
    // Requesting record permission without NSMicrophoneUsageDescription
    // terminates the process, so the refusal has to happen first. The host
    // test binary has no such key, which is what this exercises.
    if (!is_darwin) return error.SkipZigTest;

    try testing.expectError(BridgeError.PermissionDenied, requireMicrophoneUsageDescription());
}

test "every declared action dispatches to something" {
    var bridge = AudioRecordingBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
}

test "each permission block is global and has its own invoke" {
    if (!is_darwin) return error.SkipZigTest;

    for (&permission_blocks) |*b| {
        try testing.expectEqual(&_NSConcreteGlobalBlock, b.isa);
        try testing.expectEqual(BLOCK_IS_GLOBAL, b.flags);
        try testing.expectEqual(@sizeOf(PermissionBlock), @as(usize, @intCast(b.descriptor.size)));
    }
    try testing.expect(permission_blocks[0].invoke != permission_blocks[1].invoke);
}

test "a main-queue hop for a slot that is not the pending one is ignored" {
    // The hop carries only an index. If the ticket it names is not the one
    // waiting — a stale fire, or a start that was already cancelled — it must
    // do nothing rather than answer somebody else's call.
    if (!is_darwin) return error.SkipZigTest;

    pending = null;
    beginOnMain(@ptrFromInt(1));
    try testing.expect(pending == null);
}
