const std = @import("std");
const builtin = @import("builtin");
const io_context = @import("io_context.zig");

// GPU discovery needs the Objective-C runtime, not the desktop Window/WebView host.
const objc = @import("objc_runtime.zig").objc;

/// Metal helpers – only resolved on macOS.
const metal = if (builtin.os.tag == .macos) struct {
    extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

    fn createDevice() ?*anyopaque {
        return MTLCreateSystemDefaultDevice();
    }
} else struct {
    fn createDevice() ?*anyopaque {
        return null;
    }
};

/// Operations the standalone rendering API can execute. Detecting a hardware
/// device does not mean this module has a draw or shader backend.
pub const RenderingCapabilities = struct {
    offscreen_clear: bool = true,
    hardware_canvas: bool = false,
    shader_compilation: bool = false,
    draw: bool = false,
    compute: bool = false,
    presentation: bool = false,
    hardware_video_decode: bool = false,
    post_processing: bool = false,
    ray_tracing: bool = false,
    multi_gpu_discovery: bool = false,
};

pub const RenderError = error{
    UnsupportedOperation,
    MissingRenderTarget,
    ShaderNotReady,
    InvalidColor,
};

/// Hardware discovery and offscreen resources. Check rendering capabilities
/// separately before relying on native drawing or presentation.
pub const GPUBackend = enum {
    auto,
    metal, // macOS
    vulkan, // Linux/Windows
    opengl, // Fallback
    software, // No acceleration
};

pub const GPUConfig = struct {
    backend: GPUBackend = .auto,
    vsync: bool = true,
    max_fps: ?u32 = null,
    hardware_decode: bool = true,
    canvas_acceleration: bool = true,
    webgl_enabled: bool = true,
    webgl2_enabled: bool = true,
    power_preference: PowerPreference = .default,
};

pub const PowerPreference = enum {
    default,
    low_power, // Integrated GPU
    high_performance, // Discrete GPU
};

pub const GPUInfo = struct {
    vendor: []const u8,
    renderer: []const u8,
    version: []const u8,
    backend: GPUBackend,
    memory_mb: usize,
    discrete: bool,
};

pub const GPU = struct {
    config: GPUConfig,
    info: ?GPUInfo,
    allocator: std.mem.Allocator,
    /// Cached Metal device handle (macOS only)
    metal_device: ?*anyopaque = null,
    /// Frame-rate tracking state
    last_frame_time: ?std.Io.Clock.Timestamp = null,
    frame_count: u32 = 0,
    current_fps: f64 = 0.0,

    pub fn init(allocator: std.mem.Allocator, config: GPUConfig) !GPU {
        return GPU{
            .config = config,
            .info = null,
            .allocator = allocator,
            .metal_device = null,
            .last_frame_time = null,
            .frame_count = 0,
            .current_fps = 0.0,
        };
    }

    pub fn getRenderingCapabilities(self: *const GPU) RenderingCapabilities {
        _ = self;
        return .{};
    }

    pub fn deinit(self: *GPU) void {
        // Release the Metal device if we acquired one
        if (builtin.os.tag == .macos) {
            if (self.metal_device) |dev| {
                objc.msgSend(dev, objc.sel_registerName("release"));
                self.metal_device = null;
            }
        }
    }

    /// Get (or lazily create) the Metal device handle. macOS only.
    fn getMetalDevice(self: *GPU) ?*anyopaque {
        if (builtin.os.tag != .macos) return null;
        if (self.metal_device) |dev| return dev;
        self.metal_device = metal.createDevice();
        if (self.metal_device) |dev| {
            _ = objc.msgSendId(dev, objc.sel_registerName("retain"));
        }
        return self.metal_device;
    }

    /// Detect and select optimal GPU backend
    pub fn detectBackend(self: *GPU) !GPUBackend {
        if (self.config.backend != .auto) {
            return self.config.backend;
        }

        return switch (builtin.os.tag) {
            .macos => .metal,
            .linux => .vulkan,
            .windows => .vulkan,
            else => .opengl,
        };
    }

    /// Query GPU information
    pub fn queryInfo(self: *GPU) !GPUInfo {
        const backend = try self.detectBackend();

        return switch (builtin.os.tag) {
            .macos => try self.queryMetal(),
            .linux => try self.queryVulkan(),
            .windows => try self.queryVulkan(),
            else => GPUInfo{
                .vendor = "Unknown",
                .renderer = "Software",
                .version = "1.0",
                .backend = backend,
                .memory_mb = 0,
                .discrete = false,
            },
        };
    }

    fn queryMetal(self: *GPU) !GPUInfo {
        if (builtin.os.tag != .macos) {
            return GPUInfo{
                .vendor = "Unknown",
                .renderer = "Software",
                .version = "0.0",
                .backend = .software,
                .memory_mb = 0,
                .discrete = false,
            };
        }

        const device = self.getMetalDevice() orelse {
            return GPUInfo{
                .vendor = "Unknown",
                .renderer = "Metal (no device)",
                .version = "0.0",
                .backend = .metal,
                .memory_mb = 0,
                .discrete = false,
            };
        };

        // Query device name via [MTLDevice name] -> NSString
        var renderer: []const u8 = "Metal GPU";
        const name_nsstring = objc.msgSendId(device, objc.sel_registerName("name"));
        if (name_nsstring) |ns| {
            const cstr = objc.msgSendId(ns, objc.sel_registerName("UTF8String"));
            if (cstr) |c| {
                renderer = std.mem.span(@as([*:0]const u8, @ptrCast(c)));
            }
        }

        // Determine vendor from device name
        var vendor: []const u8 = "Apple";
        if (std.mem.indexOf(u8, renderer, "AMD") != null or std.mem.indexOf(u8, renderer, "Radeon") != null) {
            vendor = "AMD";
        } else if (std.mem.indexOf(u8, renderer, "Intel") != null) {
            vendor = "Intel";
        } else if (std.mem.indexOf(u8, renderer, "NVIDIA") != null or std.mem.indexOf(u8, renderer, "GeForce") != null) {
            vendor = "NVIDIA";
        }

        // Query recommended max working set size for VRAM estimate (returns u64 bytes)
        const mem_send = @as(
            *const fn (*anyopaque, objc.SEL) callconv(.c) u64,
            @ptrCast(&objc.objc_msgSend),
        );
        const max_working_set = mem_send(device, objc.sel_registerName("recommendedMaxWorkingSetSize"));
        const memory_mb: usize = @intCast(max_working_set / (1024 * 1024));

        // isLowPower returns YES for integrated GPUs, so discrete = !isLowPower
        const is_low_power = objc.msgSendBool(device, objc.sel_registerName("isLowPower"));

        self.info = GPUInfo{
            .vendor = vendor,
            .renderer = renderer,
            .version = "Metal",
            .backend = .metal,
            .memory_mb = memory_mb,
            .discrete = !is_low_power,
        };
        return self.info.?;
    }

    fn queryVulkan(self: *GPU) !GPUInfo {
        // On Linux, try to read basic GPU info from sysfs as a lightweight approach.
        // This avoids the complexity of dlopen-ing libvulkan at runtime while still
        // returning real hardware info on most desktop Linux systems.
        if (builtin.os.tag == .linux) {
            return self.queryLinuxSysfs();
        }

        // Windows / other: return generic Vulkan info as fallback
        self.info = GPUInfo{
            .vendor = "Unknown",
            .renderer = "Vulkan",
            .version = "1.0",
            .backend = .vulkan,
            .memory_mb = 0,
            .discrete = false,
        };
        return self.info.?;
    }

    // Static buffers for sysfs reads so returned slices remain valid.
    var sysfs_vendor_buf: [256]u8 = undefined;
    var sysfs_label_buf: [256]u8 = undefined;

    /// Best-effort GPU info from Linux sysfs (works without Vulkan runtime).
    fn queryLinuxSysfs(self: *GPU) !GPUInfo {
        var vendor: []const u8 = "Unknown";
        var renderer: []const u8 = "GPU";
        var memory_mb: usize = 0;
        var discrete = false;

        // Read PCI vendor from /sys/class/drm/card0/device/vendor
        if (readSysfsLineInto("/sys/class/drm/card0/device/vendor", &sysfs_vendor_buf)) |vendor_line| {
            vendor = mapPciVendor(vendor_line);
        }

        // Read device name from /sys/class/drm/card0/device/label or use vendor
        if (readSysfsLineInto("/sys/class/drm/card0/device/label", &sysfs_label_buf)) |label| {
            renderer = label;
        } else {
            renderer = vendor;
        }

        // Read VRAM size from /sys/class/drm/card0/device/mem_info_vram_total (AMD)
        if (readSysfsU64("/sys/class/drm/card0/device/mem_info_vram_total")) |vram_bytes| {
            memory_mb = @intCast(vram_bytes / (1024 * 1024));
            discrete = memory_mb > 512; // Heuristic: >512 MB VRAM implies discrete
        }

        self.info = GPUInfo{
            .vendor = vendor,
            .renderer = renderer,
            .version = "sysfs",
            .backend = .vulkan,
            .memory_mb = memory_mb,
            .discrete = discrete,
        };
        return self.info.?;
    }

    /// Read bytes from a sysfs path and trim trailing whitespace.
    /// Returns a trimmed slice into `dest`, or null on any failure.
    fn readSysfsLineInto(comptime path: [*:0]const u8, dest: []u8) ?[]const u8 {
        return readSysfsRaw(path, dest);
    }

    /// Read a u64 integer from a sysfs path (e.g. memory sizes in bytes).
    fn readSysfsU64(comptime path: [*:0]const u8) ?u64 {
        var buf: [64]u8 = undefined;
        const line = readSysfsRaw(path, &buf) orelse return null;
        return std.fmt.parseInt(u64, line, 0) catch return null;
    }

    /// Low-level sysfs reader. Returns trimmed content or null.
    fn readSysfsRaw(comptime path: [*:0]const u8, dest: []u8) ?[]const u8 {
        if (builtin.os.tag != .linux) return null;
        const io = io_context.get();
        const file = std.Io.Dir.cwd().openFile(io, std.mem.span(path), .{}) catch return null;
        defer file.close(io);
        const n = file.readPositional(io, &.{dest}, 0) catch return null;
        if (n == 0) return null;
        var end = n;
        while (end > 0 and (dest[end - 1] == '\n' or dest[end - 1] == '\r' or dest[end - 1] == ' ')) {
            end -= 1;
        }
        if (end == 0) return null;
        return dest[0..end];
    }

    /// Map a PCI vendor ID string (e.g. "0x10de") to a human-readable name.
    fn mapPciVendor(vendor_str: []const u8) []const u8 {
        const id = std.fmt.parseInt(u32, vendor_str, 0) catch return "Unknown";
        return switch (id) {
            0x1002 => "AMD",
            0x10de => "NVIDIA",
            0x8086 => "Intel",
            0x1a03 => "ASPEED",
            0x1234 => "QEMU",
            else => "Unknown",
        };
    }

    /// Enable GPU acceleration for a window.
    /// On macOS, configures the WKWebView's preferences to enable GPU-accelerated
    /// rendering.  On Linux, delegates to the window's enableGPUAcceleration method.
    /// `window` should be a platform Window (or pointer to one).
    pub fn enableForWindow(self: *GPU, window: anytype) !void {
        _ = self;
        const RawType = @TypeOf(window);
        // Unwrap a single pointer level so @hasField / @hasDecl work on the struct.
        const Window = switch (@typeInfo(RawType)) {
            .pointer => |p| p.child,
            else => RawType,
        };

        if (builtin.os.tag == .macos) {
            // Expect window to expose a webview field (objc id)
            if (@hasField(Window, "webview")) {
                const webview = window.webview;
                if (webview) |wv| {
                    // Get configuration -> preferences and enable accelerated drawing
                    const config_obj = objc.msgSendId(wv, objc.sel_registerName("configuration"));
                    if (config_obj) |cfg| {
                        const prefs = objc.msgSendId(cfg, objc.sel_registerName("preferences"));
                        if (prefs) |p| {
                            // _acceleratedDrawingEnabled is a private but widely-used
                            // WKPreferences property that enables GPU compositing.
                            objc.msgSendVoid1(p, objc.sel_registerName("_setAcceleratedDrawingEnabled:"), true);
                        }
                    }
                    // Ensure the view uses a CALayer for GPU compositing
                    objc.msgSendVoid1(wv, objc.sel_registerName("setWantsLayer:"), true);
                }
            }
        } else if (builtin.os.tag == .linux) {
            // Linux windows expose enableGPUAcceleration directly
            if (@hasDecl(Window, "enableGPUAcceleration")) {
                window.enableGPUAcceleration(true);
            }
        }
        // Windows: WebView2 enables hardware acceleration by default; no-op.
    }

    /// Set power preference
    pub fn setPowerPreference(self: *GPU, preference: PowerPreference) void {
        self.config.power_preference = preference;
    }

    /// Enable/disable VSync
    pub fn setVSync(self: *GPU, enabled: bool) void {
        self.config.vsync = enabled;
    }

    /// Set maximum FPS (null for unlimited)
    pub fn setMaxFPS(self: *GPU, fps: ?u32) void {
        self.config.max_fps = fps;
    }

    /// Get current FPS.
    /// Call this once per frame. It measures wall-clock time between calls and
    /// returns a smoothed frames-per-second value.  The first call returns 0.
    pub fn getCurrentFPS(self: *GPU) f64 {
        const now_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);

        if (self.last_frame_time) |last| {
            self.frame_count += 1;
            const elapsed = last.durationTo(now_ts);
            const elapsed_ns = @as(u64, @intCast(elapsed.raw.nanoseconds));

            // Update FPS once per second (or when enough frames accumulate)
            if (elapsed_ns >= 1_000_000_000) {
                const elapsed_sec: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
                self.current_fps = @as(f64, @floatFromInt(self.frame_count)) / elapsed_sec;
                self.frame_count = 0;
                self.last_frame_time = now_ts;
            }
        } else {
            // First call -- just record the timestamp
            self.last_frame_time = now_ts;
            self.frame_count = 0;
            self.current_fps = 0.0;
        }

        return self.current_fps;
    }

    /// Check if GPU acceleration is available
    pub fn isAccelerationAvailable(self: *GPU) bool {
        const backend = self.detectBackend() catch return false;
        return backend != .software;
    }

    /// Get GPU memory usage in MB.
    /// On macOS, queries the Metal device's currentAllocatedSize.
    /// On Linux, reads from sysfs (AMD) when available.
    /// Returns 0 when the information cannot be determined.
    pub fn getMemoryUsage(self: *GPU) !usize {
        if (builtin.os.tag == .macos) {
            const device = self.getMetalDevice() orelse return 0;
            // currentAllocatedSize returns NSUInteger (bytes)
            const size_send = @as(
                *const fn (*anyopaque, objc.SEL) callconv(.c) u64,
                @ptrCast(&objc.objc_msgSend),
            );
            const bytes = size_send(device, objc.sel_registerName("currentAllocatedSize"));
            return @intCast(bytes / (1024 * 1024));
        }

        if (builtin.os.tag == .linux) {
            if (readSysfsU64("/sys/class/drm/card0/device/mem_info_vram_used")) |used_bytes| {
                return @intCast(used_bytes / (1024 * 1024));
            }
        }

        return 0;
    }
};

/// Frame rate limiter
pub const FrameLimiter = struct {
    target_fps: u32,
    frame_time_ns: u64,
    start_ts: ?std.Io.Clock.Timestamp,

    pub fn init(target_fps: u32) FrameLimiter {
        const frame_time: u64 = 1_000_000_000 / target_fps;
        return FrameLimiter{
            .target_fps = target_fps,
            .frame_time_ns = frame_time,
            .start_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake),
        };
    }

    pub fn limit(self: *FrameLimiter) void {
        if (self.start_ts) |start| {
            const end_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);
            const elapsed = start.durationTo(end_ts);
            const elapsed_ns = @as(u64, @intCast(elapsed.raw.nanoseconds));

            if (elapsed_ns < self.frame_time_ns) {
                const sleep_ns = self.frame_time_ns - elapsed_ns;
                std.Io.sleep(io_context.get(), .fromNanoseconds(sleep_ns), .awake) catch return;
            }

            self.start_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);
        }
    }

    pub fn setTargetFPS(self: *FrameLimiter, fps: u32) void {
        self.target_fps = fps;
        self.frame_time_ns = 1_000_000_000 / fps;
    }
};

/// Hardware video decode
pub const VideoDecoder = struct {
    gpu: *GPU,
    hardware_enabled: bool,

    pub fn init(gpu: *GPU) VideoDecoder {
        return VideoDecoder{
            .gpu = gpu,
            .hardware_enabled = gpu.config.hardware_decode and gpu.getRenderingCapabilities().hardware_video_decode,
        };
    }

    pub fn decode(self: *VideoDecoder, data: []const u8) ![]u8 {
        _ = self;
        _ = data;
        return error.UnsupportedOperation;
    }

    pub fn isHardwareAccelerated(self: VideoDecoder) bool {
        return self.hardware_enabled and self.gpu.isAccelerationAvailable();
    }
};

/// Canvas acceleration
pub const CanvasAccelerator = struct {
    gpu: *GPU,
    enabled: bool,

    pub fn init(gpu: *GPU) CanvasAccelerator {
        return CanvasAccelerator{
            .gpu = gpu,
            .enabled = gpu.config.canvas_acceleration and gpu.getRenderingCapabilities().hardware_canvas,
        };
    }

    pub fn drawRect(self: *CanvasAccelerator, x: i32, y: i32, width: u32, height: u32) RenderError!void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        return error.UnsupportedOperation;
    }

    pub fn drawCircle(self: *CanvasAccelerator, x: i32, y: i32, radius: u32) RenderError!void {
        _ = self;
        _ = x;
        _ = y;
        _ = radius;
        return error.UnsupportedOperation;
    }

    pub fn clear(self: *CanvasAccelerator) RenderError!void {
        _ = self;
        return error.UnsupportedOperation;
    }
};

/// Pipeline State
pub const PipelineState = struct {
    current_shader: ?*Shader = null,
    current_render_target: ?*RenderTarget = null,
    viewport: ViewportCommand = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    scissor: ?ScissorCommand = null,
    scissor_enabled: bool = false,
    depth_test_enabled: bool = true,
    depth_write_enabled: bool = true,
    blend_enabled: bool = false,
    blend_src: BlendFactor = .one,
    blend_dst: BlendFactor = .zero,
    cull_mode: CullMode = .back,
    front_face: FrontFace = .counter_clockwise,

    pub const BlendFactor = enum {
        zero,
        one,
        src_alpha,
        one_minus_src_alpha,
        dst_alpha,
        one_minus_dst_alpha,
    };

    pub const CullMode = enum { none, front, back, front_and_back };
    pub const FrontFace = enum { clockwise, counter_clockwise };
};

/// Advanced GPU Rendering Pipeline
pub const RenderPipeline = struct {
    gpu: *GPU,
    shaders: std.ArrayList(Shader),
    render_targets: std.ArrayList(RenderTarget),
    allocator: std.mem.Allocator,
    state: PipelineState,
    command_buffer: std.ArrayList(RenderCommand),
    statistics: RenderStatistics,

    pub const RenderStatistics = struct {
        draw_calls: u32 = 0,
        triangles_drawn: u32 = 0,
        vertices_processed: u32 = 0,
        commands_executed: u32 = 0,
        frame_count: u64 = 0,

        pub fn reset(self: *RenderStatistics) void {
            self.draw_calls = 0;
            self.triangles_drawn = 0;
            self.vertices_processed = 0;
            self.commands_executed = 0;
        }

        pub fn nextFrame(self: *RenderStatistics) void {
            self.frame_count += 1;
            self.reset();
        }
    };

    pub fn init(allocator: std.mem.Allocator, gpu: *GPU) RenderPipeline {
        return RenderPipeline{
            .gpu = gpu,
            .shaders = .empty,
            .render_targets = .empty,
            .allocator = allocator,
            .state = .{},
            .command_buffer = .empty,
            .statistics = .{},
        };
    }

    pub fn deinit(self: *RenderPipeline) void {
        for (self.shaders.items) |*shader| {
            shader.deinit();
        }
        self.shaders.deinit(self.allocator);

        for (self.render_targets.items) |*target| {
            target.deinit();
        }
        self.render_targets.deinit(self.allocator);
        self.command_buffer.deinit(self.allocator);
    }

    pub fn createShader(self: *RenderPipeline, source: ShaderSource) !*Shader {
        const shader = try Shader.init(self.allocator, source);
        try self.shaders.append(self.allocator, shader);
        return &self.shaders.items[self.shaders.items.len - 1];
    }

    pub fn createRenderTarget(self: *RenderPipeline, width: u32, height: u32, format: TextureFormat) !*RenderTarget {
        var target = try RenderTarget.init(self.allocator, width, height, format);
        errdefer target.deinit();
        try self.render_targets.append(self.allocator, target);
        return &self.render_targets.items[self.render_targets.items.len - 1];
    }

    /// Submit a command for deferred execution
    pub fn submit(self: *RenderPipeline, command: RenderCommand) !void {
        try self.command_buffer.append(self.allocator, command);
    }

    /// Clear the command buffer
    pub fn clearCommands(self: *RenderPipeline) void {
        self.command_buffer.clearRetainingCapacity();
    }

    /// Execute all queued render commands
    pub fn render(self: *RenderPipeline, commands: []const RenderCommand) !void {
        for (commands) |command| {
            try self.executeCommand(command);
        }
    }

    /// Execute queued command buffer
    pub fn flush(self: *RenderPipeline) !void {
        // A failed batch may already have executed its prefix. Do not replay it
        // when the caller submits a corrected batch after the error.
        defer self.command_buffer.clearRetainingCapacity();
        for (self.command_buffer.items) |command| {
            try self.executeCommand(command);
        }
    }

    /// Execute a single render command
    fn executeCommand(self: *RenderPipeline, command: RenderCommand) !void {
        switch (command) {
            .clear => |clear_cmd| {
                const target = self.state.current_render_target orelse return error.MissingRenderTarget;
                try target.clear(clear_cmd.color);
            },
            .draw, .draw_indexed, .dispatch_compute => return error.UnsupportedOperation,
            .set_shader => |shader| {
                if (!shader.isReady()) return error.ShaderNotReady;
                self.state.current_shader = shader;
            },
            .set_render_target => |target| {
                self.state.current_render_target = target;
            },
            .set_viewport => |viewport| {
                self.state.viewport = viewport;
            },
            .set_scissor => |scissor| {
                self.state.scissor = scissor;
                self.state.scissor_enabled = true;
            },
        }
        self.statistics.commands_executed += 1;
    }

    /// Begin a new frame
    pub fn beginFrame(self: *RenderPipeline) void {
        self.statistics.nextFrame();
        self.clearCommands();
    }

    /// Flush the offscreen frame. This does not present a native surface.
    pub fn endFrame(self: *RenderPipeline) !void {
        try self.flush();
    }

    /// Set pipeline state
    pub fn setDepthTest(self: *RenderPipeline, enabled: bool) void {
        self.state.depth_test_enabled = enabled;
    }

    pub fn setDepthWrite(self: *RenderPipeline, enabled: bool) void {
        self.state.depth_write_enabled = enabled;
    }

    pub fn setBlend(self: *RenderPipeline, enabled: bool) void {
        self.state.blend_enabled = enabled;
    }

    pub fn setBlendFunc(self: *RenderPipeline, src: PipelineState.BlendFactor, dst: PipelineState.BlendFactor) void {
        self.state.blend_src = src;
        self.state.blend_dst = dst;
    }

    pub fn setCullMode(self: *RenderPipeline, mode: PipelineState.CullMode) void {
        self.state.cull_mode = mode;
    }

    pub fn disableScissor(self: *RenderPipeline) void {
        self.state.scissor_enabled = false;
        self.state.scissor = null;
    }

    /// Get current statistics
    pub fn getStatistics(self: *const RenderPipeline) RenderStatistics {
        return self.statistics;
    }

    /// Get current state
    pub fn getState(self: *const RenderPipeline) PipelineState {
        return self.state;
    }
};

/// Shader Management
pub const ShaderType = enum {
    vertex,
    fragment,
    compute,
    geometry,
};

pub const ShaderSource = struct {
    type: ShaderType,
    code: []const u8,
    entry_point: []const u8 = "main",
};

pub const ShaderError = error{
    CompilationFailed,
    InvalidSource,
    UnsupportedShaderType,
    ValidationFailed,
    ShaderCompilationUnavailable,
    OutOfMemory,
};

pub const ShaderUniform = struct {
    name: []const u8,
    location: u32,
    uniform_type: UniformType,
    size: usize,

    pub const UniformType = enum {
        float,
        vec2,
        vec3,
        vec4,
        mat3,
        mat4,
        int,
        ivec2,
        ivec3,
        ivec4,
        sampler2d,
        sampler3d,
        sampler_cube,
    };

    pub fn getSize(uniform_type: UniformType) usize {
        return switch (uniform_type) {
            .float, .int => 4,
            .vec2, .ivec2 => 8,
            .vec3, .ivec3 => 12,
            .vec4, .ivec4 => 16,
            .mat3 => 36,
            .mat4 => 64,
            .sampler2d, .sampler3d, .sampler_cube => 4,
        };
    }
};

pub const Shader = struct {
    type: ShaderType,
    source: []const u8,
    entry_point: []const u8,
    compiled: bool,
    allocator: std.mem.Allocator,
    shader_id: u32,
    uniforms: std.ArrayList(ShaderUniform),
    compile_log: ?[]const u8,
    validated: bool,

    var next_shader_id: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, source: ShaderSource) !Shader {
        const shader_id = next_shader_id;
        next_shader_id += 1;

        return Shader{
            .type = source.type,
            .source = source.code,
            .entry_point = source.entry_point,
            .compiled = false,
            .allocator = allocator,
            .shader_id = shader_id,
            .uniforms = .empty,
            .compile_log = null,
            .validated = false,
        };
    }

    pub fn deinit(self: *Shader) void {
        self.uniforms.deinit(self.allocator);
        if (self.compile_log) |log| {
            self.allocator.free(log);
        }
    }

    /// No shader compiler is connected to this standalone API yet. Source
    /// presence and invented uniform locations cannot establish a GPU program.
    pub fn compile(self: *Shader) ShaderError!void {
        if (self.source.len == 0 or self.entry_point.len == 0)
            return error.ValidationFailed;
        return error.ShaderCompilationUnavailable;
    }

    /// Get uniform by name
    pub fn getUniform(self: *const Shader, name: []const u8) ?ShaderUniform {
        for (self.uniforms.items) |uniform| {
            if (std.mem.eql(u8, uniform.name, name)) {
                return uniform;
            }
        }
        return null;
    }

    /// Check if shader is ready for use
    pub fn isReady(self: *const Shader) bool {
        return self.compiled and self.validated;
    }

    /// Get compile log (errors/warnings)
    pub fn getCompileLog(self: *const Shader) ?[]const u8 {
        return self.compile_log;
    }
};

/// Texture Management
pub const TextureFormat = enum {
    rgba8,
    rgba16f,
    rgba32f,
    depth24_stencil8,
    depth32f,
    r8,
    rg8,
    rgb8,
    bgra8,

    pub fn getBytesPerPixel(self: TextureFormat) usize {
        return switch (self) {
            .r8 => 1,
            .rg8 => 2,
            .rgb8 => 3,
            .rgba8, .bgra8 => 4,
            .rgba16f => 8,
            .rgba32f => 16,
            .depth24_stencil8 => 4,
            .depth32f => 4,
        };
    }

    pub fn isDepthFormat(self: TextureFormat) bool {
        return self == .depth24_stencil8 or self == .depth32f;
    }
};

pub const TextureError = error{
    InvalidDimensions,
    AllocationFailed,
    AllocationLimitExceeded,
    OutOfMemory,
};

pub const Texture = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    texture_id: u32,
    allocator: std.mem.Allocator,
    data: ?[]u8,
    mip_levels: u32,
    sampler_state: SamplerState,
    limits: Limits,

    pub const Limits = struct {
        max_bytes: usize = 64 * 1024 * 1024,
    };

    fn byteLength(width: u32, height: u32, format: TextureFormat, limits: Limits) TextureError!usize {
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const count = std.math.mul(usize, width, height) catch return error.InvalidDimensions;
        const bytes = std.math.mul(usize, count, format.getBytesPerPixel()) catch return error.InvalidDimensions;
        if (bytes > limits.max_bytes) return error.AllocationLimitExceeded;
        return bytes;
    }

    pub const SamplerState = struct {
        min_filter: FilterMode = .linear,
        mag_filter: FilterMode = .linear,
        wrap_u: WrapMode = .repeat,
        wrap_v: WrapMode = .repeat,
        anisotropy: u8 = 1,
    };

    pub const FilterMode = enum { nearest, linear, linear_mipmap_linear };
    pub const WrapMode = enum { repeat, clamp, mirror };

    var next_texture_id: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: TextureFormat) !Texture {
        return initWithLimits(allocator, width, height, format, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, width: u32, height: u32, format: TextureFormat, limits: Limits) !Texture {
        const data_size = try byteLength(width, height, format, limits);

        const texture_id = next_texture_id;
        next_texture_id += 1;

        const data = try allocator.alloc(u8, data_size);
        @memset(data, 0);

        return Texture{
            .width = width,
            .height = height,
            .format = format,
            .texture_id = texture_id,
            .allocator = allocator,
            .data = data,
            .mip_levels = 1,
            .sampler_state = .{},
            .limits = limits,
        };
    }

    pub fn deinit(self: *Texture) void {
        if (self.data) |data| {
            self.allocator.free(data);
            self.data = null;
        }
    }

    pub fn upload(self: *Texture, pixels: []const u8) TextureError!void {
        if (self.data == null) return TextureError.AllocationFailed;
        const expected_size = self.data.?.len;
        if (pixels.len != expected_size) return TextureError.InvalidDimensions;
        @memmove(self.data.?, pixels);
    }

    pub fn download(self: *const Texture, dest: []u8) TextureError!void {
        if (self.data == null) return TextureError.AllocationFailed;
        if (dest.len != self.data.?.len) return TextureError.InvalidDimensions;
        @memmove(dest, self.data.?);
    }

    pub fn setPixel(self: *Texture, x: u32, y: u32, color: [4]u8) void {
        if (x >= self.width or y >= self.height) return;
        if (self.data == null) return;
        const bpp = self.format.getBytesPerPixel();
        const offset = (@as(usize, y) * self.width + x) * bpp;
        const data = self.data.?;
        const copy_len = @min(bpp, 4);
        @memcpy(data[offset..][0..copy_len], color[0..copy_len]);
    }

    pub fn getPixel(self: *const Texture, x: u32, y: u32) ?[4]u8 {
        if (x >= self.width or y >= self.height) return null;
        if (self.data == null) return null;
        const bpp = self.format.getBytesPerPixel();
        const offset = (@as(usize, y) * self.width + x) * bpp;
        var result: [4]u8 = .{ 0, 0, 0, 255 };
        const copy_len = @min(bpp, 4);
        @memcpy(result[0..copy_len], self.data.?[offset..][0..copy_len]);
        return result;
    }

    pub fn resize(self: *Texture, new_width: u32, new_height: u32) !void {
        const new_data = try self.resizedStorage(new_width, new_height);
        self.replaceStorage(new_width, new_height, new_data);
    }

    fn resizedStorage(self: *const Texture, new_width: u32, new_height: u32) ![]u8 {
        if (self.data == null) return error.AllocationFailed;
        const new_size = try byteLength(new_width, new_height, self.format, self.limits);
        const new_data = try self.allocator.alloc(u8, new_size);
        @memset(new_data, 0);
        return new_data;
    }

    fn replaceStorage(self: *Texture, new_width: u32, new_height: u32, new_data: []u8) void {
        if (self.data) |old_data| {
            self.allocator.free(old_data);
        }
        self.data = new_data;
        self.width = new_width;
        self.height = new_height;
    }

    pub fn setSamplerState(self: *Texture, state: SamplerState) void {
        self.sampler_state = state;
    }
};

pub const RenderTarget = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    texture_id: u32,
    framebuffer_id: u32,
    allocator: std.mem.Allocator,
    color_texture: ?Texture,
    depth_texture: ?Texture,
    clear_color: [4]f32,

    var next_framebuffer_id: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: TextureFormat) !RenderTarget {
        const framebuffer_id = next_framebuffer_id;
        next_framebuffer_id += 1;

        // Create color texture
        var color_texture = try Texture.init(allocator, width, height, format);
        errdefer color_texture.deinit();

        // Create depth texture if not a depth format
        var depth_texture: ?Texture = null;
        if (!format.isDepthFormat()) {
            depth_texture = try Texture.init(allocator, width, height, .depth24_stencil8);
        }

        return RenderTarget{
            .width = width,
            .height = height,
            .format = format,
            .texture_id = color_texture.texture_id,
            .framebuffer_id = framebuffer_id,
            .allocator = allocator,
            .color_texture = color_texture,
            .depth_texture = depth_texture,
            .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
        };
    }

    pub fn deinit(self: *RenderTarget) void {
        if (self.color_texture) |*tex| {
            tex.deinit();
        }
        if (self.depth_texture) |*tex| {
            tex.deinit();
        }
    }

    pub fn resize(self: *RenderTarget, width: u32, height: u32) !void {
        const color_data = if (self.color_texture) |*tex| try tex.resizedStorage(width, height) else null;
        errdefer if (color_data) |data| self.color_texture.?.allocator.free(data);
        const depth_data = if (self.depth_texture) |*tex| try tex.resizedStorage(width, height) else null;
        if (color_data) |data| self.color_texture.?.replaceStorage(width, height, data);
        if (depth_data) |data| self.depth_texture.?.replaceStorage(width, height, data);
        self.width = width;
        self.height = height;
    }

    /// The CPU clear path currently implements RGBA8. Validate all inputs
    /// before touching either attachment or reporting a successful command.
    pub fn clear(self: *RenderTarget, color: [4]f32) RenderError!void {
        if (self.format != .rgba8) return error.UnsupportedOperation;
        const texture = self.getColorTexture() orelse return error.MissingRenderTarget;
        const data = texture.data orelse return error.MissingRenderTarget;
        if (self.depth_texture) |*depth| {
            if (depth.data == null) return error.MissingRenderTarget;
        }
        for (color) |channel| {
            if (!std.math.isFinite(channel) or channel < 0 or channel > 1)
                return error.InvalidColor;
        }
        const pixel: [4]u8 = .{
            @intFromFloat(color[0] * 255.0),
            @intFromFloat(color[1] * 255.0),
            @intFromFloat(color[2] * 255.0),
            @intFromFloat(color[3] * 255.0),
        };
        var i: usize = 0;
        while (i < data.len) : (i += 4) {
            @memcpy(data[i..][0..4], &pixel);
        }
        if (self.depth_texture) |*depth| {
            @memset(depth.data.?, 0xFF);
        }
        self.clear_color = color;
    }

    pub fn setClearColor(self: *RenderTarget, color: [4]f32) void {
        self.clear_color = color;
    }

    pub fn getColorTexture(self: *RenderTarget) ?*Texture {
        if (self.color_texture) |*tex| {
            return tex;
        }
        return null;
    }

    pub fn getDepthTexture(self: *RenderTarget) ?*Texture {
        if (self.depth_texture) |*tex| {
            return tex;
        }
        return null;
    }
};

/// Render Commands
pub const RenderCommand = union(enum) {
    clear: ClearCommand,
    draw: DrawCommand,
    draw_indexed: DrawIndexedCommand,
    dispatch_compute: ComputeCommand,
    set_shader: *Shader,
    set_render_target: *RenderTarget,
    set_viewport: ViewportCommand,
    set_scissor: ScissorCommand,
};

pub const ClearCommand = struct {
    color: [4]f32,
    depth: f32 = 1.0,
    stencil: u8 = 0,
};

pub const DrawCommand = struct {
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
};

pub const DrawIndexedCommand = struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
};

pub const ComputeCommand = struct {
    groups_x: u32,
    groups_y: u32,
    groups_z: u32,
};

pub const ViewportCommand = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32 = 0.0,
    max_depth: f32 = 1.0,
};

pub const ScissorCommand = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// Buffer Management
pub const BufferType = enum {
    vertex,
    index,
    uniform,
    storage,
};

pub const BufferUsage = enum {
    static,
    dynamic,
    stream,
};

pub const BufferError = error{
    InvalidSize,
    InvalidOffset,
    BufferOverflow,
    AllocationFailed,
    OutOfMemory,
};

pub const Buffer = struct {
    type: BufferType,
    usage: BufferUsage,
    size: usize,
    buffer_id: u32,
    allocator: std.mem.Allocator,
    // CPU-side staging buffer for software fallback and data management
    staging_data: ?[]u8,
    dirty: bool,
    mapped: bool,

    // Global buffer ID counter for generating unique IDs
    var next_buffer_id: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, buffer_type: BufferType, usage: BufferUsage, size: usize) !Buffer {
        if (size == 0) return BufferError.InvalidSize;

        const buffer_id = next_buffer_id;
        next_buffer_id += 1;

        // Allocate staging buffer for CPU-side data storage
        const staging = try allocator.alloc(u8, size);
        @memset(staging, 0);

        return Buffer{
            .type = buffer_type,
            .usage = usage,
            .size = size,
            .buffer_id = buffer_id,
            .allocator = allocator,
            .staging_data = staging,
            .dirty = false,
            .mapped = false,
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.staging_data) |staging| {
            self.allocator.free(staging);
            self.staging_data = null;
        }
        self.buffer_id = 0;
    }

    /// Upload data to buffer (copies to staging buffer, marks dirty for GPU sync)
    pub fn upload(self: *Buffer, data: []const u8, offset: usize) BufferError!void {
        if (self.staging_data == null) return BufferError.AllocationFailed;
        if (offset >= self.size) return BufferError.InvalidOffset;
        if (offset + data.len > self.size) return BufferError.BufferOverflow;

        const staging = self.staging_data.?;
        @memcpy(staging[offset..][0..data.len], data);
        self.dirty = true;
    }

    /// Download data from buffer (copies from staging buffer)
    pub fn download(self: *Buffer, data: []u8, offset: usize) BufferError!void {
        if (self.staging_data == null) return BufferError.AllocationFailed;
        if (offset >= self.size) return BufferError.InvalidOffset;
        if (offset + data.len > self.size) return BufferError.BufferOverflow;

        const staging = self.staging_data.?;
        @memcpy(data, staging[offset..][0..data.len]);
    }

    /// Map buffer for direct CPU access
    pub fn map(self: *Buffer) BufferError![]u8 {
        if (self.staging_data == null) return BufferError.AllocationFailed;
        if (self.mapped) return self.staging_data.?;
        self.mapped = true;
        return self.staging_data.?;
    }

    /// Unmap buffer and mark as dirty
    pub fn unmap(self: *Buffer) void {
        if (self.mapped) {
            self.dirty = true;
            self.mapped = false;
        }
    }

    /// Clear buffer contents to zero
    pub fn clear(self: *Buffer) void {
        if (self.staging_data) |staging| {
            @memset(staging, 0);
            self.dirty = true;
        }
    }

    /// Resize buffer (reallocates staging data)
    pub fn resize(self: *Buffer, new_size: usize) !void {
        if (new_size == 0) return BufferError.InvalidSize;
        if (new_size == self.size) return;

        if (self.staging_data) |old_staging| {
            const new_staging = try self.allocator.alloc(u8, new_size);
            const copy_size = @min(self.size, new_size);
            @memcpy(new_staging[0..copy_size], old_staging[0..copy_size]);
            if (new_size > self.size) {
                @memset(new_staging[copy_size..], 0);
            }
            self.allocator.free(old_staging);
            self.staging_data = new_staging;
        } else {
            self.staging_data = try self.allocator.alloc(u8, new_size);
            @memset(self.staging_data.?, 0);
        }
        self.size = new_size;
        self.dirty = true;
    }

    /// Check if buffer needs GPU synchronization
    pub fn isDirty(self: *const Buffer) bool {
        return self.dirty;
    }

    /// Mark buffer as synchronized with GPU
    pub fn markClean(self: *Buffer) void {
        self.dirty = false;
    }

    /// Get buffer data as typed slice
    pub fn getTypedData(self: *Buffer, comptime T: type) BufferError![]T {
        if (self.staging_data == null) return BufferError.AllocationFailed;
        const staging = self.staging_data.?;
        const typed_len = staging.len / @sizeOf(T);
        return @as([*]T, @ptrCast(@alignCast(staging.ptr)))[0..typed_len];
    }
};

/// Mesh Rendering
pub const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,
    vertex_buffer: Buffer,
    index_buffer: Buffer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, vertices: []Vertex, indices: []u32) !Mesh {
        const vertex_buffer = try Buffer.init(
            allocator,
            .vertex,
            .static,
            vertices.len * @sizeOf(Vertex),
        );

        const index_buffer = try Buffer.init(
            allocator,
            .index,
            .static,
            indices.len * @sizeOf(u32),
        );

        return Mesh{
            .vertices = vertices,
            .indices = indices,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
    }

    pub fn upload(self: *Mesh) !void {
        const vertex_data = std.mem.sliceAsBytes(self.vertices);
        try self.vertex_buffer.upload(vertex_data, 0);

        const index_data = std.mem.sliceAsBytes(self.indices);
        try self.index_buffer.upload(index_data, 0);
    }

    pub fn draw(self: *Mesh) !void {
        _ = self;
        return error.UnsupportedOperation;
    }
};

/// Post-Processing Effects
pub const PostProcessor = struct {
    pipeline: *RenderPipeline,
    effects: std.ArrayList(Effect),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pipeline: *RenderPipeline) PostProcessor {
        return PostProcessor{
            .pipeline = pipeline,
            .effects = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PostProcessor) void {
        self.effects.deinit(self.allocator);
    }

    pub fn addEffect(self: *PostProcessor, effect: Effect) !void {
        try self.effects.append(self.allocator, effect);
    }

    pub fn process(self: *PostProcessor, input: *RenderTarget, output: *RenderTarget) !void {
        _ = self;
        _ = input;
        _ = output;
        return error.UnsupportedOperation;
    }
};

pub const Effect = enum {
    bloom,
    blur,
    sharpen,
    vignette,
    chromatic_aberration,
    film_grain,
    color_grading,
    tone_mapping,
    anti_aliasing,
    ambient_occlusion,
};

/// Performance Profiling
pub const GPUProfiler = struct {
    queries: std.ArrayList(Query),
    allocator: std.mem.Allocator,
    active_start_ts: ?std.Io.Clock.Timestamp,
    active_query_name: ?[]const u8,

    pub const Query = struct {
        name: []const u8,
        duration_ns: u64,
    };

    pub fn init(allocator: std.mem.Allocator) GPUProfiler {
        return GPUProfiler{
            .queries = .empty,
            .allocator = allocator,
            .active_start_ts = null,
            .active_query_name = null,
        };
    }

    pub fn deinit(self: *GPUProfiler) void {
        self.queries.deinit(self.allocator);
    }

    pub fn beginQuery(self: *GPUProfiler, name: []const u8) !void {
        self.active_query_name = name;
        self.active_start_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);
    }

    pub fn endQuery(self: *GPUProfiler) !void {
        if (self.active_start_ts) |start_ts| {
            if (self.active_query_name) |name| {
                const end_ts = std.Io.Clock.Timestamp.now(io_context.get(), .awake);
                const elapsed = start_ts.durationTo(end_ts);
                const duration = @as(u64, @intCast(elapsed.raw.nanoseconds));
                try self.queries.append(self.allocator, .{
                    .name = name,
                    .duration_ns = duration,
                });
            }
        }
        self.active_start_ts = null;
        self.active_query_name = null;
    }

    pub fn getResults(self: *GPUProfiler) []Query {
        return self.queries.items;
    }

    pub fn clear(self: *GPUProfiler) void {
        self.queries.clearRetainingCapacity();
    }
};

/// Compute Shader Support
pub const ComputeShader = struct {
    shader: Shader,
    workgroup_size: [3]u32,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, workgroup_size: [3]u32) !ComputeShader {
        const shader_source = ShaderSource{
            .type = .compute,
            .code = source,
        };

        return ComputeShader{
            .shader = try Shader.init(allocator, shader_source),
            .workgroup_size = workgroup_size,
        };
    }

    pub fn deinit(self: *ComputeShader) void {
        self.shader.deinit();
    }

    pub fn dispatch(self: *ComputeShader, groups_x: u32, groups_y: u32, groups_z: u32) !void {
        _ = self;
        _ = groups_x;
        _ = groups_y;
        _ = groups_z;
        return error.UnsupportedOperation;
    }
};

/// Ray Tracing Support
pub const RayTracer = struct {
    gpu: *GPU,
    acceleration_structure: ?*anyopaque,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, gpu: *GPU) !RayTracer {
        return RayTracer{
            .gpu = gpu,
            .acceleration_structure = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RayTracer) void {
        _ = self;
    }

    pub fn buildAccelerationStructure(self: *RayTracer, meshes: []const Mesh) !void {
        _ = self;
        _ = meshes;
        return error.UnsupportedOperation;
    }

    pub fn trace(self: *RayTracer, ray_origin: [3]f32, ray_direction: [3]f32) !?Hit {
        _ = self;
        _ = ray_origin;
        _ = ray_direction;
        return error.UnsupportedOperation;
    }

    pub const Hit = struct {
        distance: f32,
        position: [3]f32,
        normal: [3]f32,
        mesh_id: u32,
    };
};

/// Multi-GPU Support
pub const MultiGPU = struct {
    gpus: std.ArrayList(*GPU),
    primary_gpu: ?*GPU,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MultiGPU {
        return MultiGPU{
            .gpus = .empty,
            .primary_gpu = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultiGPU) void {
        self.gpus.deinit(self.allocator);
    }

    pub fn detectGPUs(self: *MultiGPU) !void {
        _ = self;
        return error.UnsupportedOperation;
    }

    pub fn setPrimaryGPU(self: *MultiGPU, index: usize) !void {
        if (index >= self.gpus.items.len) return error.InvalidGPUIndex;
        self.primary_gpu = self.gpus.items[index];
    }

    pub fn getGPUCount(self: *MultiGPU) usize {
        return self.gpus.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "gpu initialization" {
    const allocator = std.testing.allocator;
    var gpu = try GPU.init(allocator, .{});
    defer gpu.deinit();

    try std.testing.expect(gpu.config.vsync);
    try std.testing.expectEqual(GPUBackend.auto, gpu.config.backend);
}

test "gpu backend detection" {
    const allocator = std.testing.allocator;
    var gpu = try GPU.init(allocator, .{});
    defer gpu.deinit();

    const backend = try gpu.detectBackend();
    // Should return a valid backend for any platform
    try std.testing.expect(backend == .metal or backend == .vulkan or backend == .opengl or backend == .software);
}

test "buffer creation and operations" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .vertex, .static, 256);
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 256), buffer.size);
    try std.testing.expect(!buffer.dirty);
    try std.testing.expect(!buffer.mapped);
    try std.testing.expect(buffer.buffer_id > 0);
}

test "buffer upload and download" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .vertex, .dynamic, 16);
    defer buffer.deinit();

    const test_data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try buffer.upload(&test_data, 0);
    try std.testing.expect(buffer.dirty);

    var downloaded: [8]u8 = undefined;
    try buffer.download(&downloaded, 0);
    try std.testing.expectEqualSlices(u8, &test_data, &downloaded);
}

test "buffer map and unmap" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .uniform, .dynamic, 64);
    defer buffer.deinit();

    const mapped = try buffer.map();
    try std.testing.expect(buffer.mapped);
    try std.testing.expectEqual(@as(usize, 64), mapped.len);

    // Write directly to mapped memory
    mapped[0] = 0xAB;
    mapped[1] = 0xCD;

    buffer.unmap();
    try std.testing.expect(!buffer.mapped);
    try std.testing.expect(buffer.dirty);

    // Verify data persisted
    var read_data: [2]u8 = undefined;
    try buffer.download(&read_data, 0);
    try std.testing.expectEqual(@as(u8, 0xAB), read_data[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), read_data[1]);
}

test "buffer resize" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .storage, .dynamic, 32);
    defer buffer.deinit();

    const initial_data = [_]u8{ 1, 2, 3, 4 };
    try buffer.upload(&initial_data, 0);

    try buffer.resize(64);
    try std.testing.expectEqual(@as(usize, 64), buffer.size);

    // Old data should be preserved
    var preserved: [4]u8 = undefined;
    try buffer.download(&preserved, 0);
    try std.testing.expectEqualSlices(u8, &initial_data, &preserved);
}

test "buffer error handling" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.init(allocator, .vertex, .static, 8);
    defer buffer.deinit();

    // Test buffer overflow
    const large_data: [16]u8 = @splat(0);
    try std.testing.expectError(BufferError.BufferOverflow, buffer.upload(&large_data, 0));

    // Test invalid offset
    const small_data: [4]u8 = @splat(0);
    try std.testing.expectError(BufferError.InvalidOffset, buffer.upload(&small_data, 100));
}

test "shader creation and compilation" {
    const allocator = std.testing.allocator;
    var shader = try Shader.init(allocator, .{
        .type = .vertex,
        .code = "void main() { gl_Position = vec4(0.0); }",
    });
    defer shader.deinit();

    try std.testing.expect(!shader.compiled);
    try std.testing.expect(shader.shader_id > 0);

    try std.testing.expectError(error.ShaderCompilationUnavailable, shader.compile());
    try std.testing.expect(!shader.compiled);
    try std.testing.expect(!shader.validated);
}

test "shader uniforms" {
    const allocator = std.testing.allocator;
    var shader = try Shader.init(allocator, .{
        .type = .vertex,
        .code = "void main() {}",
    });
    defer shader.deinit();

    try std.testing.expectError(error.ShaderCompilationUnavailable, shader.compile());
    try std.testing.expect(shader.getUniform("modelViewProjection") == null);
}

test "texture creation" {
    const allocator = std.testing.allocator;
    var texture = try Texture.init(allocator, 64, 64, .rgba8);
    defer texture.deinit();

    try std.testing.expectEqual(@as(u32, 64), texture.width);
    try std.testing.expectEqual(@as(u32, 64), texture.height);
    try std.testing.expect(texture.texture_id > 0);
    try std.testing.expect(texture.data != null);
}

test "texture pixel operations" {
    const allocator = std.testing.allocator;
    var texture = try Texture.init(allocator, 8, 8, .rgba8);
    defer texture.deinit();

    // Set a pixel
    const red: [4]u8 = .{ 255, 0, 0, 255 };
    texture.setPixel(3, 4, red);

    // Get the pixel back
    const pixel = texture.getPixel(3, 4);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?[0]);
    try std.testing.expectEqual(@as(u8, 0), pixel.?[1]);
}

test "render target creation" {
    const allocator = std.testing.allocator;
    var target = try RenderTarget.init(allocator, 800, 600, .rgba8);
    defer target.deinit();

    try std.testing.expectEqual(@as(u32, 800), target.width);
    try std.testing.expectEqual(@as(u32, 600), target.height);
    try std.testing.expect(target.color_texture != null);
    try std.testing.expect(target.depth_texture != null);
}

test "render target clear" {
    const allocator = std.testing.allocator;
    var target = try RenderTarget.init(allocator, 4, 4, .rgba8);
    defer target.deinit();

    try target.clear(.{ 1.0, 0.0, 0.0, 1.0 });

    // Check that color texture was cleared to red
    if (target.color_texture) |*tex| {
        const pixel = tex.getPixel(0, 0);
        try std.testing.expect(pixel != null);
        try std.testing.expectEqual(@as(u8, 255), pixel.?[0]); // Red
        try std.testing.expectEqual(@as(u8, 0), pixel.?[1]); // Green
    }
}

test "render pipeline initialization" {
    const allocator = std.testing.allocator;
    var gpu = try GPU.init(allocator, .{});
    defer gpu.deinit();

    var pipeline = RenderPipeline.init(allocator, &gpu);
    defer pipeline.deinit();

    try std.testing.expectEqual(@as(u64, 0), pipeline.statistics.frame_count);
}

test "render pipeline command execution" {
    const allocator = std.testing.allocator;
    var gpu = try GPU.init(allocator, .{});
    defer gpu.deinit();

    var pipeline = RenderPipeline.init(allocator, &gpu);
    defer pipeline.deinit();

    // Create a render target
    const target = try pipeline.createRenderTarget(800, 600, .rgba8);

    // Submit commands
    try pipeline.submit(.{ .set_render_target = target });
    try pipeline.submit(.{ .clear = .{ .color = .{ 0.2, 0.3, 0.4, 1.0 } } });
    try pipeline.submit(.{ .draw = .{ .vertex_count = 6 } });

    // Execute
    try std.testing.expectError(error.UnsupportedOperation, pipeline.flush());

    try std.testing.expectEqual(@as(u32, 2), pipeline.statistics.commands_executed);
    try std.testing.expectEqual(@as(u32, 0), pipeline.statistics.draw_calls);
    try std.testing.expectEqual(@as(u32, 0), pipeline.statistics.vertices_processed);
}

test "render pipeline state management" {
    const allocator = std.testing.allocator;
    var gpu = try GPU.init(allocator, .{});
    defer gpu.deinit();

    var pipeline = RenderPipeline.init(allocator, &gpu);
    defer pipeline.deinit();

    pipeline.setDepthTest(false);
    pipeline.setBlend(true);
    pipeline.setBlendFunc(.src_alpha, .one_minus_src_alpha);

    const state = pipeline.getState();
    try std.testing.expect(!state.depth_test_enabled);
    try std.testing.expect(state.blend_enabled);
    try std.testing.expectEqual(PipelineState.BlendFactor.src_alpha, state.blend_src);
}

test "frame limiter" {
    var limiter = FrameLimiter.init(60);
    try std.testing.expectEqual(@as(u32, 60), limiter.target_fps);

    limiter.setTargetFPS(30);
    try std.testing.expectEqual(@as(u32, 30), limiter.target_fps);
}

test "gpu profiler" {
    const allocator = std.testing.allocator;
    var profiler = GPUProfiler.init(allocator);
    defer profiler.deinit();

    try profiler.beginQuery("test_pass");
    // Simulate some work
    try std.Io.sleep(io_context.get(), .fromNanoseconds(1_000_000), .awake);
    try profiler.endQuery();

    const results = profiler.getResults();
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].duration_ns > 0);
}

test "texture format bytes per pixel" {
    try std.testing.expectEqual(@as(usize, 1), TextureFormat.r8.getBytesPerPixel());
    try std.testing.expectEqual(@as(usize, 4), TextureFormat.rgba8.getBytesPerPixel());
    try std.testing.expectEqual(@as(usize, 8), TextureFormat.rgba16f.getBytesPerPixel());
    try std.testing.expectEqual(@as(usize, 16), TextureFormat.rgba32f.getBytesPerPixel());
}

test "shader uniform sizes" {
    try std.testing.expectEqual(@as(usize, 4), ShaderUniform.getSize(.float));
    try std.testing.expectEqual(@as(usize, 16), ShaderUniform.getSize(.vec4));
    try std.testing.expectEqual(@as(usize, 64), ShaderUniform.getSize(.mat4));
}
