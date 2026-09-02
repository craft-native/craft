const std = @import("std");
const log = @import("log.zig");

pub const DebugOverlay = struct {
    enabled: bool = false,
    show_fps: bool = true,
    show_memory: bool = true,
    show_events: bool = true,
    show_network: bool = false,
    position: OverlayPosition = .top_right,

    pub const OverlayPosition = enum {
        top_left,
        top_right,
        bottom_left,
        bottom_right,
    };
};

pub const DevMode = struct {
    enabled: bool = false,
    overlay: DebugOverlay = .{},
    verbose_logging: bool = false,
    break_on_errors: bool = false,
    hot_reload_enabled: bool = true,
    profiling_enabled: bool = false,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn enable(self: *Self) void {
        self.enabled = true;
        self.overlay.enabled = true;
        self.verbose_logging = true;
        log.setLevel(.Debug);
        log.info("Developer mode enabled", .{});
    }

    pub fn disable(self: *Self) void {
        self.enabled = false;
        self.overlay.enabled = false;
        self.verbose_logging = false;
        log.setLevel(.Info);
        log.info("Developer mode disabled", .{});
    }

    pub fn toggle(self: *Self) void {
        if (self.enabled) {
            self.disable();
        } else {
            self.enable();
        }
    }

    pub fn getOverlayHTML(self: Self) ![]const u8 {
        if (!self.overlay.enabled) {
            return "";
        }

        const position_css = switch (self.overlay.position) {
            .top_left => "top: 10px; left: 10px;",
            .top_right => "top: 10px; right: 10px;",
            .bottom_left => "bottom: 10px; left: 10px;",
            .bottom_right => "bottom: 10px; right: 10px;",
        };

        return try std.fmt.allocPrint(self.allocator,
            \\<div id="craft-debug-overlay" style="
            \\  position: fixed;
            \\  {s}
            \\  background: rgba(0, 0, 0, 0.85);
            \\  color: #00ff00;
            \\  font-family: monospace;
            \\  font-size: 12px;
            \\  padding: 10px;
            \\  border-radius: 5px;
            \\  z-index: 999999;
            \\  min-width: 200px;
            \\  backdrop-filter: blur(10px);
            \\">
            \\  <div style="font-weight: bold; margin-bottom: 5px; color: #00ffff;">
            \\    ⚡ Craft Dev Mode
            \\  </div>
            \\  <div id="craft-fps" style="margin: 3px 0;">FPS: <span>--</span></div>
            \\  <div id="craft-memory" style="margin: 3px 0;">Memory: <span>--</span></div>
            \\  <div id="craft-events" style="margin: 3px 0;">Events: <span>0</span></div>
            \\  <div style="margin-top: 8px; padding-top: 5px; border-top: 1px solid #333;">
            \\    <div style="font-size: 10px; color: #888;">
            \\      Press Ctrl+Shift+D to toggle
            \\    </div>
            \\  </div>
            \\</div>
            \\<script>
            \\(function() {{
            \\  let frameCount = 0;
            \\  let lastTime = performance.now();
            \\  let eventCount = 0;
            \\  
            \\  function updateOverlay() {{
            \\    frameCount++;
            \\    const now = performance.now();
            \\    const delta = now - lastTime;
            \\    
            \\    if (delta >= 1000) {{
            \\      const fps = Math.round((frameCount * 1000) / delta);
            \\      document.querySelector('#craft-fps span').textContent = fps;
            \\      frameCount = 0;
            \\      lastTime = now;
            \\      
            \\      // Update memory if available
            \\      if (performance.memory) {{
            \\        const usedMB = Math.round(performance.memory.usedJSHeapSize / 1048576);
            \\        const totalMB = Math.round(performance.memory.totalJSHeapSize / 1048576);
            \\        document.querySelector('#craft-memory span').textContent = 
            \\          usedMB + ' / ' + totalMB + ' MB';
            \\      }}
            \\    }}
            \\    
            \\    requestAnimationFrame(updateOverlay);
            \\  }}
            \\  
            \\  // Track events
            \\  const originalAddEventListener = EventTarget.prototype.addEventListener;
            \\  EventTarget.prototype.addEventListener = function(...args) {{
            \\    eventCount++;
            \\    document.querySelector('#craft-events span').textContent = eventCount;
            \\    return originalAddEventListener.apply(this, args);
            \\  }};
            \\  
            \\  // Keyboard shortcut to toggle
            \\  document.addEventListener('keydown', (e) => {{
            \\    if (e.ctrlKey && e.shiftKey && e.key === 'D') {{
            \\      const overlay = document.getElementById('craft-debug-overlay');
            \\      overlay.style.display = overlay.style.display === 'none' ? 'block' : 'none';
            \\    }}
            \\  }});
            \\  
            \\  updateOverlay();
            \\}})();
            \\</script>
        , .{position_css});
    }

    pub fn logEvent(self: Self, event_name: []const u8, data: []const u8) void {
        if (!self.enabled or !self.verbose_logging) return;
        log.debug("Event: {s} - {s}", .{ event_name, data });
    }

    pub fn logError(self: Self, err: anyerror, context: []const u8) void {
        log.err("Error in {s}: {}", .{ context, err });

        if (self.break_on_errors) {
            log.fatal("Breaking on error (dev mode)", .{});
            // In a real debugger, this would trigger a breakpoint
        }
    }

    pub fn logPerformance(self: Self, operation: []const u8, duration_ms: f64) void {
        if (!self.enabled or !self.profiling_enabled) return;

        if (duration_ms > 16.67) { // More than 1 frame at 60fps
            log.warn("Performance: {s} took {d:.2}ms (slow!)", .{ operation, duration_ms });
        } else {
            log.debug("Performance: {s} took {d:.2}ms", .{ operation, duration_ms });
        }
    }
};

const global_state = @import("global_state.zig");

pub fn initGlobalDevMode(allocator: std.mem.Allocator) void {
    global_state.instance.initDevMode(allocator);
}

pub fn getGlobalDevMode() ?*DevMode {
    return global_state.instance.getDevMode();
}

pub fn enable() void {
    if (global_state.instance.getDevMode()) |dm| {
        dm.enable();
    }
}

pub fn disable() void {
    if (global_state.instance.getDevMode()) |dm| {
        dm.disable();
    }
}

pub fn isEnabled() bool {
    if (global_state.instance.getDevMode()) |dm| {
        return dm.enabled;
    }
    return false;
}

/// Enhanced error display for developer mode
pub const ErrorDisplay = struct {
    show_stack_trace: bool = true,
    show_source_context: bool = true,
    show_suggestions: bool = true,
    color_output: bool = true,

    pub fn formatError(self: ErrorDisplay, allocator: std.mem.Allocator, err: anyerror, context: []const u8, file: []const u8, line: u32) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        const writer = buf.writer(allocator);

        // Header with emoji for visibility
        if (self.color_output) {
            try writer.writeAll("\x1b[31m\x1b[1m"); // Red + Bold
        }
        try writer.writeAll("🔥 Error Occurred\n");
        if (self.color_output) {
            try writer.writeAll("\x1b[0m"); // Reset
        }

        // Error details
        try writer.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});
        try writer.print("Error: {s}\n", .{@errorName(err)});
        try writer.print("Context: {s}\n", .{context});
        try writer.print("Location: {s}:{d}\n", .{ file, line });
        try writer.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n", .{});

        // Suggestions based on common errors
        if (self.show_suggestions) {
            if (std.mem.eql(u8, @errorName(err), "OutOfMemory")) {
                try writer.writeAll("\n💡 Suggestion: Check for memory leaks or increase memory allocation\n");
            } else if (std.mem.eql(u8, @errorName(err), "FileNotFound")) {
                try writer.writeAll("\n💡 Suggestion: Verify the file path exists and is accessible\n");
            } else if (std.mem.eql(u8, @errorName(err), "AccessDenied")) {
                try writer.writeAll("\n💡 Suggestion: Check file permissions or run with appropriate privileges\n");
            }
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn displayErrorOverlay(self: ErrorDisplay, allocator: std.mem.Allocator, err: anyerror, context: []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(allocator,
            \\<div style="
            \\  position: fixed;
            \\  top: 50%;
            \\  left: 50%;
            \\  transform: translate(-50%, -50%);
            \\  background: #2d2d2d;
            \\  color: #f8f8f2;
            \\  padding: 30px;
            \\  border-radius: 10px;
            \\  box-shadow: 0 10px 40px rgba(0,0,0,0.5);
            \\  z-index: 1000000;
            \\  font-family: 'Consolas', 'Monaco', monospace;
            \\  max-width: 600px;
            \\  border: 2px solid #ff5555;
            \\">
            \\  <div style="font-size: 24px; margin-bottom: 15px; color: #ff5555;">
            \\    🔥 Error Occurred
            \\  </div>
            \\  <div style="background: #1e1e1e; padding: 15px; border-radius: 5px; margin: 10px 0;">
            \\    <div style="color: #ff79c6; font-weight: bold;">Error:</div>
            \\    <div style="color: #f8f8f2; margin-top: 5px;">{s}</div>
            \\  </div>
            \\  <div style="background: #1e1e1e; padding: 15px; border-radius: 5px; margin: 10px 0;">
            \\    <div style="color: #8be9fd; font-weight: bold;">Context:</div>
            \\    <div style="color: #f8f8f2; margin-top: 5px;">{s}</div>
            \\  </div>
            \\  <div style="margin-top: 20px; padding: 10px; background: #282a36; border-left: 3px solid #50fa7b; border-radius: 3px;">
            \\    <div style="color: #50fa7b; font-size: 12px;">💡 TIP</div>
            \\    <div style="color: #f8f8f2; font-size: 12px; margin-top: 5px;">
            \\      Check the browser console for more details
            \\    </div>
            \\  </div>
            \\  <button onclick="this.parentElement.remove()" style="
            \\    margin-top: 15px;
            \\    padding: 8px 20px;
            \\    background: #ff5555;
            \\    color: white;
            \\    border: none;
            \\    border-radius: 5px;
            \\    cursor: pointer;
            \\    font-family: inherit;
            \\  ">Close</button>
            \\</div>
        , .{ @errorName(err), context });
    }
};
