//! The machinery an asynchronous reply needs, built once.
//!
//! Everything served so far answers from inside the dispatch: the request id
//! is on `request_context`'s stack, the reply reads it, done. A completion
//! handler breaks both halves of that at once — it fires after the dispatch
//! frame is gone (so the id is no longer anywhere), and it fires on whatever
//! queue the framework felt like (so `evaluateJavaScript`, which is
//! main-thread-only, cannot be called from it directly).
//!
//! Getting this wrong is not hypothetical; it is the repo's inheritance.
//! `request_context.current()` returning null in a late reply silently drops
//! correlation to action-name matching, which hands caller B's answer to
//! caller A whenever two calls of one action are in flight. And the previous
//! block implementation was built on the stack and handed to an async API,
//! with its own doc comment asserting a lifetime ("valid for duration of
//! call") that async precisely does not honour.
//!
//! Three pieces, each chosen for being checkable:
//!
//!   - a slot pool that captures {request id, action} at dispatch time, with
//!     generation counters so a stale or double-firing completion cannot
//!     resolve a slot that has been reused;
//!   - completion blocks that are module-level and flagged BLOCK_IS_GLOBAL,
//!     because `Block_copy` on a global block returns the same pointer —
//!     no heap copy, no descriptor lifetime, no copy/dispose helpers. Each
//!     pool slot has its own pre-built block with the slot index baked in,
//!     which is how a non-capturing block knows who it is;
//!   - delivery hopped to the main queue with `dispatch_async_f` — the
//!     function-pointer variant, so the hop itself needs no block at all.

const std = @import("std");
const builtin = @import("builtin");
const objc_runtime = @import("objc_runtime.zig");
const request_context = @import("request_context.zig");
const bridge_error = @import("bridge_error.zig");
const compat_mutex = @import("compat_mutex.zig");

const objc = objc_runtime.objc;
const is_darwin = builtin.target.os.tag.isDarwin();

/// How many async calls may be in flight at once. A page that exceeds this
/// gets an explicit Busy error, which is an answer — the alternative was a
/// silently dropped reply.
pub const max_in_flight = 16;

const Slot = struct {
    /// Incremented on every acquire and release. A completion carrying a
    /// stale generation is a late or duplicate fire for a call that has
    /// already been answered; it must do nothing rather than resolve
    /// whoever owns the slot now.
    generation: u32 = 0,
    in_use: bool = false,
    /// The id the reply names. -1 for a call the page sent without one.
    request_id: i64 = -1,
    /// The action, copied into fixed storage: the dispatch frame's slices are
    /// dead by the time the completion fires.
    action_buf: [64]u8 = undefined,
    action_len: usize = 0,
    /// What the completion resolved. Written on the firing thread, read on
    /// the main thread after the dispatch_async_f hop.
    granted: bool = false,
    /// A module-shaped reply, for completions this file cannot shape itself.
    /// Owned by the slot; freed on delivery. Null means use `granted`.
    json: ?[]u8 = null,
};

var slots: [max_in_flight]Slot = @splat(.{});
var slots_mutex: compat_mutex.Mutex = .{};

/// A slot ticket: which slot, and which lease of it.
pub const Ticket = struct {
    index: u5,
    generation: u32,
};

/// Capture the current request's identity for a reply that will arrive after
/// the dispatch is gone. Called from inside the dispatch, which is the only
/// place `request_context.current()` still means this call.
///
/// Null means the pool is full. The caller must answer Busy — returning
/// silence here would reproduce the exact bug this file exists to prevent.
pub fn acquire(action: []const u8) ?Ticket {
    if (action.len > 64) return null;

    slots_mutex.lock();
    defer slots_mutex.unlock();

    for (&slots, 0..) |*slot, i| {
        if (slot.in_use) continue;
        slot.in_use = true;
        slot.generation +%= 1;
        slot.request_id = if (request_context.current()) |id| @intCast(id) else -1;
        @memcpy(slot.action_buf[0..action.len], action);
        slot.action_len = action.len;
        return .{ .index = @intCast(i), .generation = slot.generation };
    }
    return null;
}

/// Release without replying — for the error path between acquire and the
/// framework call, where the caller is about to answer synchronously itself.
pub fn abandon(ticket: Ticket) void {
    slots_mutex.lock();
    defer slots_mutex.unlock();
    const slot = &slots[ticket.index];
    if (slot.generation != ticket.generation or !slot.in_use) return;
    slot.in_use = false;
    slot.generation +%= 1;
}

// ---------------------------------------------------------------------------
// The block pool: one pre-built BOOL-completion block per slot.
// ---------------------------------------------------------------------------

const BlockDescriptor = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
};

/// void (^)(BOOL) — the shape of `requestAccessForMediaType:completionHandler:`
/// and, with the error parameter ignored by the invoke, close enough to
/// `requestAuthorizationWithOptions:` that each gets its own invoke below.
const BoolBlock = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 1 << 28. A global block is never copied: `Block_copy` returns the same
/// pointer. That is the entire trick — no heap block, no copy/dispose pair,
/// no descriptor lifetime, and the pool's blocks are safely handed to any
/// API that escapes them.
const BLOCK_IS_GLOBAL: c_int = 1 << 28;

const bool_block_descriptor = BlockDescriptor{ .size = @sizeOf(BoolBlock) };

extern var _NSConcreteGlobalBlock: anyopaque;

/// The per-slot invokes. Comptime-generated so each block knows its slot
/// without capturing anything: the index is baked into the function, and the
/// function is baked into the block.
fn makeBoolInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const BoolBlock, granted: bool) callconv(.c) void {
            completionFired(index, granted);
        }
    };
    return @ptrCast(&S.invoke);
}

/// void (^)(BOOL, NSError *) — `requestAuthorizationWithOptions:` and friends.
/// The error object is deliberately unused: the granted flag is the answer
/// the page's contract carries, and Swift discarded the error here too.
fn makeBoolErrorInvoke(comptime index: u5) *const anyopaque {
    const S = struct {
        fn invoke(_: *const BoolBlock, granted: bool, _: objc.id) callconv(.c) void {
            completionFired(index, granted);
        }
    };
    return @ptrCast(&S.invoke);
}

fn makeBlocks(comptime maker: fn (comptime u5) *const anyopaque) [max_in_flight]BoolBlock {
    var out: [max_in_flight]BoolBlock = undefined;
    for (&out, 0..) |*b, i| {
        b.* = .{
            .isa = &_NSConcreteGlobalBlock,
            .flags = BLOCK_IS_GLOBAL,
            .invoke = maker(@intCast(i)),
            .descriptor = &bool_block_descriptor,
        };
    }
    return out;
}

var bool_blocks: [max_in_flight]BoolBlock = if (is_darwin) makeBlocks(makeBoolInvoke) else undefined;
var bool_error_blocks: [max_in_flight]BoolBlock = if (is_darwin) makeBlocks(makeBoolErrorInvoke) else undefined;

/// The block to pass as a `void (^)(BOOL)` completion handler for the call
/// this ticket was acquired for.
pub fn boolBlock(ticket: Ticket) *anyopaque {
    return @ptrCast(&bool_blocks[ticket.index]);
}

/// The block to pass as a `void (^)(BOOL, NSError *)` completion handler.
pub fn boolErrorBlock(ticket: Ticket) *anyopaque {
    return @ptrCast(&bool_error_blocks[ticket.index]);
}

// ---------------------------------------------------------------------------
// Firing: any thread → main queue → reply.
// ---------------------------------------------------------------------------

const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_async_f(queue: *anyopaque, context: ?*anyopaque, work: dispatch_function_t) void;
/// `dispatch_get_main_queue()` is a macro over this global.
extern var _dispatch_main_q: anyopaque;

fn completionFired(index: u5, granted: bool) void {
    // Record the outcome under the lock, but deliver from the main queue:
    // the reply ends in `evaluateJavaScript`, which is main-thread-only, and
    // this may be running on whatever queue the framework chose.
    {
        slots_mutex.lock();
        defer slots_mutex.unlock();
        const slot = &slots[index];
        if (!slot.in_use) return; // stale fire for an abandoned slot
        slot.granted = granted;
    }

    // The context pointer carries only the slot index; everything else stays
    // in the slot, guarded by its generation.
    dispatch_async_f(&_dispatch_main_q, @ptrFromInt(@as(usize, index) + 1), deliverOnMain);
}

fn deliverOnMain(context: ?*anyopaque) callconv(.c) void {
    const index: usize = @intFromPtr(context orelse return) - 1;

    var action_buf: [64]u8 = undefined;
    var action_len: usize = 0;
    var request_id: i64 = -1;
    var granted = false;
    var json: ?[]u8 = null;
    {
        slots_mutex.lock();
        defer slots_mutex.unlock();
        const slot = &slots[index];
        if (!slot.in_use) return;
        action_len = slot.action_len;
        @memcpy(action_buf[0..action_len], slot.action_buf[0..action_len]);
        request_id = slot.request_id;
        granted = slot.granted;
        json = slot.json;
        slot.json = null;
        slot.in_use = false;
        slot.generation +%= 1;
    }
    defer if (json) |owned| std.heap.c_allocator.free(owned);

    const action = action_buf[0..action_len];

    // Restore the identity captured at dispatch, so the reply names the call
    // that is actually waiting — the whole point of this file.
    request_context.push(if (request_id < 0) null else @intCast(request_id));
    defer request_context.pop();

    bridge_error.sendResultToJS(
        std.heap.c_allocator,
        action,
        json orelse if (granted) "\"granted\"" else "\"denied\"",
    );
}

/// Deliver a reply for a ticket whose completion this file could not shape.
///
/// The pre-built pool blocks cover `void (^)(BOOL)` and `void (^)(BOOL, NSError *)`,
/// which is most permission-style APIs and nothing else. A completion handing
/// back an array — `getPendingNotificationRequestsWithCompletionHandler:` — has
/// to be shaped by the module that knows how to serialise it.
///
/// So a module may build its own block, and still get the two things that are
/// genuinely hard: the request id captured at dispatch (the block reads its
/// ticket from wherever it stashed it) and the hop to the main queue. It hands
/// the finished JSON here and this does the rest.
///
/// The JSON is copied, because the caller's buffer is usually a stack local in
/// a completion that returns immediately after this call.
pub fn deliverJson(ticket: Ticket, json: []const u8) void {
    const allocator = std.heap.c_allocator;

    slots_mutex.lock();
    const valid = slots[ticket.index].in_use and slots[ticket.index].generation == ticket.generation;
    if (valid) {
        // Stash the payload on the slot so the main-queue hop carries nothing
        // but an index, same as the BOOL path.
        slots[ticket.index].json = allocator.dupe(u8, json) catch null;
    }
    slots_mutex.unlock();

    if (!valid) return;
    dispatch_async_f(&_dispatch_main_q, @ptrFromInt(@as(usize, ticket.index) + 1), deliverOnMain);
}

const testing = std.testing;

test "acquire captures the current request id, release makes the slot reusable" {
    request_context.push(42);
    defer request_context.pop();

    const ticket = acquire("requestPermission") orelse return error.PoolUnexpectedlyFull;
    try testing.expectEqual(@as(i64, 42), slots[ticket.index].request_id);
    try testing.expectEqualStrings("requestPermission", slots[ticket.index].action_buf[0..slots[ticket.index].action_len]);

    abandon(ticket);
    try testing.expect(!slots[ticket.index].in_use);
}

test "a stale ticket cannot abandon a slot that was re-leased" {
    const first = acquire("a") orelse return error.PoolUnexpectedlyFull;
    abandon(first);

    // Re-lease the same slot; the old ticket's generation is now stale.
    const second = acquire("b") orelse return error.PoolUnexpectedlyFull;
    defer abandon(second);

    abandon(first); // must be a no-op
    try testing.expect(slots[second.index].in_use);
}

test "the pool exhausts loudly rather than silently" {
    var tickets: [max_in_flight]Ticket = undefined;
    var n: usize = 0;
    defer for (tickets[0..n]) |t| abandon(t);

    while (n < max_in_flight) : (n += 1) {
        tickets[n] = acquire("x") orelse break;
    }
    // Whatever other tests leased, the pool must end by refusing with null —
    // never by handing out a slot it does not have.
    try testing.expect(acquire("one-too-many") == null);
}

test "an action longer than the slot's storage is refused at acquire" {
    // Truncating it instead would make the eventual reply name a different
    // action than the page called — correlation by wrong name, reported as
    // success.
    // (`**` no longer lexes as one operator in this Zig; @splat says the same.)
    const long: [65]u8 = @splat('a');
    try testing.expect(acquire(&long) == null);
}

test "a module-shaped reply is carried and freed, and beats the granted flag" {
    request_context.push(5);
    const ticket = acquire("getPendingNotifications") orelse return error.PoolUnexpectedlyFull;
    request_context.pop();

    deliverJson(ticket, "[{\"id\":\"a\"}]");

    // The payload is on the slot until the main-queue hop drains it. Reading it
    // here is the only way to assert the copy happened without a run loop.
    slots_mutex.lock();
    defer slots_mutex.unlock();
    try testing.expect(slots[ticket.index].json != null);
    try testing.expectEqualStrings("[{\"id\":\"a\"}]", slots[ticket.index].json.?);

    // Drain by hand so the test leaves no allocation behind: the dispatch hop
    // will not run without a live main queue.
    std.heap.c_allocator.free(slots[ticket.index].json.?);
    slots[ticket.index].json = null;
    slots[ticket.index].in_use = false;
    slots[ticket.index].generation +%= 1;
}

test "a stale ticket cannot inject a payload into a re-leased slot" {
    const first = acquire("a") orelse return error.PoolUnexpectedlyFull;
    abandon(first);
    const second = acquire("b") orelse return error.PoolUnexpectedlyFull;
    defer abandon(second);

    deliverJson(first, "\"stale\"");

    slots_mutex.lock();
    defer slots_mutex.unlock();
    try testing.expect(slots[second.index].json == null);
}
