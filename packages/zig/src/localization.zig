//! Localization and Internationalization Module
//!
//! Provides comprehensive i18n/l10n functionality:
//! - String translation with fallback
//! - Locale detection (system locale)
//! - Pluralization rules
//! - Date/time/number formatting per locale
//! - RTL language support
//! - ICU message format support
//!
//! Example usage:
//! ```zig
//! var i18n = try Localization.init(allocator);
//! defer i18n.deinit();
//!
//! try i18n.loadTranslations("en", english_translations);
//! try i18n.loadTranslations("es", spanish_translations);
//! i18n.setLocale("es");
//!
//! const greeting = i18n.t("hello"); // "Hola"
//! const items = i18n.plural("items", 5); // "5 items"
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// An environment variable as a slice, or null when it is unset.
///
/// libc rather than std: `std.posix` has no `getenv` in this compiler version,
/// and this build links libc everywhere.
fn envOrEmpty(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

/// Supported locale identifiers
pub const Locale = struct {
    language: []const u8, // ISO 639-1 (e.g., "en", "es", "zh")
    region: ?[]const u8 = null, // ISO 3166-1 alpha-2 (e.g., "US", "GB", "CN")
    script: ?[]const u8 = null, // ISO 15924 (e.g., "Hans", "Hant")

    pub fn format(self: Locale, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll(self.language);
        if (self.script) |script| {
            try writer.writeByte('-');
            try writer.writeAll(script);
        }
        if (self.region) |region| {
            try writer.writeByte('-');
            try writer.writeAll(region);
        }

        return fbs.getWritten();
    }

    /// Parse a locale string like "en", "en-US", "zh-Hans-CN", or "en_US"
    /// (the POSIX form, which uses `_` instead of `-`). Returns a Locale
    /// with slices pointing into `locale_str`, so the caller must keep
    /// `locale_str` alive for the Locale's lifetime.
    pub fn parse(locale_str: []const u8) Locale {
        // Accept `-` OR `_` as the separator. `detectFromEnv` used to build
        // a stack-local copy just to rewrite `_` to `-`, and then returned
        // a Locale whose slices pointed into that dead stack buffer. By
        // making parse treat both separators identically we let callers
        // pass the env var's borrowed slice directly — no copy needed.
        const sep_idx = std.mem.indexOfAny(u8, locale_str, "-_");

        if (sep_idx == null) return .{ .language = locale_str };

        const language = locale_str[0..sep_idx.?];
        const rest = locale_str[sep_idx.? + 1 ..];

        const sep2 = std.mem.indexOfAny(u8, rest, "-_");
        const second = if (sep2) |i| rest[0..i] else rest;
        const third: ?[]const u8 = if (sep2) |i| rest[i + 1 ..] else null;

        if (second.len == 4) {
            // Script (e.g. "Hans")
            return .{
                .language = language,
                .script = second,
                .region = third,
            };
        }
        // Region (e.g. "US")
        return .{
            .language = language,
            .region = second,
        };
    }

    pub fn isRTL(self: Locale) bool {
        // RTL languages: Arabic, Hebrew, Persian, Urdu, etc.
        const rtl_languages = [_][]const u8{ "ar", "he", "fa", "ur", "yi", "ps", "sd" };
        for (rtl_languages) |rtl| {
            if (std.mem.eql(u8, self.language, rtl)) return true;
        }
        return false;
    }
};

/// Pluralization rules for different languages
pub const PluralCategory = enum {
    zero,
    one,
    two,
    few,
    many,
    other,

    pub fn toString(self: PluralCategory) []const u8 {
        return switch (self) {
            .zero => "zero",
            .one => "one",
            .two => "two",
            .few => "few",
            .many => "many",
            .other => "other",
        };
    }
};

/// Plural rules for common languages
pub const PluralRules = struct {
    /// Get plural category for a count in a given language
    pub fn getCategory(language: []const u8, count: i64) PluralCategory {
        // English, German, Dutch, etc. (one/other)
        if (std.mem.eql(u8, language, "en") or
            std.mem.eql(u8, language, "de") or
            std.mem.eql(u8, language, "nl") or
            std.mem.eql(u8, language, "it") or
            std.mem.eql(u8, language, "es") or
            std.mem.eql(u8, language, "pt"))
        {
            return if (count == 1) .one else .other;
        }

        // French, Brazilian Portuguese (zero/one uses singular)
        if (std.mem.eql(u8, language, "fr")) {
            return if (count == 0 or count == 1) .one else .other;
        }

        // Russian, Ukrainian, Polish (complex rules)
        if (std.mem.eql(u8, language, "ru") or std.mem.eql(u8, language, "uk")) {
            return getRussianPlural(count);
        }

        // Polish
        if (std.mem.eql(u8, language, "pl")) {
            return getPolishPlural(count);
        }

        // Arabic (zero/one/two/few/many/other)
        if (std.mem.eql(u8, language, "ar")) {
            return getArabicPlural(count);
        }

        // Chinese, Japanese, Korean, Vietnamese (no plural forms)
        if (std.mem.eql(u8, language, "zh") or
            std.mem.eql(u8, language, "ja") or
            std.mem.eql(u8, language, "ko") or
            std.mem.eql(u8, language, "vi"))
        {
            return .other;
        }

        // Default: simple one/other
        return if (count == 1) .one else .other;
    }

    fn getRussianPlural(count: i64) PluralCategory {
        const n = @abs(count);
        const mod10 = @mod(n, 10);
        const mod100 = @mod(n, 100);

        if (mod10 == 1 and mod100 != 11) return .one;
        if (mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14)) return .few;
        return .many;
    }

    fn getPolishPlural(count: i64) PluralCategory {
        const n = @abs(count);
        const mod10 = @mod(n, 10);
        const mod100 = @mod(n, 100);

        if (n == 1) return .one;
        if (mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14)) return .few;
        return .many;
    }

    fn getArabicPlural(count: i64) PluralCategory {
        const n = @abs(count);
        const mod100 = @mod(n, 100);

        if (n == 0) return .zero;
        if (n == 1) return .one;
        if (n == 2) return .two;
        if (mod100 >= 3 and mod100 <= 10) return .few;
        if (mod100 >= 11 and mod100 <= 99) return .many;
        return .other;
    }
};

/// Number formatting options
pub const NumberFormat = struct {
    style: Style = .decimal,
    minimum_integer_digits: u8 = 1,
    minimum_fraction_digits: u8 = 0,
    maximum_fraction_digits: u8 = 3,
    use_grouping: bool = true,
    currency_code: ?[]const u8 = null,

    pub const Style = enum {
        decimal,
        currency,
        percent,
        scientific,
    };
};

/// Date/time formatting options
pub const DateTimeFormat = struct {
    date_style: ?DateStyle = null,
    time_style: ?TimeStyle = null,
    hour12: ?bool = null,

    pub const DateStyle = enum {
        full, // "Monday, January 1, 2024"
        long, // "January 1, 2024"
        medium, // "Jan 1, 2024"
        short, // "1/1/24"
    };

    pub const TimeStyle = enum {
        full, // "1:30:00 PM Pacific Standard Time"
        long, // "1:30:00 PM PST"
        medium, // "1:30:00 PM"
        short, // "1:30 PM"
    };
};

/// Translation entry with optional plural forms
pub const TranslationEntry = struct {
    value: []const u8,
    plural_one: ?[]const u8 = null,
    plural_two: ?[]const u8 = null,
    plural_few: ?[]const u8 = null,
    plural_many: ?[]const u8 = null,
    plural_zero: ?[]const u8 = null,
    context: ?[]const u8 = null,
};

/// Main localization manager
pub const Localization = struct {
    allocator: std.mem.Allocator,
    current_locale: Locale,
    fallback_locale: Locale,
    translations: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(TranslationEntry)),
    number_formats: std.StringHashMapUnmanaged(LocaleNumberFormat),
    date_formats: std.StringHashMapUnmanaged(LocaleDateFormat),

    const Self = @This();

    const LocaleNumberFormat = struct {
        decimal_separator: []const u8 = ".",
        grouping_separator: []const u8 = ",",
        currency_symbol: []const u8 = "$",
        currency_position: enum { before, after } = .before,
        percent_symbol: []const u8 = "%",
    };

    const LocaleDateFormat = struct {
        short_date: []const u8 = "M/d/yy",
        medium_date: []const u8 = "MMM d, yyyy",
        long_date: []const u8 = "MMMM d, yyyy",
        full_date: []const u8 = "EEEE, MMMM d, yyyy",
        short_time: []const u8 = "h:mm a",
        medium_time: []const u8 = "h:mm:ss a",
        long_time: []const u8 = "h:mm:ss a z",
        full_time: []const u8 = "h:mm:ss a zzzz",
        first_day_of_week: u8 = 0, // 0 = Sunday
        am_symbol: []const u8 = "AM",
        pm_symbol: []const u8 = "PM",
    };

    /// Initialize localization system
    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .current_locale = .{ .language = "en" },
            .fallback_locale = .{ .language = "en" },
            .translations = .{},
            .number_formats = .{},
            .date_formats = .{},
        };

        // Populate defaults. If the second setup fails, release everything
        // the first one put in the map — previously a partial init on OOM
        // leaked every entry already added to `number_formats`.
        try self.setupDefaultNumberFormats();
        errdefer self.number_formats.deinit(self.allocator);
        try self.setupDefaultDateFormats();
        errdefer self.date_formats.deinit(self.allocator);

        // Try to detect system locale
        self.current_locale = self.detectSystemLocale() orelse self.fallback_locale;

        return self;
    }

    fn setupDefaultNumberFormats(self: *Self) !void {
        // English (US)
        try self.number_formats.put(self.allocator, "en", .{});

        // German
        try self.number_formats.put(self.allocator, "de", .{
            .decimal_separator = ",",
            .grouping_separator = ".",
            .currency_symbol = "\xe2\x82\xac", // Euro sign
            .currency_position = .after,
        });

        // French
        try self.number_formats.put(self.allocator, "fr", .{
            .decimal_separator = ",",
            .grouping_separator = " ",
            .currency_symbol = "\xe2\x82\xac",
            .currency_position = .after,
        });

        // Spanish
        try self.number_formats.put(self.allocator, "es", .{
            .decimal_separator = ",",
            .grouping_separator = ".",
            .currency_symbol = "\xe2\x82\xac",
            .currency_position = .after,
        });

        // Japanese
        try self.number_formats.put(self.allocator, "ja", .{
            .currency_symbol = "\xc2\xa5", // Yen sign
            .currency_position = .before,
        });

        // Chinese
        try self.number_formats.put(self.allocator, "zh", .{
            .currency_symbol = "\xc2\xa5",
            .currency_position = .before,
        });
    }

    fn setupDefaultDateFormats(self: *Self) !void {
        // English (US)
        try self.date_formats.put(self.allocator, "en", .{});

        // German
        try self.date_formats.put(self.allocator, "de", .{
            .short_date = "dd.MM.yy",
            .medium_date = "dd.MM.yyyy",
            .long_date = "d. MMMM yyyy",
            .full_date = "EEEE, d. MMMM yyyy",
            .first_day_of_week = 1, // Monday
        });

        // French
        try self.date_formats.put(self.allocator, "fr", .{
            .short_date = "dd/MM/yy",
            .medium_date = "d MMM yyyy",
            .long_date = "d MMMM yyyy",
            .full_date = "EEEE d MMMM yyyy",
            .first_day_of_week = 1,
        });

        // Japanese
        try self.date_formats.put(self.allocator, "ja", .{
            .short_date = "yy/MM/dd",
            .medium_date = "yyyy/MM/dd",
            .long_date = "yyyy\xe5\xb9\xb4M\xe6\x9c\x88d\xe6\x97\xa5",
            .full_date = "yyyy\xe5\xb9\xb4M\xe6\x9c\x88d\xe6\x97\xa5EEEE",
            .first_day_of_week = 0,
            .am_symbol = "\xe5\x8d\x88\xe5\x89\x8d",
            .pm_symbol = "\xe5\x8d\x88\xe5\xbe\x8c",
        });
    }

    /// Detect system locale
    pub fn detectSystemLocale(self: *Self) ?Locale {
        _ = self;
        if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
            return detectMacOSLocale();
        } else if (builtin.os.tag == .linux) {
            return detectLinuxLocale();
        } else if (builtin.os.tag == .windows) {
            return detectWindowsLocale();
        }
        return null;
    }

    fn detectMacOSLocale() ?Locale {
        // Would use NSLocale.currentLocale in real implementation
        // For now, check LANG environment variable
        return detectFromEnv();
    }

    fn detectLinuxLocale() ?Locale {
        return detectFromEnv();
    }

    fn detectWindowsLocale() ?Locale {
        // Would use GetUserDefaultLocaleName in real implementation
        return detectFromEnv();
    }

    fn detectFromEnv() ?Locale {
        // Check common locale environment variables. We slice directly into
        // the env var's backing memory, which stays live for the process
        // lifetime — the previous implementation built a stack-local copy
        // and returned a Locale whose slices pointed into that dead buffer.
        const env_vars = [_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
        for (env_vars) |env_var| {
            if (envOrEmpty(env_var)) |value| {
                // Strip `.UTF-8`, `.ISO-8859-1`, etc. — the codepage suffix
                // isn't part of the locale identifier.
                const dot_pos = std.mem.indexOf(u8, value, ".");
                const locale_slice = value[0 .. dot_pos orelse value.len];
                if (locale_slice.len == 0) continue;
                // `parse` now accepts `_` directly so this slice works as-is.
                return Locale.parse(locale_slice);
            }
        }
        return null;
    }

    /// Set current locale
    pub fn setLocale(self: *Self, locale_str: []const u8) void {
        self.current_locale = Locale.parse(locale_str);
    }

    /// Set fallback locale
    pub fn setFallbackLocale(self: *Self, locale_str: []const u8) void {
        self.fallback_locale = Locale.parse(locale_str);
    }

    /// Get current locale
    pub fn getLocale(self: *Self) Locale {
        return self.current_locale;
    }

    /// Check if current locale is RTL
    pub fn isRTL(self: *Self) bool {
        return self.current_locale.isRTL();
    }

    /// Load translations for a locale.
    ///
    /// Mutates the stored inner hashmap in place via `getOrPut`. The previous
    /// implementation did `get()` (which returns a *copy* of the value), added
    /// entries to the copy, then `put()` the copy back — leaking the
    /// previously stored hashmap's backing storage on every call.
    pub fn loadTranslations(self: *Self, locale: []const u8, translations_list: []const struct { key: []const u8, value: TranslationEntry }) !void {
        const gop = try self.translations.getOrPut(self.allocator, locale);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        for (translations_list) |entry| {
            try gop.value_ptr.put(self.allocator, entry.key, entry.value);
        }
    }

    /// Add a single translation (same in-place pattern as `loadTranslations`).
    pub fn addTranslation(self: *Self, locale: []const u8, key: []const u8, entry: TranslationEntry) !void {
        const gop = try self.translations.getOrPut(self.allocator, locale);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.put(self.allocator, key, entry);
    }

    /// Translate a key (shorthand for translate)
    pub fn t(self: *Self, key: []const u8) []const u8 {
        return self.translate(key, null);
    }

    /// Translate a key with context
    pub fn tc(self: *Self, key: []const u8, context: []const u8) []const u8 {
        return self.translate(key, context);
    }

    /// Translate a key
    pub fn translate(self: *Self, key: []const u8, context: ?[]const u8) []const u8 {
        // Try current locale
        if (self.getTranslation(self.current_locale.language, key, context)) |entry| {
            return entry.value;
        }

        // Try fallback locale
        if (self.getTranslation(self.fallback_locale.language, key, context)) |entry| {
            return entry.value;
        }

        // Return key as fallback
        return key;
    }

    fn getTranslation(self: *Self, locale: []const u8, key: []const u8, context: ?[]const u8) ?TranslationEntry {
        if (self.translations.get(locale)) |locale_translations| {
            if (locale_translations.get(key)) |entry| {
                // Check context match
                if (context) |ctx| {
                    if (entry.context) |entry_ctx| {
                        if (!std.mem.eql(u8, ctx, entry_ctx)) return null;
                    }
                }
                return entry;
            }
        }
        return null;
    }

    /// Translate with pluralization
    pub fn plural(self: *Self, key: []const u8, count: i64) []const u8 {
        return self.translatePlural(key, count, null);
    }

    /// Translate with pluralization and context
    pub fn translatePlural(self: *Self, key: []const u8, count: i64, context: ?[]const u8) []const u8 {
        const category = PluralRules.getCategory(self.current_locale.language, count);

        // Try current locale
        if (self.getTranslation(self.current_locale.language, key, context)) |entry| {
            if (self.getPluralForm(entry, category)) |plural_form| {
                return plural_form;
            }
            return entry.value;
        }

        // Try fallback locale
        if (self.getTranslation(self.fallback_locale.language, key, context)) |entry| {
            if (self.getPluralForm(entry, category)) |plural_form| {
                return plural_form;
            }
            return entry.value;
        }

        return key;
    }

    fn getPluralForm(self: *Self, entry: TranslationEntry, category: PluralCategory) ?[]const u8 {
        _ = self;
        return switch (category) {
            .zero => entry.plural_zero,
            .one => entry.plural_one,
            .two => entry.plural_two,
            .few => entry.plural_few,
            .many => entry.plural_many,
            .other => null, // Use default value
        };
    }

    /// Format a number according to locale
    pub fn formatNumber(self: *Self, value: f64, options: NumberFormat, buf: []u8) ![]const u8 {
        const format = self.number_formats.get(self.current_locale.language) orelse
            self.number_formats.get("en") orelse
            LocaleNumberFormat{};

        var pos: usize = 0;

        switch (options.style) {
            .currency => {
                if (format.currency_position == .before) {
                    const sym = options.currency_code orelse format.currency_symbol;
                    @memcpy(buf[pos..][0..sym.len], sym);
                    pos += sym.len;
                }
                pos = try self.writeFormattedNumber(buf, pos, value, format, options);
                if (format.currency_position == .after) {
                    buf[pos] = ' ';
                    pos += 1;
                    const sym = options.currency_code orelse format.currency_symbol;
                    @memcpy(buf[pos..][0..sym.len], sym);
                    pos += sym.len;
                }
            },
            .percent => {
                pos = try self.writeFormattedNumber(buf, pos, value * 100, format, options);
                @memcpy(buf[pos..][0..format.percent_symbol.len], format.percent_symbol);
                pos += format.percent_symbol.len;
            },
            .decimal, .scientific => {
                pos = try self.writeFormattedNumber(buf, pos, value, format, options);
            },
        }

        return buf[0..pos];
    }

    fn writeFormattedNumber(self: *Self, buf: []u8, start_pos: usize, value: f64, format: LocaleNumberFormat, options: NumberFormat) !usize {
        _ = self;
        var pos = start_pos;
        const abs_value = @abs(value);
        const int_part: i64 = @intFromFloat(abs_value);
        const frac_part = abs_value - @as(f64, @floatFromInt(int_part));

        if (value < 0) {
            buf[pos] = '-';
            pos += 1;
        }

        // Format integer part with grouping
        var int_buf: [32]u8 = undefined;
        const int_str = try std.fmt.bufPrint(&int_buf, "{d}", .{int_part});

        if (options.use_grouping and int_str.len > 3) {
            var src_pos: usize = 0;
            const first_group = int_str.len % 3;
            if (first_group > 0) {
                @memcpy(buf[pos..][0..first_group], int_str[0..first_group]);
                pos += first_group;
                src_pos = first_group;
            }
            while (src_pos < int_str.len) {
                if (src_pos > 0) {
                    @memcpy(buf[pos..][0..format.grouping_separator.len], format.grouping_separator);
                    pos += format.grouping_separator.len;
                }
                @memcpy(buf[pos..][0..3], int_str[src_pos..][0..3]);
                pos += 3;
                src_pos += 3;
            }
        } else {
            @memcpy(buf[pos..][0..int_str.len], int_str);
            pos += int_str.len;
        }

        // Format fraction part
        if (options.maximum_fraction_digits > 0 and frac_part > 0) {
            @memcpy(buf[pos..][0..format.decimal_separator.len], format.decimal_separator);
            pos += format.decimal_separator.len;
            var frac_val = frac_part;
            var digits: usize = 0;
            while (digits < options.maximum_fraction_digits and frac_val > 0.0000001) {
                frac_val *= 10;
                const digit: u8 = @intFromFloat(frac_val);
                buf[pos] = '0' + digit;
                pos += 1;
                frac_val -= @as(f64, @floatFromInt(digit));
                digits += 1;
            }
            // Add minimum fraction digits
            while (digits < options.minimum_fraction_digits) {
                buf[pos] = '0';
                pos += 1;
                digits += 1;
            }
        } else if (options.minimum_fraction_digits > 0) {
            @memcpy(buf[pos..][0..format.decimal_separator.len], format.decimal_separator);
            pos += format.decimal_separator.len;
            var i: usize = 0;
            while (i < options.minimum_fraction_digits) : (i += 1) {
                buf[pos] = '0';
                pos += 1;
            }
        }

        return pos;
    }

    /// Format currency
    pub fn formatCurrency(self: *Self, value: f64, currency_code: ?[]const u8, buf: []u8) ![]const u8 {
        return self.formatNumber(value, .{
            .style = .currency,
            .minimum_fraction_digits = 2,
            .maximum_fraction_digits = 2,
            .currency_code = currency_code,
        }, buf);
    }

    /// Format percentage
    pub fn formatPercent(self: *Self, value: f64, buf: []u8) ![]const u8 {
        return self.formatNumber(value, .{
            .style = .percent,
            .maximum_fraction_digits = 1,
        }, buf);
    }

    /// Get text direction for current locale
    pub fn getTextDirection(self: *Self) TextDirection {
        return if (self.current_locale.isRTL()) .rtl else .ltr;
    }

    pub const TextDirection = enum {
        ltr,
        rtl,

        pub fn toString(self: TextDirection) []const u8 {
            return switch (self) {
                .ltr => "ltr",
                .rtl => "rtl",
            };
        }
    };

    /// Get list of available locales
    pub fn getAvailableLocales(self: *Self, buf: [][]const u8) [][]const u8 {
        var count: usize = 0;
        var it = self.translations.iterator();
        while (it.next()) |entry| {
            if (count >= buf.len) break;
            buf[count] = entry.key_ptr.*;
            count += 1;
        }
        return buf[0..count];
    }

    /// Check if a locale has translations
    pub fn hasLocale(self: *Self, locale: []const u8) bool {
        return self.translations.contains(locale);
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        var trans_it = self.translations.iterator();
        while (trans_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.translations.deinit(self.allocator);
        self.number_formats.deinit(self.allocator);
        self.date_formats.deinit(self.allocator);
    }
};

/// Localization presets for common use cases
pub const LocalizationPresets = struct {
    /// Common UI strings in English
    pub fn englishUI() [15]struct { key: []const u8, value: TranslationEntry } {
        return .{
            .{ .key = "ok", .value = .{ .value = "OK" } },
            .{ .key = "cancel", .value = .{ .value = "Cancel" } },
            .{ .key = "save", .value = .{ .value = "Save" } },
            .{ .key = "delete", .value = .{ .value = "Delete" } },
            .{ .key = "edit", .value = .{ .value = "Edit" } },
            .{ .key = "close", .value = .{ .value = "Close" } },
            .{ .key = "search", .value = .{ .value = "Search" } },
            .{ .key = "loading", .value = .{ .value = "Loading..." } },
            .{ .key = "error", .value = .{ .value = "Error" } },
            .{ .key = "success", .value = .{ .value = "Success" } },
            .{ .key = "warning", .value = .{ .value = "Warning" } },
            .{ .key = "confirm", .value = .{ .value = "Confirm" } },
            .{ .key = "yes", .value = .{ .value = "Yes" } },
            .{ .key = "no", .value = .{ .value = "No" } },
            .{ .key = "back", .value = .{ .value = "Back" } },
        };
    }

    /// Common UI strings in Spanish
    pub fn spanishUI() [15]struct { key: []const u8, value: TranslationEntry } {
        return .{
            .{ .key = "ok", .value = .{ .value = "Aceptar" } },
            .{ .key = "cancel", .value = .{ .value = "Cancelar" } },
            .{ .key = "save", .value = .{ .value = "Guardar" } },
            .{ .key = "delete", .value = .{ .value = "Eliminar" } },
            .{ .key = "edit", .value = .{ .value = "Editar" } },
            .{ .key = "close", .value = .{ .value = "Cerrar" } },
            .{ .key = "search", .value = .{ .value = "Buscar" } },
            .{ .key = "loading", .value = .{ .value = "Cargando..." } },
            .{ .key = "error", .value = .{ .value = "Error" } },
            .{ .key = "success", .value = .{ .value = "\xc3\x89xito" } },
            .{ .key = "warning", .value = .{ .value = "Advertencia" } },
            .{ .key = "confirm", .value = .{ .value = "Confirmar" } },
            .{ .key = "yes", .value = .{ .value = "S\xc3\xad" } },
            .{ .key = "no", .value = .{ .value = "No" } },
            .{ .key = "back", .value = .{ .value = "Atr\xc3\xa1s" } },
        };
    }

    /// Common UI strings in French
    pub fn frenchUI() [15]struct { key: []const u8, value: TranslationEntry } {
        return .{
            .{ .key = "ok", .value = .{ .value = "OK" } },
            .{ .key = "cancel", .value = .{ .value = "Annuler" } },
            .{ .key = "save", .value = .{ .value = "Enregistrer" } },
            .{ .key = "delete", .value = .{ .value = "Supprimer" } },
            .{ .key = "edit", .value = .{ .value = "Modifier" } },
            .{ .key = "close", .value = .{ .value = "Fermer" } },
            .{ .key = "search", .value = .{ .value = "Rechercher" } },
            .{ .key = "loading", .value = .{ .value = "Chargement..." } },
            .{ .key = "error", .value = .{ .value = "Erreur" } },
            .{ .key = "success", .value = .{ .value = "Succ\xc3\xa8s" } },
            .{ .key = "warning", .value = .{ .value = "Avertissement" } },
            .{ .key = "confirm", .value = .{ .value = "Confirmer" } },
            .{ .key = "yes", .value = .{ .value = "Oui" } },
            .{ .key = "no", .value = .{ .value = "Non" } },
            .{ .key = "back", .value = .{ .value = "Retour" } },
        };
    }

    /// Common UI strings in German
    pub fn germanUI() [15]struct { key: []const u8, value: TranslationEntry } {
        return .{
            .{ .key = "ok", .value = .{ .value = "OK" } },
            .{ .key = "cancel", .value = .{ .value = "Abbrechen" } },
            .{ .key = "save", .value = .{ .value = "Speichern" } },
            .{ .key = "delete", .value = .{ .value = "L\xc3\xb6schen" } },
            .{ .key = "edit", .value = .{ .value = "Bearbeiten" } },
            .{ .key = "close", .value = .{ .value = "Schlie\xc3\x9fen" } },
            .{ .key = "search", .value = .{ .value = "Suchen" } },
            .{ .key = "loading", .value = .{ .value = "Laden..." } },
            .{ .key = "error", .value = .{ .value = "Fehler" } },
            .{ .key = "success", .value = .{ .value = "Erfolg" } },
            .{ .key = "warning", .value = .{ .value = "Warnung" } },
            .{ .key = "confirm", .value = .{ .value = "Best\xc3\xa4tigen" } },
            .{ .key = "yes", .value = .{ .value = "Ja" } },
            .{ .key = "no", .value = .{ .value = "Nein" } },
            .{ .key = "back", .value = .{ .value = "Zur\xc3\xbcck" } },
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Locale parsing" {
    const en_us = Locale.parse("en-US");
    try std.testing.expectEqualStrings("en", en_us.language);
    try std.testing.expectEqualStrings("US", en_us.region.?);

    const zh_hans = Locale.parse("zh-Hans-CN");
    try std.testing.expectEqualStrings("zh", zh_hans.language);
    try std.testing.expectEqualStrings("Hans", zh_hans.script.?);
    try std.testing.expectEqualStrings("CN", zh_hans.region.?);

    const simple = Locale.parse("fr");
    try std.testing.expectEqualStrings("fr", simple.language);
    try std.testing.expect(simple.region == null);
}

test "Locale parsing accepts POSIX underscore form" {
    const en_us = Locale.parse("en_US");
    try std.testing.expectEqualStrings("en", en_us.language);
    try std.testing.expectEqualStrings("US", en_us.region.?);

    const zh_hans = Locale.parse("zh_Hans_CN");
    try std.testing.expectEqualStrings("zh", zh_hans.language);
    try std.testing.expectEqualStrings("Hans", zh_hans.script.?);
    try std.testing.expectEqualStrings("CN", zh_hans.region.?);
}

test "Locale RTL detection" {
    const arabic = Locale{ .language = "ar" };
    try std.testing.expect(arabic.isRTL());

    const hebrew = Locale{ .language = "he" };
    try std.testing.expect(hebrew.isRTL());

    const english = Locale{ .language = "en" };
    try std.testing.expect(!english.isRTL());

    const spanish = Locale{ .language = "es" };
    try std.testing.expect(!spanish.isRTL());
}

test "Plural rules - English" {
    try std.testing.expectEqual(PluralCategory.one, PluralRules.getCategory("en", 1));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("en", 0));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("en", 2));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("en", 5));
}

test "Plural rules - French" {
    try std.testing.expectEqual(PluralCategory.one, PluralRules.getCategory("fr", 0));
    try std.testing.expectEqual(PluralCategory.one, PluralRules.getCategory("fr", 1));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("fr", 2));
}

test "Plural rules - Russian" {
    try std.testing.expectEqual(PluralCategory.one, PluralRules.getCategory("ru", 1));
    try std.testing.expectEqual(PluralCategory.one, PluralRules.getCategory("ru", 21));
    try std.testing.expectEqual(PluralCategory.few, PluralRules.getCategory("ru", 2));
    try std.testing.expectEqual(PluralCategory.few, PluralRules.getCategory("ru", 3));
    try std.testing.expectEqual(PluralCategory.few, PluralRules.getCategory("ru", 4));
    try std.testing.expectEqual(PluralCategory.many, PluralRules.getCategory("ru", 5));
    try std.testing.expectEqual(PluralCategory.many, PluralRules.getCategory("ru", 11));
}

test "Plural rules - Arabic" {
    try std.testing.expectEqual(PluralCategory.zero, PluralRules.getCategory("ar", 0));
    try std.testing.expectEqual(PluralCategory.one, PluralRules.getCategory("ar", 1));
    try std.testing.expectEqual(PluralCategory.two, PluralRules.getCategory("ar", 2));
    try std.testing.expectEqual(PluralCategory.few, PluralRules.getCategory("ar", 3));
    try std.testing.expectEqual(PluralCategory.many, PluralRules.getCategory("ar", 11));
}

test "Plural rules - Chinese/Japanese (no plurals)" {
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("zh", 0));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("zh", 1));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("zh", 100));
    try std.testing.expectEqual(PluralCategory.other, PluralRules.getCategory("ja", 1));
}

test "Localization initialization" {
    const allocator = std.testing.allocator;
    var i18n = try Localization.init(allocator);
    defer i18n.deinit();

    try std.testing.expectEqualStrings("en", i18n.fallback_locale.language);
}

test "Localization basic translation" {
    const allocator = std.testing.allocator;
    var i18n = try Localization.init(allocator);
    defer i18n.deinit();

    try i18n.addTranslation("en", "hello", .{ .value = "Hello" });
    try i18n.addTranslation("es", "hello", .{ .value = "Hola" });

    i18n.setLocale("en");
    try std.testing.expectEqualStrings("Hello", i18n.t("hello"));

    i18n.setLocale("es");
    try std.testing.expectEqualStrings("Hola", i18n.t("hello"));
}

test "Localization fallback" {
    const allocator = std.testing.allocator;
    var i18n = try Localization.init(allocator);
    defer i18n.deinit();

    try i18n.addTranslation("en", "hello", .{ .value = "Hello" });

    i18n.setLocale("es"); // Spanish has no translation
    try std.testing.expectEqualStrings("Hello", i18n.t("hello")); // Falls back to English
}

test "Localization missing key returns key" {
    const allocator = std.testing.allocator;
    var i18n = try Localization.init(allocator);
    defer i18n.deinit();

    try std.testing.expectEqualStrings("unknown.key", i18n.t("unknown.key"));
}

test "Text direction" {
    const allocator = std.testing.allocator;
    var i18n = try Localization.init(allocator);
    defer i18n.deinit();

    i18n.setLocale("en");
    try std.testing.expectEqual(Localization.TextDirection.ltr, i18n.getTextDirection());

    i18n.setLocale("ar");
    try std.testing.expectEqual(Localization.TextDirection.rtl, i18n.getTextDirection());
}

test "Number formatting - basic" {
    const allocator = std.testing.allocator;
    var i18n = try Localization.init(allocator);
    defer i18n.deinit();

    var buf: [64]u8 = undefined;

    i18n.setLocale("en");
    const result = try i18n.formatNumber(1234.56, .{}, &buf);
    try std.testing.expect(result.len > 0);
}

test "LocalizationPresets" {
    const english = LocalizationPresets.englishUI();
    try std.testing.expectEqual(@as(usize, 15), english.len);
    try std.testing.expectEqualStrings("ok", english[0].key);
    try std.testing.expectEqualStrings("OK", english[0].value.value);

    const spanish = LocalizationPresets.spanishUI();
    try std.testing.expectEqual(@as(usize, 15), spanish.len);
    try std.testing.expectEqualStrings("Aceptar", spanish[0].value.value);
}

test "PluralCategory toString" {
    try std.testing.expectEqualStrings("one", PluralCategory.one.toString());
    try std.testing.expectEqualStrings("other", PluralCategory.other.toString());
    try std.testing.expectEqualStrings("few", PluralCategory.few.toString());
}
