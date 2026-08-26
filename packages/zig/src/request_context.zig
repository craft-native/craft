//! Which bridge call the current reply belongs to.
//!
//! The page can have several calls of the same action in flight at once, and
//! six action names are served by more than one bridge (`get` by keychain and
//! tags, `isEnabled` by autoLaunch, bluetooth and crashReporter, and four
//! more). Until now a reply named only its action, so `craft-bridge.js` had to
//! guess which caller it answered by shifting a per-action FIFO — a guess that
//! is wrong the moment two calls settle out of the order they were made.
//!
//! Rather than thread an id parameter through 267 `sendResultToJS` call sites
//! in 39 files — five different `handleMessage` signatures, most of them
//! reached through helpers — the dispatcher records the id of the message it
//! is serving here, and `bridge_error.zig` reads it back when it formats the
//! reply. Handlers are untouched and cannot forget to pass it along.
//!
//! ## Why a stack and not one slot
//!
//! Bridge dispatch nests. `bridge_dialog.zig` runs `NSOpenPanel` and friends
//! through `runModal`, which spins a nested run loop, and that run loop keeps
//! delivering `WKScriptMessage`s — so a second bridge call is dispatched, and
//! completes, in the middle of the first one. A single slot would be
//! overwritten by the inner call and the outer dialog's reply would go out
//! wearing the inner call's id, which is worse than no id at all: the page
//! would resolve a stranger's promise and be certain it was right.
//!
//! ## Why every frame is pushed, even without an id
//!
//! `push` takes an optional. A message that carries no `i` — an older page, or
//! the description-format fallback path — still pushes a frame, holding null.
//! If id-less messages skipped the push instead, one dispatched inside a call
//! that *does* have an id would inherit it, and the same misattribution
//! follows. An absent id has to shadow the outer one.
//!
//! ## Threading
//!
//! Thread-local, and deliberately so. Every bridge message is dispatched on the
//! main thread, and every one of the 267 reply sites is reached synchronously
//! from that dispatch (verified: none sits inside a `callconv(.c)` callback).
//! A reply that did somehow originate on a worker thread reads an empty stack,
//! reports no id, and the page falls back to the action FIFO — exactly the
//! behaviour it has today. Degrading to the old guess is acceptable; handing
//! out an id belonging to whatever the main thread happens to be serving is
//! not.

const std = @import("std");

/// Deep enough for any real nesting: frames are only added by a modal run loop
/// re-entering dispatch, and those nest by user action — a file panel opened
/// from a file panel. Sixteen is far past anything a person can drive.
pub const max_depth = 16;

threadlocal var frames: [max_depth]?u64 = undefined;
threadlocal var depth: usize = 0;

/// Begin serving `id`. Pass null when the message carried no id, so it shadows
/// any enclosing request rather than inheriting it. Always pair with `pop`.
pub fn push(id: ?u64) void {
    if (depth < max_depth) frames[depth] = id;
    // Counted past the array on purpose: `pop` stays balanced with `push`, and
    // `current` reports the overflowed frames as unknown rather than reading a
    // stale id from the top of the array.
    depth += 1;
}

/// Finish serving the innermost request.
pub fn pop() void {
    if (depth == 0) return;
    depth -= 1;
}

/// The id of the request being served on this thread, or null if there is
/// none, if it carried none, or if nesting ran past `max_depth`. Null means
/// "cannot say" — the page keeps its old FIFO behaviour — never "no such
/// call".
pub fn current() ?u64 {
    if (depth == 0 or depth > max_depth) return null;
    return frames[depth - 1];
}

/// How deep dispatch is nested right now. For tests and diagnostics.
pub fn currentDepth() usize {
    return depth;
}

/// Drop every frame. Tests only — production balances push/pop with `defer`.
pub fn resetForTesting() void {
    depth = 0;
}

/// The `i` field of a bridge envelope: the page's id for this call.
///
/// Absent for the tray and menubar polling `_post`s, which nobody awaits, and
/// for the description-format fallback path — so a missing or unusable value
/// is normal and means "no id", not a malformed message.
/// Accepts a JSON number or a decimal string: JavaScript integers arrive as
/// numbers, but an id that has been through a `JSON.stringify` round trip on
/// the page's side could arrive as either.
pub fn fromEnvelope(root: std.json.ObjectMap) ?u64 {
    const v = root.get("i") orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

const testing = std.testing;

test "no request in flight reports no id" {
    resetForTesting();
    try testing.expectEqual(@as(?u64, null), current());
}

test "the id of the request being served is the one reported" {
    resetForTesting();
    push(7);
    defer pop();
    try testing.expectEqual(@as(?u64, 7), current());
}

test "a nested request does not leak its id to the enclosing reply" {
    // This is the dialog case: runModal spins a nested run loop, another
    // bridge message is dispatched and answered inside it, and only then does
    // the dialog reply. The outer reply must still be id 1.
    resetForTesting();
    push(1);
    {
        push(2);
        try testing.expectEqual(@as(?u64, 2), current());
        pop();
    }
    try testing.expectEqual(@as(?u64, 1), current());
    pop();
    try testing.expectEqual(@as(?u64, null), current());
}

test "a nested message without an id shadows the enclosing one" {
    // The failure this prevents: an older page, or the description-format
    // fallback, dispatched inside a call that does have an id. Inheriting 1
    // here would send that page's reply to a promise it never made.
    resetForTesting();
    push(1);
    push(null);
    try testing.expectEqual(@as(?u64, null), current());
    pop();
    try testing.expectEqual(@as(?u64, 1), current());
    pop();
}

test "nesting past max_depth reports unknown rather than a stale id" {
    resetForTesting();
    var i: usize = 0;
    while (i < max_depth) : (i += 1) push(@intCast(i));
    try testing.expectEqual(@as(?u64, max_depth - 1), current());

    push(999);
    // 999 had nowhere to go. The answer is "cannot say", not frames[15].
    try testing.expectEqual(@as(?u64, null), current());
    pop();

    try testing.expectEqual(@as(?u64, max_depth - 1), current());
    i = 0;
    while (i < max_depth) : (i += 1) pop();
    try testing.expectEqual(@as(usize, 0), currentDepth());
}

test "push and pop stay balanced across overflow" {
    resetForTesting();
    const over = max_depth + 5;
    var i: usize = 0;
    while (i < over) : (i += 1) push(1);
    try testing.expectEqual(@as(usize, over), currentDepth());
    i = 0;
    while (i < over) : (i += 1) pop();
    try testing.expectEqual(@as(usize, 0), currentDepth());
    try testing.expectEqual(@as(?u64, null), current());
}

test "pop on an empty stack is not an underflow" {
    resetForTesting();
    pop();
    pop();
    try testing.expectEqual(@as(usize, 0), currentDepth());
    push(3);
    try testing.expectEqual(@as(?u64, 3), current());
    pop();
}

test "id zero is a real id, distinct from absent" {
    // JS ids start at 1 so this should not arise, but the type must not quietly
    // conflate the two — a `0 == none` sentinel is how this bug class returns.
    resetForTesting();
    push(0);
    try testing.expectEqual(@as(?u64, 0), current());
    pop();
    try testing.expectEqual(@as(?u64, null), current());
}

fn envelopeId(json: []const u8) !?u64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return fromEnvelope(parsed.value.object);
}

test "the envelope's id is read as the call id" {
    try testing.expectEqual(@as(?u64, 12), try envelopeId(
        \\{"t":"tags","a":"get","d":"","i":12}
    ));
}

test "a message with no id is not an error, it is a message nobody awaits" {
    try testing.expectEqual(@as(?u64, null), try envelopeId(
        \\{"t":"tray","a":"pollActions","d":""}
    ));
}

test "an id that arrived as a string is still an id" {
    try testing.expectEqual(@as(?u64, 900719925474099), try envelopeId(
        \\{"t":"tags","a":"get","i":"900719925474099"}
    ));
}

test "an unusable id is no id rather than a rejected message" {
    // The message still has to be served. Refusing to dispatch it would turn a
    // page that sends something odd into a page where nothing works at all.
    for ([_][]const u8{
        \\{"a":"get","i":-1}
        ,
        \\{"a":"get","i":null}
        ,
        \\{"a":"get","i":"abc"}
        ,
        \\{"a":"get","i":{"nested":1}}
        ,
        \\{"a":"get","i":[1]}
        ,
        \\{"a":"get","i":true}
        ,
    }) |json| {
        try testing.expectEqual(@as(?u64, null), try envelopeId(json));
    }
}

test "the largest id JavaScript can count to round-trips" {
    try testing.expectEqual(@as(?u64, 9007199254740991), try envelopeId(
        \\{"a":"get","i":9007199254740991}
    ));
}
