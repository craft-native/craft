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
const declared_sources = [_]struct { namespace: []const u8, path: []const u8, source: []const u8 }{
    .{ .namespace = "clipboard", .path = "src/bridge_clipboard.zig", .source = @embedFile("src/bridge_clipboard.zig") },
    .{ .namespace = "tray", .path = "src/bridge_tray.zig", .source = @embedFile("src/bridge_tray.zig") },
    .{ .namespace = "app", .path = "src/bridge_app.zig", .source = @embedFile("src/bridge_app.zig") },
    .{ .namespace = "screen", .path = "src/bridge_screen.zig", .source = @embedFile("src/bridge_screen.zig") },
    .{ .namespace = "capabilities", .path = "src/bridge_capabilities.zig", .source = @embedFile("src/bridge_capabilities.zig") },
};

const dispatcher_source = @embedFile("src/macos.zig");

/// How many namespaces may still answer `undeclared`.
///
/// A ratchet, not a target. It exists so `undeclared` cannot quietly become
/// where surfaces go to avoid being audited — the number may only ever be
/// lowered, and lowering it is what "declaring a namespace" costs.
const max_undeclared: usize = 45;

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

/// Pull `pub const <ident> = "<name>";` pairs out of a bridge's `A` block.
fn constantFor(source: []const u8, action_name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, source, search, "    pub const ")) |at| {
        const line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
        const line = source[at..line_end];
        search = line_end;

        // ` = "` is four bytes, so the value starts at eq + 4.
        const eq = std.mem.indexOf(u8, line, " = \"") orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue;
        if (close <= eq + 4) continue;
        const value = line[eq + 4 .. close];
        if (!std.mem.eql(u8, value, action_name)) continue;

        return std.mem.trim(u8, line["    pub const ".len..eq], " ");
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

                const constant = constantFor(source, action.name) orelse {
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
                    const c = constantFor(source, action.name) orelse continue;
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
