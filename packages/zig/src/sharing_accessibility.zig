//! Authorized native sharing indicators for browsers and conferencing apps.
//! Browser web content and conferencing chat/message lists are excluded.
//! All IPC runs on a bounded worker, never on the UI thread.
const std = @import("std");
const builtin = @import("builtin");
const detect = @import("screen_sharing.zig");

pub fn matches(bundle_id: []const u8, title: []const u8) bool {
    if (!std.mem.eql(u8, bundle_id, "com.google.Chrome")) return false;
    const suffix = " - Tab content shared - Google Chrome";
    return title.len >= suffix.len and detect.containsIgnoreCase(title[title.len - suffix.len ..], suffix);
}

/// The caller supplies an autorelease pool and runs off AppKit's main thread.
/// A stalled browser gets a short IPC timeout and cannot stall other UI work.
pub fn visit(context: anytype, comptime onWindow: anytype) !void {
    if (comptime builtin.os.tag != .macos) return;
    if (!AXIsProcessTrusted()) return;
    const macos = @import("macos.zig");
    const io = @import("io_context.zig").get();
    const workspace = macos.msgSend0(macos.getClass("NSWorkspace"), "sharedWorkspace");
    const apps = macos.msgSend0(workspace, "runningApplications");
    const Count = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_ulong;
    const count: Count = @ptrCast(&macos.objc.objc_msgSend);
    const Pid = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_int;
    const pid: Pid = @ptrCast(&macos.objc.objc_msgSend);
    var saw_discord = false;
    defer if (!saw_discord) discord_panel.reset(0);
    var index: c_ulong = 0;
    while (index < count(apps, macos.sel("count"))) : (index += 1) {
        const app = macos.msgSend1(apps, "objectAtIndex:", index);
        const bundle_id = string(macos.msgSend0(app, "bundleIdentifier")) orelse continue;
        const provider = providerFor(bundle_id) orelse continue;
        if (provider == .discord) saw_discord = true;
        // An unrelated browser with many windows must not consume another
        // application's detection budget. Each trusted app gets bounded IPC.
        const deadline = std.Io.Clock.awake.now(io).nanoseconds + 750 * std.time.ns_per_ms;
        const process_id = pid(app, macos.sel("processIdentifier"));
        if (provider == .discord and discord_panel.pid != process_id) discord_panel.reset(process_id);
        const element = AXUIElementCreateApplication(process_id) orelse continue;
        defer CFRelease(element);
        _ = AXUIElementSetMessagingTimeout(element, 0.05);
        if (provider == .discord or provider == .slack) enableElectronAccessibility(element);
        var windows: ?*anyopaque = null;
        const windows_error = AXUIElementCopyAttributeValue(element, macos.createNSString("AXWindows"), &windows);
        if (!attributeAbsentOrSuccess(windows_error)) return error.AccessibilityReadIncomplete;
        if (windows == null) continue;
        defer CFRelease(windows);
        const length = @min(CFArrayGetCount(windows), 128);
        var ordered: [128]?*anyopaque = undefined;
        var window_index: c_long = 0;
        while (window_index < length) : (window_index += 1)
            ordered[@intCast(window_index)] = CFArrayGetValueAtIndex(windows, window_index);
        // Electron can put auxiliary windows ahead of its actual application
        // surface. Inspect the main window before spending its bounded IPC
        // budget on those windows.
        if (provider == .discord) {
            if (copyAttribute(element, "AXMainWindow")) |main_window| {
                defer CFRelease(main_window);
                window_index = 0;
                while (window_index < length) : (window_index += 1) {
                    if (CFEqual(ordered[@intCast(window_index)], main_window)) {
                        std.mem.swap(?*anyopaque, &ordered[0], &ordered[@intCast(window_index)]);
                        break;
                    }
                }
            }
        }
        // Slack's floating capture toolbar is much cheaper to inspect than
        // its full workspace. Read that live surface before huddle windows.
        var floating_slack = false;
        if (provider == .slack) {
            window_index = 0;
            while (window_index < length and std.Io.Clock.awake.now(io).nanoseconds < deadline) : (window_index += 1) {
                const window = ordered[@intCast(window_index)] orelse continue;
                _ = AXUIElementSetMessagingTimeout(window, 0.05);
                const title = copyAttribute(window, "AXTitle") orelse continue;
                defer CFRelease(title);
                if (!std.mem.eql(u8, string(title) orelse continue, "Slack")) continue;
                std.mem.swap(?*anyopaque, &ordered[0], &ordered[@intCast(window_index)]);
                floating_slack = true;
                break;
            }
        }
        window_index = 0;
        while (window_index < length) : (window_index += 1) {
            if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.AccessibilityReadIncomplete;
            const window = ordered[@intCast(window_index)] orelse continue;
            _ = AXUIElementSetMessagingTimeout(window, 0.05);
            if (provider == .dia) {
                var reader = NativeBannerReader{ .deadline = deadline };
                if (reader.containsBanner(window, 0, .dia)) {
                    try onWindow(context, "Dia", "Browser tab sharing");
                    break;
                }
                try reader.requireComplete();
                continue;
            }
            if (provider == .chrome) {
                var reader = NativeBannerReader{ .deadline = deadline };
                if (reader.containsBanner(window, 0, .chrome)) {
                    try onWindow(context, "Google Chrome", "Browser tab sharing");
                    break;
                }
                try reader.requireComplete();
            }
            if (provider == .discord or provider == .slack) {
                var reader = NativeBannerReader{ .deadline = deadline, .remaining = 512 };
                if (reader.containsConferenceControl(window, provider, floating_slack and window_index == 0)) {
                    try onWindow(context, if (provider == .discord) "Discord" else "Slack", "Screen sharing controls");
                    break;
                }
                if (provider == .discord and !reader.scope_seen) reader.incomplete = true;
                try reader.requireComplete();
                if (provider == .discord and reader.scope_seen) break;
                continue;
            }
            var title: ?*anyopaque = null;
            if (AXUIElementCopyAttributeValue(window, macos.createNSString("AXTitle"), &title) != 0 or title == null) continue;
            defer CFRelease(title);
            const text = string(title) orelse continue;
            if (matches(bundle_id, text)) {
                try onWindow(context, "Google Chrome", text);
                break;
            }
        }
    }
}

/// Both controls must belong to the same native surface. A page can contain
/// identical words, so AXWebArea descendants are excluded before traversal.
const Banner = struct {
    sharing: bool = false,
    stop: bool = false,
    other_tab: bool = false,
    switch_tab: bool = false,

    fn observe(self: *Banner, role: []const u8, label: []const u8) void {
        if (std.mem.eql(u8, role, "AXStaticText") and std.mem.eql(u8, label, "Sharing this tab")) self.sharing = true;
        if (std.mem.eql(u8, role, "AXButton") and std.mem.eql(u8, label, "Stop Sharing")) self.stop = true;
        if (std.mem.eql(u8, role, "AXStaticText") and std.mem.startsWith(u8, label, "Sharing ") and
            !std.mem.eql(u8, label, "Sharing this tab") and std.mem.indexOf(u8, label, " — ") != null) self.other_tab = true;
        if (std.mem.eql(u8, role, "AXButton") and std.mem.eql(u8, label, "Share This Tab")) self.switch_tab = true;
    }

    fn active(self: Banner) bool {
        return (self.sharing and self.stop) or (self.other_tab and self.switch_tab);
    }

    fn observeChrome(self: *Banner, role: []const u8, label: []const u8) void {
        // Chrome exposes this browser-owned infobar as a labelled group.
        // Its wording changes when the captured tab is in the background.
        if (std.mem.eql(u8, role, "AXGroup") and
            ((std.mem.startsWith(u8, label, "Sharing this tab to ") and label.len > "Sharing this tab to ".len) or
                (std.mem.startsWith(u8, label, "Sharing ") and std.mem.endsWith(u8, label, " to this tab") and label.len > "Sharing  to this tab".len))) self.sharing = true;
        if (std.mem.eql(u8, role, "AXButton") and std.mem.eql(u8, label, "Stop sharing")) self.stop = true;
    }
};

/// Slack's compact huddle moves capture controls into a separate app-owned
/// "Slack" window. Require both controls in its toolbar, never chat labels.
const SlackShareControls = struct {
    stop: bool = false,
    draw: bool = false,

    fn observe(self: *SlackShareControls, role: []const u8, label: []const u8) void {
        if (std.mem.eql(u8, role, "AXButton") and std.mem.eql(u8, label, "Stop sharing your screen")) self.stop = true;
        if (std.mem.eql(u8, role, "AXCheckBox") and std.mem.eql(u8, label, "Draw on your own screen")) self.draw = true;
    }

    fn active(self: SlackShareControls) bool {
        return self.stop and self.draw;
    }
};

/// Only used inside Discord's positively identified status panel. Its share
/// toggle and adjacent app-owned label provide explicit active/idle evidence,
/// including while the stream preview is being rebuilt.
const DiscordControls = struct {
    preceding_toggle: ?bool = null,
    sharing: ?bool = null,

    fn control(self: *DiscordControls, value: ?bool) void {
        self.preceding_toggle = value;
    }

    fn text(self: *DiscordControls, share_label: bool) void {
        if (share_label) self.sharing = self.preceding_toggle;
        self.preceding_toggle = null;
    }
};

const NativeBannerReader = struct {
    deadline: i96,
    remaining: usize = 256,
    incomplete: bool = false,
    scope_seen: bool = false,
    discord_controls: DiscordControls = .{},

    fn requireComplete(self: *NativeBannerReader) !void {
        if (self.incomplete) {
            return error.AccessibilityReadIncomplete;
        }
    }

    fn readAttribute(self: *NativeBannerReader, element: ?*anyopaque, name: [:0]const u8) ?*anyopaque {
        var value: ?*anyopaque = null;
        const result = AXUIElementCopyAttributeValue(element, @import("macos.zig").createNSString(name), &value);
        if (result != 0) {
            if (!attributeAbsentOrSuccess(result)) {
                self.incomplete = true;
            }
            return null;
        }
        return value;
    }

    const Attributes = struct {
        values: *anyopaque,

        fn deinit(self: Attributes) void {
            CFRelease(self.values);
        }

        fn value(self: Attributes, index: c_long) ?*anyopaque {
            const item = CFArrayGetValueAtIndex(self.values, index) orelse return null;
            if (CFGetTypeID(item) == AXValueGetTypeID() or CFGetTypeID(item) == CFNullGetTypeID()) return null;
            return item;
        }

        fn labelled(self: Attributes, label: []const u8) bool {
            for (0..3) |index| {
                if (std.mem.eql(u8, string(self.value(@intCast(index))) orelse continue, label)) return true;
            }
            return false;
        }
    };

    fn attributes(self: *NativeBannerReader, element: ?*anyopaque) ?Attributes {
        const macos = @import("macos.zig");
        const names = [_]?*anyopaque{
            macos.createNSString("AXTitle"), macos.createNSString("AXDescription"),
            macos.createNSString("AXValue"), macos.createNSString("AXChildren"),
        };
        const attributes_array = CFArrayCreate(null, &names, names.len, null) orelse {
            self.incomplete = true;
            return null;
        };
        defer CFRelease(attributes_array);
        var values: ?*anyopaque = null;
        if (AXUIElementCopyMultipleAttributeValues(element, attributes_array, 0, &values) != 0 or values == null) {
            self.incomplete = true;
            return null;
        }
        const result = Attributes{ .values = values.? };
        if (CFGetTypeID(values) != CFArrayGetTypeID() or CFArrayGetCount(values) != names.len) {
            result.deinit();
            self.incomplete = true;
            return null;
        }
        for (0..names.len) |index| {
            const value = CFArrayGetValueAtIndex(values, @intCast(index)) orelse continue;
            if (CFGetTypeID(value) == AXValueGetTypeID() and AXValueGetType(value) == 5) {
                var code: c_int = 0;
                if (!AXValueGetValue(value, 5, &code) or !attributeAbsentOrSuccess(code)) self.incomplete = true;
            }
        }
        return result;
    }

    fn labelled(self: *NativeBannerReader, element: ?*anyopaque, label: []const u8) bool {
        const values = self.attributes(element) orelse return false;
        defer values.deinit();
        return values.labelled(label);
    }

    fn exhausted(self: *NativeBannerReader, depth: usize, maximum: usize) bool {
        return self.beyondLimits(depth, maximum) or self.expired();
    }

    fn beyondLimits(self: *NativeBannerReader, depth: usize, maximum: usize) bool {
        if (depth > maximum or self.remaining == 0) {
            self.incomplete = true;
            return true;
        }
        return false;
    }

    fn containsBanner(self: *NativeBannerReader, element: ?*anyopaque, depth: usize, provider: Provider) bool {
        // Chrome adds native window/content wrappers above its infobars.
        // Keep the same node and IPC budgets, while allowing those wrappers.
        if (self.exhausted(depth, if (provider == .chrome) 12 else 6)) return false;
        self.remaining -= 1;
        _ = AXUIElementSetMessagingTimeout(element, 0.05);
        const role = self.readAttribute(element, "AXRole") orelse return false;
        defer CFRelease(role);
        if (!nativeContainer(string(role) orelse return false)) return false;
        const children = self.readAttribute(element, "AXChildren") orelse return false;
        defer CFRelease(children);
        if (CFGetTypeID(children) != CFArrayGetTypeID()) return false;
        const length = @min(CFArrayGetCount(children), 128);
        if (CFArrayGetCount(children) > 128) self.incomplete = true;
        var banner = Banner{};
        var index: c_long = 0;
        while (index < length and self.remaining > 0 and !self.expired()) : (index += 1) {
            const child = CFArrayGetValueAtIndex(children, index) orelse continue;
            self.remaining -= 1;
            _ = AXUIElementSetMessagingTimeout(child, 0.05);
            const child_role = self.readAttribute(child, "AXRole") orelse continue;
            defer CFRelease(child_role);
            const role_text = string(child_role) orelse continue;
            // Do not read labels from web content, including its root.
            if (!std.mem.eql(u8, role_text, "AXStaticText") and !std.mem.eql(u8, role_text, "AXButton") and
                !(provider == .chrome and std.mem.eql(u8, role_text, "AXGroup"))) continue;
            for ([_][:0]const u8{ "AXTitle", "AXDescription", "AXValue" }) |attribute| {
                if (self.expired()) return false;
                const label = self.readAttribute(child, attribute) orelse continue;
                defer CFRelease(label);
                const label_text = string(label) orelse continue;
                if (provider == .chrome) banner.observeChrome(role_text, label_text) else banner.observe(role_text, label_text);
            }
            if (banner.active()) return true;
        }
        index = 0;
        while (index < length and !self.expired()) : (index += 1) {
            if (self.containsBanner(CFArrayGetValueAtIndex(children, index), depth + 1, provider)) return true;
        }
        return false;
    }

    /// Find the shallow app-owned control panel before walking deeper UI.
    /// A depth-first walk can exhaust the IPC budget in navigation wrappers
    /// before reaching a sibling status panel, producing false stop events.
    fn containsConferenceControl(self: *NativeBannerReader, element: ?*anyopaque, provider: Provider, floating_slack: bool) bool {
        // Retain only the public AX element identifying the app-owned panel,
        // never its sharing state. Every call reads the live panel again.
        // This avoids rescanning unrelated navigation on each watcher tick.
        if (provider == .discord) {
            if (discord_panel.element) |panel| {
                const role_value = self.readAttribute(panel, "AXRole");
                defer if (role_value) |value| CFRelease(value);
                if (role_value != null and std.mem.eql(u8, string(role_value) orelse "", "AXGroup") and self.labelled(panel, "User status and settings")) {
                    self.scope_seen = true;
                    return self.containsPanelControl(panel, 0, provider);
                }
                discord_panel.reset(discord_panel.pid);
                // Discard an invalid handle, then make a fresh bounded walk.
                // That walk must independently establish active or idle state.
                self.incomplete = false;
            }
        }
        const Node = struct { element: *anyopaque, depth: u8 };
        var queue: [512]Node = undefined;
        var count: usize = 1;
        var cursor: usize = 0;
        const root = element orelse return false;
        _ = CFRetain(root);
        queue[0] = .{ .element = root, .depth = 0 };
        defer for (queue[0..count]) |node| CFRelease(node.element);

        while (cursor < count and self.remaining > 0 and !self.expired()) : (cursor += 1) {
            const node = queue[cursor];
            self.remaining -= 1;
            _ = AXUIElementSetMessagingTimeout(node.element, 0.05);
            const role_value = self.readAttribute(node.element, "AXRole") orelse continue;
            defer CFRelease(role_value);
            const role = string(role_value) orelse continue;
            if (!conferenceContainer(role)) continue;
            if (floating_slack and std.mem.eql(u8, role, "AXToolbar")) {
                var controls = SlackShareControls{};
                if (self.containsSlackShareControls(node.element, 0, &controls)) return true;
            }
            const values = self.attributes(node.element) orelse continue;
            defer values.deinit();
            const scope_role = if (provider == .discord) "AXGroup" else "AXToolbar";
            const scope_label = if (provider == .discord) "User status and settings" else "Huddles actions";
            if (std.mem.eql(u8, role, scope_role) and values.labelled(scope_label)) {
                self.scope_seen = true;
                if (provider == .discord) discord_panel.retain(node.element);
                return self.containsPanelControl(node.element, 0, provider);
            }
            if (node.depth >= 24) {
                self.incomplete = true;
                continue;
            }
            const children = values.value(3) orelse continue;
            if (CFGetTypeID(children) != CFArrayGetTypeID()) continue;
            const child_count = @min(CFArrayGetCount(children), 128);
            if (CFArrayGetCount(children) > 128) self.incomplete = true;
            var child_index: c_long = 0;
            while (child_index < child_count and count < queue.len) : (child_index += 1) {
                const child = CFArrayGetValueAtIndex(children, child_index) orelse continue;
                _ = CFRetain(child);
                queue[count] = .{ .element = child, .depth = node.depth + 1 };
                count += 1;
            }
            if (child_index < child_count) self.incomplete = true;
        }
        if (cursor < count) self.incomplete = true;
        return false;
    }

    /// Only descend inside a positively identified application control panel.
    /// Message lists, outlines, editors and arbitrary button labels stay out.
    fn containsPanelControl(self: *NativeBannerReader, element: ?*anyopaque, depth: usize, provider: Provider) bool {
        if (self.exhausted(depth, 24)) return false;
        self.remaining -= 1;
        _ = AXUIElementSetMessagingTimeout(element, 0.05);
        const role_value = self.readAttribute(element, "AXRole") orelse return false;
        defer CFRelease(role_value);
        const role = string(role_value) orelse return false;
        const control = std.mem.eql(u8, role, "AXButton") or std.mem.eql(u8, role, "AXCheckBox");
        if (control) {
            const values = self.attributes(element) orelse return false;
            defer values.deinit();
            if (provider == .discord) self.discord_controls.control(toggleValue(values.value(2)));
            return values.labelled(if (provider == .discord) "Stop Streaming" else "Stop sharing screen");
        }
        if (provider == .discord and std.mem.eql(u8, role, "AXStaticText")) {
            self.discord_controls.text(self.labelled(element, "Share Your Screen"));
            return self.discord_controls.sharing == true;
        }
        // Electron exposes its application UI as AXWebArea. Lists, outlines,
        // message text, editors and arbitrary buttons are not traversed.
        if (!conferenceContainer(role)) return false;
        const children = self.readAttribute(element, "AXChildren") orelse {
            if (depth == 0) self.incomplete = true;
            return false;
        };
        defer CFRelease(children);
        if (CFGetTypeID(children) != CFArrayGetTypeID()) return false;
        const length = @min(CFArrayGetCount(children), 128);
        if (depth == 0 and length == 0) self.incomplete = true;
        if (CFArrayGetCount(children) > 128) self.incomplete = true;
        var index: c_long = 0;
        while (index < length and !self.expired()) : (index += 1) {
            if (self.containsPanelControl(CFArrayGetValueAtIndex(children, index), depth + 1, provider)) return true;
        }
        return false;
    }

    fn containsSlackShareControls(self: *NativeBannerReader, element: ?*anyopaque, depth: usize, controls: *SlackShareControls) bool {
        if (self.exhausted(depth, 4)) return false;
        const children = self.readAttribute(element, "AXChildren") orelse return false;
        defer CFRelease(children);
        if (CFGetTypeID(children) != CFArrayGetTypeID()) return false;
        const length = @min(CFArrayGetCount(children), 128);
        if (CFArrayGetCount(children) > 128) self.incomplete = true;
        var index: c_long = 0;
        while (index < length and self.remaining > 0 and !self.expired()) : (index += 1) {
            self.remaining -= 1;
            const child = CFArrayGetValueAtIndex(children, index) orelse continue;
            _ = AXUIElementSetMessagingTimeout(child, 0.05);
            const role_value = self.readAttribute(child, "AXRole") orelse continue;
            defer CFRelease(role_value);
            const role = string(role_value) orelse continue;
            // Electron wraps individual toolbar controls in presentation
            // groups. Stay inside this toolbar; lists, editors, nested web
            // areas and other toolbars cannot contribute matching labels.
            if (std.mem.eql(u8, role, "AXGroup")) {
                if (self.containsSlackShareControls(child, depth + 1, controls)) return true;
                continue;
            }
            if (!std.mem.eql(u8, role, "AXButton") and !std.mem.eql(u8, role, "AXCheckBox")) continue;
            for ([_][:0]const u8{ "AXTitle", "AXDescription", "AXValue" }) |attribute| {
                if (self.expired()) return false;
                const label = self.readAttribute(child, attribute) orelse continue;
                defer CFRelease(label);
                controls.observe(role, string(label) orelse continue);
            }
            if (controls.active()) return true;
        }
        return false;
    }

    fn expired(self: *NativeBannerReader) bool {
        if (std.Io.Clock.awake.now(@import("io_context.zig").get()).nanoseconds >= self.deadline) {
            self.incomplete = true;
            return true;
        }
        return false;
    }
};

fn toggleValue(value: ?*anyopaque) ?bool {
    if (value == null) return null;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue(value);
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        var number: i64 = 0;
        if (CFNumberGetValue(value, 4, &number)) {
            if (number == 0) return false;
            if (number == 1) return true;
        }
    }
    if (string(value)) |text| {
        if (std.mem.eql(u8, text, "0")) return false;
        if (std.mem.eql(u8, text, "1")) return true;
    }
    return null;
}

fn nativeContainer(role: []const u8) bool {
    return std.mem.eql(u8, role, "AXWindow") or std.mem.eql(u8, role, "AXGroup") or
        std.mem.eql(u8, role, "AXScrollArea") or std.mem.eql(u8, role, "AXSplitGroup");
}

// Access is serialized by the screen-sharing bridge's evaluation mutex.
const PanelReference = struct {
    pid: c_int = 0,
    element: ?*anyopaque = null,

    fn reset(self: *PanelReference, process_id: c_int) void {
        if (self.element) |value| CFRelease(value);
        self.* = .{ .pid = process_id };
    }

    fn retain(self: *PanelReference, element: *anyopaque) void {
        self.reset(self.pid);
        self.element = CFRetain(element);
    }
};
var discord_panel: PanelReference = .{};

const Provider = enum { chrome, dia, discord, slack };

fn providerFor(bundle_id: []const u8) ?Provider {
    if (std.mem.eql(u8, bundle_id, "com.google.Chrome")) return .chrome;
    if (std.mem.eql(u8, bundle_id, "company.thebrowser.dia")) return .dia;
    if (std.mem.eql(u8, bundle_id, "com.hnc.Discord")) return .discord;
    if (std.mem.eql(u8, bundle_id, "com.tinyspeck.slackmacgap")) return .slack;
    return null;
}

fn conferenceContainer(role: []const u8) bool {
    return nativeContainer(role) or std.mem.eql(u8, role, "AXWebArea") or std.mem.eql(u8, role, "AXToolbar");
}

// Unsupported optional attributes and missing values are valid absence.
// Busy, stale, denied and failed IPC are not evidence that sharing stopped.
fn attributeAbsentOrSuccess(result: c_int) bool {
    return result == 0 or result == -25205 or result == -25212;
}

fn enableElectronAccessibility(element: ?*anyopaque) void {
    // Electron's documented third-party accessibility interface, not a
    // command-line switch or injected renderer script:
    // https://www.electronjs.org/docs/latest/tutorial/accessibility
    if (copyAttribute(element, "AXManualAccessibility")) |enabled| {
        defer CFRelease(enabled);
        if (CFGetTypeID(enabled) == CFBooleanGetTypeID() and CFBooleanGetValue(enabled)) return;
    }
    _ = AXUIElementSetAttributeValue(element, @import("macos.zig").createNSString("AXManualAccessibility"), kCFBooleanTrue);
}

fn copyAttribute(element: ?*anyopaque, name: [:0]const u8) ?*anyopaque {
    var value: ?*anyopaque = null;
    if (AXUIElementCopyAttributeValue(element, @import("macos.zig").createNSString(name), &value) != 0) return null;
    return value;
}

fn string(value: ?*anyopaque) ?[]const u8 {
    if (value == null or CFGetTypeID(value) != CFStringGetTypeID()) return null;
    const macos = @import("macos.zig");
    const utf8 = macos.msgSend0(value, "UTF8String");
    if (utf8 == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
}

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn AXUIElementCreateApplication(pid: c_int) ?*anyopaque;
extern "c" fn AXUIElementSetMessagingTimeout(element: ?*anyopaque, timeout: f32) c_int;
extern "c" fn AXUIElementCopyMultipleAttributeValues(element: ?*anyopaque, attributes: ?*anyopaque, options: u32, values: *?*anyopaque) c_int;
extern "c" fn CFArrayCreate(allocator: ?*anyopaque, values: [*]const ?*anyopaque, count: c_long, callbacks: ?*const anyopaque) ?*anyopaque;
extern "c" fn AXValueGetTypeID() c_ulong;
extern "c" fn CFNullGetTypeID() c_ulong;
extern "c" fn AXValueGetType(value: ?*anyopaque) c_int;
extern "c" fn AXValueGetValue(value: ?*anyopaque, kind: c_int, output: *c_int) bool;
extern "c" fn AXUIElementCopyAttributeValue(element: ?*anyopaque, attribute: ?*anyopaque, value: *?*anyopaque) c_int;
extern "c" fn AXUIElementSetAttributeValue(element: ?*anyopaque, attribute: ?*anyopaque, value: ?*anyopaque) c_int;
extern "c" var kCFBooleanTrue: ?*anyopaque;
extern "c" fn CFNumberGetTypeID() c_ulong;
extern "c" fn CFNumberGetValue(value: ?*anyopaque, kind: c_int, output: *i64) bool;
extern "c" fn CFBooleanGetTypeID() c_ulong;
extern "c" fn CFBooleanGetValue(value: ?*anyopaque) bool;
extern "c" fn CFArrayGetCount(array: ?*anyopaque) c_long;
extern "c" fn CFArrayGetValueAtIndex(array: ?*anyopaque, index: c_long) ?*anyopaque;
extern "c" fn CFGetTypeID(value: ?*anyopaque) c_ulong;
extern "c" fn CFStringGetTypeID() c_ulong;
extern "c" fn CFArrayGetTypeID() c_ulong;
extern "c" fn CFRelease(value: ?*anyopaque) void;
extern "c" fn CFRetain(value: ?*anyopaque) ?*anyopaque;
extern "c" fn CFEqual(first: ?*anyopaque, second: ?*anyopaque) bool;

test "tab capture requires Chrome's native sharing suffix" {
    try std.testing.expect(matches("com.google.Chrome", "Hush capture check - Tab content shared - Google Chrome"));
    try std.testing.expect(!matches("com.google.Chrome", "Tab content shared - Google Chrome"));
    try std.testing.expect(!matches("com.google.Chrome", "Hush capture check - Google Chrome"));
    try std.testing.expect(!matches("com.apple.TextEdit", "Hush capture check - Tab content shared - Google Chrome"));
    try std.testing.expect(!matches("com.google.Chrome", "Hush capture check - Tab content shared - Google Chrome Notes"));
}

test "Dia requires both native controls on one surface" {
    var banner = Banner{};
    banner.observe("AXStaticText", "Sharing this tab");
    try std.testing.expect(!banner.active());
    banner.observe("AXButton", "Stop Sharing");
    try std.testing.expect(banner.active());
    var wrong_roles = Banner{};
    wrong_roles.observe("AXButton", "Sharing this tab");
    wrong_roles.observe("AXStaticText", "Stop Sharing");
    try std.testing.expect(!wrong_roles.active());
    var wrong_labels = Banner{};
    wrong_labels.observe("AXStaticText", "Sharing this tab soon");
    wrong_labels.observe("AXButton", "Stop Sharing");
    try std.testing.expect(!wrong_labels.active());
    try std.testing.expect(nativeContainer("AXWindow"));
    try std.testing.expect(nativeContainer("AXGroup"));
    try std.testing.expect(!nativeContainer("AXWebArea"));
    try std.testing.expect(!nativeContainer("AXStaticText"));
}

test "Dia keeps detecting capture when another tab is selected" {
    var banner = Banner{};
    banner.observe("AXStaticText", "Sharing Hush capture check — 127.0.0.1");
    try std.testing.expect(!banner.active());
    banner.observe("AXButton", "Share This Tab");
    try std.testing.expect(banner.active());
    var mixed = Banner{};
    mixed.observe("AXStaticText", "Sharing this tab");
    mixed.observe("AXButton", "Share This Tab");
    try std.testing.expect(!mixed.active());
}

test "Chrome sharing banner survives selection of the receiving Meet tab" {
    var background = Banner{};
    background.observeChrome("AXGroup", "Sharing 127.0.0.1:60577 to this tab");
    try std.testing.expect(!background.active());
    background.observeChrome("AXButton", "Stop sharing");
    try std.testing.expect(background.active());

    var foreground = Banner{};
    foreground.observeChrome("AXGroup", "Sharing this tab to http://127.0.0.1:60577");
    foreground.observeChrome("AXButton", "Stop sharing");
    try std.testing.expect(foreground.active());

    var page = Banner{};
    page.observeChrome("AXStaticText", "Sharing 127.0.0.1:60577 to this tab");
    page.observeChrome("AXButton", "Stop sharing");
    try std.testing.expect(!page.active());
    try std.testing.expect(!nativeContainer("AXWebArea"));

    var idle = Banner{};
    idle.observeChrome("AXGroup", "Sharing  to this tab");
    idle.observeChrome("AXButton", "Stop sharing");
    try std.testing.expect(!idle.active());
}

test "only trusted app identities can expose conferencing renderer controls" {
    try std.testing.expectEqual(Provider.discord, providerFor("com.hnc.Discord").?);
    try std.testing.expectEqual(Provider.slack, providerFor("com.tinyspeck.slackmacgap").?);
    try std.testing.expect(providerFor("com.example.Discord") == null);
    try std.testing.expect(providerFor("com.google.Chrome.beta") == null);
    try std.testing.expect(conferenceContainer("AXWebArea"));
    try std.testing.expect(!conferenceContainer("AXList"));
    try std.testing.expect(!conferenceContainer("AXOutline"));
    try std.testing.expect(!conferenceContainer("AXTextArea"));
    try std.testing.expect(!conferenceContainer("AXStaticText"));
    try std.testing.expect(!conferenceContainer("AXButton"));
}

test "Slack floating capture toolbar requires its stop and drawing controls" {
    var controls = SlackShareControls{};
    controls.observe("AXButton", "Stop sharing your screen");
    try std.testing.expect(!controls.active());
    controls.observe("AXCheckBox", "Draw on your own screen");
    try std.testing.expect(controls.active());

    var chat = SlackShareControls{};
    chat.observe("AXStaticText", "Stop sharing your screen");
    chat.observe("AXStaticText", "Draw on your own screen");
    try std.testing.expect(!chat.active());

    var idle = SlackShareControls{};
    idle.observe("AXButton", "Share your screen");
    idle.observe("AXButton", "Draw on your own screen");
    try std.testing.expect(!idle.active());

    var wrong_stop = SlackShareControls{};
    wrong_stop.observe("AXCheckBox", "Stop sharing your screen");
    wrong_stop.observe("AXSwitch", "Draw on your own screen");
    try std.testing.expect(!wrong_stop.active());

    var wrong_draw = SlackShareControls{};
    wrong_draw.observe("AXButton", "Stop sharing your screen");
    wrong_draw.observe("AXButton", "Draw on your own screen");
    try std.testing.expect(!wrong_draw.active());
}

test "incomplete Accessibility reads cannot become sharing stop evidence" {
    try std.testing.expect(attributeAbsentOrSuccess(0));
    try std.testing.expect(attributeAbsentOrSuccess(-25205));
    try std.testing.expect(attributeAbsentOrSuccess(-25212));
    for ([_]c_int{ -25200, -25202, -25204, -25208, -25211 }) |result|
        try std.testing.expect(!attributeAbsentOrSuccess(result));
    var exhausted = NativeBannerReader{ .deadline = 0, .remaining = 0 };
    try std.testing.expect(exhausted.beyondLimits(0, 24));
    try std.testing.expectError(error.AccessibilityReadIncomplete, exhausted.requireComplete());
    var too_deep = NativeBannerReader{ .deadline = 0 };
    try std.testing.expect(too_deep.beyondLimits(25, 24));
    try std.testing.expectError(error.AccessibilityReadIncomplete, too_deep.requireComplete());
    var complete = NativeBannerReader{ .deadline = 0 };
    try complete.requireComplete();
}

test "Discord share labels cannot reuse an unrelated native toggle" {
    var controls = DiscordControls{};
    try std.testing.expect(controls.sharing == null);
    controls.control(false);
    controls.text(false); // Camera or mute is not screen-sharing evidence.
    controls.text(true);
    try std.testing.expect(controls.sharing == null);
    controls.control(true);
    controls.text(true);
    try std.testing.expect(controls.sharing == true);
    controls.control(false);
    controls.text(true);
    try std.testing.expect(controls.sharing == false);
    controls.control(null);
    controls.text(true);
    try std.testing.expect(controls.sharing == null);
}
