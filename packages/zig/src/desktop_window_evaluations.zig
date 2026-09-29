//! Correlate asynchronous desktop JavaScript evaluations without retaining a
//! native webview pointer. A callback carries only a monotonic ticket; a
//! navigation or close removes the ticket before an old callback can answer a
//! promise in a new document or a reopened window.

const std = @import("std");
const desktop_bridge_envelope = @import("desktop_bridge_envelope.zig");

pub const capacity = 256;

pub const Pending = struct {
    ticket: u64,
    sender_id: u32,
    target_id: u32,
    request_id: ?u64,
};

pub const Tracker = struct {
    entries: [capacity]?Pending = @splat(null),
    next_ticket: u64 = 1,

    pub fn begin(self: *Tracker, sender_id: u32, target_id: u32, request_id: ?u64) !u64 {
        if (sender_id == 0 or target_id == 0) return error.InvalidParameter;
        if (self.next_ticket == 0) return error.Busy;
        for (&self.entries) |*slot| {
            if (slot.* != null) continue;
            const ticket = self.next_ticket;
            self.next_ticket = if (ticket == std.math.maxInt(u64)) 0 else ticket + 1;
            slot.* = .{
                .ticket = ticket,
                .sender_id = sender_id,
                .target_id = target_id,
                .request_id = request_id,
            };
            return ticket;
        }
        return error.Busy;
    }

    pub fn take(self: *Tracker, ticket: u64) ?Pending {
        if (ticket == 0) return null;
        for (&self.entries) |*slot| {
            if (slot.*) |pending| {
                if (pending.ticket != ticket) continue;
                slot.* = null;
                return pending;
            }
        }
        return null;
    }

    /// Remove every operation whose requesting page or evaluation target is
    /// being replaced. The caller may reject only those with a *different*
    /// still-live sender; a navigating sender no longer owns its old promise.
    pub fn invalidateWindow(self: *Tracker, window_id: u32, out: *[capacity]Pending) []const Pending {
        if (window_id == 0) return out[0..0];
        var count: usize = 0;
        for (&self.entries) |*slot| {
            if (slot.*) |pending| {
                if (pending.sender_id != window_id and pending.target_id != window_id) continue;
                out[count] = pending;
                count += 1;
                slot.* = null;
            }
        }
        return out[0..count];
    }
};

/// Native engines return JSON text, which is inserted into a bridge reply.
/// Reject malformed or unbounded results before they can become page script.
pub fn validResultJson(json: []const u8) bool {
    if (json.len == 0 or json.len > desktop_bridge_envelope.max_message_bytes) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return false;
    defer parsed.deinit();
    return true;
}

test "concurrent evaluations retain their sender, target, and request id" {
    var tracker: Tracker = .{};
    const first = try tracker.begin(1, 2, 41);
    const second = try tracker.begin(3, 2, 42);
    try std.testing.expect(second > first);
    try std.testing.expectEqualDeep(Pending{ .ticket = second, .sender_id = 3, .target_id = 2, .request_id = 42 }, tracker.take(second).?);
    try std.testing.expectEqualDeep(Pending{ .ticket = first, .sender_id = 1, .target_id = 2, .request_id = 41 }, tracker.take(first).?);
    try std.testing.expect(tracker.take(first) == null);
}

test "navigation invalidates both target and sender without touching other pages" {
    var tracker: Tracker = .{};
    const targeted = try tracker.begin(1, 2, 11);
    const originated = try tracker.begin(2, 3, 12);
    const unaffected = try tracker.begin(4, 5, 13);
    var cancelled: [capacity]Pending = undefined;
    const affected = tracker.invalidateWindow(2, &cancelled);
    try std.testing.expectEqual(@as(usize, 2), affected.len);
    try std.testing.expectEqual(targeted, affected[0].ticket);
    try std.testing.expectEqual(originated, affected[1].ticket);
    try std.testing.expect(tracker.take(targeted) == null);
    try std.testing.expect(tracker.take(originated) == null);
    try std.testing.expectEqual(unaffected, tracker.take(unaffected).?.ticket);
}

test "closed and reopened windows cannot inherit an old completion" {
    var tracker: Tracker = .{};
    const old = try tracker.begin(1, 2, 7);
    var cancelled: [capacity]Pending = undefined;
    _ = tracker.invalidateWindow(2, &cancelled);
    const reopened = try tracker.begin(1, 3, 7);
    try std.testing.expect(old != reopened);
    try std.testing.expect(tracker.take(old) == null);
    try std.testing.expectEqual(reopened, tracker.take(reopened).?.ticket);
}

test "a full tracker refuses work without displacing an in-flight call" {
    var tracker: Tracker = .{};
    for (0..capacity) |i| {
        _ = try tracker.begin(1, 2, @intCast(i));
    }
    try std.testing.expectError(error.Busy, tracker.begin(1, 2, 999));
    try std.testing.expectEqual(@as(?u64, 1), if (tracker.take(1)) |pending| pending.ticket else null);
    try std.testing.expectError(error.InvalidParameter, tracker.begin(0, 2, null));
}

test "only bounded JSON results may enter a bridge reply" {
    try std.testing.expect(validResultJson("42"));
    try std.testing.expect(validResultJson("{\"title\":\"Child\"}"));
    try std.testing.expect(validResultJson("null"));
    try std.testing.expect(!validResultJson("undefined"));
    try std.testing.expect(!validResultJson("1);alert('injected')"));
    const large = try std.testing.allocator.alloc(u8, desktop_bridge_envelope.max_message_bytes + 1);
    defer std.testing.allocator.free(large);
    try std.testing.expect(!validResultJson(large));
}
