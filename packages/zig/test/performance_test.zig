const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Note: This performance test file uses only standard library to avoid
// module conflicts with the Craft framework modules.

/// Performance test configuration
const PerformanceConfig = struct {
    iterations: usize = 1000,
    warmup_iterations: usize = 100,
};

/// Performance metrics collector
const PerformanceMetrics = struct {
    timings: std.ArrayList(u64),

    fn init(_: std.mem.Allocator) PerformanceMetrics {
        return .{
            .timings = .empty,
        };
    }

    fn deinit(self: *PerformanceMetrics, allocator: std.mem.Allocator) void {
        self.timings.deinit(allocator);
    }

    fn record(self: *PerformanceMetrics, allocator: std.mem.Allocator, duration_ns: u64) !void {
        try self.timings.append(allocator, duration_ns);
    }

    fn calculateStats(self: *PerformanceMetrics) Stats {
        if (self.timings.items.len == 0) return .{};

        var total: u64 = 0;
        var min_val: u64 = std.math.maxInt(u64);
        var max_val: u64 = 0;

        for (self.timings.items) |timing| {
            total += timing;
            if (timing < min_val) min_val = timing;
            if (timing > max_val) max_val = timing;
        }

        const count = self.timings.items.len;
        const mean = total / count;

        // Calculate median
        std.mem.sort(u64, self.timings.items, {}, comptime std.sort.asc(u64));
        const median = if (count % 2 == 0)
            (self.timings.items[count / 2 - 1] + self.timings.items[count / 2]) / 2
        else
            self.timings.items[count / 2];

        // Calculate percentiles
        const p95_idx = @min((count * 95) / 100, count - 1);
        const p99_idx = @min((count * 99) / 100, count - 1);

        return .{
            .mean = mean,
            .median = median,
            .min = min_val,
            .max = max_val,
            .p95 = self.timings.items[p95_idx],
            .p99 = self.timings.items[p99_idx],
            .count = count,
        };
    }

    const Stats = struct {
        mean: u64 = 0,
        median: u64 = 0,
        min: u64 = 0,
        max: u64 = 0,
        p95: u64 = 0,
        p99: u64 = 0,
        count: usize = 0,

        fn print(self: Stats, name: []const u8) void {
            std.debug.print("\n=== {s} Performance Stats ===\n", .{name});
            std.debug.print("Iterations: {d}\n", .{self.count});
            std.debug.print("Mean:       {d} ns ({d:.2} µs)\n", .{ self.mean, @as(f64, @floatFromInt(self.mean)) / 1_000.0 });
            std.debug.print("Median:     {d} ns ({d:.2} µs)\n", .{ self.median, @as(f64, @floatFromInt(self.median)) / 1_000.0 });
            std.debug.print("Min:        {d} ns ({d:.2} µs)\n", .{ self.min, @as(f64, @floatFromInt(self.min)) / 1_000.0 });
            std.debug.print("Max:        {d} ns ({d:.2} µs)\n", .{ self.max, @as(f64, @floatFromInt(self.max)) / 1_000.0 });
            std.debug.print("P95:        {d} ns ({d:.2} µs)\n", .{ self.p95, @as(f64, @floatFromInt(self.p95)) / 1_000.0 });
            std.debug.print("P99:        {d} ns ({d:.2} µs)\n", .{ self.p99, @as(f64, @floatFromInt(self.p99)) / 1_000.0 });
        }
    };
};

/// Timer utility for precise measurements.
const Timer = struct {
    start_ns: i128,

    fn start() Timer {
        return .{ .start_ns = monotonic_ns() };
    }

    fn elapsed(self: *const Timer) u64 {
        const diff = monotonic_ns() - self.start_ns;
        if (diff < 0) return 0;
        return @as(u64, @intCast(diff));
    }

    fn monotonic_ns() i128 {
        // Inlined rather than imported: this file is its own root module and
        // cannot reach `../src/compat.zig`. POSIX `clock_gettime` has no
        // Windows counterpart (`clockid_t` is `void` there).
        if (comptime builtin.os.tag == .windows) {
            const kern = struct {
                extern "kernel32" fn QueryPerformanceCounter(c: *i64) callconv(.c) c_int;
                extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.c) c_int;
            };
            var counter: i64 = 0;
            var frequency: i64 = 0;
            if (kern.QueryPerformanceFrequency(&frequency) == 0 or frequency <= 0) return 0;
            if (kern.QueryPerformanceCounter(&counter) == 0) return 0;
            return @intCast((@as(u128, @intCast(counter)) * std.time.ns_per_s) / @as(u128, @intCast(frequency)));
        }
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }
};

// =============================================================================
// Basic Performance Tests
// =============================================================================

test "Performance: Arena allocator bulk operations" {
    const config = PerformanceConfig{ .iterations = 1000 };
    var metrics = PerformanceMetrics.init(testing.allocator);
    defer metrics.deinit(testing.allocator);

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const timer = Timer.start();
        var j: usize = 0;
        while (j < 100) : (j += 1) {
            _ = try arena.allocator().alloc(u8, 1024);
        }
        try metrics.record(testing.allocator, timer.elapsed());
    }

    const stats = metrics.calculateStats();
    stats.print("Arena Bulk Allocation (100 x 1KB)");
}

test "Performance: ArrayList append operations" {
    const config = PerformanceConfig{ .iterations = 10000 };
    var metrics = PerformanceMetrics.init(testing.allocator);
    defer metrics.deinit(testing.allocator);

    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(testing.allocator);

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const timer = Timer.start();
        try list.append(testing.allocator, @intCast(i));
        try metrics.record(testing.allocator, timer.elapsed());
    }

    const stats = metrics.calculateStats();
    stats.print("ArrayList Append");
}

test "Performance: HashMap insert operations" {
    const config = PerformanceConfig{ .iterations = 100 };
    var metrics = PerformanceMetrics.init(testing.allocator);
    defer metrics.deinit(testing.allocator);

    var map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer map.deinit();

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const timer = Timer.start();
        try map.put(@intCast(i), @intCast(i));
        try metrics.record(testing.allocator, timer.elapsed());
    }

    const stats = metrics.calculateStats();
    stats.print("HashMap Insert");
}

test "Performance: String formatting" {
    const config = PerformanceConfig{ .iterations = 100000 };
    var metrics = PerformanceMetrics.init(testing.allocator);
    defer metrics.deinit(testing.allocator);

    var buf: [256]u8 = undefined;

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const timer = Timer.start();
        _ = std.fmt.bufPrint(&buf, "Hello {s}! Number: {d}", .{ "World", i }) catch unreachable;
        try metrics.record(testing.allocator, timer.elapsed());
    }

    const stats = metrics.calculateStats();
    stats.print("String Formatting");

    // Should be very fast
    try testing.expect(stats.mean < 10_000);
}

// =============================================================================
// Stress Tests
// =============================================================================

test "Stress: Memory allocation patterns" {
    const iterations = 10000;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var allocations: std.ArrayList([]u8) = .empty;
    defer allocations.deinit(testing.allocator);

    const timer = Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const size = 1024 + (i % 1024);
        const mem = try allocator.alloc(u8, size);
        try allocations.append(testing.allocator, mem);
    }
    const duration = timer.elapsed();

    std.debug.print("\nStress Test: {d} allocations in {d:.2} ms\n", .{ iterations, @as(f64, @floatFromInt(duration)) / 1_000_000.0 });
    std.debug.print("Average allocation size: 1.5 KB\n", .{});
    std.debug.print("Total allocated: {d} MB\n", .{(iterations * 1536) / (1024 * 1024)});
}

test "Stress: Rapid ArrayList growth" {
    const iterations = 100000;
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(testing.allocator);

    const timer = Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try list.append(testing.allocator, @intCast(i));
    }
    const duration = timer.elapsed();

    std.debug.print("\nStress Test: {d} appends in {d:.2} ms\n", .{ iterations, @as(f64, @floatFromInt(duration)) / 1_000_000.0 });
    std.debug.print("Throughput: {d:.0} ops/sec\n", .{@as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(duration)) / 1_000_000_000.0)});

    // Should complete in reasonable time
    try testing.expect(duration < 5_000_000_000);
}
