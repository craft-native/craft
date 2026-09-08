//! Reaching Java from Zig, on Android.
//!
//! The counterpart to `objc_runtime.zig`, and structurally nothing like it.
//! Objective-C is a handful of C symbols — `objc_msgSend`, `objc_getClass` —
//! that the linker resolves. JNI exports no such symbols. Everything goes
//! through a **function table** the JVM hands the native method:
//!
//!     JNIEnv          == const struct JNINativeInterface *
//!     the argument    == JNIEnv *          (so: a pointer to that pointer)
//!     a call          == (*env)->FindClass(env, "android/os/Build")
//!
//! So `JNIEnv` here is `*const *const JNINativeInterface`, and every call is
//! two dereferences and an index into a table.
//!
//! ## The index is the whole correctness problem
//!
//! A field's *position* in `JNINativeInterface` is its memory offset. Get one
//! wrong and the call still compiles, still runs, and invokes a different
//! function with arguments meant for another signature — a crash if you are
//! lucky, silent corruption if not. There is no name check at runtime.
//!
//! The order below is transcribed from OpenJDK's `jni.h`, member by member,
//! not from memory. Each tenth entry carries its index so a reader can audit
//! the transcription by counting rather than by trusting it, and
//! `jniIndexOf` + the offset test at the bottom assert it.
//!
//! ## Why the struct stops at 215
//!
//! It is deliberately truncated after `RegisterNatives`. Zig never *allocates*
//! one of these — the table always belongs to the JVM — so reading a field at
//! a lower offset out of the real, longer table is correct, and every entry
//! not declared is one that cannot be transcribed wrongly. Adding a call means
//! extending the list in order, from the header.
//!
//! Forty-four of the declared entries are the array functions at 171-214, and
//! none of them is called. They are there because `RegisterNatives` sits
//! behind them: a member's position is its offset, so there is no way to reach
//! 215 without transcribing every step to it.
//!
//! ## Every field is an opaque pointer, on purpose
//!
//! All 171 entries are `?*const anyopaque`, and each wrapper casts to its own
//! typed signature at the call site — the same shape `objc_runtime.msgSendId1`
//! uses for `objc_msgSend`. Two reasons. The struct layout becomes trivially
//! correct, because every member is one pointer wide whatever its real
//! signature. And a mistyped signature is then a local bug in one wrapper
//! rather than a shift in every offset after it.
//!
//! ## This layer is host-testable, and that is not an accident of the design
//!
//! `objc_runtime.zig` can only be exercised where a real Objective-C runtime
//! exists. A `JNIEnv` is just a pointer to a table of pointers, so a test can
//! build one out of Zig functions and drive the wrappers against it with no
//! JVM, no emulator and no NDK. The tests at the bottom do exactly that: they
//! are what checks that a wrapper reads the slot it names.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// The primitive types, from jni.h
// =============================================================================

pub const jint = i32;
pub const jlong = i64;
pub const jbyte = i8;
pub const jboolean = u8;
pub const jchar = u16;
pub const jshort = i16;
pub const jfloat = f32;
pub const jdouble = f64;
pub const jsize = jint;

pub const JNI_FALSE: jboolean = 0;
pub const JNI_TRUE: jboolean = 1;

/// Every Java reference is an opaque pointer. They are deliberately distinct
/// names rather than one alias: `jclass` and `jstring` are both `jobject` to
/// the C compiler, and keeping the names apart is the only thing documenting
/// which a given wrapper expects.
pub const jobject = ?*anyopaque;
pub const jclass = jobject;
pub const jstring = jobject;
pub const jthrowable = jobject;
pub const jmethodID = ?*anyopaque;
pub const jfieldID = ?*anyopaque;

/// One Java argument, as the `A`-form calls take them.
///
/// A C union of every primitive plus a reference, eight bytes wide. Arguments
/// are passed as an array of these rather than variadically — see
/// `Jni.callObjectMethodA` for why that is the only form offered.
pub const jvalue = extern union {
    z: jboolean,
    b: jbyte,
    c: jchar,
    s: jshort,
    i: jint,
    j: jlong,
    f: jfloat,
    d: jdouble,
    l: jobject,
};

/// `JNIEnv*` as the JVM passes it to a native method.
pub const JNIEnv = *const *const JNINativeInterface;

// =============================================================================
// The function table
//
// Transcribed in declaration order from OpenJDK's jni.h. The index comments
// are load-bearing documentation: they are how a reader audits this against
// the header without re-deriving it.
// =============================================================================

/// Every slot in the table is a function pointer, so they are all declared as
/// one — a nullary C function — and each wrapper casts to its real signature at
/// the call site.
///
/// Not `?*const anyopaque`: a data pointer is one-byte-aligned, a function
/// pointer is not, and casting between them needs an `@alignCast` at every
/// single call. Typing the slot correctly once removes that from 20 places and
/// leaves the struct layout untouched — a function pointer is exactly as wide.
pub const JniFn = ?*const fn () callconv(.c) void;

pub const JNINativeInterface = extern struct {
    reserved0: JniFn, // 0
    reserved1: JniFn,
    reserved2: JniFn,
    reserved3: JniFn,

    GetVersion: JniFn, // 4
    DefineClass: JniFn,
    FindClass: JniFn, // 6
    FromReflectedMethod: JniFn,
    FromReflectedField: JniFn,
    ToReflectedMethod: JniFn,

    GetSuperclass: JniFn, // 10
    IsAssignableFrom: JniFn,
    ToReflectedField: JniFn,
    Throw: JniFn,
    ThrowNew: JniFn,
    ExceptionOccurred: JniFn, // 15
    ExceptionDescribe: JniFn, // 16
    ExceptionClear: JniFn, // 17
    FatalError: JniFn,
    PushLocalFrame: JniFn, // 19

    PopLocalFrame: JniFn, // 20
    NewGlobalRef: JniFn, // 21
    DeleteGlobalRef: JniFn,
    DeleteLocalRef: JniFn, // 23
    IsSameObject: JniFn,
    NewLocalRef: JniFn,
    EnsureLocalCapacity: JniFn,
    AllocObject: JniFn,
    NewObject: JniFn,
    NewObjectV: JniFn,

    NewObjectA: JniFn, // 30
    GetObjectClass: JniFn, // 31
    IsInstanceOf: JniFn,
    GetMethodID: JniFn, // 33
    CallObjectMethod: JniFn, // 34
    CallObjectMethodV: JniFn,
    CallObjectMethodA: JniFn,
    CallBooleanMethod: JniFn, // 37
    CallBooleanMethodV: JniFn,
    CallBooleanMethodA: JniFn,

    CallByteMethod: JniFn, // 40
    CallByteMethodV: JniFn,
    CallByteMethodA: JniFn,
    CallCharMethod: JniFn,
    CallCharMethodV: JniFn,
    CallCharMethodA: JniFn,
    CallShortMethod: JniFn,
    CallShortMethodV: JniFn,
    CallShortMethodA: JniFn,
    CallIntMethod: JniFn, // 49

    CallIntMethodV: JniFn, // 50
    CallIntMethodA: JniFn,
    CallLongMethod: JniFn, // 52
    CallLongMethodV: JniFn,
    CallLongMethodA: JniFn,
    CallFloatMethod: JniFn,
    CallFloatMethodV: JniFn,
    CallFloatMethodA: JniFn,
    CallDoubleMethod: JniFn,
    CallDoubleMethodV: JniFn,

    CallDoubleMethodA: JniFn, // 60
    CallVoidMethod: JniFn, // 61
    CallVoidMethodV: JniFn,
    CallVoidMethodA: JniFn,
    CallNonvirtualObjectMethod: JniFn, // 64
    CallNonvirtualObjectMethodV: JniFn,
    CallNonvirtualObjectMethodA: JniFn,
    CallNonvirtualBooleanMethod: JniFn,
    CallNonvirtualBooleanMethodV: JniFn,
    CallNonvirtualBooleanMethodA: JniFn,

    CallNonvirtualByteMethod: JniFn, // 70
    CallNonvirtualByteMethodV: JniFn,
    CallNonvirtualByteMethodA: JniFn,
    CallNonvirtualCharMethod: JniFn,
    CallNonvirtualCharMethodV: JniFn,
    CallNonvirtualCharMethodA: JniFn,
    CallNonvirtualShortMethod: JniFn,
    CallNonvirtualShortMethodV: JniFn,
    CallNonvirtualShortMethodA: JniFn,
    CallNonvirtualIntMethod: JniFn,

    CallNonvirtualIntMethodV: JniFn, // 80
    CallNonvirtualIntMethodA: JniFn,
    CallNonvirtualLongMethod: JniFn,
    CallNonvirtualLongMethodV: JniFn,
    CallNonvirtualLongMethodA: JniFn,
    CallNonvirtualFloatMethod: JniFn,
    CallNonvirtualFloatMethodV: JniFn,
    CallNonvirtualFloatMethodA: JniFn,
    CallNonvirtualDoubleMethod: JniFn,
    CallNonvirtualDoubleMethodV: JniFn,

    CallNonvirtualDoubleMethodA: JniFn, // 90
    CallNonvirtualVoidMethod: JniFn,
    CallNonvirtualVoidMethodV: JniFn,
    CallNonvirtualVoidMethodA: JniFn,
    GetFieldID: JniFn, // 94
    GetObjectField: JniFn, // 95
    GetBooleanField: JniFn,
    GetByteField: JniFn,
    GetCharField: JniFn,
    GetShortField: JniFn,

    GetIntField: JniFn, // 100
    GetLongField: JniFn,
    GetFloatField: JniFn,
    GetDoubleField: JniFn,
    SetObjectField: JniFn, // 104
    SetBooleanField: JniFn,
    SetByteField: JniFn,
    SetCharField: JniFn,
    SetShortField: JniFn,
    SetIntField: JniFn,

    SetLongField: JniFn, // 110
    SetFloatField: JniFn,
    SetDoubleField: JniFn,
    GetStaticMethodID: JniFn, // 113
    CallStaticObjectMethod: JniFn, // 114
    CallStaticObjectMethodV: JniFn,
    CallStaticObjectMethodA: JniFn,
    CallStaticBooleanMethod: JniFn,
    CallStaticBooleanMethodV: JniFn,
    CallStaticBooleanMethodA: JniFn,

    CallStaticByteMethod: JniFn, // 120
    CallStaticByteMethodV: JniFn,
    CallStaticByteMethodA: JniFn,
    CallStaticCharMethod: JniFn,
    CallStaticCharMethodV: JniFn,
    CallStaticCharMethodA: JniFn,
    CallStaticShortMethod: JniFn,
    CallStaticShortMethodV: JniFn,
    CallStaticShortMethodA: JniFn,
    CallStaticIntMethod: JniFn,

    CallStaticIntMethodV: JniFn, // 130
    CallStaticIntMethodA: JniFn,
    CallStaticLongMethod: JniFn,
    CallStaticLongMethodV: JniFn,
    CallStaticLongMethodA: JniFn,
    CallStaticFloatMethod: JniFn,
    CallStaticFloatMethodV: JniFn,
    CallStaticFloatMethodA: JniFn,
    CallStaticDoubleMethod: JniFn,
    CallStaticDoubleMethodV: JniFn,

    CallStaticDoubleMethodA: JniFn, // 140
    CallStaticVoidMethod: JniFn, // 141
    CallStaticVoidMethodV: JniFn,
    CallStaticVoidMethodA: JniFn,
    GetStaticFieldID: JniFn, // 144
    GetStaticObjectField: JniFn, // 145
    GetStaticBooleanField: JniFn,
    GetStaticByteField: JniFn,
    GetStaticCharField: JniFn,
    GetStaticShortField: JniFn,

    GetStaticIntField: JniFn, // 150
    GetStaticLongField: JniFn,
    GetStaticFloatField: JniFn,
    GetStaticDoubleField: JniFn,
    SetStaticObjectField: JniFn, // 154
    SetStaticBooleanField: JniFn,
    SetStaticByteField: JniFn,
    SetStaticCharField: JniFn,
    SetStaticShortField: JniFn,
    SetStaticIntField: JniFn,

    SetStaticLongField: JniFn, // 160
    SetStaticFloatField: JniFn,
    SetStaticDoubleField: JniFn,
    NewString: JniFn, // 163
    GetStringLength: JniFn,
    GetStringChars: JniFn,
    ReleaseStringChars: JniFn,
    NewStringUTF: JniFn, // 167
    GetStringUTFLength: JniFn, // 168
    GetStringUTFChars: JniFn, // 169

    ReleaseStringUTFChars: JniFn, // 170

    // 171-214 are the array functions. None is called: nothing in this bridge
    // passes a Java array yet. They are declared anyway because `RegisterNatives`
    // sits behind them and a member's position is its offset — there is no way
    // to reach 215 without transcribing every step to it.
    GetArrayLength: JniFn, // 171
    NewObjectArray: JniFn,
    GetObjectArrayElement: JniFn,
    SetObjectArrayElement: JniFn,
    NewBooleanArray: JniFn,
    NewByteArray: JniFn,
    NewCharArray: JniFn,
    NewShortArray: JniFn,
    NewIntArray: JniFn,
    NewLongArray: JniFn,

    NewFloatArray: JniFn, // 181
    NewDoubleArray: JniFn,
    GetBooleanArrayElements: JniFn,
    GetByteArrayElements: JniFn,
    GetCharArrayElements: JniFn,
    GetShortArrayElements: JniFn,
    GetIntArrayElements: JniFn,
    GetLongArrayElements: JniFn,
    GetFloatArrayElements: JniFn,
    GetDoubleArrayElements: JniFn,

    ReleaseBooleanArrayElements: JniFn, // 191
    ReleaseByteArrayElements: JniFn,
    ReleaseCharArrayElements: JniFn,
    ReleaseShortArrayElements: JniFn,
    ReleaseIntArrayElements: JniFn,
    ReleaseLongArrayElements: JniFn,
    ReleaseFloatArrayElements: JniFn,
    ReleaseDoubleArrayElements: JniFn,
    GetBooleanArrayRegion: JniFn,
    GetByteArrayRegion: JniFn,

    GetCharArrayRegion: JniFn, // 201
    GetShortArrayRegion: JniFn,
    GetIntArrayRegion: JniFn,
    GetLongArrayRegion: JniFn,
    GetFloatArrayRegion: JniFn,
    GetDoubleArrayRegion: JniFn,
    SetBooleanArrayRegion: JniFn,
    SetByteArrayRegion: JniFn,
    SetCharArrayRegion: JniFn,
    SetShortArrayRegion: JniFn,

    SetIntArrayRegion: JniFn, // 211
    SetLongArrayRegion: JniFn,
    SetFloatArrayRegion: JniFn,
    SetDoubleArrayRegion: JniFn,
    RegisterNatives: JniFn, // 215 — the table is cut here
};

/// The declared index of a member, for the offset audit below.
///
/// `@offsetOf` divided by the pointer size only means something because every
/// member is one pointer wide — which is the reason they are all opaque.
pub fn jniIndexOf(comptime name: []const u8) usize {
    return @offsetOf(JNINativeInterface, name) / @sizeOf(JniFn);
}

// =============================================================================
// The JavaVM, and binding native methods
//
// A second, much smaller table. `JNI_OnLoad` is handed a `JavaVM*` rather than
// a `JNIEnv*` — the VM is process-wide and thread-independent, the env is
// per-thread — so reaching Java from `JNI_OnLoad` means asking the VM for this
// thread's env first.
// =============================================================================

/// `JavaVM`'s function table. Eight entries, and the layout is from the same
/// header as the big one.
pub const JNIInvokeInterface = extern struct {
    reserved0: JniFn, // 0
    reserved1: JniFn,
    reserved2: JniFn,
    DestroyJavaVM: JniFn, // 3
    AttachCurrentThread: JniFn, // 4
    DetachCurrentThread: JniFn, // 5
    GetEnv: JniFn, // 6
    AttachCurrentThreadAsDaemon: JniFn, // 7
};

pub const JavaVM = *const *const JNIInvokeInterface;

/// The JNI version this library asks for and `JNI_OnLoad` returns.
///
/// 1.6 is what every Android runtime provides and the floor Android documents;
/// asking for 1.8 gets `JNI_EVERSION` from ART and the library fails to load.
pub const JNI_VERSION_1_6: jint = 0x00010006;
pub const JNI_OK: jint = 0;
pub const JNI_EDETACHED: jint = -2;

/// One `name`/`signature`/`function` triple for `RegisterNatives`.
///
/// `name` and `signature` are `char*` in the header rather than `const char*`;
/// the JVM does not write through them, and matching the declared type avoids
/// a cast at every call site.
pub const JNINativeMethod = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    fnPtr: *const anyopaque,
};

/// This thread's `JNIEnv`, or null when the thread is not attached.
///
/// `GetEnv` is the only correct way to get one. A `JNIEnv` belongs to a single
/// thread and caching one across threads is the classic JNI crash — so a
/// callback arriving on a framework thread asks here rather than reusing the
/// env it was registered with. This is the same hazard `ios_events.zig` solves
/// by hopping to the main queue, in a form where the runtime will not tell you
/// you got it wrong.
pub fn envForThisThread(vm: JavaVM) ?JNIEnv {
    const get: *const fn (JavaVM, *?*anyopaque, jint) callconv(.c) jint =
        @ptrCast(vm.*.GetEnv orelse return null);

    var env: ?*anyopaque = null;
    if (get(vm, &env, JNI_VERSION_1_6) != JNI_OK) return null;
    return @ptrCast(@alignCast(env orelse return null));
}

/// Bind native implementations to a Java class's `external`/`native` methods.
///
/// The alternative is exporting a symbol named
/// `Java_<package>_<class>_<method>`, which the JVM finds by mangling. That
/// cannot work here: craft templates the package name per app, so a mangled
/// export would bind for exactly one package and silently fail to resolve for
/// every other — an `UnsatisfiedLinkError` at first call, long after build.
/// Registering by name at load time is independent of the package.
pub fn registerNatives(
    env: JNIEnv,
    cls: jclass,
    methods: []const JNINativeMethod,
) JniError!void {
    const j = Jni.init(env);
    const register: *const fn (JNIEnv, jclass, [*]const JNINativeMethod, jint) callconv(.c) jint =
        @ptrCast(env.*.RegisterNatives orelse return JniError.NotFound);

    if (register(env, cls, methods.ptr, @intCast(methods.len)) != JNI_OK) {
        try j.check();
        return JniError.NotFound;
    }
}

// =============================================================================
// Errors
// =============================================================================

pub const JniError = error{
    /// A Java exception was pending. Already described and cleared — see
    /// `Jni.check`.
    JavaException,
    /// `FindClass` / `GetMethodID` / `GetFieldID` returned null without an
    /// exception, which the spec allows for a genuinely absent name.
    NotFound,
    /// A `jstring` that was null where a string was required.
    NullReference,
    /// `GetStringUTFChars` returned null — the JVM could not allocate.
    StringUnavailable,
    /// The JVM handed back bytes that are not well-formed modified UTF-8.
    MalformedString,
    OutOfMemory,
};

// =============================================================================
// The wrapper
// =============================================================================

/// A `JNIEnv` plus the discipline every call to it needs.
///
/// The discipline is the point of this type. JNI does not signal failure by
/// returning an error: a failing call sets a *pending exception* on the thread
/// and returns whatever it returns. Calling almost any other JNI function
/// while one is pending is undefined behaviour — so "check after every call
/// that can throw" is not defensive style here, it is the calling convention.
/// Objective-C has no equivalent: a message to nil is simply nil.
///
/// Every method below that can throw ends in `check`, which describes the
/// exception to logcat and clears it before returning `JavaException`. Clearing
/// is mandatory rather than polite: leaving it pending poisons the next call,
/// so a wrapper that reported the error without clearing would turn one failure
/// into an unpredictable second one.
pub const Jni = struct {
    env: JNIEnv,

    const Self = @This();

    pub fn init(env: JNIEnv) Self {
        return .{ .env = env };
    }

    fn table(self: Self) *const JNINativeInterface {
        return self.env.*;
    }

    /// Was an exception left pending? Describe it, clear it, and say so.
    ///
    /// `ExceptionOccurred` rather than `ExceptionCheck`: both answer the
    /// question, and this one is at a verified index in the table above.
    /// It returns a local reference, so the throwable is deleted here — a
    /// leaked local ref per failed call is exactly how the 16-slot local frame
    /// overflows in a loop.
    pub fn check(self: Self) JniError!void {
        const occurred: *const fn (JNIEnv) callconv(.c) jthrowable =
            @ptrCast(self.table().ExceptionOccurred orelse return);
        const pending = occurred(self.env);
        if (pending == null) return;

        // Describe before clear: `ExceptionDescribe` prints the stack trace to
        // logcat, and it is the only place that information exists. `BridgeError`
        // carries a code to the page, never a Java stack.
        if (self.table().ExceptionDescribe) |raw| {
            const describe: *const fn (JNIEnv) callconv(.c) void = @ptrCast(raw);
            describe(self.env);
        }
        if (self.table().ExceptionClear) |raw| {
            const clear: *const fn (JNIEnv) callconv(.c) void = @ptrCast(raw);
            clear(self.env);
        }
        if (self.table().DeleteLocalRef) |raw| {
            const del: *const fn (JNIEnv, jobject) callconv(.c) void = @ptrCast(raw);
            del(self.env, pending);
        }
        return JniError.JavaException;
    }

    /// `FindClass("android/os/Build")` — slashes, not dots.
    ///
    /// The returned reference is **local**: valid until the native method
    /// returns, and not shareable between threads. A class looked up once and
    /// kept must go through `newGlobalRef`.
    pub fn findClass(self: Self, name: [*:0]const u8) JniError!jclass {
        const find: *const fn (JNIEnv, [*:0]const u8) callconv(.c) jclass =
            @ptrCast(self.table().FindClass orelse return JniError.NotFound);
        const cls = find(self.env, name);
        try self.check();
        return cls orelse JniError.NotFound;
    }

    pub fn staticFieldId(self: Self, cls: jclass, name: [*:0]const u8, sig: [*:0]const u8) JniError!jfieldID {
        const get: *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jfieldID =
            @ptrCast(self.table().GetStaticFieldID orelse return JniError.NotFound);
        const id = get(self.env, cls, name, sig);
        try self.check();
        return id orelse JniError.NotFound;
    }

    pub fn staticObjectField(self: Self, cls: jclass, id: jfieldID) JniError!jobject {
        const get: *const fn (JNIEnv, jclass, jfieldID) callconv(.c) jobject =
            @ptrCast(self.table().GetStaticObjectField orelse return JniError.NotFound);
        const value = get(self.env, cls, id);
        try self.check();
        return value;
    }

    pub fn staticIntField(self: Self, cls: jclass, id: jfieldID) JniError!jint {
        const get: *const fn (JNIEnv, jclass, jfieldID) callconv(.c) jint =
            @ptrCast(self.table().GetStaticIntField orelse return JniError.NotFound);
        const value = get(self.env, cls, id);
        try self.check();
        return value;
    }

    pub fn methodId(self: Self, cls: jclass, name: [*:0]const u8, sig: [*:0]const u8) JniError!jmethodID {
        const get: *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID =
            @ptrCast(self.table().GetMethodID orelse return JniError.NotFound);
        const id = get(self.env, cls, name, sig);
        try self.check();
        return id orelse JniError.NotFound;
    }

    /// A no-argument instance call returning an object.
    ///
    /// Only the nullary form is offered, and that is a deliberate limit rather
    /// than an unfinished one. `CallObjectMethod` is variadic, and a variadic
    /// call through a `callconv(.c)` pointer has to get the platform's
    /// argument-passing rules exactly right — arm64 and x86-64 Android disagree
    /// about where the eighth integer argument lives. `CallObjectMethodA`,
    /// which takes a `jvalue` array, is the form to add when arguments are
    /// needed: same table, no variadic ABI to reproduce.
    pub fn callObjectMethod(self: Self, obj: jobject, id: jmethodID) JniError!jobject {
        const call: *const fn (JNIEnv, jobject, jmethodID) callconv(.c) jobject =
            @ptrCast(self.table().CallObjectMethod orelse return JniError.NotFound);
        const result = call(self.env, obj, id);
        try self.check();
        return result;
    }

    // --- The argument-taking forms -------------------------------------
    //
    // Every one of these is the `A` variant, taking a `[]const jvalue`. The
    // bare `CallObjectMethod` is variadic in C, and calling a variadic
    // function through a `callconv(.c)` pointer means reproducing the
    // platform's argument-passing rules exactly — which arm64 and x86-64
    // Android do not share. The `A` form takes an array instead, so there is
    // no ABI to reproduce and one implementation is right on both.
    //
    // `args.ptr` is passed even when the slice is empty; a zero-argument call
    // never reads it, and a null there would be a second thing to reason about.

    pub fn callObjectMethodA(self: Self, obj: jobject, id: jmethodID, args: []const jvalue) JniError!jobject {
        const call: *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jobject =
            @ptrCast(self.table().CallObjectMethodA orelse return JniError.NotFound);
        const result = call(self.env, obj, id, args.ptr);
        try self.check();
        return result;
    }

    pub fn callIntMethodA(self: Self, obj: jobject, id: jmethodID, args: []const jvalue) JniError!jint {
        const call: *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jint =
            @ptrCast(self.table().CallIntMethodA orelse return JniError.NotFound);
        const result = call(self.env, obj, id, args.ptr);
        try self.check();
        return result;
    }

    pub fn callBooleanMethodA(self: Self, obj: jobject, id: jmethodID, args: []const jvalue) JniError!bool {
        const call: *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jboolean =
            @ptrCast(self.table().CallBooleanMethodA orelse return JniError.NotFound);
        const result = call(self.env, obj, id, args.ptr);
        try self.check();
        // `jboolean` is a `u8` and the JVM only ever sets it to 0 or 1, but a
        // `!= 0` rather than `== 1` is what the spec licenses.
        return result != JNI_FALSE;
    }

    pub fn callLongMethodA(self: Self, obj: jobject, id: jmethodID, args: []const jvalue) JniError!jlong {
        const call: *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jlong =
            @ptrCast(self.table().CallLongMethodA orelse return JniError.NotFound);
        const result = call(self.env, obj, id, args.ptr);
        try self.check();
        return result;
    }

    pub fn callVoidMethodA(self: Self, obj: jobject, id: jmethodID, args: []const jvalue) JniError!void {
        const call: *const fn (JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) void =
            @ptrCast(self.table().CallVoidMethodA orelse return JniError.NotFound);
        call(self.env, obj, id, args.ptr);
        try self.check();
    }

    /// `new <cls>(args)`. `id` must be the `<init>` method id.
    pub fn newObjectA(self: Self, cls: jclass, id: jmethodID, args: []const jvalue) JniError!jobject {
        const new: *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject =
            @ptrCast(self.table().NewObjectA orelse return JniError.NotFound);
        const obj = new(self.env, cls, id, args.ptr);
        try self.check();
        return obj orelse JniError.NotFound;
    }

    // --- Instance fields -------------------------------------------------
    //
    // Needed because Android exposes plain public fields on several of the
    // classes this bridge reads — `DisplayMetrics.widthPixels`,
    // `PackageInfo.versionName` — with no getter to call.

    pub fn fieldId(self: Self, cls: jclass, name: [*:0]const u8, sig: [*:0]const u8) JniError!jfieldID {
        const get: *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jfieldID =
            @ptrCast(self.table().GetFieldID orelse return JniError.NotFound);
        const id = get(self.env, cls, name, sig);
        try self.check();
        return id orelse JniError.NotFound;
    }

    pub fn objectField(self: Self, obj: jobject, id: jfieldID) JniError!jobject {
        const get: *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jobject =
            @ptrCast(self.table().GetObjectField orelse return JniError.NotFound);
        const value = get(self.env, obj, id);
        try self.check();
        return value;
    }

    pub fn intField(self: Self, obj: jobject, id: jfieldID) JniError!jint {
        const get: *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jint =
            @ptrCast(self.table().GetIntField orelse return JniError.NotFound);
        const value = get(self.env, obj, id);
        try self.check();
        return value;
    }

    pub fn longField(self: Self, obj: jobject, id: jfieldID) JniError!jlong {
        const get: *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jlong =
            @ptrCast(self.table().GetLongField orelse return JniError.NotFound);
        const value = get(self.env, obj, id);
        try self.check();
        return value;
    }

    pub fn floatField(self: Self, obj: jobject, id: jfieldID) JniError!jfloat {
        const get: *const fn (JNIEnv, jobject, jfieldID) callconv(.c) jfloat =
            @ptrCast(self.table().GetFloatField orelse return JniError.NotFound);
        const value = get(self.env, obj, id);
        try self.check();
        return value;
    }

    // --- Arrays -----------------------------------------------------------
    //
    // `long[]` for `VibrationEffect.createWaveform`, and `String[]` for the
    // projection and selection arguments a `ContentResolver.query` takes.
    //
    // The two are shaped differently because JNI is: a primitive array can be
    // filled from a Zig slice in one `SetLongArrayRegion` call, which is both
    // faster and the only form that cannot leave a partially-filled array
    // behind on an error. An object array has no region form and has to be
    // written a slot at a time.

    pub fn newLongArray(self: Self, values: []const jlong) JniError!jobject {
        const new: *const fn (JNIEnv, jsize) callconv(.c) jobject =
            @ptrCast(self.table().NewLongArray orelse return JniError.NotFound);
        const array = new(self.env, @intCast(values.len)) orelse {
            try self.check();
            return JniError.OutOfMemory;
        };

        if (values.len == 0) return array;

        const set: *const fn (JNIEnv, jobject, jsize, jsize, [*]const jlong) callconv(.c) void =
            @ptrCast(self.table().SetLongArrayRegion orelse return JniError.NotFound);
        set(self.env, array, 0, @intCast(values.len), values.ptr);
        try self.check();
        return array;
    }

    /// `new <element_class>[len]`, every slot null.
    ///
    /// `NewObjectArray` takes an initial element for every slot; null is what
    /// the Kotlin's `arrayOf(...)` starts from before its entries are written,
    /// and every caller here fills the array immediately.
    pub fn newObjectArray(self: Self, len: usize, element_class: jclass) JniError!jobject {
        const new: *const fn (JNIEnv, jsize, jclass, jobject) callconv(.c) jobject =
            @ptrCast(self.table().NewObjectArray orelse return JniError.NotFound);
        const array = new(self.env, @intCast(len), element_class, null) orelse {
            try self.check();
            return JniError.OutOfMemory;
        };
        try self.check();
        return array;
    }

    pub fn setObjectArrayElement(self: Self, array: jobject, index: usize, value: jobject) JniError!void {
        const set: *const fn (JNIEnv, jobject, jsize, jobject) callconv(.c) void =
            @ptrCast(self.table().SetObjectArrayElement orelse return JniError.NotFound);
        set(self.env, array, @intCast(index), value);
        try self.check();
    }

    /// Make a Java `String` from UTF-8.
    ///
    /// The JVM wants *modified* UTF-8 here, the same encoding `stringToUtf8`
    /// decodes on the way back — so a string carrying a NUL or an astral
    /// character has to be re-encoded rather than handed over. Callers pass
    /// NUL-terminated literals and ASCII package names today, which are
    /// identical in both encodings; `encodeModifiedUtf8` is the function to
    /// add when that stops being true, and this is where it goes.
    pub fn newStringUtf(self: Self, text: [*:0]const u8) JniError!jstring {
        const new: *const fn (JNIEnv, [*:0]const u8) callconv(.c) jstring =
            @ptrCast(self.table().NewStringUTF orelse return JniError.NotFound);
        const str = new(self.env, text);
        try self.check();
        return str orelse JniError.OutOfMemory;
    }

    pub fn callIntMethod(self: Self, obj: jobject, id: jmethodID) JniError!jint {
        const call: *const fn (JNIEnv, jobject, jmethodID) callconv(.c) jint =
            @ptrCast(self.table().CallIntMethod orelse return JniError.NotFound);
        const result = call(self.env, obj, id);
        try self.check();
        return result;
    }

    pub fn callLongMethod(self: Self, obj: jobject, id: jmethodID) JniError!jlong {
        const call: *const fn (JNIEnv, jobject, jmethodID) callconv(.c) jlong =
            @ptrCast(self.table().CallLongMethod orelse return JniError.NotFound);
        const result = call(self.env, obj, id);
        try self.check();
        return result;
    }

    // --- Static methods ---------------------------------------------------
    //
    // `Runtime.getRuntime()` and `Log.d(tag, msg)` are both static, and a
    // static call is a different table entry from an instance one taking the
    // class rather than the receiver. Passing a jclass to CallObjectMethod
    // compiles and is undefined at runtime.

    pub fn staticMethodId(self: Self, cls: jclass, name: [*:0]const u8, sig: [*:0]const u8) JniError!jmethodID {
        const get: *const fn (JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID =
            @ptrCast(self.table().GetStaticMethodID orelse return JniError.NotFound);
        const id = get(self.env, cls, name, sig);
        try self.check();
        return id orelse JniError.NotFound;
    }

    pub fn callStaticObjectMethodA(self: Self, cls: jclass, id: jmethodID, args: []const jvalue) JniError!jobject {
        const call: *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject =
            @ptrCast(self.table().CallStaticObjectMethodA orelse return JniError.NotFound);
        const result = call(self.env, cls, id, args.ptr);
        try self.check();
        return result;
    }

    pub fn callStaticLongMethodA(self: Self, cls: jclass, id: jmethodID, args: []const jvalue) JniError!jlong {
        const call: *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jlong =
            @ptrCast(self.table().CallStaticLongMethodA orelse return JniError.NotFound);
        const result = call(self.env, cls, id, args.ptr);
        try self.check();
        return result;
    }

    pub fn callStaticVoidMethodA(self: Self, cls: jclass, id: jmethodID, args: []const jvalue) JniError!void {
        const call: *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) void =
            @ptrCast(self.table().CallStaticVoidMethodA orelse return JniError.NotFound);
        call(self.env, cls, id, args.ptr);
        try self.check();
    }

    pub fn callStaticIntMethodA(self: Self, cls: jclass, id: jmethodID, args: []const jvalue) JniError!jint {
        const call: *const fn (JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jint =
            @ptrCast(self.table().CallStaticIntMethodA orelse return JniError.NotFound);
        const result = call(self.env, cls, id, args.ptr);
        try self.check();
        return result;
    }

    pub fn objectClass(self: Self, obj: jobject) JniError!jclass {
        const get: *const fn (JNIEnv, jobject) callconv(.c) jclass =
            @ptrCast(self.table().GetObjectClass orelse return JniError.NotFound);
        return get(self.env, obj) orelse JniError.NotFound;
    }

    /// Open a scope that owns every local reference created inside it.
    ///
    /// The JVM only guarantees sixteen local reference slots. A function that
    /// walks a few objects — an Activity to a WindowManager to a Display to a
    /// DisplayMetrics — spends them without ever looking like it is
    /// allocating, and overflowing aborts the process rather than failing a
    /// call. `popLocalFrame` frees the whole scope in one go, which is both
    /// less code than a `defer` per reference and impossible to get half-right.
    pub fn pushLocalFrame(self: Self, capacity: jint) JniError!void {
        const push: *const fn (JNIEnv, jint) callconv(.c) jint =
            @ptrCast(self.table().PushLocalFrame orelse return JniError.NotFound);
        if (push(self.env, capacity) != 0) {
            try self.check();
            return JniError.OutOfMemory;
        }
    }

    /// Close the scope. `keep` is the one reference to survive it, promoted
    /// into the enclosing frame — null when nothing needs to.
    pub fn popLocalFrame(self: Self, keep: jobject) jobject {
        const pop: *const fn (JNIEnv, jobject) callconv(.c) jobject =
            @ptrCast(self.table().PopLocalFrame orelse return null);
        return pop(self.env, keep);
    }

    pub fn deleteLocalRef(self: Self, obj: jobject) void {
        if (obj == null) return;
        const del: *const fn (JNIEnv, jobject) callconv(.c) void =
            @ptrCast(self.table().DeleteLocalRef orelse return);
        del(self.env, obj);
    }

    /// Promote a local reference to one that survives the native method and
    /// can cross threads. Must be paired with `deleteGlobalRef`.
    pub fn newGlobalRef(self: Self, obj: jobject) JniError!jobject {
        const new: *const fn (JNIEnv, jobject) callconv(.c) jobject =
            @ptrCast(self.table().NewGlobalRef orelse return JniError.NotFound);
        return new(self.env, obj) orelse JniError.NotFound;
    }

    pub fn deleteGlobalRef(self: Self, obj: jobject) void {
        if (obj == null) return;
        const del: *const fn (JNIEnv, jobject) callconv(.c) void =
            @ptrCast(self.table().DeleteGlobalRef orelse return);
        del(self.env, obj);
    }

    /// Read a `jstring` as standard UTF-8. Caller owns the result.
    ///
    /// What the JVM hands back is **modified** UTF-8, which is not UTF-8 — see
    /// `decodeModifiedUtf8`. Converting here rather than at each call site is
    /// the point: a bridge that puts these bytes straight into JSON would emit
    /// a document no standard parser accepts.
    pub fn stringToUtf8(self: Self, allocator: std.mem.Allocator, str: jstring) JniError![]u8 {
        if (str == null) return JniError.NullReference;

        const get: *const fn (JNIEnv, jstring, ?*jboolean) callconv(.c) ?[*:0]const u8 =
            @ptrCast(self.table().GetStringUTFChars orelse return JniError.StringUnavailable);
        const raw = get(self.env, str, null) orelse {
            try self.check();
            return JniError.StringUnavailable;
        };
        defer if (self.table().ReleaseStringUTFChars) |rel| {
            const release: *const fn (JNIEnv, jstring, [*:0]const u8) callconv(.c) void = @ptrCast(rel);
            release(self.env, str, raw);
        };

        // `std.mem.span` is safe here for a reason worth stating: modified
        // UTF-8 encodes U+0000 as the two bytes C0 80, so a NUL byte never
        // appears inside the payload and the terminator is unambiguous.
        return decodeModifiedUtf8(allocator, std.mem.span(raw));
    }
};

// =============================================================================
// Modified UTF-8
// =============================================================================

/// Convert Java's modified UTF-8 to the standard encoding.
///
/// Two differences, both of which corrupt a JSON payload if ignored:
///
///  - **U+0000 is encoded as `C0 80`**, a two-byte form standard UTF-8 forbids
///    as overlong. This is what makes a Java string safely NUL-terminated in C,
///    and it is why `std.mem.span` can be trusted on the buffer above.
///  - **Characters outside the BMP are two three-byte sequences**, one per
///    UTF-16 surrogate, rather than one four-byte sequence. So an emoji in a
///    device name arrives as a CESU-8 surrogate pair, which every standard
///    decoder rejects.
///
/// Everything else is byte-identical, so the common path copies straight
/// through and only the two special forms are rewritten.
/// The code unit a three-byte UTF-8 sequence encodes.
///
/// Split out because the surrogate path needs the *value*, not the character:
/// `std.unicode.utf8Decode` rejects a lone surrogate, which is exactly what
/// each half of a CESU-8 pair is.
fn decodeThreeByte(bytes: *const [3]u8) u32 {
    return (@as(u32, bytes[0] & 0x0F) << 12) |
        (@as(u32, bytes[1] & 0x3F) << 6) |
        @as(u32, bytes[2] & 0x3F);
}

pub fn decodeModifiedUtf8(allocator: std.mem.Allocator, input: []const u8) JniError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const b0 = input[i];

        // C0 80 is the NUL escape, and the only overlong form that is legal.
        if (b0 == 0xC0 and i + 1 < input.len and input[i + 1] == 0x80) {
            try out.append(allocator, 0);
            i += 2;
            continue;
        }

        // A high surrogate begins ED A0..AF. Paired with a following low
        // surrogate it is one astral character in two three-byte pieces.
        if (b0 == 0xED and i + 5 < input.len and
            input[i + 1] >= 0xA0 and input[i + 1] <= 0xAF and
            input[i + 3] == 0xED and input[i + 4] >= 0xB0 and input[i + 4] <= 0xBF)
        {
            // Each surrogate is a whole three-byte sequence, so decode both to
            // their real UTF-16 code units before combining. Folding only the
            // trailing bits together instead drops the 0xD000 the leading ED
            // contributes, and lands several planes away from the character.
            const high = decodeThreeByte(input[i..][0..3]);
            const low = decodeThreeByte(input[i + 3 ..][0..3]);
            if (high < 0xD800 or high > 0xDBFF or low < 0xDC00 or low > 0xDFFF) {
                return JniError.MalformedString;
            }
            const code_point = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);

            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(code_point), &buf) catch
                return JniError.MalformedString;
            try out.appendSlice(allocator, buf[0..len]);
            i += 6;
            continue;
        }

        // Everything else is already standard UTF-8; copy the whole sequence
        // so a multi-byte character is never split by the checks above.
        const len = std.unicode.utf8ByteSequenceLength(b0) catch
            return JniError.MalformedString;
        if (i + len > input.len) return JniError.MalformedString;
        try out.appendSlice(allocator, input[i .. i + len]);
        i += len;
    }

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
//
// A `JNIEnv` is a pointer to a table of pointers, so a test can build one out
// of Zig functions and drive every wrapper against it. No JVM, no emulator, no
// NDK. This is the property that makes the layer checkable at all — the
// Objective-C equivalent needs a real runtime and so has no counterpart to
// these.
// =============================================================================

const testing = std.testing;

test "the transcribed table puts every member at the index the header gives it" {
    // The one bug this file can have that nothing else would catch. A member
    // dropped or duplicated shifts every entry after it, and the call still
    // compiles — it just invokes a different function. These indices are from
    // OpenJDK's jni.h, and they are the reason the struct is auditable.
    try testing.expectEqual(@as(usize, 4), jniIndexOf("GetVersion"));
    try testing.expectEqual(@as(usize, 6), jniIndexOf("FindClass"));
    try testing.expectEqual(@as(usize, 15), jniIndexOf("ExceptionOccurred"));
    try testing.expectEqual(@as(usize, 17), jniIndexOf("ExceptionClear"));
    try testing.expectEqual(@as(usize, 21), jniIndexOf("NewGlobalRef"));
    try testing.expectEqual(@as(usize, 23), jniIndexOf("DeleteLocalRef"));
    try testing.expectEqual(@as(usize, 31), jniIndexOf("GetObjectClass"));
    try testing.expectEqual(@as(usize, 33), jniIndexOf("GetMethodID"));
    try testing.expectEqual(@as(usize, 34), jniIndexOf("CallObjectMethod"));
    try testing.expectEqual(@as(usize, 49), jniIndexOf("CallIntMethod"));
    try testing.expectEqual(@as(usize, 94), jniIndexOf("GetFieldID"));
    try testing.expectEqual(@as(usize, 113), jniIndexOf("GetStaticMethodID"));
    try testing.expectEqual(@as(usize, 144), jniIndexOf("GetStaticFieldID"));
    try testing.expectEqual(@as(usize, 145), jniIndexOf("GetStaticObjectField"));
    try testing.expectEqual(@as(usize, 150), jniIndexOf("GetStaticIntField"));
    try testing.expectEqual(@as(usize, 167), jniIndexOf("NewStringUTF"));
    try testing.expectEqual(@as(usize, 169), jniIndexOf("GetStringUTFChars"));
    try testing.expectEqual(@as(usize, 170), jniIndexOf("ReleaseStringUTFChars"));
    try testing.expectEqual(@as(usize, 171), jniIndexOf("GetArrayLength"));
    try testing.expectEqual(@as(usize, 199), jniIndexOf("GetBooleanArrayRegion"));
    try testing.expectEqual(@as(usize, 215), jniIndexOf("RegisterNatives"));

    // And the table is exactly as long as it claims — 216 entries, cut after
    // RegisterNatives. A member appended without a reason would make the
    // truncation comment a lie.
    try testing.expectEqual(
        @as(usize, 216 * @sizeOf(JniFn)),
        @sizeOf(JNINativeInterface),
    );
}

// --- A fake JVM ------------------------------------------------------------

var fake_pending_exception: jobject = null;
var fake_describe_calls: usize = 0;
var fake_clear_calls: usize = 0;
var fake_deleted_locals: usize = 0;

fn fakeExceptionOccurred(_: JNIEnv) callconv(.c) jthrowable {
    return fake_pending_exception;
}
fn fakeExceptionDescribe(_: JNIEnv) callconv(.c) void {
    fake_describe_calls += 1;
}
fn fakeExceptionClear(_: JNIEnv) callconv(.c) void {
    fake_clear_calls += 1;
    fake_pending_exception = null;
}
fn fakeDeleteLocalRef(_: JNIEnv, _: jobject) callconv(.c) void {
    fake_deleted_locals += 1;
}

var fake_class: u8 = 0;
fn fakeFindClass(_: JNIEnv, _: [*:0]const u8) callconv(.c) jclass {
    return @ptrCast(&fake_class);
}
fn fakeFindClassMissing(_: JNIEnv, _: [*:0]const u8) callconv(.c) jclass {
    return null;
}

var fake_field: u8 = 0;
fn fakeStaticFieldId(_: JNIEnv, _: jclass, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) jfieldID {
    return @ptrCast(&fake_field);
}
fn fakeStaticIntField(_: JNIEnv, _: jclass, _: jfieldID) callconv(.c) jint {
    return 34;
}

var fake_string_bytes: [*:0]const u8 = "Pixel";
fn fakeGetStringUTFChars(_: JNIEnv, _: jstring, _: ?*jboolean) callconv(.c) ?[*:0]const u8 {
    return fake_string_bytes;
}
var fake_released: usize = 0;
fn fakeReleaseStringUTFChars(_: JNIEnv, _: jstring, _: [*:0]const u8) callconv(.c) void {
    fake_released += 1;
}

fn emptyTable() JNINativeInterface {
    return std.mem.zeroes(JNINativeInterface);
}

fn resetFakes() void {
    fake_pending_exception = null;
    fake_describe_calls = 0;
    fake_clear_calls = 0;
    fake_deleted_locals = 0;
    fake_released = 0;
}

test "a pending exception is described, cleared, and reported" {
    resetFakes();
    var table = emptyTable();
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);
    table.ExceptionDescribe = @ptrCast(&fakeExceptionDescribe);
    table.ExceptionClear = @ptrCast(&fakeExceptionClear);
    table.DeleteLocalRef = @ptrCast(&fakeDeleteLocalRef);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    // Nothing pending: check is a no-op and clears nothing.
    try jni.check();
    try testing.expectEqual(@as(usize, 0), fake_clear_calls);

    // Pending: described before cleared, and the throwable's local ref freed.
    var throwable: u8 = 0;
    fake_pending_exception = @ptrCast(&throwable);
    try testing.expectError(JniError.JavaException, jni.check());
    try testing.expectEqual(@as(usize, 1), fake_describe_calls);
    try testing.expectEqual(@as(usize, 1), fake_clear_calls);

    // The leak that overflows a 16-slot local frame in a loop.
    try testing.expectEqual(@as(usize, 1), fake_deleted_locals);

    // And it really was cleared, so the next call is not poisoned.
    try jni.check();
}

test "a throwing call reports the exception rather than its return value" {
    resetFakes();
    var table = emptyTable();
    table.FindClass = @ptrCast(&fakeFindClass);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);
    table.ExceptionDescribe = @ptrCast(&fakeExceptionDescribe);
    table.ExceptionClear = @ptrCast(&fakeExceptionClear);
    table.DeleteLocalRef = @ptrCast(&fakeDeleteLocalRef);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    // The JVM's contract: a failed FindClass may still hand back a non-null
    // value with an exception pending. The exception wins.
    var throwable: u8 = 0;
    fake_pending_exception = @ptrCast(&throwable);
    try testing.expectError(JniError.JavaException, jni.findClass("android/os/Build"));
}

test "an absent class with no exception is NotFound, not a crash" {
    resetFakes();
    var table = emptyTable();
    table.FindClass = @ptrCast(&fakeFindClassMissing);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);
    try testing.expectError(JniError.NotFound, jni.findClass("android/os/Nope"));
}

test "static field reads go through the slots they name" {
    resetFakes();
    var table = emptyTable();
    table.FindClass = @ptrCast(&fakeFindClass);
    table.GetStaticFieldID = @ptrCast(&fakeStaticFieldId);
    table.GetStaticIntField = @ptrCast(&fakeStaticIntField);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    const cls = try jni.findClass("android/os/Build$VERSION");
    const id = try jni.staticFieldId(cls, "SDK_INT", "I");
    try testing.expectEqual(@as(jint, 34), try jni.staticIntField(cls, id));
}

test "a jstring is read as UTF-8 and the JVM's buffer is always released" {
    resetFakes();
    var table = emptyTable();
    table.GetStringUTFChars = @ptrCast(&fakeGetStringUTFChars);
    table.ReleaseStringUTFChars = @ptrCast(&fakeReleaseStringUTFChars);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    var str: u8 = 0;
    const text = try jni.stringToUtf8(testing.allocator, @ptrCast(&str));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Pixel", text);

    // Releasing is not optional: GetStringUTFChars may have handed back a copy,
    // and the JVM frees it on release or never.
    try testing.expectEqual(@as(usize, 1), fake_released);
}

test "a null jstring is an error, not an empty string" {
    resetFakes();
    var table = emptyTable();
    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);
    try testing.expectError(JniError.NullReference, jni.stringToUtf8(testing.allocator, null));
}

test "modified UTF-8 decodes to the standard encoding" {
    const alloc = testing.allocator;

    // Plain ASCII and ordinary multi-byte text pass straight through.
    for ([_][]const u8{ "Pixel 8 Pro", "Xiaomi", "é", "日本語", "" }) |plain| {
        const out = try decodeModifiedUtf8(alloc, plain);
        defer alloc.free(out);
        try testing.expectEqualStrings(plain, out);
    }

    // U+0000 arrives as C0 80 and must become one NUL byte. A decoder that
    // passed this through would put an overlong sequence into the JSON reply.
    {
        const out = try decodeModifiedUtf8(alloc, "a\xC0\x80b");
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, &[_]u8{ 'a', 0, 'b' }, out);
    }

    // U+1F600 as a CESU-8 surrogate pair — ED A0 BD ED B8 80 — is one
    // four-byte character in standard UTF-8. This is the form an emoji in a
    // device name actually arrives in.
    {
        const out = try decodeModifiedUtf8(alloc, "\xED\xA0\xBD\xED\xB8\x80");
        defer alloc.free(out);
        try testing.expectEqualStrings("\u{1F600}", out);
        try testing.expectEqual(@as(usize, 4), out.len);
    }

    // Surrounded by text, so the pair is found at a non-zero offset and the
    // bytes on either side survive.
    {
        const out = try decodeModifiedUtf8(alloc, "hi \xED\xA0\xBD\xED\xB8\x80!");
        defer alloc.free(out);
        try testing.expectEqualStrings("hi \u{1F600}!", out);
    }

    // A three-byte sequence starting ED that is *not* a surrogate pair is
    // ordinary text and must not be mangled: U+D7FF's neighbour U+FFFD.
    {
        const out = try decodeModifiedUtf8(alloc, "\u{FFFD}");
        defer alloc.free(out);
        try testing.expectEqualStrings("\u{FFFD}", out);
    }

    // Truncated input is refused rather than read past the end.
    try testing.expectError(JniError.MalformedString, decodeModifiedUtf8(alloc, "\xE6\x97"));
    try testing.expectError(JniError.MalformedString, decodeModifiedUtf8(alloc, "\xFF"));
}

// --- Argument passing ------------------------------------------------------

var fake_seen_args: [4]jvalue = undefined;
var fake_arg_count: usize = 0;
var fake_called_obj: jobject = null;
var fake_called_id: jmethodID = null;

var fake_returned: u8 = 0;
fn fakeCallObjectMethodA(_: JNIEnv, obj: jobject, id: jmethodID, args: [*]const jvalue) callconv(.c) jobject {
    fake_called_obj = obj;
    fake_called_id = id;
    // The fake knows its own arity; a real one is told by the signature.
    fake_seen_args[0] = args[0];
    fake_seen_args[1] = args[1];
    fake_arg_count = 2;
    return @ptrCast(&fake_returned);
}

fn fakeIntField(_: JNIEnv, _: jobject, _: jfieldID) callconv(.c) jint {
    return 1080;
}
fn fakeFloatField(_: JNIEnv, _: jobject, _: jfieldID) callconv(.c) jfloat {
    return 2.75;
}
fn fakeLongField(_: JNIEnv, _: jobject, _: jfieldID) callconv(.c) jlong {
    return 4_000_000_123;
}
fn fakeFieldId(_: JNIEnv, _: jclass, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) jfieldID {
    return @ptrCast(&fake_field);
}

test "jvalue is the eight-byte union the A-form calls expect" {
    // Wrong size here would misalign every argument after the first, and the
    // call would still run — the classic JNI failure that looks like garbage
    // data rather than a crash.
    try testing.expectEqual(@as(usize, 8), @sizeOf(jvalue));
    try testing.expectEqual(@as(usize, 8), @alignOf(jvalue));

    // Each member reads back what was written, which is what says the union is
    // laid out rather than merely sized.
    var v = jvalue{ .i = -7 };
    try testing.expectEqual(@as(jint, -7), v.i);
    v = jvalue{ .j = 4_000_000_123 };
    try testing.expectEqual(@as(jlong, 4_000_000_123), v.j);
    v = jvalue{ .d = 0.5 };
    try testing.expectEqual(@as(jdouble, 0.5), v.d);
}

test "arguments arrive in the array, in order, undamaged" {
    resetFakes();
    var table = emptyTable();
    table.CallObjectMethodA = @ptrCast(&fakeCallObjectMethodA);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    var receiver: u8 = 0;
    var name_string: u8 = 0;
    var method: u8 = 0;

    // `getPackageInfo(String, int)` — the exact shape getDeviceInfo needs, and
    // the one a variadic call would be most likely to get wrong: a reference
    // and an int, which travel in different register files.
    const args = [_]jvalue{
        .{ .l = @ptrCast(&name_string) },
        .{ .i = 0 },
    };
    const result = try jni.callObjectMethodA(@ptrCast(&receiver), @ptrCast(&method), &args);

    try testing.expect(result != null);
    try testing.expectEqual(@as(jobject, @ptrCast(&receiver)), fake_called_obj);
    try testing.expectEqual(@as(usize, 2), fake_arg_count);
    try testing.expectEqual(@as(jobject, @ptrCast(&name_string)), fake_seen_args[0].l);
    try testing.expectEqual(@as(jint, 0), fake_seen_args[1].i);
}

test "instance fields read through the slots they name" {
    resetFakes();
    var table = emptyTable();
    table.FindClass = @ptrCast(&fakeFindClass);
    table.GetFieldID = @ptrCast(&fakeFieldId);
    table.GetIntField = @ptrCast(&fakeIntField);
    table.GetFloatField = @ptrCast(&fakeFloatField);
    table.GetLongField = @ptrCast(&fakeLongField);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    const cls = try jni.findClass("android/util/DisplayMetrics");
    var obj: u8 = 0;
    const metrics: jobject = @ptrCast(&obj);

    // Three different widths off three adjacent table slots — an off-by-one in
    // the transcription would read the wrong one and still return a number.
    try testing.expectEqual(@as(jint, 1080), try jni.intField(metrics, try jni.fieldId(cls, "widthPixels", "I")));
    try testing.expectEqual(@as(jfloat, 2.75), try jni.floatField(metrics, try jni.fieldId(cls, "density", "F")));
    try testing.expectEqual(@as(jlong, 4_000_000_123), try jni.longField(metrics, try jni.fieldId(cls, "longVersionCode", "J")));
}

test "a field read that throws reports the exception, not the value" {
    resetFakes();
    var table = emptyTable();
    table.GetIntField = @ptrCast(&fakeIntField);
    table.ExceptionOccurred = @ptrCast(&fakeExceptionOccurred);
    table.ExceptionDescribe = @ptrCast(&fakeExceptionDescribe);
    table.ExceptionClear = @ptrCast(&fakeExceptionClear);
    table.DeleteLocalRef = @ptrCast(&fakeDeleteLocalRef);

    const ptr: *const JNINativeInterface = &table;
    const jni = Jni.init(&ptr);

    var throwable: u8 = 0;
    fake_pending_exception = @ptrCast(&throwable);
    var obj: u8 = 0;
    try testing.expectError(JniError.JavaException, jni.intField(@ptrCast(&obj), null));
}
