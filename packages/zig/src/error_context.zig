const std = @import("std");

/// Error Context System
/// Provides detailed error information with stack traces and context
/// Get current timestamp in milliseconds (compatible with Zig 0.16)
fn getMilliTimestamp() i64 {
    // `compat.milliTimestamp` is this exact function, cross-platform. The copy
    // that lived here reached for POSIX `clock_gettime`, whose `clockid_t` is
    // `void` on Windows, so every module carrying it failed to compile for
    // that target — which is why `zig build test` could not run there.
    return @import("compat.zig").milliTimestamp();
}

pub const ErrorSeverity = enum {
    info,
    warning,
    err,
    fatal,

    pub fn toString(self: ErrorSeverity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .warning => "WARNING",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }
};

pub const ErrorCategory = enum {
    // System errors
    memory,
    io,
    network,
    platform,

    // Application errors
    validation,
    configuration,
    security,
    plugin,

    // Component errors
    component,
    rendering,
    event,

    // Build/Development errors
    build,
    compilation,

    pub fn toString(self: ErrorCategory) []const u8 {
        return switch (self) {
            .memory => "Memory",
            .io => "I/O",
            .network => "Network",
            .platform => "Platform",
            .validation => "Validation",
            .configuration => "Configuration",
            .security => "Security",
            .plugin => "Plugin",
            .component => "Component",
            .rendering => "Rendering",
            .event => "Event",
            .build => "Build",
            .compilation => "Compilation",
        };
    }
};

pub const ErrorCode = enum(u32) {
    // Memory errors (1000-1099)
    out_of_memory = 1000,
    invalid_allocation = 1001,
    memory_leak = 1002,
    double_free = 1003,

    // I/O errors (1100-1199)
    file_not_found = 1100,
    permission_denied = 1101,
    file_already_exists = 1102,
    invalid_path = 1103,

    // Network errors (1200-1299)
    connection_refused = 1200,
    connection_timeout = 1201,
    network_unreachable = 1202,
    invalid_url = 1203,

    // Platform errors (1300-1399)
    unsupported_platform = 1300,
    platform_init_failed = 1301,
    missing_dependency = 1302,

    // Validation errors (1400-1499)
    invalid_input = 1400,
    invalid_format = 1401,
    out_of_range = 1402,
    constraint_violation = 1403,

    // Configuration errors (1500-1599)
    missing_config = 1500,
    invalid_config = 1501,
    config_parse_error = 1502,

    // Security errors (1600-1699)
    permission_denied_security = 1600,
    signature_verification_failed = 1601,
    encryption_failed = 1602,
    authentication_failed = 1603,

    // Plugin errors (1700-1799)
    plugin_not_found = 1700,
    plugin_load_failed = 1701,
    plugin_incompatible = 1702,
    plugin_execution_timeout = 1703,

    // Component errors (1800-1899)
    component_not_found = 1800,
    component_init_failed = 1801,
    invalid_state = 1802,
    circular_dependency = 1803,

    // Rendering errors (1900-1999)
    render_failed = 1900,
    gpu_error = 1901,
    shader_compilation_failed = 1902,

    pub fn getCategory(self: ErrorCode) ErrorCategory {
        const code = @backingInt(self);
        return switch (code / 100) {
            10 => .memory,
            11 => .io,
            12 => .network,
            13 => .platform,
            14 => .validation,
            15 => .configuration,
            16 => .security,
            17 => .plugin,
            18 => .component,
            19 => .rendering,
            else => .component,
        };
    }

    pub fn getDescription(self: ErrorCode) []const u8 {
        return switch (self) {
            .out_of_memory => "Out of memory",
            .invalid_allocation => "Invalid memory allocation",
            .memory_leak => "Memory leak detected",
            .double_free => "Double free detected",
            .file_not_found => "File not found",
            .permission_denied => "Permission denied",
            .file_already_exists => "File already exists",
            .invalid_path => "Invalid file path",
            .connection_refused => "Connection refused",
            .connection_timeout => "Connection timeout",
            .network_unreachable => "Network unreachable",
            .invalid_url => "Invalid URL",
            .unsupported_platform => "Unsupported platform",
            .platform_init_failed => "Platform initialization failed",
            .missing_dependency => "Missing dependency",
            .invalid_input => "Invalid input",
            .invalid_format => "Invalid format",
            .out_of_range => "Value out of range",
            .constraint_violation => "Constraint violation",
            .missing_config => "Missing configuration",
            .invalid_config => "Invalid configuration",
            .config_parse_error => "Configuration parse error",
            .permission_denied_security => "Security permission denied",
            .signature_verification_failed => "Signature verification failed",
            .encryption_failed => "Encryption failed",
            .authentication_failed => "Authentication failed",
            .plugin_not_found => "Plugin not found",
            .plugin_load_failed => "Plugin load failed",
            .plugin_incompatible => "Plugin incompatible",
            .plugin_execution_timeout => "Plugin execution timeout",
            .component_not_found => "Component not found",
            .component_init_failed => "Component initialization failed",
            .invalid_state => "Invalid state",
            .circular_dependency => "Circular dependency detected",
            .render_failed => "Render failed",
            .gpu_error => "GPU error",
            .shader_compilation_failed => "Shader compilation failed",
        };
    }
};

pub const StackFrame = struct {
    function: []const u8,
    file: []const u8,
    line: u32,

    pub fn format(self: StackFrame, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "  at {s} ({s}:{d})", .{ self.function, self.file, self.line });
    }
};

pub const ErrorContext = struct {
    code: ErrorCode,
    message: []const u8,
    severity: ErrorSeverity,
    timestamp: i64,
    stack_trace: std.ArrayList(StackFrame),
    metadata: std.StringHashMap([]const u8),
    cause: ?*ErrorContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, code: ErrorCode, message: []const u8) !*ErrorContext {
        const ctx = try allocator.create(ErrorContext);
        // Without this errdefer, a future change that added a failable op
        // between `create` and `return` would leak the struct allocation.
        errdefer allocator.destroy(ctx);
        ctx.* = ErrorContext{
            .code = code,
            .message = message,
            .severity = .err,
            .timestamp = getMilliTimestamp(),
            .stack_trace = .empty,
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .cause = null,
            .allocator = allocator,
        };
        return ctx;
    }

    pub fn deinit(self: *ErrorContext) void {
        self.stack_trace.deinit(self.allocator);
        self.metadata.deinit();
        // `cause.deinit()` already calls `allocator.destroy(cause)` at the end
        // of its own body. Calling `destroy` again here was a double-free
        // that corrupted the heap whenever an error had a chained cause.
        if (self.cause) |cause| {
            cause.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn setSeverity(self: *ErrorContext, severity: ErrorSeverity) *ErrorContext {
        self.severity = severity;
        return self;
    }

    pub fn addStackFrame(self: *ErrorContext, function: []const u8, file: []const u8, line: u32) !*ErrorContext {
        try self.stack_trace.append(self.allocator, .{
            .function = function,
            .file = file,
            .line = line,
        });
        return self;
    }

    pub fn addMetadata(self: *ErrorContext, key: []const u8, value: []const u8) !*ErrorContext {
        try self.metadata.put(key, value);
        return self;
    }

    pub fn setCause(self: *ErrorContext, cause: *ErrorContext) *ErrorContext {
        self.cause = cause;
        return self;
    }

    pub fn getCategory(self: *const ErrorContext) ErrorCategory {
        return self.code.getCategory();
    }

    pub fn format(self: *const ErrorContext, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Header
        const header = try std.fmt.allocPrint(allocator, "[{s}] {s} (Code: {d})\n", .{
            self.severity.toString(),
            self.code.getCategory().toString(),
            @backingInt(self.code),
        });
        defer allocator.free(header);
        try buf.appendSlice(allocator, header);

        // Message
        const msg = try std.fmt.allocPrint(allocator, "Message: {s}\n", .{self.message});
        defer allocator.free(msg);
        try buf.appendSlice(allocator, msg);

        // Description
        const desc = try std.fmt.allocPrint(allocator, "Description: {s}\n", .{self.code.getDescription()});
        defer allocator.free(desc);
        try buf.appendSlice(allocator, desc);

        // Timestamp
        const timestamp_sec = @divFloor(self.timestamp, 1000);
        const time_str = try std.fmt.allocPrint(allocator, "Time: {d}\n", .{timestamp_sec});
        defer allocator.free(time_str);
        try buf.appendSlice(allocator, time_str);

        // Metadata
        if (self.metadata.count() > 0) {
            try buf.appendSlice(allocator, "\nMetadata:\n");
            var it = self.metadata.iterator();
            while (it.next()) |entry| {
                const meta_line = try std.fmt.allocPrint(allocator, "  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer allocator.free(meta_line);
                try buf.appendSlice(allocator, meta_line);
            }
        }

        // Stack trace
        if (self.stack_trace.items.len > 0) {
            try buf.appendSlice(allocator, "\nStack trace:\n");
            for (self.stack_trace.items) |frame| {
                const formatted = try frame.format(allocator);
                defer allocator.free(formatted);
                const frame_line = try std.fmt.allocPrint(allocator, "{s}\n", .{formatted});
                defer allocator.free(frame_line);
                try buf.appendSlice(allocator, frame_line);
            }
        }

        // Cause
        if (self.cause) |cause| {
            try buf.appendSlice(allocator, "\nCaused by:\n");
            const cause_formatted = try cause.format(allocator);
            defer allocator.free(cause_formatted);
            const cause_line = try std.fmt.allocPrint(allocator, "{s}\n", .{cause_formatted});
            defer allocator.free(cause_line);
            try buf.appendSlice(allocator, cause_line);
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn print(self: *const ErrorContext) !void {
        const formatted = try self.format(self.allocator);
        defer self.allocator.free(formatted);
        std.debug.print("{s}\n", .{formatted});
    }
};

/// Error Recovery Strategy
pub const RecoveryStrategy = enum {
    retry,
    fallback,
    ignore,
    fail,

    pub fn toString(self: RecoveryStrategy) []const u8 {
        return switch (self) {
            .retry => "Retry",
            .fallback => "Fallback",
            .ignore => "Ignore",
            .fail => "Fail",
        };
    }
};

pub const RecoveryAction = struct {
    strategy: RecoveryStrategy,
    max_retries: ?u32,
    retry_delay_ms: ?u64,
    fallback_fn: ?*const fn () anyerror!void,

    pub fn init(strategy: RecoveryStrategy) RecoveryAction {
        return RecoveryAction{
            .strategy = strategy,
            .max_retries = null,
            .retry_delay_ms = null,
            .fallback_fn = null,
        };
    }

    pub fn withRetries(self: RecoveryAction, max_retries: u32, delay_ms: u64) RecoveryAction {
        return RecoveryAction{
            .strategy = self.strategy,
            .max_retries = max_retries,
            .retry_delay_ms = delay_ms,
            .fallback_fn = self.fallback_fn,
        };
    }

    pub fn withFallback(self: RecoveryAction, fallback_fn: *const fn () anyerror!void) RecoveryAction {
        return RecoveryAction{
            .strategy = self.strategy,
            .max_retries = self.max_retries,
            .retry_delay_ms = self.retry_delay_ms,
            .fallback_fn = fallback_fn,
        };
    }
};

/// Helper macro for creating error context with automatic stack frame
pub fn createError(allocator: std.mem.Allocator, code: ErrorCode, message: []const u8, comptime function: []const u8, comptime file: []const u8, comptime line: u32) !*ErrorContext {
    const ctx = try ErrorContext.init(allocator, code, message);
    _ = try ctx.addStackFrame(function, file, line);
    return ctx;
}

test "error context creation" {
    const allocator = std.testing.allocator;
    const ctx = try ErrorContext.init(allocator, .file_not_found, "Could not find config.json");
    defer ctx.deinit();

    try std.testing.expectEqualStrings("Could not find config.json", ctx.message);
    try std.testing.expect(ctx.code == .file_not_found);
    try std.testing.expect(ctx.severity == .err);
}

test "error context with stack trace" {
    const allocator = std.testing.allocator;
    const ctx = try ErrorContext.init(allocator, .component_init_failed, "Button init failed");
    defer ctx.deinit();

    _ = try ctx.addStackFrame("init", "button.zig", 42);
    _ = try ctx.addStackFrame("createComponent", "factory.zig", 100);

    try std.testing.expect(ctx.stack_trace.items.len == 2);
    try std.testing.expectEqualStrings("init", ctx.stack_trace.items[0].function);
}

test "error context with metadata" {
    const allocator = std.testing.allocator;
    const ctx = try ErrorContext.init(allocator, .invalid_input, "Invalid email format");
    defer ctx.deinit();

    _ = try ctx.addMetadata("field", "email");
    _ = try ctx.addMetadata("value", "invalid@");

    try std.testing.expect(ctx.metadata.count() == 2);
}

test "error context with cause" {
    const allocator = std.testing.allocator;

    // Wire ctx first so if `cause` init fails there is nothing to clean up.
    const ctx = try ErrorContext.init(allocator, .network_unreachable, "Network error");
    errdefer ctx.deinit();
    const cause = try ErrorContext.init(allocator, .connection_timeout, "Connection timed out");
    _ = ctx.setCause(cause);
    defer ctx.deinit(); // walks through `cause` once set

    try std.testing.expect(ctx.cause != null);
    try std.testing.expect(ctx.cause.?.code == .connection_timeout);
}

test "error code categories" {
    try std.testing.expect(ErrorCode.out_of_memory.getCategory() == .memory);
    try std.testing.expect(ErrorCode.file_not_found.getCategory() == .io);
    try std.testing.expect(ErrorCode.connection_refused.getCategory() == .network);
    try std.testing.expect(ErrorCode.invalid_input.getCategory() == .validation);
}

test "recovery strategy" {
    var action = RecoveryAction.init(.retry);
    action = action.withRetries(3, 1000);

    try std.testing.expect(action.strategy == .retry);
    try std.testing.expect(action.max_retries.? == 3);
    try std.testing.expect(action.retry_delay_ms.? == 1000);
}
