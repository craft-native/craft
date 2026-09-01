//! The `mobile` namespace's three Vision actions: `classifyImage`,
//! `detectObjects` and `recognizeText`.
//!
//! All three were unservable until `ios_config.zig` landed — their Swift arms
//! are conditional on `config.enableMLKit`, and the dispatcher's guard has no
//! `else`, so a page calling one in an app that left the flag off gets a
//! promise that never settles. `ios_dispatch.route` now refuses on the flag
//! before this module runs, and what is left is Swift's own behaviour.
//!
//! ## Why these three are the cheapest remaining tier
//!
//! No permission, no presented UI, no delegate, no long-lived subscription.
//! A page hands over a base64 image and gets an array back. The whole
//! interaction is a pure function of its input, which also makes it the one
//! tier a fixture can prove end to end without a human tapping anything: the
//! test page draws a word on a `<canvas>`, sends `toDataURL`'s payload, and
//! asserts the word comes back.
//!
//! ## `detectObjects` detects animals
//!
//! `CraftApp.swift:4656` builds a `VNRecognizeAnimalsRequest`, whose entire
//! vocabulary is cat and dog. The action is named `detectObjects` and its TS
//! signature promises objects, but what it does is find pets. That is carried
//! across unchanged and written down here rather than quietly widened to
//! `VNDetectRectanglesRequest` or a Core ML model: the reply shape, the label
//! strings and the empty result for a photo of a chair are all observable
//! behaviour that a page may already depend on. Renaming the action or
//! changing the request is a decision for whoever owns the API, not a
//! translation detail.
//!
//! ## Threading, and the one place a shortcut was refused
//!
//! Swift performs every request on `DispatchQueue.global(qos: .userInitiated)`,
//! and so does this. Running Vision inline on the main thread would have been
//! materially less code — no context to hand across, no retain/release pair —
//! and would freeze the UI for as long as recognition takes, which for
//! `.accurate` text on a full-page image is comfortably visible. The author of
//! the Swift moved it off the main thread deliberately; a port that quietly
//! moved it back would be trading the user's responsiveness for the porter's
//! convenience.
//!
//! The hand-across is a heap-allocated `Work`, passed straight to
//! `dispatch_async_f` as its context pointer, rather than the index-into-a-pool
//! shape `ios_events` uses. The pool exists there because a location stream can
//! burst faster than the main queue drains; a Vision request is user-initiated
//! and arrives one at a time, so a bounded pool would only add an exhaustion
//! path nothing reaches. `ios_async`'s ticket pool still bounds the number of
//! outstanding *replies*, which is the resource that actually needs a ceiling.
//!
//! ## Two of the three do not work on a simulator
//!
//! `VNClassifyImageRequest` and `VNRecognizeAnimalsRequest` are Core ML
//! backed, and the simulator cannot build an inference context for either —
//! they fail with "Failed to create espresso context" and "Could not create
//! inference context" respectively. `VNRecognizeTextRequest` uses a different
//! path and works there.
//!
//! That is a property of the simulator, not of this module, and the right
//! response is the one below: report the failure with the framework's own
//! description in the log and settle the page's promise with
//! `NATIVE_CALL_FAILED`. An empty array would have been the tempting answer
//! and the wrong one — "I found no cats" and "I could not look" are different
//! facts, and only one of them is true. The fixture asserts that both actions
//! *answer*, by either route, because answering at all is what this phase
//! changes: their Swift arms are gated with no `else`.
//!
//! The request handler is built on the calling thread and retained across the
//! hop. `[UIImage imageWithData:]` returns an autoreleased object, and the main
//! runloop drains its pool at the end of the turn — so a `CGImage` merely
//! borrowed from it would be freed while the background queue was still reading
//! it. `VNImageRequestHandler` retains the image it is initialised with, so
//! retaining the handler is enough to keep the pixels alive, and it is released
//! on every path out of the background function.

const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const bridge_error = @import("bridge_error.zig");
const objc_runtime = @import("objc_runtime.zig");
const ios_async = @import("ios_async.zig");

const objc = objc_runtime.objc;
const BridgeError = bridge_error.BridgeError;
const Id = ?*anyopaque;
const is_darwin = builtin.target.os.tag.isDarwin();

pub const A = struct {
    pub const classify_image = "classifyImage";
    pub const detect_objects = "detectObjects";
    pub const recognize_text = "recognizeText";
};

/// `.result`: each action resolves with an array or rejects, and the injected
/// JS returns a promise the page awaits.
pub const capability_actions = [_]capabilities.ActionDecl{
    .{ .name = A.classify_image, .reply = .result },
    .{ .name = A.detect_objects, .reply = .result },
    .{ .name = A.recognize_text, .reply = .result },
};

/// Which request to build, and how to shape what it returns.
const Kind = enum {
    classify,
    detect,
    recognize,

    fn action(self: Kind) []const u8 {
        return switch (self) {
            .classify => A.classify_image,
            .detect => A.detect_objects,
            .recognize => A.recognize_text,
        };
    }

    /// The Vision request class. `detect` is `VNRecognizeAnimalsRequest` on
    /// purpose — see the module comment.
    fn className(self: Kind) [*:0]const u8 {
        return switch (self) {
            .classify => "VNClassifyImageRequest",
            .detect => "VNRecognizeAnimalsRequest",
            .recognize => "VNRecognizeTextRequest",
        };
    }
};

/// Swift keeps the first ten classifications and all of everything else.
///
/// `observations.prefix(10)` at `CraftApp.swift:4632`. Vision returns well over
/// a thousand classifications for a single image, ordered by confidence, so the
/// cap is what keeps the reply from being a megabyte of labels with confidence
/// 0.0001. It applies to `classifyImage` alone.
const max_classifications = 10;

pub const VisionBridge = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn handleMessage(self: *Self, action: []const u8, data: []const u8) !void {
        const kind: Kind = if (std.mem.eql(u8, action, A.classify_image))
            .classify
        else if (std.mem.eql(u8, action, A.detect_objects))
            .detect
        else if (std.mem.eql(u8, action, A.recognize_text))
            .recognize
        else
            return BridgeError.UnknownAction;

        try self.perform(kind, data);
    }

    /// Decode the image, build the request, and hand both to a background
    /// queue.
    ///
    /// Everything that can fail synchronously does so here, before a ticket is
    /// taken: a bad payload, an image Vision cannot read, a process with no
    /// Vision framework. That ordering matters — a ticket acquired and then
    /// dropped on an early return is a slot that stays in use until the pool
    /// wraps, and the pool is what bounds concurrent replies.
    fn perform(self: *Self, kind: Kind, data: []const u8) !void {
        if (!is_darwin) return BridgeError.PlatformNotSupported;

        const base64 = try readImageField(self.allocator, data);
        defer self.allocator.free(base64);

        const handler = try makeRequestHandler(self.allocator, base64);
        errdefer release(handler);

        const request = try makeRequest(kind);
        errdefer release(request);

        // The process allocator, explicitly, and not `self.allocator`. This
        // outlives the dispatch frame by definition — the background function
        // is what frees it — so it must not come from anything scoped to the
        // call. The two happen to be the same allocator today
        // (`ios_dispatch` dispatches with `c_allocator`), which is exactly why
        // the coupling is worth spelling out rather than inheriting.
        const work = std.heap.c_allocator.create(Work) catch return BridgeError.AllocationFailed;
        errdefer std.heap.c_allocator.destroy(work);

        // Last, so every failure above answers synchronously with its own
        // error rather than through a ticket nobody would deliver.
        const ticket = ios_async.acquire(kind.action()) orelse {
            std.log.warn(
                "{s}: no free reply slot; {d} native calls are already awaiting one",
                .{ kind.action(), ios_async.max_in_flight },
            );
            return BridgeError.NativeCallFailed;
        };

        work.* = .{ .handler = handler, .request = request, .kind = kind, .ticket = ticket };
        dispatch_async_f(userInitiatedQueue(), work, performOnBackground);
    }
};

/// What crosses the queue boundary.
///
/// Heap-allocated per call and owned by `performOnBackground`, which frees it
/// and releases both Objective-C objects on every path out.
const Work = struct {
    handler: Id,
    request: Id,
    kind: Kind,
    ticket: ios_async.Ticket,
};

/// Run the request and answer, off the main thread.
///
/// `dispatch_async_f` guarantees exactly one call, so this owns `work`
/// outright. Nothing here touches the main thread directly:
/// `ios_async.deliverJson` does its own hop.
fn performOnBackground(context: ?*anyopaque) callconv(.c) void {
    const allocator = std.heap.c_allocator;
    const work: *Work = @ptrCast(@alignCast(context orelse return));
    defer {
        release(work.handler);
        release(work.request);
        allocator.destroy(work);
    }

    const sel_perform = objc.sel_registerName("performRequests:error:") orelse {
        ios_async.deliverError(work.ticket);
        return;
    };
    const NSArray = objc.objc_getClass("NSArray") orelse {
        ios_async.deliverError(work.ticket);
        return;
    };
    const sel_with_object = objc.sel_registerName("arrayWithObject:") orelse {
        ios_async.deliverError(work.ticket);
        return;
    };
    const requests = objc.msgSendId1(NSArray, sel_with_object, work.request) orelse {
        ios_async.deliverError(work.ticket);
        return;
    };

    var err: Id = null;
    const PerformFn = *const fn (Id, objc.SEL, Id, *Id) callconv(.c) bool;
    const performFn: PerformFn = @ptrCast(&objc.objc_msgSend);
    if (!performFn(work.handler, sel_perform, requests, &err)) {
        // Swift rejects with `error.localizedDescription`. The protocol has no
        // slot for a native message, so the code carries what it can and the
        // description goes to the log, where it is at least readable — rather
        // than being dropped on the floor as "something went wrong".
        logNSError(work.kind.action(), err);
        ios_async.deliverErrorCode(work.ticket, BridgeError.NativeCallFailed);
        return;
    }

    const json = shapeResults(allocator, work.kind, work.request) catch |shape_err| {
        std.log.warn("{s}: could not shape the results: {}", .{ work.kind.action(), shape_err });
        ios_async.deliverError(work.ticket);
        return;
    };
    defer allocator.free(json);

    ios_async.deliverJson(work.ticket, json);
}

/// The `image` field, as Swift reads it.
///
/// `body["image"] as? String` with no `else` in the dispatcher: a missing or
/// mistyped field replies nothing at all and the page waits out its timeout.
/// That is not carried across — every path here ends in a value or an error.
fn readImageField(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return BridgeError.InvalidJSON,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |o| o,
        else => return BridgeError.InvalidJSON,
    };
    const value = object.get("image") orelse return BridgeError.MissingData;
    const text = switch (value) {
        .string => |s| s,
        else => return BridgeError.InvalidParameter,
    };
    if (text.len == 0) return BridgeError.InvalidParameter;

    return allocator.dupe(u8, text) catch BridgeError.AllocationFailed;
}

/// `VNImageRequestHandler(cgImage:options:)`, +1, or the reason there is none.
///
/// Follows Swift's three-step guard exactly — base64 to `NSData`, `NSData` to
/// `UIImage`, `UIImage` to `CGImage` — and collapses all three into
/// `InvalidParameter`, which is what "Invalid image data" means in a protocol
/// that has no message field.
///
/// The base64 is handed to `NSData` rather than decoded in Zig so the accepted
/// input is exactly Swift's. `Data(base64Encoded:)` uses default options,
/// which reject any character outside the alphabet — including the newlines
/// some encoders wrap at column 64, and including the `data:image/png;base64,`
/// prefix a page might forward from a canvas. A Zig decoder written to be
/// "helpful" about either would accept images the Swift arm refuses.
fn makeRequestHandler(allocator: std.mem.Allocator, base64: []const u8) !Id {
    const ns_base64 = objc.createNSString(base64, allocator) catch
        return BridgeError.AllocationFailed;

    const NSData = objc.objc_getClass("NSData") orelse return BridgeError.NativeCallFailed;
    const sel_alloc = objc.sel_registerName("alloc") orelse return BridgeError.NativeCallFailed;
    const sel_init_b64 = objc.sel_registerName("initWithBase64EncodedString:options:") orelse
        return BridgeError.NativeCallFailed;

    const data_alloc = objc.msgSendId(NSData, sel_alloc) orelse return BridgeError.NativeCallFailed;
    const InitB64Fn = *const fn (Id, objc.SEL, Id, c_ulong) callconv(.c) Id;
    const initB64: InitB64Fn = @ptrCast(&objc.objc_msgSend);
    const ns_data = initB64(data_alloc, sel_init_b64, ns_base64, 0) orelse {
        std.log.warn("vision: the image field is not valid base64", .{});
        return BridgeError.InvalidParameter;
    };
    defer release(ns_data);

    // UIKit, so this is null on a host that links Cocoa — the honest refusal
    // rather than a link error, the same route `takeScreenshot` takes.
    const UIImage = objc.objc_getClass("UIImage") orelse {
        std.log.warn("vision: UIImage is not in this process", .{});
        return BridgeError.PlatformNotSupported;
    };
    const sel_with_data = objc.sel_registerName("imageWithData:") orelse
        return BridgeError.NativeCallFailed;
    const image = objc.msgSendId1(UIImage, sel_with_data, ns_data) orelse {
        std.log.warn("vision: the decoded bytes are not an image UIKit can read", .{});
        return BridgeError.InvalidParameter;
    };

    const sel_cg = objc.sel_registerName("CGImage") orelse return BridgeError.NativeCallFailed;
    const cg_image = objc.msgSendId(image, sel_cg) orelse {
        // A UIImage backed by a CIImage has no CGImage. Swift's third guard.
        std.log.warn("vision: the image has no CGImage representation", .{});
        return BridgeError.InvalidParameter;
    };

    const VNImageRequestHandler = objc.objc_getClass("VNImageRequestHandler") orelse {
        std.log.warn(
            "vision: VNImageRequestHandler is not in this process; the app does not link Vision",
            .{},
        );
        return BridgeError.PlatformNotSupported;
    };
    const NSDictionary = objc.objc_getClass("NSDictionary") orelse
        return BridgeError.NativeCallFailed;
    const sel_dictionary = objc.sel_registerName("dictionary") orelse
        return BridgeError.NativeCallFailed;
    const options = objc.msgSendId(NSDictionary, sel_dictionary) orelse
        return BridgeError.NativeCallFailed;

    const sel_init_handler = objc.sel_registerName("initWithCGImage:options:") orelse
        return BridgeError.NativeCallFailed;
    const handler_alloc = objc.msgSendId(VNImageRequestHandler, sel_alloc) orelse
        return BridgeError.NativeCallFailed;

    // +1 and kept: this is what holds the pixels alive across the queue hop.
    return objc.msgSendId2(handler_alloc, sel_init_handler, cg_image, options) orelse
        BridgeError.NativeCallFailed;
}

/// `VNRequestTextRecognitionLevelAccurate`. Swift sets it explicitly at
/// `CraftApp.swift:4731`, and the default is the same value — but the default
/// is Vision's to change and the spec's is not.
const text_recognition_level_accurate: c_long = 0;

/// The request object, +1, with no completion handler.
///
/// Swift constructs its requests with a completion block and then performs
/// them; the block is optional, and `performRequests:error:` is synchronous,
/// so reading `results` after it returns gets the same observations without a
/// block. That matters beyond tidiness: a completion block would have to be
/// global to be legal here, and a global block cannot carry the ticket that
/// says which page call it is answering.
fn makeRequest(kind: Kind) !Id {
    const class = objc.objc_getClass(kind.className()) orelse {
        std.log.warn(
            "{s}: {s} is not in this process; the app does not link Vision",
            .{ kind.action(), kind.className() },
        );
        return BridgeError.PlatformNotSupported;
    };
    const request = objc.allocInit(class) catch return BridgeError.NativeCallFailed;

    if (kind == .recognize) {
        const sel_level = objc.sel_registerName("setRecognitionLevel:") orelse
            return BridgeError.NativeCallFailed;
        const SetLevelFn = *const fn (Id, objc.SEL, c_long) callconv(.c) void;
        const setLevel: SetLevelFn = @ptrCast(&objc.objc_msgSend);
        setLevel(request, sel_level, text_recognition_level_accurate);
    }

    return request;
}

/// The reply body: a bare JSON array, matching `resolveCallback`'s
/// `.fragmentsAllowed` serialisation of a Swift array.
fn shapeResults(allocator: std.mem.Allocator, kind: Kind, request: Id) ![]u8 {
    const sel_results = objc.sel_registerName("results") orelse return error.SelectorNotFound;
    const results = objc.msgSendId(request, sel_results) orelse {
        // Swift's `as? [VN…Observation]` failing is a rejection there. A nil
        // `results` is not the same as an empty one: no request ran.
        return error.NoResults;
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    const count = try arrayCount(results);
    const limit = if (kind == .classify) @min(count, max_classifications) else count;

    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const observation = try arrayObjectAt(results, i);
        if (i != 0) try out.append(allocator, ',');
        switch (kind) {
            .classify => try appendClassification(allocator, &out, observation),
            .detect => try appendDetection(allocator, &out, observation),
            .recognize => try appendRecognizedText(allocator, &out, observation),
        }
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

/// `{"label": identifier, "confidence": confidence}`.
fn appendClassification(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    observation: Id,
) !void {
    const identifier = try readIdentifier(observation);
    try out.appendSlice(allocator, "{\"label\":");
    try appendJsonString(allocator, out, identifier);
    try out.appendSlice(allocator, ",\"confidence\":");
    try appendConfidence(allocator, out, try readConfidence(observation));
    try out.append(allocator, '}');
}

/// `{"labels": [...], "boundingBox": {...}, "confidence": c}`.
fn appendDetection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    observation: Id,
) !void {
    const sel_labels = objc.sel_registerName("labels") orelse return error.SelectorNotFound;
    const labels = objc.msgSendId(observation, sel_labels);

    try out.appendSlice(allocator, "{\"labels\":[");
    if (labels) |list| {
        const count = try arrayCount(list);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (i != 0) try out.append(allocator, ',');
            try appendClassification(allocator, out, try arrayObjectAt(list, i));
        }
    }
    try out.appendSlice(allocator, "],\"boundingBox\":");
    try appendBoundingBox(allocator, out, try readBoundingBox(observation));
    try out.appendSlice(allocator, ",\"confidence\":");
    try appendConfidence(allocator, out, try readConfidence(observation));
    try out.append(allocator, '}');
}

/// `{"text": s, "confidence": c, "boundingBox": {...}}`.
///
/// Swift takes `topCandidates(1).first` and **skips the observation entirely**
/// when there is none, so the reply can be shorter than the observation list.
/// Emitting a null-text entry instead would be a different array.
fn appendRecognizedText(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    observation: Id,
) !void {
    const sel_top = objc.sel_registerName("topCandidates:") orelse return error.SelectorNotFound;
    const TopFn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) Id;
    const topFn: TopFn = @ptrCast(&objc.objc_msgSend);
    const candidates = topFn(observation, sel_top, 1) orelse return error.NoCandidates;

    const sel_first = objc.sel_registerName("firstObject") orelse return error.SelectorNotFound;
    const candidate = objc.msgSendId(candidates, sel_first) orelse return error.NoCandidates;

    const sel_string = objc.sel_registerName("string") orelse return error.SelectorNotFound;
    const ns_text = objc.msgSendId(candidate, sel_string) orelse return error.NoCandidates;
    const text = objc.getNSStringUTF8(ns_text) orelse return error.NoCandidates;

    try out.appendSlice(allocator, "{\"text\":");
    try appendJsonString(allocator, out, std.mem.span(text));
    try out.appendSlice(allocator, ",\"confidence\":");
    // The candidate's confidence, not the observation's — Swift reads
    // `candidate.confidence`, and the two differ: one scores the transcription,
    // the other scores having found text at all.
    try appendConfidence(allocator, out, try readConfidence(candidate));
    try out.appendSlice(allocator, ",\"boundingBox\":");
    try appendBoundingBox(allocator, out, try readBoundingBox(observation));
    try out.append(allocator, '}');
}

/// `{"x":…,"y":…,"width":…,"height":…}`, Swift's four keys in Swift's order.
fn appendBoundingBox(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    box: objc.CGRect,
) !void {
    try out.appendSlice(allocator, "{\"x\":");
    try appendDouble(allocator, out, box.origin.x);
    try out.appendSlice(allocator, ",\"y\":");
    try appendDouble(allocator, out, box.origin.y);
    try out.appendSlice(allocator, ",\"width\":");
    try appendDouble(allocator, out, box.size.width);
    try out.appendSlice(allocator, ",\"height\":");
    try appendDouble(allocator, out, box.size.height);
    try out.append(allocator, '}');
}

/// A `VNConfidence`, which is a `float`.
///
/// Widened to `f64` before formatting rather than printed as an `f32`: the
/// value crosses into JavaScript, whose numbers are doubles, and the shortest
/// representation that round-trips an `f32` is not the shortest that
/// round-trips the double a page will compare against.
fn appendConfidence(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    confidence: f32,
) !void {
    try appendDouble(allocator, out, @floatCast(confidence));
}

fn appendDouble(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: f64,
) !void {
    // NaN and the infinities are not JSON. Vision does not produce them for a
    // confidence or a normalised box, but a value that reached the page as a
    // bare `nan` would be a syntax error in the source `evaluateJavaScript:`
    // parses — the whole reply lost, not one field.
    if (std.math.isNan(value) or std.math.isInf(value)) {
        try out.append(allocator, '0');
        return;
    }
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try out.appendSlice(allocator, text);
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    try bridge_error.appendJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

fn readIdentifier(observation: Id) ![]const u8 {
    const sel = objc.sel_registerName("identifier") orelse return error.SelectorNotFound;
    const ns = objc.msgSendId(observation, sel) orelse return error.NoIdentifier;
    const utf8 = objc.getNSStringUTF8(ns) orelse return error.NoIdentifier;
    return std.mem.span(utf8);
}

fn readConfidence(observation: Id) !f32 {
    const sel = objc.sel_registerName("confidence") orelse return error.SelectorNotFound;
    const ConfidenceFn = *const fn (Id, objc.SEL) callconv(.c) f32;
    const confidenceFn: ConfidenceFn = @ptrCast(&objc.objc_msgSend);
    return confidenceFn(observation, sel);
}

fn readBoundingBox(observation: Id) !objc.CGRect {
    const sel = objc.sel_registerName("boundingBox") orelse return error.SelectorNotFound;
    const BoxFn = *const fn (Id, objc.SEL) callconv(.c) objc.CGRect;
    const boxFn: BoxFn = @ptrCast(&objc.objc_msgSend);
    return boxFn(observation, sel);
}

fn arrayCount(array: Id) !usize {
    const sel = objc.sel_registerName("count") orelse return error.SelectorNotFound;
    const CountFn = *const fn (Id, objc.SEL) callconv(.c) c_ulong;
    const countFn: CountFn = @ptrCast(&objc.objc_msgSend);
    return @intCast(countFn(array, sel));
}

fn arrayObjectAt(array: Id, index: usize) !Id {
    const sel = objc.sel_registerName("objectAtIndex:") orelse return error.SelectorNotFound;
    const AtFn = *const fn (Id, objc.SEL, c_ulong) callconv(.c) Id;
    const atFn: AtFn = @ptrCast(&objc.objc_msgSend);
    return atFn(array, sel, @intCast(index)) orelse error.NilObservation;
}

fn logNSError(action: []const u8, err: Id) void {
    const ns_error = err orelse {
        std.log.warn("{s}: the request failed and reported no error", .{action});
        return;
    };
    const sel = objc.sel_registerName("localizedDescription") orelse return;
    const ns_description = objc.msgSendId(ns_error, sel) orelse return;
    const utf8 = objc.getNSStringUTF8(ns_description) orelse return;
    std.log.warn("{s}: {s}", .{ action, std.mem.span(utf8) });
}

fn release(object: Id) void {
    const target = object orelse return;
    const sel = objc.sel_registerName("release") orelse return;
    objc.msgSend(target, sel);
}

// ---------------------------------------------------------------------------
// The background queue
// ---------------------------------------------------------------------------

const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
extern "c" fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: dispatch_function_t) void;
extern "c" fn dispatch_get_global_queue(identifier: c_long, flags: c_ulong) ?*anyopaque;

/// `QOS_CLASS_USER_INITIATED`, the class Swift names.
///
/// The page is waiting on the answer, which is what this class means; the
/// default would deprioritise a request a user is watching a spinner for.
const qos_class_user_initiated: c_long = 0x19;

fn userInitiatedQueue() ?*anyopaque {
    return dispatch_get_global_queue(qos_class_user_initiated, 0);
}

const testing = std.testing;

test "the action names match the Swift case labels exactly" {
    // The conformance ratchet compares these against `case "…":` in
    // CraftApp.swift in both directions; a prettier spelling would register as
    // Zig serving an action the spec does not have.
    try testing.expectEqualStrings("classifyImage", A.classify_image);
    try testing.expectEqualStrings("detectObjects", A.detect_objects);
    try testing.expectEqualStrings("recognizeText", A.recognize_text);
}

test "detectObjects builds an animal request, which is what the spec does" {
    // Pinned because it looks like a mistake. `CraftApp.swift:4656` uses
    // VNRecognizeAnimalsRequest, whose whole vocabulary is cat and dog, for an
    // action named detectObjects. Substituting a general detector here would
    // change the labels, the confidences and the empty-vs-non-empty answer for
    // every image a page already sends.
    try testing.expectEqualStrings("VNRecognizeAnimalsRequest", std.mem.span(Kind.detect.className()));
    try testing.expectEqualStrings("VNClassifyImageRequest", std.mem.span(Kind.classify.className()));
    try testing.expectEqualStrings("VNRecognizeTextRequest", std.mem.span(Kind.recognize.className()));
}

test "every declared action maps to a kind" {
    // A name in the table `handleMessage` never compares against would reach
    // the shim as UnknownAction while the manifest claimed Zig served it.
    var bridge = VisionBridge.init(testing.allocator);
    defer bridge.deinit();

    for (capability_actions) |decl| {
        bridge.handleMessage(decl.name, "{}") catch |err| {
            try testing.expect(err != BridgeError.UnknownAction);
            continue;
        };
    }
}

test "an action this module does not serve is passed on" {
    var bridge = VisionBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectError(BridgeError.UnknownAction, bridge.handleMessage("getDeviceInfo", "{}"));
}

test "the image field is required, and its absence is not a hang" {
    // Swift's arm is `if config.enableMLKit, let imageBase64 = body["image"]
    // as? String` with no else: a missing field settles nothing and the page
    // waits out its timeout. Every path here ends in a value or an error.
    try testing.expectError(BridgeError.MissingData, readImageField(testing.allocator, "{}"));
    try testing.expectError(
        BridgeError.InvalidParameter,
        readImageField(testing.allocator, "{\"image\":42}"),
    );
    try testing.expectError(
        BridgeError.InvalidParameter,
        readImageField(testing.allocator, "{\"image\":\"\"}"),
    );
    try testing.expectError(BridgeError.InvalidJSON, readImageField(testing.allocator, "not json"));
    try testing.expectError(BridgeError.InvalidJSON, readImageField(testing.allocator, "[]"));

    const ok = try readImageField(testing.allocator, "{\"image\":\"aGk=\"}");
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("aGk=", ok);
}

test "a bounding box carries Swift's four keys in Swift's order" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendBoundingBox(testing.allocator, &out, .{
        .origin = .{ .x = 0.25, .y = 0.5 },
        .size = .{ .width = 0.125, .height = 1 },
    });

    try testing.expectEqualStrings(
        "{\"x\":0.25,\"y\":0.5,\"width\":0.125,\"height\":1}",
        out.items,
    );
}

test "a confidence is widened to double before it is printed" {
    // The value crosses into JavaScript, whose numbers are doubles. Printing
    // the shortest form that round-trips an f32 gives a different decimal from
    // the one that round-trips the double a page compares against.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendConfidence(testing.allocator, &out, 0.5);
    try testing.expectEqualStrings("0.5", out.items);

    out.clearRetainingCapacity();
    try appendConfidence(testing.allocator, &out, 1);
    try testing.expectEqualStrings("1", out.items);
}

test "a non-finite number is written as 0 rather than breaking the whole reply" {
    // `nan` and `inf` are not JSON. The reply is replayed into the source
    // `evaluateJavaScript:` parses, so one of them would be a syntax error
    // that loses every field, not just its own.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendDouble(testing.allocator, &out, std.math.nan(f64));
    try appendDouble(testing.allocator, &out, std.math.inf(f64));
    try appendDouble(testing.allocator, &out, -std.math.inf(f64));
    try testing.expectEqualStrings("000", out.items);
}

test "a label with a quote survives into the reply escaped" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendJsonString(testing.allocator, &out, "a \"b\" \\ c");
    try testing.expectEqualStrings("\"a \\\"b\\\" \\\\ c\"", out.items);
}

test "the classification cap is Swift's prefix(10)" {
    // Vision returns well over a thousand classifications ordered by
    // confidence. Without the cap the reply is a megabyte of labels scoring
    // 0.0001, and it applies to classifyImage alone.
    try testing.expectEqual(@as(usize, 10), max_classifications);
}

test "an image cannot be built on a host that has no UIKit" {
    // The host test binaries link Cocoa, so UIImage is absent. Refusing is the
    // honest answer; a module that fabricated an empty result array here would
    // report "no text found" for an image it never looked at.
    if (!is_darwin) return error.SkipZigTest;

    try testing.expectError(
        BridgeError.PlatformNotSupported,
        makeRequestHandler(testing.allocator, "aGVsbG8="),
    );
}
