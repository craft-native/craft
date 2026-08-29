//! The local-database actions of the `mobile` namespace: `dbExecute`,
//! `dbQuery`.
//!
//! The database is `<sandbox>/Documents/craft.db`, the exact file the Swift
//! coordinator's `setupDatabase` opens — same directory lookup
//! (`NSDocumentDirectory` in `NSUserDomainMask`), same filename, same plain
//! `sqlite3_open`. It is deliberately **not** opened through `database.zig`'s
//! `Database`, whose init applies pragmas Swift never sets (WAL,
//! `foreign_keys=ON`, cache size, busy timeout); wrapping it would silently
//! flip an existing app's `craft.db` into WAL mode mid-migration. Raw externs,
//! no pragmas, opened lazily on the first db action and kept for the process
//! lifetime, as Swift keeps its coordinator-lifetime handle. The externs are
//! this file's own copies — `database.zig`'s are file-private by design, and
//! `extern` declarations are free to repeat.
//!
//! The payload fields are `sql` (string, required) and `params` (array,
//! optional) — the names the Swift dispatcher reads (`body["sql"]`,
//! `body["params"]`) and the shim hand-off proves ride inside `d`. The Android
//! surface posts the same pair (`CraftBridge.kt.template`'s `db.execute`
//! stringifies `params || []`), so the field names are pinned on three sides.
//!
//! ## What is carried across exactly, because it is the observable contract
//!
//!  - **`dbExecute` resolves `{"rowsAffected":<int>,"lastInsertId":<int>}`** —
//!    `sqlite3_changes` and `sqlite3_last_insert_rowid`, both fields always
//!    present.
//!  - **`dbQuery` resolves a bare JSON array of row objects keyed by column
//!    name** — Swift's `.fragmentsAllowed` makes the bare `[]`/`[{...}]` legal,
//!    and `test-bridges.html` stringifies the value straight into the page, so
//!    keys and value types are all visible contract. An empty result set is
//!    `[]`; a non-SELECT statement sent through `dbQuery` executes and
//!    resolves `[]`.
//!  - **A `BLOB` column's key is entirely absent from its row object** — not
//!    `null`. Swift's column switch has `default: break`, so a row that is all
//!    BLOBs serializes as `{}`. Anything else changes the shape.
//!  - **`NULL` columns are JSON `null`**, Swift's `NSNull`.
//!  - **A SQLite failure rejects with `sqlite3_errmsg`'s text as the
//!    message** — "no such table: x" is what the page displays (`'Error: ' +
//!    e.message`), so the raw message text is the contract and travels intact
//!    through `ErrorContext`. `dbExecute` of a SELECT that returns rows steps
//!    to `SQLITE_ROW`, not `SQLITE_DONE`, and therefore rejects — with
//!    whatever `sqlite3_errmsg` says at that point (typically "not an error").
//!    Bug-compatible on purpose: the two implementations must be
//!    interchangeable while the shim exists.
//!  - **A row value SQLite holds but JSON cannot carry (an infinite REAL,
//!    e.g. a stored `9e999`) rejects with "Native result could not be
//!    serialized"** — the exact message Swift's `JSONSerialization` catch
//!    produces when the Double reaches it.
//!
//! ## What is deliberately not carried across
//!
//! **Swift's silent hang.** The dispatcher arms are gate + `if let sql` with
//! no `else`: a missing or non-string `sql`, or `enableLocalDatabase` at its
//! default `false`, replies nothing at all. Malformed input errors here
//! instead, and the config gate is left plumbable the way clipboard's is: a
//! host calls `craft_ios_set_local_database_enabled(false)` and the actions
//! reject `PermissionDenied` — never silence. It defaults to enabled, because
//! default-off would answer every app with PERMISSION_DENIED until a host that
//! does not exist yet is written (the clipboard module records the same
//! trade).
//!
//! **The `Int32` funnels.** Swift binds integer params through `Int32(int)`,
//! which *traps* — crashes the app — for |v| >= 2^31, and reads INTEGER
//! columns through `sqlite3_column_int`, which silently wraps large values.
//! Both go through the 64-bit calls here; a crash is not a contract, and a
//! wrapped rowid is a corrupted answer.
//!
//! **Text truncation at NUL.** Swift's `sqlite3_bind_text(_, _, str, -1, nil)`
//! measures to the first NUL *and* passes SQLITE_STATIC on a temporary — a
//! latent use-after-free. Strings bind here with their byte length and
//! SQLITE_TRANSIENT, exactly as the desktop `bindText` does, so an embedded
//! NUL in a *param* survives the round trip. Reads use `column_bytes` rather
//! than `String(cString:)` for the same reason. The `sql` string itself is
//! different: SQLite stops parsing at a NUL, so a NUL there would silently
//! execute a prefix of what the page sent — refused as `InvalidParameter`
//! (rule: truncation that changes meaning is refused, not performed).
//!
//! **Silently dropped payload.** Swift binds NULL for a param it cannot
//! downcast (an object or array), ignores a `params` value that is not an
//! array, never checks a bind's return code (excess params vanish into
//! `SQLITE_RANGE`), and `prepare_v2` executes only the first statement of a
//! multi-statement string, discarding the rest. Every one of those is a page
//! payload quietly not doing what the page said. Here: non-bindable params and
//! a non-array `params` are `InvalidParameter`; bind failures reject with the
//! SQLite message; SQL that continues past the first statement (more than
//! whitespace/semicolons — a trailing `--` comment is refused too,
//! conservatively) is `InvalidParameter`.
//!
//! **Partial rows on a mid-iteration step failure.** Swift's query loop is
//! `while step == SQLITE_ROW` with the terminating code unexamined: an
//! `SQLITE_BUSY` or corruption error just ends the loop and *resolves* the
//! rows collected so far, indistinguishable from a complete result. That is
//! fabricated success; a step that ends with anything but `SQLITE_DONE`
//! rejects here, with the SQLite message.
//!
//! **The error `code` label.** Swift rejected with its catch-all
//! `"CRAFT_ERROR"`; a Zig-served rejection carries `NATIVE_CALL_FAILED`
//! (`ErrorContext` owns the code vocabulary). The message text — the part the
//! page displays and the part that names the failing table — is preserved
//! verbatim.
//!
//! **A failed open is closed.** Swift's `setupDatabase` ignores that
//! `sqlite3_open` hands back a handle even on failure, and leaves it set — so
//! later actions run against a half-open handle. Here a failed open is closed
//! and the action rejects "Database not initialized", the message Swift's
//! `guard let db` produces for exactly this condition. The open is retried on
//! the next action rather than latched broken.
//!
//! ## Host-test safety, named because it is invisible
//!
//! On a macOS host, the lazy open would land in the *developer's*
//! `~/Documents/craft.db`. Every test below therefore either fails validation
//! before `ensureDatabase` can run, or drives `runExecute`/`runQuery` directly
//! against its own `:memory:` handle. No test may hand `handleMessage` a
//! payload with a valid `sql`.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const request_context = @import("request_context.zig");
const memory = @import("memory.zig");
const objc_runtime = @import("objc_runtime.zig");

const objc = objc_runtime.objc;

// SQLite, spelled exactly as `database.zig` spells it (those declarations are
// file-private by design; `extern` declarations are free to repeat). The
// vendored amalgamation is compiled into every artifact that links this
// module on Darwin — `ios_surface_tests`, `ios_module_tests`, the device lib —
// per `build.zig`.
const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

const SQLITE_INTEGER = 1;
const SQLITE_FLOAT = 2;
const SQLITE_TEXT = 3;
const SQLITE_BLOB = 4;
const SQLITE_NULL = 5;

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) ?[*:0]const u8;
extern fn sqlite3_changes(db: ?*sqlite3) c_int;
extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, zSql: [*]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*[*]const u8) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) c_int;
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;
extern fn sqlite3_bind_double(stmt: ?*sqlite3_stmt, idx: c_int, value: f64) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, text: [*]const u8, len: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_column_name(stmt: ?*sqlite3_stmt, idx: c_int) ?[*:0]const u8;
extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, idx: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, idx: c_int) i64;
extern fn sqlite3_column_double(stmt: ?*sqlite3_stmt, idx: c_int) f64;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, idx: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, idx: c_int) c_int;

/// `((sqlite3_destructor_type)-1)`: copy the bound bytes rather than borrow
/// them. An opaque pointer, never a typed fn pointer — the all-ones address
/// cannot satisfy fn-pointer alignment, and the long comment in `database.zig`
/// records the two Linux link breakages the typed spelling caused.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

/// The action names, spelled exactly as the Swift `case` labels spell them.
/// `test/ios_conformance_test.zig` matches the two lists by string in both
/// directions.
pub const A = struct {
    pub const db_execute = "dbExecute";
    pub const db_query = "dbQuery";
};

/// Both `.result`: each Swift path resolves or rejects a callback, and both
/// are awaited by the page. Both `.live`: plain SQLite C calls, no UI, no
/// permission prompt, no completion handler — the amalgamation is compiled
/// into the iOS artifacts, so nothing warrants `.unavailable`.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.db_execute, .reply = .result },
    .{ .name = A.db_query, .reply = .result },
};

/// The `enableLocalDatabase` gate, kept plumbable per the clipboard precedent
/// (`craft_ios_set_clipboard_enabled`). Swift's gate at `false` replied
/// *nothing*; off here means `PermissionDenied`, never silence. Main-thread
/// only, like every gate in the chain: the WKScriptMessageHandler callback is
/// the sole reader, a host at startup the sole writer.
var local_database_enabled: bool = true;

pub fn setEnabled(value: bool) void {
    local_database_enabled = value;
}

export fn craft_ios_set_local_database_enabled(value: bool) callconv(.c) void {
    local_database_enabled = value;
}

/// The one process-lifetime handle to `Documents/craft.db`, mirroring Swift's
/// coordinator-lifetime `db`. Opened lazily on the first db action rather than
/// at init, because `DbBridge` is constructed per-message by the dispatch loop
/// and must stay free to construct. Never populated by tests — see the module
/// comment on host-test safety.
var global_db: ?*sqlite3 = null;

/// Which handler an action selects, split from `handleMessage` so the
/// table-versus-dispatch agreement is assertable on a host without invoking a
/// handler whose success path would open the developer's own `craft.db`.
const Route = enum { execute, query };

fn routeFor(action: []const u8) ?Route {
    if (std.mem.eql(u8, action, A.db_execute)) return .execute;
    if (std.mem.eql(u8, action, A.db_query)) return .query;
    return null;
}

pub const DbBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const route = routeFor(action) orelse return bridge_error.BridgeError.UnknownAction;
        // Exhaustive, so a `Route` without a handler is a compile error.
        return switch (route) {
            .execute => self.serve(.execute, data),
            .query => self.serve(.query, data),
        };
    }

    /// One body for both actions — they share the gate, the payload shape, the
    /// database handle, and the two reply routes; only the runner differs.
    fn serve(self: *Self, route: Route, data: []const u8) !void {
        const action: []const u8 = switch (route) {
            .execute => A.db_execute,
            .query => A.db_query,
        };

        if (!local_database_enabled) return bridge_error.BridgeError.PermissionDenied;

        var parsed = try parsePayload(self.allocator, data);
        defer parsed.deinit();
        const request = try parseRequest(parsed.value);

        // Validation strictly precedes the open: this ordering is what lets
        // the host tests exercise every refusal above without ever creating
        // `~/Documents/craft.db` on the machine running them.
        // `if` comparisons rather than a `switch`: on Darwin the comptime
        // platform gate is pruned, so `error.UnsupportedPlatform` is not in
        // the inferred error set and a switch arm naming it would not compile.
        const db = ensureDatabase(self.allocator) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.UnsupportedPlatform) return err;
            // Swift's `guard let db` message, verbatim — the observable
            // reply for "there is no database to run this against".
            rejectWithMessage(self.allocator, action, "Database not initialized");
            return;
        };

        const outcome = switch (route) {
            .execute => try runExecute(self.allocator, db, request),
            .query => try runQuery(self.allocator, db, request),
        };
        switch (outcome) {
            .ok => |fragment| {
                defer self.allocator.free(fragment);
                bridge_error.sendResultToJS(self.allocator, action, fragment);
            },
            .failed => |message| {
                defer self.allocator.free(message);
                rejectWithMessage(self.allocator, action, message);
            },
        }
    }
};

/// Parse `d`, distinguishing a bad payload from a failed allocation — telling
/// the page INVALID_JSON about its own good JSON sends whoever debugs it to
/// the wrong side of the bridge.
fn parsePayload(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return bridge_error.BridgeError.InvalidJSON,
    };
}

/// The payload after validation. `sql` and `params` are the names the injected
/// surfaces post and the Swift dispatcher reads — pinned on both sides of the
/// migration. `params` borrows the parsed JSON's array items; the caller keeps
/// the parse alive until the run completes.
const Request = struct {
    sql: []const u8,
    params: []const std.json.Value,
};

fn parseRequest(payload: std.json.Value) !Request {
    const object = switch (payload) {
        .object => |o| o,
        else => return bridge_error.BridgeError.InvalidJSON,
    };

    const sql_field = object.get("sql") orelse return bridge_error.BridgeError.MissingData;
    const sql = switch (sql_field) {
        .string => |s| s,
        // Swift's `as? String` fails here and replies nothing at all.
        else => return bridge_error.BridgeError.InvalidParameter,
    };
    // the \\u0000 escape is legal JSON, so a page can reach this. SQLite stops
    // parsing SQL at a NUL: an unchecked one would silently execute a prefix
    // of what the page sent and report success for the whole.
    if (std.mem.indexOfScalar(u8, sql, 0) != null) return bridge_error.BridgeError.InvalidParameter;
    // `prepare_v2` takes the byte count as a c_int; a longer `sql` would trip
    // the `@intCast` safety panic — the same crash-instead-of-answer the
    // module doc rejects in Swift's `Int32(int)` funnel. (SQLite itself caps
    // statements at SQLITE_LIMIT_LENGTH, far below this, so nothing honest is
    // refused.)
    if (sql.len > std.math.maxInt(c_int)) return bridge_error.BridgeError.InvalidParameter;

    const params: []const std.json.Value = if (object.get("params")) |params_field| switch (params_field) {
        .array => |a| a.items,
        // `craft.db.execute(sql)` with params omitted serializes `null` on
        // some surfaces; absent and null are both "no params", as in Swift.
        .null => &[_]std.json.Value{},
        // Swift's `as? [Any]` quietly yields nil here and executes without
        // the params the page sent — a dropped payload, refused instead.
        else => return bridge_error.BridgeError.InvalidParameter,
    } else &[_]std.json.Value{};

    for (params) |param| switch (param) {
        // `bind_text` takes the byte length as a c_int — same `@intCast`
        // panic as `sql` above for a param of 2^31 bytes or more; refused
        // here so a page payload can never crash instead of erroring.
        .string => |s| if (s.len > std.math.maxInt(c_int)) return bridge_error.BridgeError.InvalidParameter,
        .integer, .float, .bool, .null => {},
        // Swift binds NULL for an object or array param — the value the page
        // sent, silently replaced with a different one. `.number_string`
        // cannot occur under default parse options; refusing it beats
        // guessing at its binding.
        else => return bridge_error.BridgeError.InvalidParameter,
    };

    return .{ .sql = sql, .params = params };
}

/// What a runner hands back: the resolve fragment, or the message the page's
/// rejection carries (SQLite's own text — the observable contract). Exactly
/// one of the two, and the caller owns either slice. Validation failures are
/// errors instead, and take the dispatcher's fixed-message route.
const RunOutcome = union(enum) {
    ok: []u8,
    failed: []u8,
};

/// The `dbExecute` resolve fragment. Key order is fixed here where Swift's
/// dictionary serialization left it arbitrary; both fields are the contract.
fn executeFragment(allocator: std.mem.Allocator, rows_affected: c_int, last_insert_id: i64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"rowsAffected\":{d},\"lastInsertId\":{d}}}",
        .{ rows_affected, last_insert_id },
    );
}

/// True when `sql` continues past the first prepared statement with anything
/// but whitespace and semicolons. `prepare_v2` points `tail` one past the end
/// of the first statement; Swift never looks, and silently discards whatever
/// follows. Conservative on purpose: a trailing `-- comment` is refused too,
/// and the page gets INVALID_PARAMETER instead of a silent partial execution.
fn hasTrailingStatement(sql: []const u8, tail: [*]const u8) bool {
    const consumed = @intFromPtr(tail) - @intFromPtr(sql.ptr);
    if (consumed >= sql.len) return false;
    const rest = std.mem.trim(u8, sql[consumed..], " \t\r\n;");
    return rest.len != 0;
}

/// `sqlite3_errmsg`'s current text, copied immediately — the pointer is only
/// valid until the next call on this connection, and `finalize` runs before
/// the message reaches the page.
fn copyErrMsg(allocator: std.mem.Allocator, db: *sqlite3) ![]u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const msg = sqlite3_errmsg(db) orelse return allocator.dupe(u8, "unknown SQLite error");
    return allocator.dupe(u8, std.mem.span(msg));
}

/// Bind one JSON param at 1-based `idx`, returning SQLite's own verdict.
///
/// The mapping Swift's downcast chain implies, minus its traps: strings carry
/// their byte length with SQLITE_TRANSIENT (Swift's `-1, nil` truncated at NUL
/// and borrowed a temporary), integers and bools go through `bind_int64`
/// (Swift's `Int32(int)` traps at 2^31; its NSNumber `true` binds as INTEGER
/// 1, matched here), floats through `bind_double`, null through `bind_null`.
fn bindValue(stmt: ?*sqlite3_stmt, idx: c_int, value: std.json.Value) c_int {
    return switch (value) {
        .string => |s| if (s.len == 0)
            // A zero-length slice's pointer may be dangling; SQLite still
            // wants a readable address for the empty string.
            sqlite3_bind_text(stmt, idx, "", 0, SQLITE_TRANSIENT)
        else
            sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), SQLITE_TRANSIENT),
        .integer => |v| sqlite3_bind_int64(stmt, idx, v),
        .float => |v| sqlite3_bind_double(stmt, idx, v),
        .bool => |v| sqlite3_bind_int64(stmt, idx, @as(i64, @intFromBool(v))),
        .null => sqlite3_bind_null(stmt, idx),
        // parseRequest refused everything else before a statement existed.
        else => unreachable,
    };
}

/// Bind all params; a failure returns the message for the page's rejection.
/// Swift never checks these return codes — excess params vanish into an
/// ignored SQLITE_RANGE. Divergence, recorded: a param that did not bind is a
/// payload that did not do what the page said.
fn bindAll(
    allocator: std.mem.Allocator,
    db: *sqlite3,
    stmt: ?*sqlite3_stmt,
    params: []const std.json.Value,
) !?[]u8 {
    for (params, 0..) |param, i| {
        const rc = bindValue(stmt, @intCast(i + 1), param);
        if (rc != SQLITE_OK) return try copyErrMsg(allocator, db);
    }
    return null;
}

/// Prepare `sql` (exactly one statement of it), or say why not.
///
/// Shared by both runners: same prepare, same multi-statement refusal, same
/// "nothing to execute" refusal for whitespace/comment-only SQL (where Swift
/// stepped a nil statement into SQLITE_MISUSE for `dbExecute` and resolved
/// `[]` for `dbQuery` — neither is an answer about SQL that contains no
/// statement).
const Prepared = union(enum) {
    stmt: *sqlite3_stmt,
    failed: []u8,
};

fn prepareOne(allocator: std.mem.Allocator, db: *sqlite3, sql: []const u8) !Prepared {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    if (sql.len == 0) return bridge_error.BridgeError.InvalidParameter;

    var stmt: ?*sqlite3_stmt = null;
    var tail: [*]const u8 = sql.ptr;
    const rc = sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, &tail);
    if (rc != SQLITE_OK) {
        _ = sqlite3_finalize(stmt);
        return .{ .failed = try copyErrMsg(allocator, db) };
    }
    const prepared = stmt orelse return bridge_error.BridgeError.InvalidParameter;
    if (hasTrailingStatement(sql, tail)) {
        _ = sqlite3_finalize(prepared);
        return bridge_error.BridgeError.InvalidParameter;
    }
    return .{ .stmt = prepared };
}

/// `dbExecute`: prepare, bind, single step to DONE, report changes + rowid.
///
/// Takes the handle explicitly so host tests run against their own `:memory:`
/// database — nothing in here knows about `Documents/craft.db`.
fn runExecute(allocator: std.mem.Allocator, db: *sqlite3, request: Request) !RunOutcome {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const stmt = switch (try prepareOne(allocator, db, request.sql)) {
        .failed => |message| return .{ .failed = message },
        .stmt => |s| s,
    };
    defer _ = sqlite3_finalize(stmt);

    if (try bindAll(allocator, db, stmt, request.params)) |message| {
        return .{ .failed = message };
    }

    // Anything but DONE rejects — including SQLITE_ROW from a SELECT sent
    // through `dbExecute`, which Swift also rejects (with the "not an error"
    // text `sqlite3_errmsg` reports at that point). Bug-compatible; see the
    // module comment.
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        return .{ .failed = try copyErrMsg(allocator, db) };
    }

    return .{ .ok = try executeFragment(allocator, sqlite3_changes(db), sqlite3_last_insert_rowid(db)) };
}

/// `dbQuery`: prepare, bind, step to completion, serialize each row as an
/// object keyed by column name — the exact JSON the page consumes.
fn runQuery(allocator: std.mem.Allocator, db: *sqlite3, request: Request) !RunOutcome {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const stmt = switch (try prepareOne(allocator, db, request.sql)) {
        .failed => |message| return .{ .failed = message },
        .stmt => |s| s,
    };
    defer _ = sqlite3_finalize(stmt);

    if (try bindAll(allocator, db, stmt, request.params)) |message| {
        return .{ .failed = message };
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    const column_count = sqlite3_column_count(stmt);
    var first_row = true;
    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            // Swift's loop condition swallows this code and resolves the rows
            // collected so far as if they were all of them. Divergence,
            // chosen: an interrupted result set is a failure, not a shorter
            // success.
            const message = try copyErrMsg(allocator, db);
            out.deinit(allocator);
            return .{ .failed = message };
        }

        if (!first_row) try out.append(allocator, ',');
        first_row = false;
        try out.append(allocator, '{');

        var first_col = true;
        var i: c_int = 0;
        while (i < column_count) : (i += 1) {
            const col_type = sqlite3_column_type(stmt, i);
            // Swift's `default: break`: the key is entirely absent, not null.
            if (col_type == SQLITE_BLOB) continue;

            // Null only on OOM inside SQLite — never "no name".
            const name = sqlite3_column_name(stmt, i) orelse return error.OutOfMemory;

            if (!first_col) try out.append(allocator, ',');
            first_col = false;
            try out.append(allocator, '"');
            // Page-controlled via `AS "alia\"s"` — escaped like every other
            // page-controlled byte that rides a reply.
            try bridge_error.appendJsonEscaped(allocator, &out, std.mem.span(name));
            try out.appendSlice(allocator, "\":");

            switch (col_type) {
                SQLITE_INTEGER => try out.print(allocator, "{d}", .{sqlite3_column_int64(stmt, i)}),
                SQLITE_FLOAT => {
                    const value = sqlite3_column_double(stmt, i);
                    if (!std.math.isFinite(value)) {
                        // SQLite can hold an infinity (`9e999`); JSON cannot.
                        // Swift's JSONSerialization throws and its catch
                        // rejects with exactly this message.
                        const message = try allocator.dupe(u8, "Native result could not be serialized");
                        out.deinit(allocator);
                        return .{ .failed = message };
                    }
                    try out.print(allocator, "{d}", .{value});
                },
                SQLITE_TEXT => {
                    // `column_text` is null only on OOM for a TEXT column.
                    // Length via `column_bytes` (valid right after
                    // `column_text`), not a NUL scan — Swift's
                    // `String(cString:)` truncated stored text at an embedded
                    // NUL; the desktop reader and this one carry it whole.
                    const text = sqlite3_column_text(stmt, i) orelse return error.OutOfMemory;
                    const len: usize = @intCast(sqlite3_column_bytes(stmt, i));
                    try out.append(allocator, '"');
                    try bridge_error.appendJsonEscaped(allocator, &out, text[0..len]);
                    try out.append(allocator, '"');
                },
                SQLITE_NULL => try out.appendSlice(allocator, "null"),
                // The five storage classes are exhaustive and BLOB was handled
                // above; SQLite returning a sixth is a broken runtime. The
                // `errdefer` above frees `out` on this error return — a manual
                // deinit here would run it twice.
                else => return error.NativeCallFailed,
            }
        }
        try out.append(allocator, '}');
    }
    try out.append(allocator, ']');

    return .{ .ok = try out.toOwnedSlice(allocator) };
}

/// Reject the current call with a free-text message — the route that carries
/// `sqlite3_errmsg`'s words to the page, where `sendErrorToJS` could only send
/// a fixed per-code string. Same wire shape (`__craftBridgeError`), same
/// escaping (`ErrorContext.toJSON`), stamped with the current request id so
/// exactly the calling promise rejects.
fn rejectWithMessage(allocator: std.mem.Allocator, action: []const u8, message: []const u8) void {
    var ctx = bridge_error.ErrorContext.init(bridge_error.BridgeError.NativeCallFailed, action, message);
    ctx.request_id = request_context.current();

    const json = ctx.toJSON(allocator) catch {
        // Out of memory mid-reply: the fixed-message route still beats
        // silence — the page's promise must settle.
        bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.NativeCallFailed);
        return;
    };
    defer allocator.free(json);

    const js = std.fmt.allocPrint(
        allocator,
        "if(window.__craftBridgeError)window.__craftBridgeError({s});",
        .{json},
    ) catch {
        bridge_error.sendErrorToJS(allocator, action, bridge_error.BridgeError.NativeCallFailed);
        return;
    };
    defer allocator.free(js);

    const bridge = @import("bridge.zig");
    bridge.evalJS(js) catch |err| {
        std.log.warn("db bridge: could not deliver rejection for '{s}': {}", .{ action, err });
    };
}

/// The process-wide handle, opened on first use at `Documents/craft.db` —
/// Swift's `setupDatabase` path exactly, so a partially migrated app reads the
/// data its Swift half wrote. A failed open is closed and reported (Swift left
/// the broken handle installed — see the module comment) and retried on the
/// next action rather than latched.
fn ensureDatabase(allocator: std.mem.Allocator) !*sqlite3 {
    if (global_db) |db| return db;
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const docs = try documentsPath(allocator);
    defer allocator.free(docs);

    const joined = try std.fmt.allocPrint(allocator, "{s}/craft.db", .{docs});
    defer allocator.free(joined);

    const db = try openDatabaseFile(allocator, joined);
    global_db = db;
    return db;
}

/// `NSFileManager` → `URLsForDirectory:inDomains:` → `firstObject` → `path`,
/// the chain Swift's `setupDatabase` runs, with every step guarded — a nil
/// anywhere is a named error, never a message to nil read as a path.
/// NSDocumentDirectory = 9, NSUserDomainMask = 1. (`mobile.zig`'s
/// `getDocumentsDirectory` is a stub returning `""` — not used on purpose.)
fn documentsPath(allocator: std.mem.Allocator) ![]u8 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const NSFileManager = objc.objc_getClass("NSFileManager") orelse return error.ClassNotFound;
    const sel_default = objc.sel_registerName("defaultManager") orelse return error.SelectorNotFound;
    const manager = objc.msgSendId(NSFileManager, sel_default);
    if (manager == null) return error.NativeCallFailed;

    const sel_urls = objc.sel_registerName("URLsForDirectory:inDomains:") orelse return error.SelectorNotFound;
    // NSUInteger arguments: explicit c_ulong, because the variadic msgSend
    // cast takes argument types from what is passed.
    const urls = objc.msgSendId2(manager, sel_urls, @as(c_ulong, 9), @as(c_ulong, 1));
    if (urls == null) return error.NativeCallFailed;

    const sel_first = objc.sel_registerName("firstObject") orelse return error.SelectorNotFound;
    const url = objc.msgSendId(urls, sel_first);
    if (url == null) return error.NotFound;

    const sel_path = objc.sel_registerName("path") orelse return error.SelectorNotFound;
    const path_obj = objc.msgSendId(url, sel_path);
    if (path_obj == null) return error.NativeCallFailed;

    const cstr = objc.getNSStringUTF8(path_obj) orelse return error.NativeCallFailed;
    return allocator.dupe(u8, std.mem.span(cstr));
}

/// Plain `sqlite3_open` — RW|CREATE, no pragmas — matching Swift; see the
/// module comment for why `database.zig`'s pragma-applying `Database` would be
/// wrong here.
fn openDatabaseFile(allocator: std.mem.Allocator, path: []const u8) !*sqlite3 {
    if (!builtin.target.os.tag.isDarwin()) return error.UnsupportedPlatform;

    const path_z = try memory.dupeZ(allocator, u8, path);
    defer allocator.free(path_z);

    var handle: ?*sqlite3 = null;
    const rc = sqlite3_open(path_z.ptr, &handle);
    if (rc != SQLITE_OK) {
        // sqlite3_open hands back a handle even on failure, carrying the
        // error detail; read it for the log, then close it.
        if (handle) |h| {
            if (sqlite3_errmsg(h)) |msg| {
                std.log.warn("craft.db open failed: {s}", .{std.mem.span(msg)});
            }
            _ = sqlite3_close(h);
        }
        return error.NativeCallFailed;
    }
    return handle orelse error.NativeCallFailed;
}

// =============================================================================
// Tests — host-only, two tiers. The routing/parsing/shaping tier is pure and
// runs everywhere. The SQLite tier drives `runExecute`/`runQuery` against its
// own `:memory:` handle — real statements, real bindings, exact reply bytes —
// and is gated on Darwin because that is where `build.zig` compiles the
// vendored amalgamation into the ios test artifacts (the code is portable C;
// the gate mirrors the build wiring, not the code). No test reaches
// `ensureDatabase`: on a macOS host that would create the developer's own
// `~/Documents/craft.db`.
// =============================================================================

const testing = std.testing;

test "the declared actions are the ones the handler serves" {
    try testing.expectEqual(@as(usize, 2), capability_actions.len);
    try testing.expectEqualStrings(A.db_execute, capability_actions[0].name);
    try testing.expectEqualStrings(A.db_query, capability_actions[1].name);

    for (capability_actions) |decl| {
        try testing.expectEqual(capabilities.Reply.result, decl.reply);
        try testing.expectEqual(capabilities.ActionStatus.live, decl.status);
    }
}

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against the `case "…":` labels in
    // `CraftApp.swift` in both directions; a prettier spelling would read as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("dbExecute", A.db_execute);
    try testing.expectEqualStrings("dbQuery", A.db_query);
}

test "every declared action routes, every route is declared, none shared" {
    var execute_declared = false;
    var query_declared = false;
    for (capability_actions) |decl| {
        const route = routeFor(decl.name) orelse {
            std.debug.print("declared action '{s}' does not route\n", .{decl.name});
            return error.DeclaredActionDoesNotRoute;
        };
        switch (route) {
            .execute => {
                if (execute_declared) return error.TwoDeclarationsShareARoute;
                execute_declared = true;
            },
            .query => {
                if (query_declared) return error.TwoDeclarationsShareARoute;
                query_declared = true;
            },
        }
    }
    // The other direction: a route with a handler and no declaration is an
    // action the page can call and the manifest denies exists.
    try testing.expect(execute_declared);
    try testing.expect(query_declared);
}

test "an action the namespace does not serve is reported, not ignored" {
    var bridge = DbBridge.init(testing.allocator);
    defer bridge.deinit();

    const strangers = [_][]const u8{
        "noSuchAction",
        // Near misses — casing is how a real typo arrives.
        "dbexecute",
        "DbQuery",
        // The JS surface names, which are not action names.
        "db",
        "execute",
        "query",
        // A Swift neighbor this module must not answer for.
        "startBluetoothScan",
    };
    for (strangers) |name| {
        try testing.expectError(
            bridge_error.BridgeError.UnknownAction,
            bridge.handleMessage(name, "{}"),
        );
    }
}

test "both actions fail validation before any database can be opened" {
    // `{}` has no `sql`, so both error out before `ensureDatabase` runs —
    // which is what makes this safe on a developer's machine (the lazy open
    // would land in ~/Documents/craft.db), and what rules out a routed name
    // whose handler ignores its payload contract.
    var bridge = DbBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(bridge_error.BridgeError.MissingData, bridge.handleMessage(A.db_execute, "{}"));
    try testing.expectError(bridge_error.BridgeError.MissingData, bridge.handleMessage(A.db_query, "{}"));
}

test "a malformed payload is reported as bad JSON, not as a missing field" {
    var bridge = DbBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.InvalidJSON,
        bridge.handleMessage(A.db_execute, "{not json"),
    );
}

test "the gate off means PermissionDenied, never Swift's silence" {
    setEnabled(false);
    defer setEnabled(true);

    var bridge = DbBridge.init(testing.allocator);
    defer bridge.deinit();

    try testing.expectError(
        bridge_error.BridgeError.PermissionDenied,
        bridge.handleMessage(A.db_query, "{}"),
    );
}

fn parseRequestFrom(json: []const u8, out_parsed: *std.json.Parsed(std.json.Value)) !Request {
    out_parsed.* = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    return parseRequest(out_parsed.value);
}

fn expectRequestError(json: []const u8, expected: anyerror) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectError(expected, parseRequest(parsed.value));
}

test "the field names the page sends are the ones that are read" {
    // `body["sql"]` / `body["params"]` in the Swift dispatcher; the same pair
    // rides `d` through the shim hand-off. A rename on either side of the
    // migration would make the two handlers read different payloads.
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"sql\":\"SELECT ?\",\"params\":[\"a\",1,2.5,null,true]}",
        .{},
    );
    defer parsed.deinit();

    const request = try parseRequest(parsed.value);
    try testing.expectEqualStrings("SELECT ?", request.sql);
    try testing.expectEqual(@as(usize, 5), request.params.len);
    try testing.expectEqualStrings("a", request.params[0].string);
    try testing.expectEqual(@as(i64, 1), request.params[1].integer);
    try testing.expectEqual(@as(f64, 2.5), request.params[2].float);
    try testing.expect(request.params[3] == .null);
    try testing.expect(request.params[4].bool);
}

test "absent and null params are no params; anything else is refused" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"sql\":\"SELECT 1\"}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), (try parseRequest(parsed.value)).params.len);

    var parsed_null = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"sql\":\"SELECT 1\",\"params\":null}", .{});
    defer parsed_null.deinit();
    try testing.expectEqual(@as(usize, 0), (try parseRequest(parsed_null.value)).params.len);

    // Swift's `as? [Any]` silently drops a non-array `params` and executes
    // without the values the page sent.
    try expectRequestError("{\"sql\":\"SELECT ?\",\"params\":\"nope\"}", bridge_error.BridgeError.InvalidParameter);
    try expectRequestError("{\"sql\":\"SELECT ?\",\"params\":7}", bridge_error.BridgeError.InvalidParameter);
}

test "an absent or non-string sql is refused rather than hung on" {
    try expectRequestError("{}", bridge_error.BridgeError.MissingData);
    try expectRequestError("{\"params\":[]}", bridge_error.BridgeError.MissingData);
    try expectRequestError("{\"sql\":7}", bridge_error.BridgeError.InvalidParameter);
    try expectRequestError("{\"sql\":null}", bridge_error.BridgeError.InvalidParameter);
}

test "sql with an embedded NUL is refused, not silently truncated" {
    // SQLite stops parsing at the NUL: "SELECT 1\x00; DROP ..." would execute
    // the SELECT and report success for the whole string.
    try expectRequestError("{\"sql\":\"SELECT 1\\u0000DROP TABLE t\"}", bridge_error.BridgeError.InvalidParameter);
}

test "a param SQLite has no honest binding for is refused, not bound as NULL" {
    // Swift binds NULL here — the value the page sent, silently replaced.
    try expectRequestError("{\"sql\":\"SELECT ?\",\"params\":[{}]}", bridge_error.BridgeError.InvalidParameter);
    try expectRequestError("{\"sql\":\"SELECT ?\",\"params\":[[1]]}", bridge_error.BridgeError.InvalidParameter);
}

test "a payload that is not an object is bad JSON, not a missing field" {
    try expectRequestError("[]", bridge_error.BridgeError.InvalidJSON);
    try expectRequestError("\"sql\"", bridge_error.BridgeError.InvalidJSON);
}

test "the execute fragment is the two-field object, keys and order pinned" {
    const fragment = try executeFragment(testing.allocator, 1, 42);
    defer testing.allocator.free(fragment);
    try testing.expectEqualStrings("{\"rowsAffected\":1,\"lastInsertId\":42}", fragment);

    const none = try executeFragment(testing.allocator, 0, 0);
    defer testing.allocator.free(none);
    try testing.expectEqualStrings("{\"rowsAffected\":0,\"lastInsertId\":0}", none);
}

test "the multi-statement detector sees a second statement and not a tail of semicolons" {
    const two: []const u8 = "SELECT 1; SELECT 2";
    try testing.expect(hasTrailingStatement(two, two.ptr + 9));

    const trailing: []const u8 = "SELECT 1;  \n;";
    try testing.expect(!hasTrailingStatement(trailing, trailing.ptr + 9));

    const exact: []const u8 = "SELECT 1";
    try testing.expect(!hasTrailingStatement(exact, exact.ptr + exact.len));
}

// -----------------------------------------------------------------------------
// The SQLite tier: real statements against this test's own :memory: database.
// -----------------------------------------------------------------------------

fn openMemoryDb() !*sqlite3 {
    var handle: ?*sqlite3 = null;
    const rc = sqlite3_open(":memory:", &handle);
    if (rc != SQLITE_OK) {
        if (handle) |h| _ = sqlite3_close(h);
        return error.OpenFailed;
    }
    return handle orelse error.OpenFailed;
}

const Runner = enum { execute, query };

/// Drive a runner through the same parse the handler uses, from the same
/// payload shape the page posts.
fn runFromJson(db: *sqlite3, runner: Runner, payload: []const u8) !RunOutcome {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const request = try parseRequest(parsed.value);
    return switch (runner) {
        .execute => runExecute(testing.allocator, db, request),
        .query => runQuery(testing.allocator, db, request),
    };
}

fn freeOutcome(outcome: RunOutcome) void {
    switch (outcome) {
        .ok => |s| testing.allocator.free(s),
        .failed => |s| testing.allocator.free(s),
    }
}

fn expectOk(outcome: RunOutcome, expected: []const u8) !void {
    switch (outcome) {
        .ok => |fragment| try testing.expectEqualStrings(expected, fragment),
        .failed => |message| {
            std.debug.print("expected ok, got rejection: {s}\n", .{message});
            return error.UnexpectedRejection;
        },
    }
}

test "create, insert with every JSON param type, and read the exact reply back" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    const created = try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (a, b, c, d, e)\"}");
    defer freeOutcome(created);
    try expectOk(created, "{\"rowsAffected\":0,\"lastInsertId\":0}");

    // One param of each bindable JSON type. `true` binds as INTEGER 1 — the
    // NSNumber funnel Swift's `as? Int` implies — and reads back as 1.
    const inserted = try runFromJson(
        db,
        .execute,
        "{\"sql\":\"INSERT INTO t VALUES (?, ?, ?, ?, ?)\",\"params\":[\"text\",42,3.5,null,true]}",
    );
    defer freeOutcome(inserted);
    try expectOk(inserted, "{\"rowsAffected\":1,\"lastInsertId\":1}");

    // The whole observable reply, byte for byte: column keys, a TEXT string,
    // an INTEGER number, a REAL number, a JSON null, the bool as 1.
    const rows = try runFromJson(db, .query, "{\"sql\":\"SELECT a, b, c, d, e FROM t\"}");
    defer freeOutcome(rows);
    try expectOk(rows, "[{\"a\":\"text\",\"b\":42,\"c\":3.5,\"d\":null,\"e\":1}]");
}

test "an empty result set is the bare fragment [], and rows accumulate with commas" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (n)\"}"));

    const empty = try runFromJson(db, .query, "{\"sql\":\"SELECT n FROM t\"}");
    defer freeOutcome(empty);
    try expectOk(empty, "[]");

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"INSERT INTO t VALUES (1)\"}"));
    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"INSERT INTO t VALUES (2)\"}"));

    const rows = try runFromJson(db, .query, "{\"sql\":\"SELECT n FROM t ORDER BY n\"}");
    defer freeOutcome(rows);
    try expectOk(rows, "[{\"n\":1},{\"n\":2}]");
}

test "a BLOB column's key is absent from the row, exactly as Swift's default: break" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    const mixed = try runFromJson(db, .query, "{\"sql\":\"SELECT 1 AS n, x'00ff' AS b\"}");
    defer freeOutcome(mixed);
    try expectOk(mixed, "[{\"n\":1}]");

    // A row that is all BLOBs is `{}` — present, and empty.
    const all_blob = try runFromJson(db, .query, "{\"sql\":\"SELECT x'00' AS b\"}");
    defer freeOutcome(all_blob);
    try expectOk(all_blob, "[{}]");
}

test "an INTEGER beyond 32 bits survives — Swift's column_int wrapped it" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (n)\"}"));
    freeOutcome(try runFromJson(
        db,
        .execute,
        "{\"sql\":\"INSERT INTO t VALUES (?)\",\"params\":[3000000000]}",
    ));

    const rows = try runFromJson(db, .query, "{\"sql\":\"SELECT n FROM t\"}");
    defer freeOutcome(rows);
    try expectOk(rows, "[{\"n\":3000000000}]");
}

test "a TEXT value with an embedded NUL rides the round trip whole" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (a)\"}"));
    // The NUL is the point: length+TRANSIENT on the way in, column_bytes on
    // the way out. Swift stored a truncated "a" and read back a truncated "a".
    freeOutcome(try runFromJson(
        db,
        .execute,
        "{\"sql\":\"INSERT INTO t VALUES (?)\",\"params\":[\"a\\u0000b\"]}",
    ));

    const rows = try runFromJson(db, .query, "{\"sql\":\"SELECT a FROM t\"}");
    defer freeOutcome(rows);
    try expectOk(rows, "[{\"a\":\"a\\u0000b\"}]");
}

test "a column name that needs escaping cannot break the reply" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    // The alias is page-controlled and lands as a JSON key.
    const rows = try runFromJson(db, .query, "{\"sql\":\"SELECT 1 AS \\\"we\\\"\\\"ird\\\"\"}");
    defer freeOutcome(rows);
    try expectOk(rows, "[{\"we\\\"ird\":1}]");
}

test "bad SQL rejects with SQLite's own words, not a fixed code string" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    const outcome = try runFromJson(db, .query, "{\"sql\":\"SELECT * FROM no_such_table\"}");
    defer freeOutcome(outcome);
    switch (outcome) {
        .ok => return error.ExpectedRejection,
        .failed => |message| {
            // "no such table: no_such_table" is what the page displays; the
            // table name in the message is the diagnostic contract.
            try testing.expect(std.mem.indexOf(u8, message, "no such table") != null);
            try testing.expect(std.mem.indexOf(u8, message, "no_such_table") != null);
        },
    }
}

test "dbExecute of a SELECT that returns rows rejects, as Swift's does" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    // step yields SQLITE_ROW, not SQLITE_DONE — bug-compatible rejection.
    const outcome = try runFromJson(db, .execute, "{\"sql\":\"SELECT 1\"}");
    defer freeOutcome(outcome);
    try testing.expect(outcome == .failed);
}

test "a non-SELECT through dbQuery executes and resolves []" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    const created = try runFromJson(db, .query, "{\"sql\":\"CREATE TABLE made_by_query (n)\"}");
    defer freeOutcome(created);
    try expectOk(created, "[]");

    // And it really executed — the table exists now.
    const proof = try runFromJson(db, .query, "{\"sql\":\"SELECT n FROM made_by_query\"}");
    defer freeOutcome(proof);
    try expectOk(proof, "[]");
}

test "multi-statement SQL is refused, not silently truncated to its first statement" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (n)\"}"));

    // Swift executes the SELECT and silently discards the DROP. Neither
    // running half the payload nor running all of it behind prepare_v2's back
    // is honest; the page gets a refusal it can see.
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        runFromJson(db, .execute, "{\"sql\":\"SELECT 1; DROP TABLE t\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        runFromJson(db, .query, "{\"sql\":\"SELECT 1; SELECT 2\"}"),
    );

    // A trailing semicolon is one statement, not two.
    const one = try runFromJson(db, .execute, "{\"sql\":\"INSERT INTO t VALUES (1); \"}");
    defer freeOutcome(one);
    try expectOk(one, "{\"rowsAffected\":1,\"lastInsertId\":1}");
}

test "SQL containing no statement is refused, not stepped into SQLITE_MISUSE" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        runFromJson(db, .execute, "{\"sql\":\"\"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        runFromJson(db, .execute, "{\"sql\":\"   \"}"),
    );
    try testing.expectError(
        bridge_error.BridgeError.InvalidParameter,
        runFromJson(db, .query, "{\"sql\":\";\"}"),
    );
}

test "a param that does not bind rejects — Swift ignored the SQLITE_RANGE" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    // Two params, one slot: the second bind fails and the failure is said,
    // where Swift silently discarded the value the page sent.
    const outcome = try runFromJson(db, .query, "{\"sql\":\"SELECT ?1 AS v\",\"params\":[1,2]}");
    defer freeOutcome(outcome);
    try testing.expect(outcome == .failed);
}

test "a stored infinity rejects with Swift's serialization message, not broken JSON" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (x)\"}"));
    // 9e999 overflows to +Inf, which SQLite stores and JSON cannot spell.
    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"INSERT INTO t VALUES (9e999)\"}"));

    const outcome = try runFromJson(db, .query, "{\"sql\":\"SELECT x FROM t\"}");
    defer freeOutcome(outcome);
    switch (outcome) {
        .ok => return error.ExpectedRejection,
        .failed => |message| try testing.expectEqualStrings("Native result could not be serialized", message),
    }
}

test "an empty-string param binds as the empty string, not as NULL" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const db = try openMemoryDb();
    defer _ = sqlite3_close(db);

    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"CREATE TABLE t (a)\"}"));
    freeOutcome(try runFromJson(db, .execute, "{\"sql\":\"INSERT INTO t VALUES (?)\",\"params\":[\"\"]}"));

    // "" and NULL are different answers and must stay different.
    const rows = try runFromJson(db, .query, "{\"sql\":\"SELECT a FROM t\"}");
    defer freeOutcome(rows);
    try expectOk(rows, "[{\"a\":\"\"}]");
}
