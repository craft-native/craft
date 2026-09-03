const std = @import("std");
const io_context = @import("io_context.zig");

/// Benchmarking System
/// Provides performance measurement and reporting for components and operations
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    mean_time_ns: u64,
    median_time_ns: u64,
    std_dev_ns: f64,
    ops_per_sec: f64,
    memory_allocated: usize,
    memory_peak: usize,

    pub fn format(self: BenchmarkResult, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
            \\{s}:
            \\  Iterations:    {d}
            \\  Total Time:    {d:.2} ms
            \\  Mean Time:     {d:.2} µs
            \\  Min Time:      {d:.2} µs
            \\  Max Time:      {d:.2} µs
            \\  Median Time:   {d:.2} µs
            \\  Std Dev:       {d:.2} µs
            \\  Ops/sec:       {d:.0}
            \\  Memory Alloc:  {d} bytes
            \\  Memory Peak:   {d} bytes
            \\
        , .{
            self.name,
            self.iterations,
            @as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.mean_time_ns)) / 1_000.0,
            @as(f64, @floatFromInt(self.min_time_ns)) / 1_000.0,
            @as(f64, @floatFromInt(self.max_time_ns)) / 1_000.0,
            @as(f64, @floatFromInt(self.median_time_ns)) / 1_000.0,
            self.std_dev_ns / 1_000.0,
            self.ops_per_sec,
            self.memory_allocated,
            self.memory_peak,
        });
    }
};

pub const Benchmark = struct {
    name: []const u8,
    allocator: std.mem.Allocator,
    iterations: usize,
    warmup_iterations: usize,
    times: std.ArrayList(u64),
    memory_tracker: ?*MemoryTracker,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, iterations: usize) !*Benchmark {
        const bench = try allocator.create(Benchmark);
        errdefer allocator.destroy(bench);
        bench.* = Benchmark{
            .name = name,
            .allocator = allocator,
            .iterations = iterations,
            .warmup_iterations = @min(iterations / 10, 100),
            .times = .empty,
            .memory_tracker = null,
        };
        return bench;
    }

    pub fn deinit(self: *Benchmark) void {
        self.times.deinit(self.allocator);
        if (self.memory_tracker) |tracker| {
            tracker.deinit();
            self.allocator.destroy(tracker);
        }
        self.allocator.destroy(self);
    }

    pub fn enableMemoryTracking(self: *Benchmark) !void {
        self.memory_tracker = try MemoryTracker.init(self.allocator);
    }

    pub fn run(self: *Benchmark, comptime func: anytype, args: anytype) !BenchmarkResult {
        // Warmup
        var i: usize = 0;
        while (i < self.warmup_iterations) : (i += 1) {
            _ = try @call(.auto, func, args);
        }

        // Reset memory tracker
        if (self.memory_tracker) |tracker| {
            tracker.reset();
        }

        // Actual benchmark
        i = 0;
        while (i < self.iterations) : (i += 1) {
            const start_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);
            _ = try @call(.auto, func, args);
            const end_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);
            const elapsed = start_ts.durationTo(end_ts);
            // Clamp to 0 so a clock slew between `start_ts` and `end_ts`
            // (NTP adjustment, VM pause, etc.) can't produce a negative
            // `raw.nanoseconds` and panic in `@intCast`.
            const raw_ns = @max(elapsed.raw.nanoseconds, 0);
            try self.times.append(self.allocator, @as(u64, @intCast(raw_ns)));
        }

        return self.calculateResult();
    }

    fn calculateResult(self: *Benchmark) !BenchmarkResult {
        if (self.times.items.len == 0) {
            return error.NoMeasurements;
        }

        // Sort times for percentile calculations
        std.mem.sort(u64, self.times.items, {}, std.sort.asc(u64));

        var total: u64 = 0;
        var min_time: u64 = std.math.maxInt(u64);
        var max_time: u64 = 0;

        for (self.times.items) |time| {
            total += time;
            min_time = @min(min_time, time);
            max_time = @max(max_time, time);
        }

        const mean = total / self.times.items.len;
        // Correct median: for even-length samples we average the two
        // middle elements. The previous code returned the upper-middle
        // element only, biasing results upward for all even iteration
        // counts.
        const n = self.times.items.len;
        const median: u64 = if (n % 2 == 1)
            self.times.items[n / 2]
        else
            (self.times.items[n / 2 - 1] + self.times.items[n / 2]) / 2;

        // Calculate standard deviation
        var variance_sum: f64 = 0.0;
        for (self.times.items) |time| {
            const diff = @as(f64, @floatFromInt(time)) - @as(f64, @floatFromInt(mean));
            variance_sum += diff * diff;
        }
        const variance = variance_sum / @as(f64, @floatFromInt(self.times.items.len));
        const std_dev = @sqrt(variance);

        // Calculate ops per second
        const mean_seconds = @as(f64, @floatFromInt(mean)) / 1_000_000_000.0;
        const ops_per_sec = if (mean_seconds > 0) 1.0 / mean_seconds else 0.0;

        var memory_allocated: usize = 0;
        var memory_peak: usize = 0;
        if (self.memory_tracker) |tracker| {
            memory_allocated = tracker.total_allocated;
            memory_peak = tracker.peak_allocated;
        }

        return BenchmarkResult{
            .name = self.name,
            .iterations = self.times.items.len,
            .total_time_ns = total,
            .min_time_ns = min_time,
            .max_time_ns = max_time,
            .mean_time_ns = mean,
            .median_time_ns = median,
            .std_dev_ns = std_dev,
            .ops_per_sec = ops_per_sec,
            .memory_allocated = memory_allocated,
            .memory_peak = memory_peak,
        };
    }
};

pub const MemoryTracker = struct {
    allocator: std.mem.Allocator,
    total_allocated: usize,
    total_freed: usize,
    peak_allocated: usize,
    current_allocated: usize,
    allocation_count: usize,
    free_count: usize,

    pub fn init(allocator: std.mem.Allocator) !*MemoryTracker {
        const tracker = try allocator.create(MemoryTracker);
        tracker.* = MemoryTracker{
            .allocator = allocator,
            .total_allocated = 0,
            .total_freed = 0,
            .peak_allocated = 0,
            .current_allocated = 0,
            .allocation_count = 0,
            .free_count = 0,
        };
        return tracker;
    }

    pub fn deinit(self: *MemoryTracker) void {
        _ = self;
    }

    pub fn reset(self: *MemoryTracker) void {
        self.total_allocated = 0;
        self.total_freed = 0;
        self.peak_allocated = 0;
        self.current_allocated = 0;
        self.allocation_count = 0;
        self.free_count = 0;
    }

    pub fn trackAllocation(self: *MemoryTracker, size: usize) void {
        self.total_allocated += size;
        self.current_allocated += size;
        self.allocation_count += 1;
        self.peak_allocated = @max(self.peak_allocated, self.current_allocated);
    }

    pub fn trackFree(self: *MemoryTracker, size: usize) void {
        self.total_freed += size;
        // Guard against integer underflow. Callers may legitimately free a
        // larger block than what we've recorded as currently allocated (e.g.
        // pre-existing allocations, mismatched track/free pairs); previously
        // this would wrap to a huge value and distort every subsequent stat.
        self.current_allocated -|= size;
        self.free_count += 1;
    }

    pub fn getReport(self: *const MemoryTracker, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
            \\Memory Report:
            \\  Total Allocated:   {d} bytes
            \\  Total Freed:       {d} bytes
            \\  Current Allocated: {d} bytes
            \\  Peak Allocated:    {d} bytes
            \\  Allocations:       {d}
            \\  Frees:             {d}
            \\  Leaked:            {d} bytes
            \\
        , .{
            self.total_allocated,
            self.total_freed,
            self.current_allocated,
            self.peak_allocated,
            self.allocation_count,
            self.free_count,
            self.current_allocated,
        });
    }
};

pub const BenchmarkSuite = struct {
    name: []const u8,
    allocator: std.mem.Allocator,
    results: std.ArrayList(BenchmarkResult),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*BenchmarkSuite {
        const suite = try allocator.create(BenchmarkSuite);
        suite.* = BenchmarkSuite{
            .name = name,
            .allocator = allocator,
            .results = .empty,
        };
        return suite;
    }

    pub fn deinit(self: *BenchmarkSuite) void {
        self.results.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addResult(self: *BenchmarkSuite, result: BenchmarkResult) !void {
        try self.results.append(self.allocator, result);
    }

    pub fn generateReport(self: *const BenchmarkSuite, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        const header = try std.fmt.allocPrint(allocator, "Benchmark Suite: {s}\n", .{self.name});
        defer allocator.free(header);
        try buf.appendSlice(allocator, header);
        try buf.appendSlice(allocator, "================================================================================\n");

        for (self.results.items) |result| {
            const formatted = try result.format(allocator);
            defer allocator.free(formatted);
            const line = try std.fmt.allocPrint(allocator, "{s}\n", .{formatted});
            defer allocator.free(line);
            try buf.appendSlice(allocator, line);
        }

        try buf.appendSlice(allocator, "================================================================================\n");
        const footer = try std.fmt.allocPrint(allocator, "Total benchmarks: {d}\n", .{self.results.items.len});
        defer allocator.free(footer);
        try buf.appendSlice(allocator, footer);

        return buf.toOwnedSlice(allocator);
    }

    pub fn generateJSON(self: *const BenchmarkSuite, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{");
        const suite_str = try std.fmt.allocPrint(allocator, "\"suite\":\"{s}\",", .{self.name});
        defer allocator.free(suite_str);
        try buf.appendSlice(allocator, suite_str);
        try buf.appendSlice(allocator, "\"results\":[");

        for (self.results.items, 0..) |result, i| {
            if (i > 0) try buf.append(allocator, ',');
            const entry = try std.fmt.allocPrint(allocator,
                \\{{"name":"{s}","iterations":{d},"total_time_ns":{d},"mean_time_ns":{d},"min_time_ns":{d},"max_time_ns":{d},"median_time_ns":{d},"std_dev_ns":{d},"ops_per_sec":{d},"memory_allocated":{d},"memory_peak":{d}}}
            , .{
                result.name,
                result.iterations,
                result.total_time_ns,
                result.mean_time_ns,
                result.min_time_ns,
                result.max_time_ns,
                result.median_time_ns,
                result.std_dev_ns,
                result.ops_per_sec,
                result.memory_allocated,
                result.memory_peak,
            });
            defer allocator.free(entry);
            try buf.appendSlice(allocator, entry);
        }

        try buf.appendSlice(allocator, "]}");
        return buf.toOwnedSlice(allocator);
    }
};

pub const ComponentBenchmark = struct {
    suite: *BenchmarkSuite,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*ComponentBenchmark {
        const bench = try allocator.create(ComponentBenchmark);
        bench.* = ComponentBenchmark{
            .suite = try BenchmarkSuite.init(allocator, "Component Benchmarks"),
            .allocator = allocator,
        };
        return bench;
    }

    pub fn deinit(self: *ComponentBenchmark) void {
        self.suite.deinit();
        self.allocator.destroy(self);
    }

    pub fn benchmarkComponentCreation(self: *ComponentBenchmark, comptime ComponentType: type, iterations: usize) !void {
        const bench = try Benchmark.init(self.allocator, "Component Creation", iterations);
        defer bench.deinit();

        const result = try bench.run(createComponent, .{ self.allocator, ComponentType });
        try self.suite.addResult(result);
    }

    fn createComponent(allocator: std.mem.Allocator, comptime ComponentType: type) !void {
        const component = try ComponentType.init(allocator);
        component.deinit();
    }

    pub fn getReport(self: *const ComponentBenchmark) ![]const u8 {
        return self.suite.generateReport(self.allocator);
    }

    pub fn getJSON(self: *const ComponentBenchmark) ![]const u8 {
        return self.suite.generateJSON(self.allocator);
    }
};

// Helper functions for common benchmarks
pub fn benchmarkAllocation(allocator: std.mem.Allocator, size: usize, iterations: usize) !BenchmarkResult {
    const bench = try Benchmark.init(allocator, "Memory Allocation", iterations);
    defer bench.deinit();

    try bench.enableMemoryTracking();
    return bench.run(allocateAndFree, .{ allocator, size });
}

fn allocateAndFree(allocator: std.mem.Allocator, size: usize) !void {
    const memory = try allocator.alloc(u8, size);
    defer allocator.free(memory);
}

pub fn benchmarkHashMapOperations(allocator: std.mem.Allocator, operations: usize) !BenchmarkResult {
    const bench = try Benchmark.init(allocator, "HashMap Operations", operations);
    defer bench.deinit();

    return bench.run(hashMapOps, .{ allocator, operations });
}

fn hashMapOps(allocator: std.mem.Allocator, ops: usize) !void {
    var map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = map.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        map.deinit();
    }

    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "key_{d}", .{i});
        try map.put(key, "value");
    }
}

pub fn benchmarkArrayListOperations(allocator: std.mem.Allocator, operations: usize) !BenchmarkResult {
    const bench = try Benchmark.init(allocator, "ArrayList Operations", operations);
    defer bench.deinit();

    return bench.run(arrayListOps, .{ allocator, operations });
}

fn arrayListOps(allocator: std.mem.Allocator, ops: usize) !void {
    var list = std.ArrayList(usize).empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < ops) : (i += 1) {
        try list.append(allocator, i);
    }
}

test "benchmark creation" {
    const allocator = std.testing.allocator;
    const bench = try Benchmark.init(allocator, "Test Benchmark", 100);
    defer bench.deinit();

    try std.testing.expectEqualStrings("Test Benchmark", bench.name);
    try std.testing.expect(bench.iterations == 100);
}

test "memory tracker" {
    const allocator = std.testing.allocator;
    const tracker = try MemoryTracker.init(allocator);
    defer tracker.deinit();

    tracker.trackAllocation(1024);
    tracker.trackAllocation(512);
    tracker.trackFree(1024);

    try std.testing.expect(tracker.total_allocated == 1536);
    try std.testing.expect(tracker.total_freed == 1024);
    try std.testing.expect(tracker.current_allocated == 512);
    try std.testing.expect(tracker.peak_allocated == 1536);
}

test "benchmark suite" {
    const allocator = std.testing.allocator;
    const suite = try BenchmarkSuite.init(allocator, "Test Suite");
    defer suite.deinit();

    const result = BenchmarkResult{
        .name = "Test",
        .iterations = 100,
        .total_time_ns = 1000000,
        .min_time_ns = 9000,
        .max_time_ns = 11000,
        .mean_time_ns = 10000,
        .median_time_ns = 10000,
        .std_dev_ns = 500.0,
        .ops_per_sec = 100000.0,
        .memory_allocated = 1024,
        .memory_peak = 2048,
    };

    try suite.addResult(result);
    try std.testing.expect(suite.results.items.len == 1);
}
