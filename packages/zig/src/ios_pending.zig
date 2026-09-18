//! A call parked on a completion block, answerable from either side exactly once.
//!
//! `ios_async` hands out reply slots, and a slot is released the moment
//! something answers it. That is right for the reply, and wrong for the block:
//! a deadline releases slot k, the next call leases slot k, and — if blocks
//! were chosen by reply slot — the first call's late completion would fire the
//! same block and answer the second call with the first one's result.
//!
//! #211 found that in `removeSiriShortcut`, where the only answer came from a
//! system daemon that sometimes never called back. The fix there was to make
//! blocks their own resource: a block whose call the deadline answered stays
//! `owed` until the framework calls it, and is never handed to another call in
//! the meantime. This file is that design, lifted out so the other actions with
//! the same shape can take a deadline safely (#223).
//!
//! What a caller still owns: the block array itself (its shape is the
//! framework's, `void (^)(void)` for Siri and `void (^)(NSArray *)` elsewhere),
//! and what it parks. This owns only who may answer, and when.

const std = @import("std");
const ios_async = @import("ios_async.zig");
const compat = @import("compat.zig");
const compat_mutex = @import("compat_mutex.zig");

/// Twice the reply slots, so every slot can be waiting while as many blocks
/// again are still owed a completion that has not come.
pub const block_count = 2 * ios_async.max_in_flight;

/// `Call` is whatever the module needs to answer: a shaped reply, a selector
/// pair, a chain of HealthKit stages. This file neither reads nor frees it —
/// whichever side takes the entry owns it from then on.
pub fn Table(comptime Call: type) type {
    return struct {
        const Self = @This();

        /// A parked call. The ticket is stored rather than rebuilt, because a
        /// `Ticket` is an index *and* a generation and the deadline matches on
        /// both — matching on the index alone is exactly the bug this prevents.
        pub const Entry = struct {
            ticket: ios_async.Ticket,
            call: Call,
            started_ms: i64,
        };

        const State = union(enum) {
            free,
            waiting: Entry,
            /// Answered by the deadline. The framework still holds this block
            /// and may call it; when it does, that call is ignored and the
            /// block is freed. Carries when the call started, so a late
            /// completion can say how late it was.
            owed: i64,
        };

        pub const Settled = union(enum) {
            /// The completion arrived first: answer with this call.
            reply: Entry,
            /// The deadline already answered. Nothing to send, and when it began.
            late: i64,
            /// No call was ever parked on this block.
            stray,
        };

        blocks: [block_count]State = @splat(.free),
        mutex: compat_mutex.Mutex = .{},

        /// Park `call` on the first free block.
        ///
        /// Null when every block is waiting or owed. The caller refuses the
        /// action rather than reusing an owed block — a refusal the page can
        /// act on, against an answer that would go to the wrong call.
        pub fn claim(self: *Self, ticket: ios_async.Ticket, call: Call) ?u5 {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.blocks, 0..) |*state, i| {
                if (state.* != .free) continue;
                state.* = .{ .waiting = .{
                    .ticket = ticket,
                    .call = call,
                    .started_ms = compat.milliTimestamp(),
                } };
                return @intCast(i);
            }
            return null;
        }

        /// The deadline's half: take the call `ticket` names if it is still
        /// waiting, and leave its block owed.
        ///
        /// Matching the whole ticket is what stops a timer armed for one call
        /// from expiring a newer call that leased the same reply slot.
        pub fn expireIfWaiting(self: *Self, ticket: ios_async.Ticket) ?Entry {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.blocks) |*state| {
                const entry = switch (state.*) {
                    .waiting => |waiting| waiting,
                    else => continue,
                };
                if (entry.ticket.index != ticket.index or
                    entry.ticket.generation != ticket.generation) continue;
                state.* = .{ .owed = entry.started_ms };
                return entry;
            }
            return null;
        }

        /// The completion's half.
        ///
        /// Each block leaves `waiting` or `owed` exactly once, under the lock,
        /// so the completion and the deadline cannot both answer.
        pub fn settle(self: *Self, block: u5) Settled {
            self.mutex.lock();
            defer self.mutex.unlock();
            const state = self.blocks[block];
            self.blocks[block] = .free;
            return switch (state) {
                .waiting => |entry| .{ .reply = entry },
                .owed => |started_ms| .{ .late = started_ms },
                .free => .stray,
            };
        }

        /// Test-only: drop every parked call without answering any of them.
        pub fn resetForTest(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.blocks = @splat(.free);
        }
    };
}

const testing = std.testing;

/// A payload with nothing in it: these tests are about who may answer.
const Marker = struct { id: u32 };
var table: Table(Marker) = .{};

fn fresh() *Table(Marker) {
    table.resetForTest();
    return &table;
}

test "a deadline answers a waiting call once and leaves its block owed" {
    const t = fresh();
    const ticket: ios_async.Ticket = .{ .index = 3, .generation = 9 };
    const block = t.claim(ticket, .{ .id = 1 }) orelse return error.NoFreeBlock;

    const taken = t.expireIfWaiting(ticket) orelse return error.NothingToExpire;
    try testing.expectEqual(@as(u32, 1), taken.call.id);
    // Gone from the deadline's point of view, and not free for another call.
    try testing.expect(t.expireIfWaiting(ticket) == null);
    try testing.expect(t.claim(.{ .index = 4, .generation = 1 }, .{ .id = 2 }) != block);
}

test "a completion after its deadline is ignored, and frees the block" {
    const t = fresh();
    const ticket: ios_async.Ticket = .{ .index = 3, .generation = 9 };
    const block = t.claim(ticket, .{ .id = 1 }) orelse return error.NoFreeBlock;
    _ = t.expireIfWaiting(ticket);

    switch (t.settle(block)) {
        .late => {},
        else => return error.LateCompletionAnswered,
    }
    // And now the block is reusable, which an owed one was not.
    try testing.expectEqual(block, t.claim(.{ .index = 5, .generation = 2 }, .{ .id = 3 }).?);
}

test "a deadline that fires after the completion does nothing" {
    const t = fresh();
    const ticket: ios_async.Ticket = .{ .index = 3, .generation = 9 };
    const block = t.claim(ticket, .{ .id = 1 }) orelse return error.NoFreeBlock;

    switch (t.settle(block)) {
        .reply => |entry| try testing.expectEqual(@as(u32, 1), entry.call.id),
        else => return error.CompletionDidNotAnswer,
    }
    try testing.expect(t.expireIfWaiting(ticket) == null);
}

test "a stale deadline cannot expire a newer call on the same reply slot" {
    // The whole reason blocks are not chosen by reply slot: slot 3 is answered
    // and released, the next call leases slot 3, and the first call's timer
    // still fires.
    const t = fresh();
    const stale: ios_async.Ticket = .{ .index = 3, .generation = 9 };
    const current: ios_async.Ticket = .{ .index = 3, .generation = 10 };
    _ = t.claim(current, .{ .id = 7 }) orelse return error.NoFreeBlock;

    try testing.expect(t.expireIfWaiting(stale) == null);
    const taken = t.expireIfWaiting(current) orelse return error.NothingToExpire;
    try testing.expectEqual(@as(u32, 7), taken.call.id);
}

test "a settle on a block nobody parked on is a stray, not an answer" {
    const t = fresh();
    switch (t.settle(0)) {
        .stray => {},
        else => return error.StrayAnswered,
    }
}

test "with every block owed, a call is refused rather than given one" {
    const t = fresh();
    for (0..block_count) |i| {
        const ticket: ios_async.Ticket = .{ .index = @intCast(i % ios_async.max_in_flight), .generation = @intCast(i + 1) };
        _ = t.claim(ticket, .{ .id = @intCast(i) }) orelse return error.NoFreeBlock;
        _ = t.expireIfWaiting(ticket);
    }
    try testing.expect(t.claim(.{ .index = 0, .generation = 999 }, .{ .id = 0 }) == null);
}

test "there are more blocks than reply slots, so a full pool can still be owed" {
    try testing.expect(block_count > ios_async.max_in_flight);
}
