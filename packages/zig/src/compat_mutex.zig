//! Craft's mutex and condition variable.
//!
//! `std.Thread.Mutex` and `std.Thread.Condition` do not exist in this Zig — the
//! Io rework moved blocking primitives to `std.Io.Mutex` and
//! `std.Io.Condition`, which take an `Io` because that is what knows how to
//! wait. This file existed to paper over that, and papered over it by spinning:
//! `Mutex.lock` looped on `tryLock` with `spinLoopHint`, `Condition.wait` spun
//! on a `u32` flag, and neither ever yielded.
//!
//! What that costs, measured: three threads waiting 300ms on a spun flag burn
//! **896ms of CPU** — three cores held against whatever they are waiting for.
//! A futex wait costs approximately nothing. On a machine with cores to spare
//! it is waste; on a busy one the waiters are competing with the thread they
//! need to finish.
//!
//! The flag-based `Condition` also had a narrower hazard — `broadcast` set one
//! flag and the first waiter to observe it cleared it, which can lose a
//! wakeup. It is a race rather than a certainty, and spinning waiters poll
//! often enough that they usually all see it; a test written to catch it
//! passed against the old code, so it is recorded here as a reason and not
//! claimed as a demonstrated bug. The CPU measurement above is the one that
//! reproduces.
//!
//! Both real primitives are used now. The `Io` they need is handed to this
//! module once at startup rather than threaded through all 88 lock sites,
//! which would have been a signature change across ten files for something
//! that is a property of the process, not of any call.
//!
//! ## Why the fallback is still here
//!
//! `io_context.init` is not the first thing that runs, and tests, the
//! `--eval` path and anything that locks before startup finishes have no `Io`.
//! Those take the spin path — but a spin that yields, so it cannot starve the
//! holder.
//!
//! The two paths are safe to mix in the only direction that occurs. `install`
//! is called once and never undone, so:
//!
//!   - before it, the only way to acquire is `tryLock`, which moves the state
//!     `unlocked -> locked_once` and never to `contended`; an unlock with no
//!     `Io` therefore has no waiter to wake, and none can exist.
//!   - after it, every acquire and release has an `Io`.
//!
//! A lock taken before and released after is fine: the state is `locked_once`,
//! and `unlock` wakes nobody either way.

const std = @import("std");

/// The `Io` used for blocking. Null until `install`.
var runtime_io: ?std.Io = null;

/// Hand this module the process `Io`. Called once, from `io_context.init`,
/// before anything else has had a chance to contend for a lock.
///
/// Deliberately not read from `io_context` on demand: `global_state.zig` locks
/// one of these mutexes to answer `io_context.get()`, so asking it here would
/// recurse into the lock being taken.
pub fn install(io: std.Io) void {
    runtime_io = io;
}

/// For tests that need to exercise the pre-startup path.
pub fn uninstallForTesting() void {
    runtime_io = null;
}

/// How many times to spin before offering the core to someone else.
///
/// Long enough that an uncontended hand-off does not pay for a syscall, short
/// enough that a waiter cannot hold a core against the lock's owner — which is
/// the failure the old unbounded spin had.
const spins_before_yield = 128;

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        if (runtime_io) |io| {
            // Uncancelable: a lock acquisition is not a cancelation point, and
            // craft has no caller prepared to handle one here.
            self.inner.lockUncancelable(io);
            return;
        }
        var spins: usize = 0;
        while (!self.inner.tryLock()) {
            spins +%= 1;
            if (spins % spins_before_yield == 0) std.Thread.yield() catch {};
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (runtime_io) |io| {
            self.inner.unlock(io);
            return;
        }
        // No `Io` means nothing can be waiting on the futex: the only way to
        // have acquired this lock is `tryLock`, which never sets `contended`.
        self.inner.state.store(.unlocked, .release);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        if (runtime_io) |io| {
            self.inner.waitUncancelable(io, &mutex.inner);
            return;
        }
        // No `Io`, so no futex to wait on. Release the lock, yield, retake it —
        // the caller is required to re-check its predicate in a loop, which is
        // the same contract a real condition variable imposes for spurious
        // wakeups.
        mutex.unlock();
        std.Thread.yield() catch {};
        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        if (runtime_io) |io| self.inner.signal(io);
    }

    pub fn broadcast(self: *Condition) void {
        if (runtime_io) |io| self.inner.broadcast(io);
    }
};

const testing = std.testing;

test "a mutex excludes" {
    var m: Mutex = .{};
    m.lock();
    try testing.expect(!m.tryLock());
    m.unlock();
    try testing.expect(m.tryLock());
    m.unlock();
}

test "lock and unlock work before an Io is installed" {
    // Startup, `--eval`, and every test take this path.
    uninstallForTesting();
    var m: Mutex = .{};
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        m.lock();
        m.unlock();
    }
    try testing.expect(m.tryLock());
    m.unlock();
}

test "a lock taken before an Io arrives can be released after" {
    // The only mixing that can occur, since `install` happens once and is
    // never undone. The state is `locked_once` either way, so `unlock` has
    // nobody to wake.
    uninstallForTesting();
    var m: Mutex = .{};
    m.lock();
    install(std.testing.io);
    defer uninstallForTesting();
    m.unlock();
    try testing.expect(m.tryLock());
    m.unlock();
}

test "several threads hand the lock around without losing a count" {
    // The spin path used to be able to starve the holder on a single core.
    // This does not detect starvation directly, but it does detect the thing
    // starvation eventually causes: a count that does not add up.
    uninstallForTesting();

    const Shared = struct {
        mutex: Mutex = .{},
        counter: usize = 0,

        fn bump(self: *@This(), times: usize) void {
            var i: usize = 0;
            while (i < times) : (i += 1) {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.counter += 1;
            }
        }
    };

    var shared: Shared = .{};
    const per_thread = 2000;
    const thread_count = 4;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Shared.bump, .{ &shared, per_thread });
    }
    for (threads) |t| t.join();

    try testing.expectEqual(thread_count * per_thread, shared.counter);
}

test "broadcast reaches every waiter" {
    // Not a regression test: the old flag-based Condition passes this too,
    // because spinning waiters poll often enough that they all observe the
    // flag before any of them clears it. Kept because it is the property the
    // replacement has to hold, and because it is the shape of test that would
    // catch a future `broadcast` that only signals one waiter.
    if (!@hasDecl(std.testing, "io")) return error.SkipZigTest;
    install(std.testing.io);
    defer uninstallForTesting();

    const Shared = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        ready: bool = false,
        woken: std.atomic.Value(usize) = .init(0),

        fn waiter(self: *@This()) void {
            self.mutex.lock();
            // Looped, because a condition variable may wake spuriously — the
            // contract both the real primitive and the fallback rely on.
            while (!self.ready) self.cond.wait(&self.mutex);
            self.mutex.unlock();
            _ = self.woken.fetchAdd(1, .release);
        }
    };

    var shared: Shared = .{};
    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.waiter, .{&shared});

    shared.mutex.lock();
    shared.ready = true;
    shared.mutex.unlock();
    shared.cond.broadcast();

    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 3), shared.woken.load(.acquire));
}
