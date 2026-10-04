const std = @import("std");
const macos = @import("../macos.zig");
const objc = macos.objc;

/// SF Symbol weight
pub const SymbolWeight = enum(i64) {
    ultralight = 1,
    thin = 2,
    light = 3,
    regular = 4,
    medium = 5,
    semibold = 6,
    bold = 7,
    heavy = 8,
    black = 9,
};

/// SF Symbol scale
pub const SymbolScale = enum(i64) {
    small = 1,
    medium = 2,
    large = 3,
};

/// SF Symbol rendering mode
pub const SymbolRenderingMode = enum(i64) {
    monochrome = 0,
    hierarchical = 1,
    palette = 2,
    multicolor = 3,
};

/// SF Symbol configuration
pub const SymbolConfiguration = struct {
    point_size: f64 = 17.0,
    weight: SymbolWeight = .regular,
    scale: SymbolScale = .medium,
    rendering_mode: SymbolRenderingMode = .monochrome,
    primary_color: ?objc.id = null,
    secondary_color: ?objc.id = null,
    tertiary_color: ?objc.id = null,
};

/// SF Symbol image cache
pub const SymbolCache = struct {
    const Self = @This();

    cache: std.StringHashMap(CachedSymbol),
    allocator: std.mem.Allocator,
    max_size: usize,
    hits: usize,
    misses: usize,

    const CachedSymbol = struct {
        image: objc.id,
        last_access: i64,
        config_hash: u64,
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return Self{
            .cache = std.StringHashMap(CachedSymbol).init(allocator),
            .allocator = allocator,
            .max_size = max_size,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // Release all cached images
        var iter = self.cache.valueIterator();
        while (iter.next()) |entry| {
            _ = macos.msgSend0(entry.image, "release");
        }
        self.cache.deinit();
    }

    pub fn get(self: *Self, name: []const u8, config_hash: u64) ?objc.id {
        if (self.cache.get(name)) |entry| {
            if (entry.config_hash == config_hash) {
                self.hits += 1;
                return macos.msgSend0(entry.image, "retain");
            }
        }
        self.misses += 1;
        return null;
    }

    pub fn put(self: *Self, name: []const u8, image: objc.id, config_hash: u64) void {
        // Evict oldest if at capacity
        if (self.cache.count() >= self.max_size) {
            self.evictOldest();
        }

        // Store owned copy of name
        const owned_name = self.allocator.dupe(u8, name) catch return;

        self.cache.put(owned_name, .{
            .image = macos.msgSend0(image, "retain"),
            .last_access = std.time.milliTimestamp(),
            .config_hash = config_hash,
        }) catch {
            self.allocator.free(owned_name);
        };
    }

    fn evictOldest(self: *Self) void {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_key: ?[]const u8 = null;

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_access < oldest_time) {
                oldest_time = entry.value_ptr.last_access;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.cache.fetchRemove(key)) |entry| {
                _ = macos.msgSend0(entry.value.image, "release");
                self.allocator.free(entry.key);
            }
        }
    }

    pub fn getStats(self: *Self) struct { hits: usize, misses: usize, size: usize, hit_rate: f64 } {
        const total = self.hits + self.misses;
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .size = self.cache.count(),
            .hit_rate = if (total > 0) @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) else 0.0,
        };
    }

    pub fn clear(self: *Self) void {
        var iter = self.cache.valueIterator();
        while (iter.next()) |entry| {
            _ = macos.msgSend0(entry.image, "release");
        }
        self.cache.clearAndFree();
    }
};

/// Create an SF Symbol image
pub fn createSFSymbol(name: [*:0]const u8, config: SymbolConfiguration) ?objc.id {
    return createSFSymbolNamed(std.mem.span(name), config);
}

/// The same, for a name that is a slice rather than a C string - one parsed
/// out of a bridge message's JSON, say. Such a slice points into the middle of
/// the payload with no terminator after it, so casting its pointer to
/// `[*:0]const u8` read on to the next NUL: `archivebox","shortcut":...`,
/// which names no symbol, and every context-menu icon silently went missing.
pub fn createSFSymbolNamed(name: []const u8, config: SymbolConfiguration) ?objc.id {
    const NSImage = macos.getClass("NSImage");
    if (NSImage == null) return null;

    // Create NSString for symbol name
    const nsstring = macos.createNSString(name);
    if (nsstring == @as(objc.id, null)) return null;

    // Create image with symbol name
    const image = macos.msgSend2(NSImage, "imageWithSystemSymbolName:accessibilityDescription:", nsstring, @as(objc.id, null));

    if (image == @as(objc.id, null)) {
        return null;
    }

    // Apply configuration if non-default
    if (config.point_size != 17.0 or config.weight != .regular or config.scale != .medium) {
        const symbol_config = createSymbolConfiguration(config);
        if (symbol_config != @as(objc.id, null)) {
            const configured_image = macos.msgSend1(image, "imageWithSymbolConfiguration:", symbol_config);
            if (configured_image != @as(objc.id, null)) {
                return configured_image;
            }
        }
    }

    return image;
}

/// Create SF Symbol with fallback
pub fn createSFSymbolWithFallback(
    name: [*:0]const u8,
    fallback_name: [*:0]const u8,
    config: SymbolConfiguration,
) ?objc.id {
    // Try primary symbol
    if (createSFSymbol(name, config)) |image| {
        return image;
    }

    // Try fallback symbol
    if (createSFSymbol(fallback_name, config)) |image| {
        return image;
    }

    // Return generic fallback
    return createSFSymbol("questionmark.circle", config);
}

/// Create symbol configuration
fn createSymbolConfiguration(config: SymbolConfiguration) objc.id {
    const NSImageSymbolConfiguration = macos.getClass("NSImageSymbolConfiguration");
    if (NSImageSymbolConfiguration == null) return null;

    // Create base configuration with point size and weight
    const symbol_config = macos.msgSend2(
        NSImageSymbolConfiguration,
        "configurationWithPointSize:weight:",
        config.point_size,
        @backingInt(config.weight),
    );

    return symbol_config;
}

/// Check if symbol exists
pub fn symbolExists(name: [*:0]const u8) bool {
    const image = createSFSymbol(name, .{});
    if (image) |img| {
        _ = macos.msgSend0(img, "release");
        return true;
    }
    return false;
}

/// Get available symbol names (subset - full list is very large)
pub fn getCommonSymbolNames() []const [*:0]const u8 {
    return &[_][*:0]const u8{
        // Navigation
        "chevron.left",
        "chevron.right",
        "chevron.up",
        "chevron.down",
        "arrow.left",
        "arrow.right",
        "arrow.up",
        "arrow.down",

        // Actions
        "plus",
        "minus",
        "xmark",
        "checkmark",
        "trash",
        "pencil",
        "square.and.pencil",

        // Media
        "play.fill",
        "pause.fill",
        "stop.fill",
        "forward.fill",
        "backward.fill",
        "speaker.wave.2.fill",
        "speaker.slash.fill",

        // Communication
        "envelope",
        "envelope.fill",
        "phone",
        "phone.fill",
        "message",
        "message.fill",

        // Files
        "folder",
        "folder.fill",
        "doc",
        "doc.fill",
        "doc.text",
        "doc.text.fill",

        // System
        "gear",
        "gearshape",
        "person",
        "person.fill",
        "house",
        "house.fill",
        "magnifyingglass",
        "star",
        "star.fill",
        "heart",
        "heart.fill",
        "bell",
        "bell.fill",

        // Devices
        "iphone",
        "ipad",
        "desktopcomputer",
        "laptopcomputer",
        "applewatch",

        // Status
        "checkmark.circle",
        "checkmark.circle.fill",
        "xmark.circle",
        "xmark.circle.fill",
        "exclamationmark.triangle",
        "exclamationmark.triangle.fill",
        "info.circle",
        "info.circle.fill",
        "questionmark.circle",
        "questionmark.circle.fill",
    };
}

/// Create NSColor from RGB
pub fn createColor(r: f64, g: f64, b: f64, a: f64) ?objc.id {
    const NSColor = macos.getClass("NSColor");
    if (NSColor == null) return null;
    return macos.msgSend4(NSColor, "colorWithRed:green:blue:alpha:", r, g, b, a);
}

/// Create NSColor from hex string
pub fn createColorFromHex(hex: []const u8) ?objc.id {
    if (hex.len < 6) return null;

    const start: usize = if (hex[0] == '#') 1 else 0;
    if (hex.len - start < 6) return null;

    const r = std.fmt.parseInt(u8, hex[start .. start + 2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[start + 2 .. start + 4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[start + 4 .. start + 6], 16) catch return null;
    const a: u8 = if (hex.len - start >= 8)
        std.fmt.parseInt(u8, hex[start + 6 .. start + 8], 16) catch 255
    else
        255;

    return createColor(
        @as(f64, @floatFromInt(r)) / 255.0,
        @as(f64, @floatFromInt(g)) / 255.0,
        @as(f64, @floatFromInt(b)) / 255.0,
        @as(f64, @floatFromInt(a)) / 255.0,
    );
}

// Global symbol cache
var global_cache: ?SymbolCache = null;

pub fn getGlobalCache() *SymbolCache {
    if (global_cache == null) {
        global_cache = SymbolCache.init(std.heap.page_allocator, 100);
    }
    return &global_cache.?;
}

/// Create cached SF Symbol
pub fn createCachedSFSymbol(name: [*:0]const u8, config: SymbolConfiguration) ?objc.id {
    const cache = getGlobalCache();
    const name_slice = std.mem.span(name);
    const config_hash = hashConfiguration(config);

    // Check cache
    if (cache.get(name_slice, config_hash)) |cached| {
        return cached;
    }

    // Create new symbol
    const image = createSFSymbol(name, config) orelse return null;

    // Cache it
    cache.put(name_slice, image, config_hash);

    return macos.msgSend0(image, "retain");
}

fn hashConfiguration(config: SymbolConfiguration) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&config.point_size));
    hasher.update(std.mem.asBytes(&config.weight));
    hasher.update(std.mem.asBytes(&config.scale));
    hasher.update(std.mem.asBytes(&config.rendering_mode));
    return hasher.final();
}

// Tests
test "SymbolCache basic operations" {
    var cache = SymbolCache.init(std.testing.allocator, 10);
    defer cache.deinit();

    // Stats should be zero initially
    const stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 0), stats.misses);
}

test "symbolExists returns false for invalid symbol" {
    // This would require actual macOS runtime
    // Just verify the function compiles
    _ = symbolExists;
}
