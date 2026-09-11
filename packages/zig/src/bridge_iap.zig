const std = @import("std");
const builtin = @import("builtin");
const bridge_error = @import("bridge_error.zig");

const BridgeError = bridge_error.BridgeError;

/// In-App Purchases bridge with full StoreKit transaction observer.
///
/// What's wired:
///   - `isAvailable`         — `+[SKPaymentQueue canMakePayments]`
///   - `getProducts`         — `SKProductsRequest` async; results come
///                             through the delegate and arrive in JS
///                             as a `craft:iap:productsLoaded` event
///   - `purchase`            — `SKPayment` + `-[SKPaymentQueue addPayment:]`;
///                             outcome via `craft:iap:purchased|failed`
///   - `restorePurchases`    — `-restoreCompletedTransactions`;
///                             each restored transaction fires
///                             `craft:iap:restored`
///   - `finishTransaction`   — `-finishTransaction:` (required for
///                             non-consumables to stop redelivery)
///   - `getReceiptData`      — `bundle.appStoreReceiptURL` → base64
///
/// Observer lifecycle:
///   On the first JS message we install a singleton `CraftIAPObserver`
///   instance as both the payment-queue observer and the products
///   request delegate. Each callback maps to a JS event with the
///   shape documented in `iap.ts`.
pub const IAPBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        // Lazy install — apps that never touch IAP shouldn't pay for
        // observer registration.
        installObserver();

        if (std.mem.eql(u8, action, "isAvailable")) {
            try self.isAvailable();
        } else if (std.mem.eql(u8, action, "getProducts")) {
            try self.getProducts(data);
        } else if (std.mem.eql(u8, action, "purchase")) {
            try self.purchase(data);
        } else if (std.mem.eql(u8, action, "restorePurchases")) {
            try self.restorePurchases();
        } else if (std.mem.eql(u8, action, "finishTransaction")) {
            try self.finishTransaction(data);
        } else if (std.mem.eql(u8, action, "getReceiptData")) {
            try self.getReceiptData();
        } else {
            return BridgeError.UnknownAction;
        }
    }

    fn isAvailable(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "isAvailable", "{\"value\":false}");
            return;
        }
        const macos = @import("macos.zig");
        const SKPaymentQueue = macos.getClass("SKPaymentQueue");
        if (@intFromPtr(SKPaymentQueue) == 0) {
            bridge_error.sendResultToJS(self.allocator, "isAvailable", "{\"value\":false}");
            return;
        }
        const can_make = macos.msgSendBool(SKPaymentQueue, "canMakePayments");
        const json = if (can_make) "{\"value\":true}" else "{\"value\":false}";
        bridge_error.sendResultToJS(self.allocator, "isAvailable", json);
    }

    fn getProducts(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getProducts", "{\"products\":[],\"started\":false}");
            return;
        }

        const ParseShape = struct { ids: []const []const u8 = &[_][]const u8{} };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value.ids.len == 0) {
            bridge_error.sendResultToJS(self.allocator, "getProducts", "{\"products\":[],\"started\":false}");
            return;
        }

        const macos = @import("macos.zig");
        const SKProductsRequest = macos.getClass("SKProductsRequest");
        if (@intFromPtr(SKProductsRequest) == 0) {
            bridge_error.sendResultToJS(self.allocator, "getProducts", "{\"products\":[],\"started\":false}");
            return;
        }

        // Build NSSet<NSString*> of identifiers.
        const NSMutableSet = macos.getClass("NSMutableSet");
        const set = macos.msgSend0(NSMutableSet, "set");
        for (parsed.value.ids) |id| {
            const ns_id = macos.createNSString(id);
            _ = macos.msgSend1(set, "addObject:", ns_id);
        }

        // Stash the request in a module-level slot so it doesn't get
        // released before the delegate callback fires. Apple's API
        // requires the request to outlive its async callback; without
        // this, the request gets dealloc'd as soon as we return and
        // the delegate never runs.
        const req_alloc = macos.msgSend0(SKProductsRequest, "alloc");
        const req = macos.msgSend1(req_alloc, "initWithProductIdentifiers:", set);
        if (active_request) |old| _ = macos.msgSend0(old, "release");
        active_request = req;

        _ = macos.msgSend1(req, "setDelegate:", getObserver());
        _ = macos.msgSend0(req, "start");

        // Resolve the JS promise immediately with `started:true`. The
        // actual product list arrives via `craft:iap:productsLoaded`.
        bridge_error.sendResultToJS(self.allocator, "getProducts", "{\"products\":[],\"started\":true}");
    }

    fn purchase(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "purchase", "{\"queued\":false,\"reason\":\"not supported\"}");
            return;
        }

        const ParseShape = struct { productId: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value.productId.len == 0) return BridgeError.MissingData;

        // SKPayment requires an SKProduct, not a bare id. We resolve
        // by id from the cache populated by getProducts. Apps must
        // call getProducts() first — that's also good UX (you want
        // to show the price before charging the user).
        const product = lookupCachedProduct(parsed.value.productId);
        if (product == null) {
            var buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"queued\":false,\"productId\":\"{s}\",\"reason\":\"call getProducts() with this id first; product not in cache\"}}", .{parsed.value.productId});
            bridge_error.sendResultToJS(self.allocator, "purchase", json);
            return;
        }

        const macos = @import("macos.zig");
        const SKPayment = macos.getClass("SKPayment");
        const payment = macos.msgSend1(SKPayment, "paymentWithProduct:", product.?);
        const SKPaymentQueue = macos.getClass("SKPaymentQueue");
        const queue = macos.msgSend0(SKPaymentQueue, "defaultQueue");
        _ = macos.msgSend1(queue, "addPayment:", payment);

        var buf: [256]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"queued\":true,\"productId\":\"{s}\"}}", .{parsed.value.productId});
        bridge_error.sendResultToJS(self.allocator, "purchase", json);
    }

    fn restorePurchases(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "restorePurchases", "{\"ok\":false}");
            return;
        }
        const macos = @import("macos.zig");
        const SKPaymentQueue = macos.getClass("SKPaymentQueue");
        const queue = macos.msgSend0(SKPaymentQueue, "defaultQueue");
        _ = macos.msgSend0(queue, "restoreCompletedTransactions");
        bridge_error.sendResultToJS(self.allocator, "restorePurchases", "{\"ok\":true}");
    }

    fn finishTransaction(self: *Self, data: []const u8) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "finishTransaction", "{\"ok\":false}");
            return;
        }

        const ParseShape = struct { transactionId: []const u8 = "" };
        const parsed = std.json.parseFromSlice(ParseShape, self.allocator, data, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return BridgeError.InvalidJSON;
        defer parsed.deinit();
        if (parsed.value.transactionId.len == 0) return BridgeError.MissingData;

        const txn = lookupCachedTransaction(parsed.value.transactionId);
        if (txn == null) {
            var buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"transactionId\":\"{s}\",\"reason\":\"unknown transaction\"}}", .{parsed.value.transactionId});
            bridge_error.sendResultToJS(self.allocator, "finishTransaction", json);
            return;
        }

        const macos = @import("macos.zig");
        const SKPaymentQueue = macos.getClass("SKPaymentQueue");
        const queue = macos.msgSend0(SKPaymentQueue, "defaultQueue");
        _ = macos.msgSend1(queue, "finishTransaction:", txn.?);
        removeCachedTransaction(parsed.value.transactionId);

        bridge_error.sendResultToJS(self.allocator, "finishTransaction", "{\"ok\":true}");
    }

    fn getReceiptData(self: *Self) !void {
        if (builtin.os.tag != .macos) {
            bridge_error.sendResultToJS(self.allocator, "getReceiptData", "{\"receipt\":null}");
            return;
        }
        const macos = @import("macos.zig");
        const NSBundle = macos.getClass("NSBundle");
        const bundle = macos.msgSend0(NSBundle, "mainBundle");
        const receipt_url = macos.msgSend0(bundle, "appStoreReceiptURL");
        if (@intFromPtr(receipt_url) == 0) {
            bridge_error.sendResultToJS(self.allocator, "getReceiptData", "{\"receipt\":null}");
            return;
        }
        const NSData = macos.getClass("NSData");
        const data = macos.msgSend1(NSData, "dataWithContentsOfURL:", receipt_url);
        if (@intFromPtr(data) == 0) {
            bridge_error.sendResultToJS(self.allocator, "getReceiptData", "{\"receipt\":null}");
            return;
        }
        const b64 = macos.msgSend1(data, "base64EncodedStringWithOptions:", @as(c_ulong, 0));
        const utf8 = macos.msgSend0(b64, "UTF8String");
        if (@intFromPtr(utf8) == 0) {
            bridge_error.sendResultToJS(self.allocator, "getReceiptData", "{\"receipt\":null}");
            return;
        }
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"receipt\":\"");
        try buf.appendSlice(self.allocator, slice);
        try buf.appendSlice(self.allocator, "\"}");
        const owned = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(owned);
        bridge_error.sendResultToJS(self.allocator, "getReceiptData", owned);
    }
};

// =============================================================================
// SKPaymentTransactionObserver + SKProductsRequestDelegate
//
// The objc runtime constructs a singleton `CraftIAPObserver` class on
// first install and registers it as both the queue observer and the
// products delegate. Module-level state below holds the active product
// + transaction caches keyed by their stable identifiers.
// =============================================================================

var observer_installed: bool = false;
var observer_instance: @import("macos.zig").objc.id = null;
var active_request: @import("macos.zig").objc.id = null;
var product_cache: std.StringHashMapUnmanaged(@import("macos.zig").objc.id) = .empty;
var transaction_cache: std.StringHashMapUnmanaged(@import("macos.zig").objc.id) = .empty;

fn installObserver() void {
    if (observer_installed) return;
    if (builtin.target.os.tag != .macos) return;

    const macos = @import("macos.zig");
    const objc = macos.objc;

    const NSObject = macos.getClass("NSObject");
    const class_name = "CraftIAPObserver";
    var cls = objc.objc_getClass(class_name);
    if (cls == null) {
        cls = objc.objc_allocateClassPair(NSObject, class_name, 0);
        if (cls == null) return;

        // SKPaymentTransactionObserver
        addMethod(cls, "paymentQueue:updatedTransactions:", &paymentQueueUpdatedTransactions);
        addMethod(cls, "paymentQueue:restoreCompletedTransactionsFinishedWithError:", &paymentQueueRestoreFinishedWithError);

        // SKProductsRequestDelegate
        addMethod(cls, "productsRequest:didReceiveResponse:", &productsRequestDidReceiveResponse);
        addMethod(cls, "request:didFailWithError:", &requestDidFailWithError);

        objc.objc_registerClassPair(cls);
    }
    observer_instance = macos.msgSend0(macos.msgSend0(cls, "alloc"), "init");

    const SKPaymentQueue = macos.getClass("SKPaymentQueue");
    if (@intFromPtr(SKPaymentQueue) != 0) {
        const queue = macos.msgSend0(SKPaymentQueue, "defaultQueue");
        _ = macos.msgSend1(queue, "addTransactionObserver:", observer_instance);
    }

    observer_installed = true;
    if (comptime builtin.mode == .Debug) {
        std.debug.print("[IAP] Installed StoreKit observer\n", .{});
    }
}

fn getObserver() @import("macos.zig").objc.id {
    if (!observer_installed) installObserver();
    return observer_instance;
}

fn addMethod(cls: @import("macos.zig").objc.Class, sel_name: [*:0]const u8, imp: *const anyopaque) void {
    const macos = @import("macos.zig");
    _ = macos.objc.class_addMethod(cls, macos.sel(sel_name), @ptrCast(@constCast(imp)), "v@:@@");
}

// =============================================================================
// SKPaymentTransactionObserver callbacks
// =============================================================================

export fn paymentQueueUpdatedTransactions(
    _: @import("macos.zig").objc.id,
    _: @import("macos.zig").objc.SEL,
    _: @import("macos.zig").objc.id, // queue
    transactions: @import("macos.zig").objc.id, // NSArray<SKPaymentTransaction *>
) callconv(.c) void {
    const macos = @import("macos.zig");
    if (@intFromPtr(transactions) == 0) return;

    const Fn = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_ulong;
    const f: Fn = @ptrCast(&macos.objc.objc_msgSend);
    const count = f(transactions, macos.sel("count"));

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const txn = macos.msgSend1(transactions, "objectAtIndex:", i);
        if (@intFromPtr(txn) == 0) continue;

        // -transactionState returns SKPaymentTransactionState:
        //   0=purchasing, 1=purchased, 2=failed, 3=restored, 4=deferred
        const StateFn = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_long;
        const sf: StateFn = @ptrCast(&macos.objc.objc_msgSend);
        const state = sf(txn, macos.sel("transactionState"));

        switch (state) {
            1 => emitTransactionEvent(txn, "craft:iap:purchased"),
            2 => emitFailureEvent(txn),
            3 => emitTransactionEvent(txn, "craft:iap:restored"),
            else => {}, // purchasing/deferred — apps don't care
        }
    }
}

export fn paymentQueueRestoreFinishedWithError(
    _: @import("macos.zig").objc.id,
    _: @import("macos.zig").objc.SEL,
    _: @import("macos.zig").objc.id, // queue
    err: @import("macos.zig").objc.id,
) callconv(.c) void {
    if (@intFromPtr(err) == 0) return;
    const macos = @import("macos.zig");
    const desc = macos.msgSend0(err, "localizedDescription");
    if (@intFromPtr(desc) == 0) return;
    const utf8 = macos.msgSend0(desc, "UTF8String");
    if (@intFromPtr(utf8) == 0) return;
    const msg = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    script.appendSlice(std.heap.c_allocator, "if (window.dispatchEvent) window.dispatchEvent(new CustomEvent('craft:iap:failed', { detail: { productId: '', message: '") catch return;
    appendEscaped(&script, msg);
    script.appendSlice(std.heap.c_allocator, "' } }));") catch return;
    script.append(std.heap.c_allocator, 0) catch return;
    evalJS(script.items);
}

export fn productsRequestDidReceiveResponse(
    _: @import("macos.zig").objc.id,
    _: @import("macos.zig").objc.SEL,
    _: @import("macos.zig").objc.id, // request
    response: @import("macos.zig").objc.id,
) callconv(.c) void {
    const macos = @import("macos.zig");
    if (@intFromPtr(response) == 0) return;

    const products = macos.msgSend0(response, "products");
    if (@intFromPtr(products) == 0) return;

    const Fn = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_ulong;
    const f: Fn = @ptrCast(&macos.objc.objc_msgSend);
    const count = f(products, macos.sel("count"));

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    script.appendSlice(std.heap.c_allocator, "if (window.dispatchEvent) window.dispatchEvent(new CustomEvent('craft:iap:productsLoaded', { detail: { products: [") catch return;

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        if (i > 0) script.append(std.heap.c_allocator, ',') catch return;
        const product = macos.msgSend1(products, "objectAtIndex:", i);
        if (@intFromPtr(product) == 0) continue;

        // Cache the SKProduct keyed by productIdentifier so purchase()
        // can find it. SKProductsResponse releases its product
        // references when we return; we explicitly retain to keep the
        // SKProduct alive in the cache.
        const id_ns = macos.msgSend0(product, "productIdentifier");
        const id_utf8 = macos.msgSend0(id_ns, "UTF8String");
        const id_slice = std.mem.span(@as([*:0]const u8, @ptrCast(id_utf8)));
        const id_owned = std.heap.c_allocator.dupe(u8, id_slice) catch continue;

        _ = macos.msgSend0(product, "retain");
        product_cache.put(std.heap.c_allocator, id_owned, product) catch {
            std.heap.c_allocator.free(id_owned);
            _ = macos.msgSend0(product, "release");
            continue;
        };

        appendProductJson(&script, product);
    }
    script.appendSlice(std.heap.c_allocator, "] } }));") catch return;
    script.append(std.heap.c_allocator, 0) catch return;
    evalJS(script.items);
}

export fn requestDidFailWithError(
    _: @import("macos.zig").objc.id,
    _: @import("macos.zig").objc.SEL,
    _: @import("macos.zig").objc.id, // request
    err: @import("macos.zig").objc.id,
) callconv(.c) void {
    const macos = @import("macos.zig");
    if (@intFromPtr(err) == 0) return;
    const desc = macos.msgSend0(err, "localizedDescription");
    if (@intFromPtr(desc) == 0) return;
    const utf8 = macos.msgSend0(desc, "UTF8String");
    if (@intFromPtr(utf8) == 0) return;
    const msg = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    script.appendSlice(std.heap.c_allocator, "if (window.dispatchEvent) window.dispatchEvent(new CustomEvent('craft:iap:productsLoaded', { detail: { products: [], error: '") catch return;
    appendEscaped(&script, msg);
    script.appendSlice(std.heap.c_allocator, "' } }));") catch return;
    script.append(std.heap.c_allocator, 0) catch return;
    evalJS(script.items);
}

// =============================================================================
// Cache + JS helpers
// =============================================================================

fn lookupCachedProduct(id: []const u8) ?@import("macos.zig").objc.id {
    return product_cache.get(id);
}

fn lookupCachedTransaction(id: []const u8) ?@import("macos.zig").objc.id {
    return transaction_cache.get(id);
}

fn removeCachedTransaction(id: []const u8) void {
    if (transaction_cache.fetchRemove(id)) |entry| {
        const macos = @import("macos.zig");
        _ = macos.msgSend0(entry.value, "release");
        std.heap.c_allocator.free(entry.key);
    }
}

fn emitTransactionEvent(txn: @import("macos.zig").objc.id, event_name: []const u8) void {
    const macos = @import("macos.zig");

    const payment = macos.msgSend0(txn, "payment");
    if (@intFromPtr(payment) == 0) return;
    const product_id_ns = macos.msgSend0(payment, "productIdentifier");
    const product_id_utf8 = macos.msgSend0(product_id_ns, "UTF8String");
    if (@intFromPtr(product_id_utf8) == 0) return;
    const product_id = std.mem.span(@as([*:0]const u8, @ptrCast(product_id_utf8)));

    const txn_id_ns = macos.msgSend0(txn, "transactionIdentifier");
    var txn_id: []const u8 = "";
    if (@intFromPtr(txn_id_ns) != 0) {
        const utf8 = macos.msgSend0(txn_id_ns, "UTF8String");
        if (@intFromPtr(utf8) != 0) {
            txn_id = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
        }
    }

    if (txn_id.len > 0) {
        const id_owned = std.heap.c_allocator.dupe(u8, txn_id) catch return;
        _ = macos.msgSend0(txn, "retain");
        transaction_cache.put(std.heap.c_allocator, id_owned, txn) catch {
            std.heap.c_allocator.free(id_owned);
            _ = macos.msgSend0(txn, "release");
            return;
        };
    }

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    script.appendSlice(std.heap.c_allocator, "if (window.dispatchEvent) window.dispatchEvent(new CustomEvent('") catch return;
    script.appendSlice(std.heap.c_allocator, event_name) catch return;
    script.appendSlice(std.heap.c_allocator, "', { detail: { productId: '") catch return;
    appendEscaped(&script, product_id);
    script.appendSlice(std.heap.c_allocator, "', transactionId: '") catch return;
    appendEscaped(&script, txn_id);
    script.appendSlice(std.heap.c_allocator, "' } }));") catch return;
    script.append(std.heap.c_allocator, 0) catch return;
    evalJS(script.items);
}

fn emitFailureEvent(txn: @import("macos.zig").objc.id) void {
    const macos = @import("macos.zig");
    const payment = macos.msgSend0(txn, "payment");
    var product_id: []const u8 = "";
    if (@intFromPtr(payment) != 0) {
        const id_ns = macos.msgSend0(payment, "productIdentifier");
        if (@intFromPtr(id_ns) != 0) {
            const utf8 = macos.msgSend0(id_ns, "UTF8String");
            if (@intFromPtr(utf8) != 0) product_id = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
        }
    }

    const err = macos.msgSend0(txn, "error");
    var msg: []const u8 = "";
    var code: c_long = 0;
    if (@intFromPtr(err) != 0) {
        const desc = macos.msgSend0(err, "localizedDescription");
        if (@intFromPtr(desc) != 0) {
            const utf8 = macos.msgSend0(desc, "UTF8String");
            if (@intFromPtr(utf8) != 0) msg = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
        }
        const CodeFn = *const fn (macos.objc.id, macos.objc.SEL) callconv(.c) c_long;
        const cf: CodeFn = @ptrCast(&macos.objc.objc_msgSend);
        code = cf(err, macos.sel("code"));
    }

    // Failed transactions need finishing right away — Apple wants
    // them off the queue so they don't redeliver.
    const SKPaymentQueue = macos.getClass("SKPaymentQueue");
    const queue = macos.msgSend0(SKPaymentQueue, "defaultQueue");
    _ = macos.msgSend1(queue, "finishTransaction:", txn);

    var script: std.ArrayListUnmanaged(u8) = .empty;
    defer script.deinit(std.heap.c_allocator);
    var code_buf: [32]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch "0";
    script.appendSlice(std.heap.c_allocator, "if (window.dispatchEvent) window.dispatchEvent(new CustomEvent('craft:iap:failed', { detail: { productId: '") catch return;
    appendEscaped(&script, product_id);
    script.appendSlice(std.heap.c_allocator, "', code: ") catch return;
    script.appendSlice(std.heap.c_allocator, code_str) catch return;
    script.appendSlice(std.heap.c_allocator, ", message: '") catch return;
    appendEscaped(&script, msg);
    script.appendSlice(std.heap.c_allocator, "' } }));") catch return;
    script.append(std.heap.c_allocator, 0) catch return;
    evalJS(script.items);
}

fn appendProductJson(buf: *std.ArrayListUnmanaged(u8), product: @import("macos.zig").objc.id) void {
    const macos = @import("macos.zig");
    const allocator = std.heap.c_allocator;

    buf.append(allocator, '{') catch return;
    appendStringField(buf, "id", macos.msgSend0(product, "productIdentifier"), true);
    appendStringField(buf, "title", macos.msgSend0(product, "localizedTitle"), false);
    appendStringField(buf, "description", macos.msgSend0(product, "localizedDescription"), false);

    // Localized price uses NSNumberFormatter scoped to the product's
    // priceLocale — same way Apple's docs recommend formatting prices.
    const price_num = macos.msgSend0(product, "price");
    const locale = macos.msgSend0(product, "priceLocale");
    if (@intFromPtr(price_num) != 0 and @intFromPtr(locale) != 0) {
        const NSNumberFormatter = macos.getClass("NSNumberFormatter");
        const fmt = macos.msgSend0(macos.msgSend0(NSNumberFormatter, "alloc"), "init");
        // NSNumberFormatterCurrencyStyle = 2
        _ = macos.msgSend1(fmt, "setNumberStyle:", @as(c_long, 2));
        _ = macos.msgSend1(fmt, "setLocale:", locale);
        const localized = macos.msgSend1(fmt, "stringFromNumber:", price_num);
        appendStringField(buf, "localizedPrice", localized, false);

        const raw = macos.msgSend0(price_num, "stringValue");
        appendStringField(buf, "price", raw, false);
    }
    if (@intFromPtr(locale) != 0) {
        const code_key = macos.createNSString("NSLocaleCurrencyCode");
        const currency = macos.msgSend1(locale, "objectForKey:", code_key);
        appendStringField(buf, "currency", currency, false);
    }

    buf.append(allocator, '}') catch return;
}

fn appendStringField(buf: *std.ArrayListUnmanaged(u8), key: []const u8, ns_str: @import("macos.zig").objc.id, first: bool) void {
    const allocator = std.heap.c_allocator;
    if (!first) buf.append(allocator, ',') catch return;
    buf.append(allocator, '"') catch return;
    buf.appendSlice(allocator, key) catch return;
    buf.appendSlice(allocator, "\":\"") catch return;
    if (@intFromPtr(ns_str) != 0) {
        const macos = @import("macos.zig");
        const utf8 = macos.msgSend0(ns_str, "UTF8String");
        if (@intFromPtr(utf8) != 0) {
            const slice = std.mem.span(@as([*:0]const u8, @ptrCast(utf8)));
            appendEscaped(buf, slice);
        }
    }
    buf.append(allocator, '"') catch return;
}

fn appendEscaped(buf: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    const allocator = std.heap.c_allocator;
    for (s) |b| {
        switch (b) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return,
            '\\' => buf.appendSlice(allocator, "\\\\") catch return,
            '\n' => buf.appendSlice(allocator, "\\n") catch return,
            '\r' => buf.appendSlice(allocator, "\\r") catch return,
            '\t' => buf.appendSlice(allocator, "\\t") catch return,
            else => buf.append(allocator, b) catch return,
        }
    }
}

fn evalJS(script: []const u8) void {
    const macos = @import("macos.zig");
    const webview = macos.getGlobalWebView() orelse return;
    const NSString = macos.getClass("NSString");
    const js = macos.msgSend1(NSString, "stringWithUTF8String:", @as([*:0]const u8, @ptrCast(script.ptr)));
    _ = macos.msgSend2(webview, "evaluateJavaScript:completionHandler:", js, @as(?*anyopaque, null));
}
