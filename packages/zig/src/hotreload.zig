const std = @import("std");
// This Zig has no std.crypto.random; compat goes to the platform CSPRNG.
const compat = @import("compat.zig");
const log = @import("log.zig");
const io_context = @import("io_context.zig");

pub const HotReloadConfig = struct {
    enabled: bool = true,
    watch_paths: []const []const u8 = &.{},
    ignore_patterns: []const []const u8 = &.{ ".git", "node_modules", ".DS_Store" },
    debounce_ms: u64 = 300,
    auto_reload: bool = true,
    reload_on_save: bool = true,
};

pub const FileWatcher = struct {
    watched_paths: std.StringHashMap(i64),
    ignore_patterns: []const []const u8,
    allocator: std.mem.Allocator,
    last_reload: i64 = 0,
    debounce_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: HotReloadConfig) !Self {
        var watcher = Self{
            .watched_paths = std.StringHashMap(i64).init(allocator),
            .ignore_patterns = config.ignore_patterns,
            .allocator = allocator,
            .debounce_ms = config.debounce_ms,
        };

        // Add watch paths
        for (config.watch_paths) |path| {
            try watcher.addPath(path);
        }

        return watcher;
    }

    pub fn deinit(self: *Self) void {
        // Free duped path keys (see addPath). Without this, every restart
        // leaks the watch list.
        var iter = self.watched_paths.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.watched_paths.deinit();
    }

    pub fn addPath(self: *Self, path: []const u8) !void {
        const stat = std.Io.Dir.cwd().statFile(io_context.get(), path, .{}) catch |err| {
            log.warn("Failed to stat {s}: {}", .{ path, err });
            return;
        };

        const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000_000));

        // Dupe the path so the caller may free or reuse its buffer; the
        // hashmap previously borrowed it and any iteration after the
        // caller's slice changed read dangling memory.
        const result = try self.watched_paths.getOrPut(path);
        if (!result.found_existing) {
            const owned = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned);
            result.key_ptr.* = owned;
        }
        result.value_ptr.* = mtime;
        log.debug("Watching: {s}", .{path});
    }

    pub fn check(self: *Self) !bool {
        var ts: std.c.timespec = undefined;
        // Previously swallowed the clock_gettime error and used the undefined
        // `ts` bytes as the current wall clock — the resulting `now` was
        // unpredictable. On failure, skip this check instead.
        if (std.c.clock_gettime(.REALTIME, &ts) != 0) return false;
        const now: i64 = @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000));

        // Debounce check
        if (now - self.last_reload < @as(i64, @intCast(self.debounce_ms))) {
            return false;
        }

        var iter = self.watched_paths.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const old_mtime = entry.value_ptr.*;

            const stat = std.Io.Dir.cwd().statFile(io_context.get(), path, .{}) catch continue;
            const new_mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000_000));

            if (new_mtime > old_mtime) {
                log.info("File changed: {s}", .{path});
                entry.value_ptr.* = new_mtime;
                self.last_reload = now;
                return true;
            }
        }

        return false;
    }

    pub fn shouldIgnore(self: Self, path: []const u8) bool {
        for (self.ignore_patterns) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }
        }
        return false;
    }
};

pub const HotReload = struct {
    config: HotReloadConfig,
    watcher: ?FileWatcher = null,
    callback: ?*const fn () void = null,
    allocator: std.mem.Allocator,
    running: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: HotReloadConfig) !Self {
        var hr = Self{
            .config = config,
            .allocator = allocator,
        };

        if (config.enabled and config.watch_paths.len > 0) {
            hr.watcher = try FileWatcher.init(allocator, config);
        }

        return hr;
    }

    pub fn deinit(self: *Self) void {
        if (self.watcher) |*w| {
            w.deinit();
        }
    }

    pub fn setCallback(self: *Self, callback: *const fn () void) void {
        self.callback = callback;
    }

    pub fn start(self: *Self) void {
        self.running = true;
        log.info("Hot reload started", .{});
    }

    pub fn stop(self: *Self) void {
        self.running = false;
        log.info("Hot reload stopped", .{});
    }

    pub fn poll(self: *Self) !void {
        if (!self.running or self.watcher == null) return;

        if (try self.watcher.?.check()) {
            log.info("Changes detected, triggering reload...", .{});

            if (self.callback) |cb| {
                cb();
            }
        }
    }
};

/// State preservation for hot reload
pub const StatePreservation = struct {
    enabled: bool = true,
    storage_key: []const u8 = "craft_hotreload_state",
    preserve_scroll: bool = true,
    preserve_form_data: bool = true,
    preserve_focus: bool = true,
    preserve_custom_state: bool = true,
};

/// Mobile hot reload support
pub const MobileReloadConfig = struct {
    enabled: bool = true,
    port: u16 = 3456,
    host: []const u8 = "127.0.0.1", // Bind to localhost only for security
    broadcast: bool = true, // Broadcast to all connected clients
    platform: enum { ios, android, both } = .both,
    dev_token: ?[]const u8 = null, // If null, a random token is generated at server start
};

/// WebSocket client connection
pub const WebSocketClient = struct {
    stream: std.net.Stream,
    platform: []const u8,
    connected_at: i64,
    id: u64,

    pub fn send(self: *WebSocketClient, message: []const u8) !void {
        // WebSocket frame format (text frame, no mask)
        var frame: [10]u8 = undefined;
        var frame_len: usize = 2;

        frame[0] = 0x81; // FIN + text opcode

        if (message.len < 126) {
            frame[1] = @intCast(message.len);
        } else if (message.len < 65536) {
            frame[1] = 126;
            frame[2] = @intCast((message.len >> 8) & 0xFF);
            frame[3] = @intCast(message.len & 0xFF);
            frame_len = 4;
        } else {
            frame[1] = 127;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                frame[2 + i] = @intCast((message.len >> @intCast((7 - i) * 8)) & 0xFF);
            }
            frame_len = 10;
        }

        _ = try self.stream.write(frame[0..frame_len]);
        _ = try self.stream.write(message);
    }

    pub fn close(self: *WebSocketClient) void {
        self.stream.close();
    }
};

/// WebSocket server for hot reload
pub const ReloadServer = struct {
    allocator: std.mem.Allocator,
    config: MobileReloadConfig,
    running: bool = false,
    server: ?std.net.Server = null,
    clients: std.ArrayList(*WebSocketClient),
    next_client_id: u64 = 1,
    accept_thread: ?std.Thread = null,
    active_token: [32]u8 = undefined, // Hex-encoded random token (16 bytes = 32 hex chars)
    active_token_len: usize = 0,

    const Self = @This();
    const token_bytes = 16; // 16 random bytes = 32 hex characters

    pub fn init(allocator: std.mem.Allocator, config: MobileReloadConfig) Self {
        var server = Self{
            .allocator = allocator,
            .config = config,
            .clients = .{},
        };

        if (config.dev_token) |token| {
            // Use configured token
            const copy_len = @min(token.len, server.active_token.len);
            @memcpy(server.active_token[0..copy_len], token[0..copy_len]);
            server.active_token_len = copy_len;
        } else {
            // Generate a random token
            var random_bytes: [token_bytes]u8 = undefined;
            compat.randomBytes(&random_bytes);
            const hex_chars = "0123456789abcdef";
            for (random_bytes, 0..) |byte, i| {
                server.active_token[i * 2] = hex_chars[byte >> 4];
                server.active_token[i * 2 + 1] = hex_chars[byte & 0x0f];
            }
            server.active_token_len = token_bytes * 2;
        }

        return server;
    }

    /// Get the active dev token as a slice
    pub fn getToken(self: *const Self) []const u8 {
        return self.active_token[0..self.active_token_len];
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        // Close all client connections
        for (self.clients.items) |client| {
            client.close();
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        self.running = true;

        // Parse address
        const address = try std.net.Address.parseIp(self.config.host, self.config.port);

        // Create server
        self.server = try address.listen(.{
            .reuse_address = true,
        });

        log.info("Hot reload server started on {s}:{d}", .{ self.config.host, self.config.port });
        log.info("Hot reload dev token: {s}", .{self.getToken()});

        // Start accept thread
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn acceptLoop(self: *Self) void {
        while (self.running) {
            if (self.server) |*server| {
                const connection = server.accept() catch |err| {
                    if (self.running) {
                        log.warn("Accept error: {}", .{err});
                    }
                    continue;
                };

                // Handle WebSocket handshake
                self.handleConnection(connection.stream) catch |err| {
                    log.warn("Connection handling error: {}", .{err});
                    connection.stream.close();
                };
            }
        }
    }

    fn handleConnection(self: *Self, stream: std.net.Stream) !void {
        // Read HTTP upgrade request
        var buf: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buf);
        if (bytes_read == 0) return error.ConnectionClosed;

        const request = buf[0..bytes_read];

        // Validate dev token before completing the handshake.
        // Accept token via Sec-WebSocket-Protocol header or ?token= query parameter.
        if (self.active_token_len > 0) {
            const token = self.getToken();
            var token_valid = false;

            // Check Sec-WebSocket-Protocol header for the token
            const proto_header = "Sec-WebSocket-Protocol: ";
            if (std.mem.indexOf(u8, request, proto_header)) |proto_start| {
                const proto_value_start = proto_start + proto_header.len;
                if (std.mem.indexOfPos(u8, request, proto_value_start, "\r\n")) |proto_end| {
                    const proto_value = request[proto_value_start..proto_end];
                    if (std.mem.eql(u8, proto_value, token)) {
                        token_valid = true;
                    }
                }
            }

            // Check query parameter ?token=xxx in the request URI
            if (!token_valid) {
                // Extract request line (first line: "GET /path?token=xxx HTTP/1.1")
                if (std.mem.indexOf(u8, request, "?token=")) |qstart| {
                    const token_start = qstart + 7; // len of "?token="
                    // Token ends at space, &, or \r
                    var token_end = token_start;
                    while (token_end < bytes_read and request[token_end] != ' ' and request[token_end] != '&' and request[token_end] != '\r') {
                        token_end += 1;
                    }
                    const req_token = request[token_start..token_end];
                    if (std.mem.eql(u8, req_token, token)) {
                        token_valid = true;
                    }
                }
            }

            if (!token_valid) {
                // Reject connection with 403 Forbidden
                const reject_response = "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n";
                _ = stream.write(reject_response) catch |err| {
                    std.log.debug("failed to write WebSocket reject response: {}", .{err});
                };
                log.warn("WebSocket connection rejected: invalid or missing dev token", .{});
                return error.InvalidWebSocketRequest;
            }
        }

        // Extract Sec-WebSocket-Key
        const key_header = "Sec-WebSocket-Key: ";
        const key_start = std.mem.indexOf(u8, request, key_header) orelse return error.InvalidWebSocketRequest;
        const key_end = std.mem.indexOfPos(u8, request, key_start + key_header.len, "\r\n") orelse return error.InvalidWebSocketRequest;
        const ws_key = request[key_start + key_header.len .. key_end];

        // Generate accept key
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(ws_key);
        hasher.update(magic);
        const hash = hasher.finalResult();

        const accept_key = std.base64.standard.Encoder.encode(&@splat(0), &hash);

        // Check if client sent a Sec-WebSocket-Protocol header (echo it back to confirm)
        const proto_header_check = "Sec-WebSocket-Protocol: ";
        const has_protocol = std.mem.indexOf(u8, request, proto_header_check) != null;

        // Send WebSocket handshake response
        const response = if (has_protocol)
            std.fmt.allocPrint(self.allocator,
                \\HTTP/1.1 101 Switching Protocols\r
                \\Upgrade: websocket\r
                \\Connection: Upgrade\r
                \\Sec-WebSocket-Accept: {s}\r
                \\Sec-WebSocket-Protocol: {s}\r
                \\\r
                \\
            , .{ accept_key, self.getToken() }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.allocator,
                \\HTTP/1.1 101 Switching Protocols\r
                \\Upgrade: websocket\r
                \\Connection: Upgrade\r
                \\Sec-WebSocket-Accept: {s}\r
                \\\r
                \\
            , .{accept_key}) catch return error.OutOfMemory;
        defer self.allocator.free(response);

        _ = try stream.write(response);

        // Create client
        const client = try self.allocator.create(WebSocketClient);
        errdefer self.allocator.destroy(client);
        var cts: std.c.timespec = undefined;
        const connected_at: i64 = if (std.c.clock_gettime(.REALTIME, &cts) == 0) @intCast(cts.sec) else 0;
        client.* = .{
            .stream = stream,
            .platform = "unknown",
            .connected_at = connected_at,
            .id = self.next_client_id,
        };
        self.next_client_id += 1;

        try self.clients.append(self.allocator, client);
        log.info("WebSocket client connected (id: {d})", .{client.id});
    }

    pub fn stop(self: *Self) void {
        self.running = false;

        // Close server
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        // Wait for accept thread
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }

        log.info("Hot reload server stopped", .{});
    }

    pub fn broadcast(self: *Self, message: []const u8) !void {
        if (!self.running) return;

        var disconnected: std.ArrayList(usize) = .empty;
        defer disconnected.deinit(self.allocator);

        // Send to all clients
        for (self.clients.items, 0..) |client, i| {
            client.send(message) catch |err| {
                log.warn("Failed to send to client {d}: {}", .{ client.id, err });
                disconnected.append(self.allocator, i) catch |alloc_err| {
                    std.log.warn("failed to track disconnected client: {}", .{alloc_err});
                };
            };
        }

        // Remove disconnected clients (in reverse order)
        var i = disconnected.items.len;
        while (i > 0) {
            i -= 1;
            const idx = disconnected.items[i];
            const client = self.clients.orderedRemove(idx);
            client.close();
            self.allocator.destroy(client);
        }
    }

    pub fn triggerReload(self: *Self) !void {
        try self.broadcast("reload");
        log.info("Reload triggered for {d} connected clients", .{self.clients.items.len});
    }

    pub fn triggerCSSReload(self: *Self) !void {
        try self.broadcast("css-reload");
        log.info("CSS reload triggered for {d} connected clients", .{self.clients.items.len});
    }

    pub fn getClientCount(self: *const Self) usize {
        return self.clients.items.len;
    }

    /// Returns the client_script with the dev token placeholder replaced.
    /// Caller owns the returned memory.
    pub fn getClientScript(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.mem.replaceOwned(u8, allocator, client_script, "__CRAFT_DEV_TOKEN__", self.getToken());
    }

    /// Returns the mobile_client_script with the dev token placeholder replaced.
    /// Caller owns the returned memory.
    pub fn getMobileClientScript(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        return std.mem.replaceOwned(u8, allocator, mobile_client_script, "__CRAFT_DEV_TOKEN__", self.getToken());
    }
};

/// Mobile-specific hot reload script (works for iOS and Android WebViews)
/// The __CRAFT_DEV_TOKEN__ placeholder must be replaced with the actual token at injection time.
pub const mobile_client_script =
    \\<script>
    \\(function() {
    \\  // Auto-detect dev server URL from current location or use localhost
    \\  const WS_HOST = window.location.hostname || 'localhost';
    \\  const WS_PORT = 3456;
    \\  const DEV_TOKEN = '__CRAFT_DEV_TOKEN__';
    \\  const WS_URL = `ws://${WS_HOST}:${WS_PORT}/_craft_reload` + (DEV_TOKEN ? `?token=${DEV_TOKEN}` : '');
    \\  const STATE_KEY = 'craft_hotreload_state';
    \\  let ws = null;
    \\  let reconnectAttempts = 0;
    \\  const MAX_RECONNECT_ATTEMPTS = 20; // More attempts for mobile
    \\
    \\  // Detect platform
    \\  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
    \\  const isAndroid = /Android/.test(navigator.userAgent);
    \\  const isMobile = isIOS || isAndroid;
    \\
    \\  console.log(`[Craft Mobile HotReload] Platform: ${isIOS ? 'iOS' : isAndroid ? 'Android' : 'Unknown'}`);
    \\
    \\  // State preservation with mobile-specific considerations
    \\  function saveState() {
    \\    const state = {
    \\      scroll: { x: window.scrollX, y: window.scrollY },
    \\      focus: document.activeElement ? {
    \\        selector: getSelector(document.activeElement),
    \\        selectionStart: document.activeElement.selectionStart,
    \\        selectionEnd: document.activeElement.selectionEnd
    \\      } : null,
    \\      forms: Array.from(document.forms).map(form => ({
    \\        id: form.id,
    \\        data: Array.from(new FormData(form).entries())
    \\      })),
    \\      customState: window.__CRAFT_STATE__ || {},
    \\      viewport: {
    \\        width: window.innerWidth,
    \\        height: window.innerHeight,
    \\        scale: window.devicePixelRatio
    \\      },
    \\      orientation: screen.orientation?.type || 'unknown',
    \\      timestamp: Date.now()
    \\    };
    \\    try {
    \\      sessionStorage.setItem(STATE_KEY, JSON.stringify(state));
    \\      console.log('[Craft Mobile HotReload] State saved');
    \\    } catch (e) {
    \\      console.error('[Craft Mobile HotReload] Failed to save state:', e);
    \\    }
    \\  }
    \\
    \\  function restoreState() {
    \\    const stateStr = sessionStorage.getItem(STATE_KEY);
    \\    if (!stateStr) return;
    \\
    \\    try {
    \\      const state = JSON.parse(stateStr);
    \\
    \\      // Restore scroll position (delayed for mobile)
    \\      if (state.scroll) {
    \\        const restoreScroll = () => window.scrollTo(state.scroll.x, state.scroll.y);
    \\        setTimeout(restoreScroll, 100);
    \\      }
    \\
    \\      // Restore form data
    \\      if (state.forms) {
    \\        state.forms.forEach(formState => {
    \\          const form = document.getElementById(formState.id);
    \\          if (form) {
    \\            formState.data.forEach(([name, value]) => {
    \\              const field = form.elements[name];
    \\              if (field) field.value = value;
    \\            });
    \\          }
    \\        });
    \\      }
    \\
    \\      // Restore focus (skip on mobile soft keyboard)
    \\      if (!isMobile && state.focus && state.focus.selector) {
    \\        const element = document.querySelector(state.focus.selector);
    \\        if (element) {
    \\          element.focus();
    \\          if (element.setSelectionRange && state.focus.selectionStart !== undefined) {
    \\            element.setSelectionRange(state.focus.selectionStart, state.focus.selectionEnd);
    \\          }
    \\        }
    \\      }
    \\
    \\      // Restore custom state
    \\      if (state.customState) {
    \\        window.__CRAFT_STATE__ = state.customState;
    \\        window.dispatchEvent(new CustomEvent('craft:state-restored', { detail: state.customState }));
    \\      }
    \\
    \\      console.log('[Craft Mobile HotReload] State restored');
    \\    } catch (e) {
    \\      console.error('[Craft Mobile HotReload] Failed to restore state:', e);
    \\    }
    \\  }
    \\
    \\  function getSelector(element) {
    \\    if (element.id) return '#' + element.id;
    \\    if (element.className) return element.tagName.toLowerCase() + '.' + element.className.split(' ').join('.');
    \\    return element.tagName.toLowerCase();
    \\  }
    \\
    \\  function connect() {
    \\    try {
    \\      ws = new WebSocket(WS_URL);
    \\
    \\      ws.onopen = () => {
    \\        console.log('[Craft Mobile HotReload] Connected to ' + WS_URL);
    \\        reconnectAttempts = 0;
    \\        // Send platform info to server
    \\        ws.send(JSON.stringify({ type: 'hello', platform: isIOS ? 'ios' : 'android' }));
    \\      };
    \\
    \\      ws.onmessage = (event) => {
    \\        console.log('[Craft Mobile HotReload] Message:', event.data);
    \\        if (event.data === 'reload') {
    \\          console.log('[Craft Mobile HotReload] Reloading...');
    \\          saveState();
    \\          // Mobile-friendly reload with slight delay
    \\          setTimeout(() => location.reload(), 50);
    \\        }
    \\      };
    \\
    \\      ws.onclose = () => {
    \\        console.log('[Craft Mobile HotReload] Disconnected');
    \\        if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
    \\          reconnectAttempts++;
    \\          const delay = Math.min(1000 * reconnectAttempts, 10000); // Max 10s
    \\          console.log(`[Craft Mobile HotReload] Reconnecting in ${delay}ms... (${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`);
    \\          setTimeout(connect, delay);
    \\        }
    \\      };
    \\
    \\      ws.onerror = (error) => {
    \\        console.error('[Craft Mobile HotReload] Error:', error);
    \\      };
    \\    } catch (e) {
    \\      console.error('[Craft Mobile HotReload] Failed to connect:', e);
    \\      // Retry on error
    \\      if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
    \\        reconnectAttempts++;
    \\        setTimeout(connect, 2000);
    \\      }
    \\    }
    \\  }
    \\
    \\  // Restore state on page load
    \\  if (document.readyState === 'loading') {
    \\    document.addEventListener('DOMContentLoaded', restoreState);
    \\  } else {
    \\    restoreState();
    \\  }
    \\
    \\  // Start connection
    \\  connect();
    \\
    \\  // Expose reload function for native bridge
    \\  if (window.craft) {
    \\    window.craft.__hotReload = {
    \\      saveState,
    \\      restoreState,
    \\      reload: () => {
    \\        saveState();
    \\        location.reload();
    \\      }
    \\    };
    \\  }
    \\})();
    \\</script>
;

// Client-side hot reload script with state preservation
// The __CRAFT_DEV_TOKEN__ placeholder must be replaced with the actual token at injection time.
pub const client_script =
    \\<script>
    \\(function() {
    \\  const DEV_TOKEN = '__CRAFT_DEV_TOKEN__';
    \\  const WS_URL = 'ws://localhost:3456/_craft_reload' + (DEV_TOKEN ? `?token=${DEV_TOKEN}` : '');
    \\  const STATE_KEY = 'craft_hotreload_state';
    \\  let ws = null;
    \\  let reconnectAttempts = 0;
    \\  const MAX_RECONNECT_ATTEMPTS = 10;
    \\
    \\  // State preservation
    \\  function saveState() {
    \\    const state = {
    \\      scroll: { x: window.scrollX, y: window.scrollY },
    \\      focus: document.activeElement ? {
    \\        selector: getSelector(document.activeElement),
    \\        selectionStart: document.activeElement.selectionStart,
    \\        selectionEnd: document.activeElement.selectionEnd
    \\      } : null,
    \\      forms: Array.from(document.forms).map(form => ({
    \\        id: form.id,
    \\        data: Array.from(new FormData(form).entries())
    \\      })),
    \\      customState: window.__ZYTE_STATE__ || {},
    \\      timestamp: Date.now()
    \\    };
    \\    sessionStorage.setItem(STATE_KEY, JSON.stringify(state));
    \\    console.log('[Craft HotReload] State saved');
    \\  }
    \\
    \\  function restoreState() {
    \\    const stateStr = sessionStorage.getItem(STATE_KEY);
    \\    if (!stateStr) return;
    \\
    \\    try {
    \\      const state = JSON.parse(stateStr);
    \\
    \\      // Restore scroll position
    \\      if (state.scroll) {
    \\        window.scrollTo(state.scroll.x, state.scroll.y);
    \\      }
    \\
    \\      // Restore form data
    \\      if (state.forms) {
    \\        state.forms.forEach(formState => {
    \\          const form = document.getElementById(formState.id);
    \\          if (form) {
    \\            formState.data.forEach(([name, value]) => {
    \\              const field = form.elements[name];
    \\              if (field) field.value = value;
    \\            });
    \\          }
    \\        });
    \\      }
    \\
    \\      // Restore focus
    \\      if (state.focus && state.focus.selector) {
    \\        const element = document.querySelector(state.focus.selector);
    \\        if (element) {
    \\          element.focus();
    \\          if (element.setSelectionRange && state.focus.selectionStart !== undefined) {
    \\            element.setSelectionRange(state.focus.selectionStart, state.focus.selectionEnd);
    \\          }
    \\        }
    \\      }
    \\
    \\      // Restore custom state
    \\      if (state.customState) {
    \\        window.__ZYTE_STATE__ = state.customState;
    \\        window.dispatchEvent(new CustomEvent('craft:state-restored', { detail: state.customState }));
    \\      }
    \\
    \\      console.log('[Craft HotReload] State restored');
    \\    } catch (e) {
    \\      console.error('[Craft HotReload] Failed to restore state:', e);
    \\    }
    \\  }
    \\
    \\  function getSelector(element) {
    \\    if (element.id) return '#' + element.id;
    \\    if (element.className) return element.tagName.toLowerCase() + '.' + element.className.split(' ').join('.');
    \\    return element.tagName.toLowerCase();
    \\  }
    \\
    \\  function connect() {
    \\    ws = new WebSocket(WS_URL);
    \\
    \\    ws.onopen = () => {
    \\      console.log('[Craft HotReload] Connected');
    \\      reconnectAttempts = 0;
    \\    };
    \\
    \\    ws.onmessage = (event) => {
    \\      if (event.data === 'reload') {
    \\        console.log('[Craft HotReload] Reloading...');
    \\        saveState();
    \\        location.reload();
    \\      }
    \\    };
    \\
    \\    ws.onclose = () => {
    \\      console.log('[Craft HotReload] Disconnected');
    \\      if (reconnectAttempts < MAX_RECONNECT_ATTEMPTS) {
    \\        reconnectAttempts++;
    \\        setTimeout(connect, 1000 * reconnectAttempts);
    \\      }
    \\    };
    \\
    \\    ws.onerror = (error) => {
    \\      console.error('[Craft HotReload] Error:', error);
    \\    };
    \\  }
    \\
    \\  // Restore state on page load
    \\  if (document.readyState === 'loading') {
    \\    document.addEventListener('DOMContentLoaded', restoreState);
    \\  } else {
    \\    restoreState();
    \\  }
    \\
    \\  connect();
    \\})();
    \\</script>
;
