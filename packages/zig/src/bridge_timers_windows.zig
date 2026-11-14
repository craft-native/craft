//! Native deadlines for hidden pages on Windows.
//!
//! The macOS backend (`bridge_timers.zig`) runs an `NSTimer` in the main run
//! loop and holds an `NSProcessInfo` activity so the machine does not sleep
//! through the deadline. The Windows equivalents are `SetTimer`, whose
//! `WM_TIMER` arrives on the thread that owns the window, and
//! `SetThreadExecutionState`.
//!
//! All state belongs to the UI thread. `WM_TIMER` is drained by the message
//! loop, the dispatch that arms a deadline runs inside the WebView2 message
//! callback (also the UI thread), and nothing here takes a lock. That is the
//! same discipline the macOS file relies on.
//!
//! One deliberate difference from macOS: `sleep` does not reply immediately. It
//! answers the original request when the deadline is reached, so the request id
//! is stored with the entry and pushed back before replying. That is what makes
//! `await craft.timers.sleep(...)` resolve at the deadline rather than at the
//! call.

const std = @import("std");
const builtin = @import("builtin");
const errors = @import("bridge_error.zig");
const request = @import("request_context.zig");
const window_context = @import("window_context.zig");

pub const A = struct {
    pub const sleep = "sleep";
    pub const cancel = "cancel";
    pub const cancel_all = "cancelAll";
};

/// What the UI thread needs to answer a deadline that has just been reached.
pub const Fired = struct {
    window_id: u32,
    request_id: u64,
    client_id: u64,
};

const capacity = 256;

const Entry = struct {
    hwnd: usize,
    window_id: u32,
    request_id: u64,
    client_id: u64,
};

var entries: [capacity]?Entry = @splat(null);

/// Whether this thread currently holds the system awake on our behalf.
var awake: bool = false;

const HWND = *anyopaque;

extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: c_uint, lpTimerFunc: ?*anyopaque) callconv(.c) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.c) c_int;
extern "kernel32" fn SetThreadExecutionState(esFlags: c_uint) callconv(.c) c_uint;

const ES_SYSTEM_REQUIRED: c_uint = 0x00000001;
const ES_CONTINUOUS: c_uint = 0x80000000;

/// `timerId` is the page's own handle for the deadline; it is what `cancel`
/// names. The engine-side id is the slot index, which is why a cancelled slot
/// can be reused without the page ever seeing a stale number.
pub fn handle(action: []const u8, data: []const u8, hwnd: usize, window_id: u32, webview: usize) !void {
    if (comptime builtin.os.tag != .windows) return error.PlatformNotSupported;
    const allocator = std.heap.c_allocator;

    if (std.mem.eql(u8, action, A.cancel_all)) {
        forgetWindow(window_id);
        errors.sendResultToJS(allocator, A.cancel_all, "{\"ok\":true}");
        return;
    }

    const Params = struct { timerId: u64, delayMs: u32 = 0 };
    const parsed = std.json.parseFromSlice(Params, allocator, data, .{}) catch return error.InvalidJSON;
    defer parsed.deinit();
    const params = parsed.value;
    // 9007199254740991 is 2^53-1, the largest integer a JS number holds exactly.
    // A day is the ceiling the macOS backend applies and there is no reason for
    // the two platforms to disagree about what a sane deadline is.
    if (params.timerId == 0 or params.timerId > 9007199254740991 or params.delayMs > 86_400_000)
        return error.InvalidParameter;

    if (std.mem.eql(u8, action, A.cancel)) {
        var cancelled = false;
        for (entries, 0..) |entry, index| {
            if (entry) |value| {
                if (value.window_id == window_id and value.client_id == params.timerId) {
                    if (remove(index, true)) |removed| deliverMissed(removed, hwnd, webview);
                    cancelled = true;
                    break;
                }
            }
        }
        errors.sendResultToJS(allocator, A.cancel, if (cancelled) "{\"cancelled\":true}" else "{\"cancelled\":false}");
        return;
    }
    if (!std.mem.eql(u8, action, A.sleep)) return error.InvalidParameter;

    const request_id = request.current() orelse return error.InvalidParameter;
    var available: ?usize = null;
    for (entries, 0..) |entry, index| {
        if (entry) |value| {
            if (value.window_id == window_id and value.client_id == params.timerId) return error.InvalidParameter;
        } else if (available == null) available = index;
    }
    const index = available orelse return error.Busy;

    // A zero deadline is legal and means "as soon as the queue drains", which is
    // exactly what SetTimer does with 0.
    if (SetTimer(@ptrFromInt(hwnd), index + 1, params.delayMs, null) == 0) return error.NativeCallFailed;
    entries[index] = .{
        .hwnd = hwnd,
        .window_id = window_id,
        .request_id = request_id,
        .client_id = params.timerId,
    };
    keepAwake();
}

/// Called from the window procedure when `WM_TIMER` arrives. Returns the entry
/// to answer, or null when the id belongs to some other timer on this window.
pub fn takeFired(timer_id: u32) ?Fired {
    if (comptime builtin.os.tag != .windows) return null;
    if (timer_id == 0 or timer_id > capacity) return null;
    const index: usize = @intCast(timer_id - 1);
    const entry = remove(index, false) orelse return null;
    return .{ .window_id = entry.window_id, .request_id = entry.request_id, .client_id = entry.client_id };
}

/// Navigation and destruction discard deadlines belonging to a page that is no
/// longer there to receive them.
pub fn forgetWindow(window_id: u32) void {
    if (comptime builtin.os.tag != .windows) return;
    for (entries, 0..) |entry, index| {
        if (entry) |value| {
            if (value.window_id == window_id) _ = remove(index, true);
        }
    }
}

/// A cancelled deadline still has to answer the `sleep` call that armed it.
/// The facade waits for both RPC replies before rejecting with `AbortError`
/// (`Promise.allSettled([nativeDelay, cancellation])`), so staying silent would
/// leave the caller's promise pending forever. The macOS backend answers
/// `{"fired":false}` for the same reason.
fn deliverMissed(entry: Entry, hwnd: usize, webview: usize) void {
    window_context.push(hwnd, webview);
    defer window_context.pop();
    request.push(entry.request_id);
    defer request.pop();
    errors.sendResultToJS(std.heap.c_allocator, A.sleep, "{\"fired\":false}");
}

fn remove(index: usize, disarm: bool) ?Entry {
    const entry = entries[index] orelse return null;
    entries[index] = null;
    if (disarm) _ = KillTimer(@ptrFromInt(entry.hwnd), index + 1);
    releaseAwakeIfIdle();
    return entry;
}

fn keepAwake() void {
    if (awake) return;
    awake = true;
    _ = SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
}

fn releaseAwakeIfIdle() void {
    for (entries) |entry| if (entry != null) return;
    if (!awake) return;
    awake = false;
    // ES_CONTINUOUS alone cancels the thread's execution-state request.
    _ = SetThreadExecutionState(ES_CONTINUOUS);
}
