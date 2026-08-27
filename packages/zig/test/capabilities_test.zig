//! The conformance test: does what craft *declares* match what it *dispatches*?
//!
//! This is the point of issue #49. Three bugs shipped where the JS bridge
//! declared a surface, native silently did not serve it, and the app found out
//! in production — and none of them were catchable, because nothing compared
//! the two halves. Every check here exists to make one specific way of drifting
//! fail the build.
//!
//! The checks are deliberately in both directions. Only comparing declarations
//! against dispatch catches a deleted arm; only the reverse catches an arm that
//! was added and never declared, which is the drift that actually happens.

const std = @import("std");
const testing = std.testing;

const registry_mod = @import("capability_registry");
const capabilities = registry_mod.capabilities;
const registry = registry_mod.registry;

/// The bridges that have opted in, with the source the literal-ban is checked
/// against. Adding a row here — plus the matching `addAnonymousImport` in
/// build.zig — is what "declaring a namespace" means.
///
/// Embedded rather than read from disk: the test is then hermetic, independent
/// of the working directory, and looking at exactly the bytes the compiler saw.
const declared_sources = [_]struct {
    namespace: []const u8,
    path: []const u8,
    /// The dispatch chain, which the literal ban and the dispatched-on check read.
    source: []const u8,
    /// Where the `pub const name = "action";` declarations live, when they are
    /// not in the same file as the chain. Defaults to `source`.
    names: ?[]const u8 = null,
}{
    .{ .namespace = "clipboard", .path = "src/bridge_clipboard.zig", .source = @embedFile("src/bridge_clipboard.zig") },
    .{ .namespace = "tray", .path = "src/bridge_tray.zig", .source = @embedFile("src/bridge_tray.zig") },
    .{ .namespace = "app", .path = "src/bridge_app.zig", .source = @embedFile("src/bridge_app.zig") },
    .{ .namespace = "screen", .path = "src/bridge_screen.zig", .source = @embedFile("src/bridge_screen.zig") },
    .{
        .namespace = "capabilities",
        .path = "src/bridge_capabilities.zig",
        .source = @embedFile("src/bridge_capabilities.zig"),
        // Its action names live in a separate file so the JS-contract test can
        // reference them without importing the registry — which reaches every
        // declared bridge and, through them, the whole native graph.
        .names = @embedFile("src/bridge_capabilities_actions.zig"),
    },
};

const dispatcher_source = @embedFile("src/macos.zig");

/// How many namespaces may still answer `undeclared`.
///
/// A ratchet, not a target. It exists so `undeclared` cannot quietly become
/// where surfaces go to avoid being audited — the number may only ever be
/// lowered, and lowering it is what "declaring a namespace" costs.
const max_undeclared: usize = 45;

/// The injected bridge script, so the channel list can be checked against the
/// events the page actually subscribes to.
const bridge_js = @embedFile("src/js/craft-bridge.js");

test "every event the page subscribes to is a declared channel" {
    // The check that was missing. `Channel` shipped with 22 entries and a doc
    // comment claiming it listed every `craft:*` the JS surface subscribes to;
    // there were 44. A manifest that omits a channel answers nothing about it,
    // which is the same overclaiming this mechanism exists to stop — so the
    // claim is now enforced rather than asserted.
    var search: usize = 0;
    var checked: usize = 0;
    while (std.mem.indexOfPos(u8, bridge_js, search, "_evt('craft:")) |at| {
        const name_start = at + "_evt('".len;
        const name_end = std.mem.indexOfScalarPos(u8, bridge_js, name_start, '\'') orelse break;
        const name = bridge_js[name_start..name_end];
        search = name_end;

        var known = false;
        for (std.enums.values(capabilities.Channel)) |ch| {
            if (std.mem.eql(u8, ch.eventName(), name)) known = true;
        }
        if (!known) {
            std.debug.print(
                "craft-bridge.js subscribes to '{s}' but it is not in the Channel enum,\n" ++
                    "  so craft.capabilities() says nothing about it at all.\n",
                .{name},
            );
            return error.SubscribedChannelNotDeclared;
        }
        checked += 1;
    }
    // A regex that silently matched nothing would make this test vacuous.
    try testing.expect(checked >= 40);
}

test "no channel is reported as definitely dead" {
    // `false` was never knowledge — it only ever meant "no emitter has
    // registered", and a page reasonably read it as "this will never fire".
    // Absence of proof is reported as `unknown` now, and there is deliberately
    // no third value to regress to.
    try testing.expectEqualStrings("live", capabilities.Liveness.live.text());
    try testing.expectEqualStrings("unknown", capabilities.Liveness.unknown.text());
    try testing.expectEqual(@as(usize, 2), std.enums.values(capabilities.Liveness).len);
}

test "nothing is marked declared without being enforced" {
    // Closes the obvious loophole: marking a namespace `.declared` in the
    // registry buys the app's trust, and it must cost a `declared_sources` row,
    // which is what subjects the bridge to the three checks below.
    for (registry) |ns| {
        if (ns.status != .declared) continue;
        var enforced = false;
        for (declared_sources) |declared| {
            if (std.mem.eql(u8, declared.namespace, ns.name)) enforced = true;
        }
        if (!enforced) {
            std.debug.print(
                "namespace '{s}' is marked declared but has no entry in declared_sources,\n" ++
                    "  so nothing checks its table against its dispatch chain.\n",
                .{ns.name},
            );
            return error.DeclaredNamespaceNotEnforced;
        }
    }
}

test "every declared namespace is in the registry, and declared" {
    for (declared_sources) |declared| {
        var found = false;
        for (registry) |ns| {
            if (!std.mem.eql(u8, ns.name, declared.namespace)) continue;
            found = true;
            try testing.expectEqual(capabilities.NamespaceStatus.declared, ns.status);
            // A declared namespace with no actions would report as "this
            // namespace serves nothing", which is a different and wrong claim.
            try testing.expect(ns.actions.len > 0);
        }
        if (!found) {
            std.debug.print("namespace '{s}' has a source entry but no registry row\n", .{declared.namespace});
            return error.NamespaceMissingFromRegistry;
        }
    }
}

test "a declared bridge compares against no action literals" {
    // The check that makes the other two airtight. With literals banned, a new
    // `else if (std.mem.eql(u8, action, "newThing"))` will not compile past
    // review without a matching table entry, because there is nowhere else to
    // put the name.
    for (declared_sources) |declared| {
        const source = declared.source;

        if (std.mem.indexOf(u8, source, "std.mem.eql(u8, action, \"")) |offset| {
            const line = std.mem.count(u8, source[0..offset], "\n") + 1;
            std.debug.print(
                "{s}:{d}: a declared bridge compares `action` against a string literal.\n" ++
                    "  Add the name to its `A` block and compare against that instead, so the\n" ++
                    "  capability table and the dispatch chain cannot disagree.\n",
                .{ declared.path, line },
            );
            return error.ActionLiteralInDeclaredBridge;
        }
    }
}

/// Pull `pub const <ident> = "<name>";` pairs out of a source.
///
/// Indentation-agnostic: the names sit inside an `A` struct in most bridges and
/// at the top level in the ones whose names are split into their own file, and
/// which of those a bridge chose is not something this check should care about.
fn constantFor(source: []const u8, action_name: []const u8) ?[]const u8 {
    const decl = "pub const ";
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, source, search, decl)) |at| {
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |nl| nl + 1 else 0;
        const line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
        search = line_end;

        // Only a declaration, not `pub const` appearing inside a comment.
        if (std.mem.trim(u8, source[line_start..at], " \t").len != 0) continue;

        const line = source[at..line_end];
        // ` = "` is four bytes, so the value starts at eq + 4.
        const eq = std.mem.indexOf(u8, line, " = \"") orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue;
        if (close <= eq + 4) continue;
        if (!std.mem.eql(u8, line[eq + 4 .. close], action_name)) continue;

        return std.mem.trim(u8, line[decl.len..eq], " ");
    }
    return null;
}

test "every declared action is actually dispatched on" {
    // Catches a table row whose dispatch arm was deleted.
    //
    // Checking for the *name* would not: `"setBadge"` still appears in the `A`
    // block after its `else if` is removed, so the row and the string agree
    // while nothing dispatches. The constant is the thing to look for, because
    // the only places it can appear are the table and the chain. This test was
    // written the wrong way first and a control check caught it.
    for (declared_sources) |declared| {
        const source = declared.source;

        for (registry) |ns| {
            if (!std.mem.eql(u8, ns.name, declared.namespace)) continue;
            for (ns.actions) |action| {
                // An action declared `unavailable` is one the page can reach
                // and craft does not serve — `tray.destroy` has no dispatch arm
                // at all, and saying so is the whole point of declaring it.
                if (action.status == .unavailable) continue;

                const constant = constantFor(declared.names orelse source, action.name) orelse {
                    std.debug.print("{s} declares '{s}' with no `A` entry naming it\n", .{ declared.path, action.name });
                    return error.DeclaredActionHasNoConstant;
                };

                var needle_buf: [160]u8 = undefined;
                const needle = try std.fmt.bufPrint(&needle_buf, "action, A.{s})", .{constant});
                if (std.mem.indexOf(u8, source, needle) == null) {
                    std.debug.print(
                        "{s} declares '{s}' (A.{s}) but nothing dispatches on it.\n" ++
                            "  Either the arm was deleted, or the declaration should go.\n",
                        .{ declared.path, action.name, constant },
                    );
                    return error.DeclaredActionNotDispatched;
                }
            }
        }
    }
}

test "every dispatched action is declared" {
    // The other direction, within a bridge: an `A` constant that the chain
    // compares against but the table does not list.
    for (declared_sources) |declared| {
        const source = declared.source;

        var search: usize = 0;
        while (std.mem.indexOfPos(u8, source, search, "action, A.")) |at| {
            const name_start = at + "action, A.".len;
            const name_end = std.mem.indexOfScalarPos(u8, source, name_start, ')') orelse break;
            const constant = source[name_start..name_end];
            search = name_end;

            var declared_here = false;
            for (registry) |ns| {
                if (!std.mem.eql(u8, ns.name, declared.namespace)) continue;
                for (ns.actions) |action| {
                    const c = constantFor(declared.names orelse source, action.name) orelse continue;
                    if (std.mem.eql(u8, c, constant)) declared_here = true;
                }
            }
            if (!declared_here) {
                std.debug.print(
                    "{s} dispatches on A.{s} but the capability table does not list it.\n" ++
                        "  Add it to `capability_actions`.\n",
                    .{ declared.path, constant },
                );
                return error.DispatchedActionNotDeclared;
            }
        }
    }
}

test "the registry covers exactly the namespaces the dispatcher routes" {
    // Both directions. A missing row means a routed namespace is invisible to
    // capabilities; an extra row means capabilities advertises something no
    // message can reach — which is how `marketplace` came to implement eleven
    // actions nothing can call.
    const source = dispatcher_source;

    const start = std.mem.indexOf(u8, source, "pub fn handleBridgeMessageJSON") orelse
        return error.DispatcherNotFound;
    // The live chain only; `handleBridgeMessage` below it is a dead fallback
    // that parses `type`/`action`/`data` while every injected script posts
    // `t`/`a`/`d`.
    const end = std.mem.indexOfPos(u8, source, start, "\npub fn handleBridgeMessage(") orelse source.len;
    const chain = source[start..end];

    for (registry) |ns| {
        // `unrouted` is the row that says "no arm routes this", so requiring an
        // arm for it would be a contradiction.
        if (ns.status == .unrouted) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "msg_type, \"{s}\"", .{ns.name});
        if (std.mem.indexOf(u8, chain, needle) == null) {
            std.debug.print("registry lists '{s}' but the dispatcher does not route it\n", .{ns.name});
            return error.RegistryNamespaceNotRouted;
        }
    }

    // And the reverse: every arm in the chain must have a row.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, chain, search, "msg_type, \"")) |at| {
        const name_start = at + "msg_type, \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, chain, name_start, '"') orelse break;
        const name = chain[name_start..name_end];
        search = name_end;

        // `debug` is a dispatcher-internal arm, not a bridge namespace: it has
        // no bridge struct and no JS facade.
        if (std.mem.eql(u8, name, "debug")) continue;

        var known = false;
        for (registry) |ns| {
            if (std.mem.eql(u8, ns.name, name)) known = true;
        }
        if (!known) {
            std.debug.print(
                "the dispatcher routes '{s}' but the registry has no row for it.\n" ++
                    "  Add one to src/capability_registry.zig — `.undeclared` is a valid answer.\n",
                .{name},
            );
            return error.RoutedNamespaceNotInRegistry;
        }
    }
}

test "an unrouted namespace really is unrouted" {
    // Otherwise the status becomes a place to park something that was quietly
    // wired up later, and the manifest starts lying in the safe direction.
    const source = dispatcher_source;
    const start = std.mem.indexOf(u8, source, "pub fn handleBridgeMessageJSON") orelse
        return error.DispatcherNotFound;
    const end = std.mem.indexOfPos(u8, source, start, "\npub fn handleBridgeMessage(") orelse source.len;
    const chain = source[start..end];

    for (registry) |ns| {
        if (ns.status != .unrouted) continue;
        var needle_buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "msg_type, \"{s}\"", .{ns.name});
        if (std.mem.indexOf(u8, chain, needle) != null) {
            std.debug.print("'{s}' is marked unrouted but the dispatcher routes it\n", .{ns.name});
            return error.UnroutedNamespaceIsRouted;
        }
    }
}

test "undeclared namespaces are under the ratchet" {
    var undeclared: usize = 0;
    for (registry) |ns| {
        if (ns.status == .undeclared) undeclared += 1;
    }
    if (undeclared > max_undeclared) {
        std.debug.print(
            "{d} namespaces are undeclared; the ceiling is {d}.\n" ++
                "  Declare one, or say why the ceiling should rise — it is meant to fall.\n",
            .{ undeclared, max_undeclared },
        );
        return error.TooManyUndeclaredNamespaces;
    }
    // And the ceiling must not be left slack: if it has been beaten, lower it.
    if (undeclared + 2 < max_undeclared) {
        std.debug.print(
            "only {d} namespaces are undeclared but the ceiling is still {d} — lower it.\n",
            .{ undeclared, max_undeclared },
        );
        return error.RatchetLeftSlack;
    }
}

test "an unavailable surface always says why" {
    // Without a reason, "unavailable" sends an app looking for a bug in its own
    // code. With one, it is a fact they can act on.
    for (registry) |ns| {
        if (ns.status == .unavailable or ns.status == .unrouted) {
            if (ns.reason == null or ns.reason.?.len == 0) {
                std.debug.print("namespace '{s}' is {s} with no reason\n", .{ ns.name, @tagName(ns.status) });
                return error.UnavailableWithoutReason;
            }
        }
        for (ns.actions) |action| {
            if (action.status == .unavailable and (action.reason == null or action.reason.?.len == 0)) {
                std.debug.print("{s}.{s} is unavailable with no reason\n", .{ ns.name, action.name });
                return error.UnavailableWithoutReason;
            }
        }
    }
}

test "no namespace or action is declared twice" {
    for (registry, 0..) |a, i| {
        for (registry[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                std.debug.print("namespace '{s}' has two registry rows\n", .{a.name});
                return error.DuplicateNamespace;
            }
        }
        for (a.actions, 0..) |x, j| {
            for (a.actions[j + 1 ..]) |y| {
                if (std.mem.eql(u8, x.name, y.name)) {
                    std.debug.print("{s} declares action '{s}' twice\n", .{ a.name, x.name });
                    return error.DuplicateAction;
                }
            }
        }
    }
}

test "the manifest renders and parses" {
    const json = try registry_mod.manifestJson(testing.allocator);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const namespaces = parsed.value.object.get("namespaces").?.object;
    try testing.expectEqual(registry.len, namespaces.count());
    try testing.expectEqualStrings("declared", namespaces.get("clipboard").?.object.get("status").?.string);
    try testing.expectEqualStrings("unavailable", namespaces.get("updater").?.object.get("status").?.string);

    // Every channel is reported, including the dead ones — an app has to be
    // able to tell "no emitter" from "a name I misspelled".
    const channels = parsed.value.object.get("channels").?.object;
    try testing.expect(channels.count() > 0);
    try testing.expect(channels.get("craft:fs:change") != null);
}

test "every bridge type the page can send is routed by the dispatcher" {
    // The direction nothing checked. `test "the registry covers exactly the
    // namespaces the dispatcher routes"` pins the registry against the
    // dispatcher, and the channel test pins the events — but what the page can
    // *call* was never compared against what native will answer.
    //
    // A new `craft.foo.bar()` added to the facade with no arm in
    // `handleBridgeMessageJSON` posts a message that is parsed, matched
    // against every arm, and dropped. `_send` resolves the moment the message
    // leaves, so the caller gets a fulfilled promise and nothing happens —
    // silent, and exactly the shape of #27, #47 and #69.
    const chain = blk: {
        const start = std.mem.indexOf(u8, dispatcher_source, "pub fn handleBridgeMessageJSON") orelse
            return error.DispatcherNotFound;
        const end = std.mem.indexOfPos(u8, dispatcher_source, start, "\npub fn handleBridgeMessage(") orelse
            dispatcher_source.len;
        break :blk dispatcher_source[start..end];
    };

    var checked: usize = 0;
    var unrouted: usize = 0;

    // `_send('type', 'action'` / `_req(` / `_post(` — the three ways the
    // facade posts a message.
    for ([_][]const u8{ "_send('", "_req('", "_post('" }) |opener| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, bridge_js, search, opener)) |hit| {
            search = hit + opener.len;
            const rest = bridge_js[search..];
            const close = std.mem.indexOfScalar(u8, rest, '\'') orelse continue;
            const msg_type = rest[0..close];
            if (msg_type.len == 0 or msg_type.len > 64) continue;

            checked += 1;

            var needle_buf: [128]u8 = undefined;
            const needle = try std.fmt.bufPrint(&needle_buf, "msg_type, \"{s}\"", .{msg_type});
            if (std.mem.indexOf(u8, chain, needle) == null) {
                unrouted += 1;
                std.debug.print(
                    "craft-bridge.js posts type '{s}' but handleBridgeMessageJSON does not route it\n",
                    .{msg_type},
                );
            }
        }
    }

    // Floor: the facade posts hundreds of messages. If a refactor changes how
    // they are written this scan finds none and would otherwise pass having
    // compared nothing at all.
    try testing.expect(checked >= 200);
    try testing.expectEqual(@as(usize, 0), unrouted);
}

/// Bridges whose payload field names are checked against what the page sends.
///
/// A ratchet like `max_undeclared`: this list may only grow. Adding a bridge
/// here is what "the fields on both sides agree" costs, and it is cheap —
/// every entry below was added after the audit that found nine bridges reading
/// keys the page has never sent.
const field_checked = [_]struct {
    /// The bridge type as the page names it in `_send`/`_req`.
    namespace: []const u8,
    source: []const u8,
}{
    .{ .namespace = "fs", .source = @embedFile("src/bridge_fs.zig") },
    .{ .namespace = "window", .source = @embedFile("src/bridge_window.zig") },
    .{ .namespace = "updater", .source = @embedFile("src/bridge_updater.zig") },
    .{ .namespace = "bluetooth", .source = @embedFile("src/bridge_bluetooth.zig") },
    .{ .namespace = "serial", .source = @embedFile("src/bridge_serial.zig") },
    .{ .namespace = "localServer", .source = @embedFile("src/bridge_local_server.zig") },
};

/// The body of `fn <action>(...)`, from its signature to the next `    fn `.
///
/// Narrowing the search to the handler is what makes this catch a name used in
/// the *wrong* handler — `writeFile` reading a key only `readFile` sends. A
/// file-wide search cannot: the first version of this test passed against the
/// exact bug it was written for, because the name still appeared elsewhere in
/// the same file.
fn handlerBody(source: []const u8, action: []const u8) ?[]const u8 {
    var needle_buf: [96]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\n    fn {s}(", .{action}) catch return null;
    const start = std.mem.indexOf(u8, source, needle) orelse return null;
    const after = start + needle.len;

    // Ends at the next declaration *or* the next doc comment, whichever comes
    // first. Stopping only at `fn ` swallows the following function's `///`
    // block — and these bridges document their payloads in it, so
    // `appendFile`'s `/// JSON: {"content": "data"}` leaked into `writeFile`'s
    // span and made the check pass against the bug it was written for.
    const next_fn = std.mem.indexOfPos(u8, source, after, "\n    fn ") orelse source.len;
    const next_doc = std.mem.indexOfPos(u8, source, after, "\n    ///") orelse source.len;
    return source[start..@min(next_fn, next_doc)];
}

/// Whether a bridge's source mentions `name` as a payload field.
///
/// Two spellings, because bridges read payloads two ways. Some scan for a
/// literal needle — `json_utils.getString(data, "path")` — where the name
/// appears quoted. Others parse into a struct, where it is an unquoted field
/// declaration: `path: []const u8 = ""`. A check that knew only the first
/// reports every struct-based bridge as broken, which is exactly what the
/// first version of this test did.
fn bridgeKnowsField(source: []const u8, name: []const u8) bool {
    var quoted_buf: [96]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{name}) catch return true;
    if (std.mem.indexOf(u8, source, quoted) != null) return true;

    // A struct field: the name at the start of an indented line, followed by a
    // colon. Anchored on the newline so `path:` inside `filePath:` or a
    // comment does not count.
    var field_buf: [96]u8 = undefined;
    const field = std.fmt.bufPrint(&field_buf, "\n    {s}: ", .{name}) catch return true;
    if (std.mem.indexOf(u8, source, field) != null) return true;

    // A struct field at any indentation, identified by its default: every
    // payload struct in these bridges declares one (`baud: u32 = 9600`).
    //
    // The default is what tells a field from a *parameter*. `fn writeFile(self:
    // *Self, data: []const u8)` contains `data: `, and accepting that made the
    // check pass against the exact bug it was written for — the handler was
    // reading the wrong key while its own parameter supplied the name.
    var nested_buf: [96]u8 = undefined;
    const nested = std.fmt.bufPrint(&nested_buf, "{s}: ", .{name}) catch return true;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, source, search, nested)) |hit| {
        search = hit + nested.len;
        if (hit != 0) {
            const before = source[hit - 1];
            if (before != ' ' and before != '\n' and before != '\t') continue;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, hit, '\n') orelse source.len;
        if (std.mem.indexOfScalarPos(u8, source[0..line_end], hit, '=') != null) return true;
    }
    return false;
}

/// Fields a handler legitimately does not name.
///
/// Narrowing the search to the handler is what makes the check catch a name
/// read in the wrong place — but it also flags two honest patterns: a handler
/// that reads the payload without keying off the field name, and one that
/// delegates the parsing to a helper. Each exemption costs a line and a
/// reason, which is the point: the list is short and every entry is arguable,
/// rather than the check being weakened for everyone.
const field_exempt = [_]struct {
    namespace: []const u8,
    action: []const u8,
    field: []const u8,
    why: []const u8,
}{
    .{
        .namespace = "window",
        .action = "setAlwaysOnTop",
        .field = "value",
        .why = "scans the payload for the literal \"false\", so it reads the boolean without naming the key",
    },
    .{ .namespace = "window", .action = "setResizable", .field = "value", .why = "same key-agnostic boolean scan" },
    .{ .namespace = "window", .action = "setMovable", .field = "value", .why = "same key-agnostic boolean scan" },
    .{ .namespace = "window", .action = "setHasShadow", .field = "value", .why = "same key-agnostic boolean scan" },
    .{
        .namespace = "bluetooth",
        .action = "connectDevice",
        .field = "id",
        .why = "delegates to `deviceAddress`, which accepts both \"id\" and \"address\"",
    },
    .{ .namespace = "bluetooth", .action = "disconnectDevice", .field = "id", .why = "same helper" },
};

fn isExempt(namespace: []const u8, action: []const u8, field: []const u8) bool {
    for (field_exempt) |e| {
        if (std.mem.eql(u8, e.namespace, namespace) and
            std.mem.eql(u8, e.action, action) and
            std.mem.eql(u8, e.field, field)) return true;
    }
    return false;
}

test "every field the page sends is a name the handler actually looks for" {
    // The bug class this exists for, from issue #69 and the audit that
    // followed it: the page posts `{"data": "..."}`, the handler reads
    // `"content"`, and nothing objects. Every bridge parses with
    // `ignore_unknown_fields = true` or scans for a literal needle, so a name
    // that does not match is not an error — the value is simply gone and the
    // caller's promise resolves.
    //
    // It cost `craft.fs.writeFile` writing empty files, `setFullscreen(false)`
    // entering fullscreen, `setVibrancy` removing vibrancy, and Bluetooth
    // connects that could never name a device.
    //
    // The check is deliberately loose: it asks only whether the field name
    // appears *somewhere* in the handling bridge, quoted. That is enough to
    // catch a name the native side has never heard of, which is the whole
    // failure, without trying to model which handler owns which action.
    var checked: usize = 0;
    var missing: usize = 0;

    for ([_][]const u8{ "_send('", "_req('" }) |opener| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, bridge_js, search, opener)) |hit| {
            search = hit + opener.len;
            const rest = bridge_js[search..];

            const type_end = std.mem.indexOfScalar(u8, rest, '\'') orelse continue;
            const msg_type = rest[0..type_end];

            // Only the bridges that have opted in.
            var source: ?[]const u8 = null;
            for (field_checked) |entry| {
                if (std.mem.eql(u8, entry.namespace, msg_type)) source = entry.source;
            }
            if (source == null) continue;

            // The action, so the search can be narrowed to its handler.
            const after_type = rest[type_end + 1 ..];
            const a_open = std.mem.indexOf(u8, after_type, "'") orelse continue;
            const a_rest = after_type[a_open + 1 ..];
            const a_end = std.mem.indexOfScalar(u8, a_rest, '\'') orelse continue;
            const action_name = a_rest[0..a_end];

            // `fn <action>(` when the handler is named after the action, which
            // is the convention throughout. Falls back to the whole file when
            // it is not — looser, but never a false alarm.
            const scope = handlerBody(source.?, action_name) orelse source.?;

            // The `_stringify({ ... })` literal for this call, if it has one.
            const call_end = std.mem.indexOfScalarPos(u8, bridge_js, search, '\n') orelse bridge_js.len;
            const call = bridge_js[search..call_end];
            const brace = std.mem.indexOf(u8, call, "_stringify({") orelse continue;
            const obj_start = brace + "_stringify({".len;
            const obj_end = std.mem.indexOfScalarPos(u8, call, obj_start, '}') orelse continue;
            const obj = call[obj_start..obj_end];

            // Field names: an identifier followed by a colon.
            var i: usize = 0;
            while (i < obj.len) {
                while (i < obj.len and !std.ascii.isAlphabetic(obj[i])) i += 1;
                const name_start = i;
                while (i < obj.len and (std.ascii.isAlphanumeric(obj[i]) or obj[i] == '_')) i += 1;
                if (i >= obj.len or name_start == i) break;
                const name = obj[name_start..i];
                var j = i;
                while (j < obj.len and obj[j] == ' ') j += 1;
                if (j >= obj.len or obj[j] != ':') continue;

                checked += 1;
                if (isExempt(msg_type, action_name, name)) continue;
                if (!bridgeKnowsField(scope, name)) {
                    missing += 1;
                    std.debug.print(
                        "craft-bridge.js sends '{s}' to the {s} bridge, which never mentions that name —\n" ++
                            "  the value is parsed and discarded, and the caller's promise still resolves.\n",
                        .{ name, msg_type },
                    );
                }
            }
        }
    }

    // Floor: these six bridges carry dozens of fields between them. A scan
    // that matched nothing would pass having compared nothing.
    try testing.expect(checked >= 30);
    try testing.expectEqual(@as(usize, 0), missing);
}
