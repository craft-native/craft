// The host shim, mirroring the design `CraftApp.swift`'s CraftSwiftShim uses —
// including the part most likely to fail silently in production: discovering
// Zig's delivery exports with `dlsym` rather than linking them.
//
// That discovery is the template's load-bearing assumption. A pure-Swift app
// has no Zig runtime, so the template cannot use `@_silgen_name` (a hard link
// dependency); it resolves the symbols at runtime and declines when absent.
// Whether `dlsym(dlopen(nil, RTLD_NOW), ...)` finds a symbol that was
// *statically linked* into the executable is exactly the kind of fact that
// must be proven on a simulator, because if a build setting strips it from the
// dynamic symbol table the seam degrades to "shim declines everything" with no
// error anywhere.
//
// Two actions, proving the two reply routes:
//   hostOnlyPing  -> craft_ios_deliver_result  (the page's promise resolves)
//   hostOnlyFail  -> craft_ios_deliver_error   (the page's promise rejects)
// The error route matters independently: delivering a rejection as a result
// would run the app's then-branch with an error-shaped object.
import Foundation

private typealias DeliverResultFn = @convention(c) (
    UnsafePointer<CChar>, UInt, UnsafePointer<CChar>, UInt, Int64
) -> Void
private typealias DeliverErrorFn = @convention(c) (
    UnsafePointer<CChar>, UInt, UnsafePointer<CChar>, UInt,
    UnsafePointer<CChar>, UInt, Int64
) -> Void

private let deliverResult: DeliverResultFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "craft_ios_deliver_result") else { return nil }
    return unsafeBitCast(sym, to: DeliverResultFn.self)
}()

private let deliverError: DeliverErrorFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "craft_ios_deliver_error") else { return nil }
    return unsafeBitCast(sym, to: DeliverErrorFn.self)
}()

@objc(CraftSwiftShim)
public class CraftSwiftShim: NSObject {
    @objc public static func handleAction(
        _ action: String,
        payload: String,
        requestId: Int64
    ) -> Bool {
        switch action {
        case "hostOnlyPing":
            guard let deliverResult else { return false }
            let json = "{\"servedBy\":\"host-shim\",\"language\":\"swift\",\"payloadBytes\":\(payload.utf8.count)}"
            action.withCString { a in
                json.withCString { j in
                    deliverResult(a, UInt(strlen(a)), j, UInt(strlen(j)), requestId)
                }
            }
            return true

        case "hostOnlyFail":
            guard let deliverError else { return false }
            // The message deliberately contains the characters Swift's old
            // hand-escaping mangled: a backslash, a quote, and a newline. If
            // they reach the page intact, escaping lives on the Zig side where
            // it belongs.
            let message = "declined \\ \"on purpose\"\nsecond line"
            action.withCString { a in
                message.withCString { m in
                    "HOST_DECLINED".withCString { c in
                        deliverError(a, UInt(strlen(a)), m, UInt(strlen(m)),
                                     c, UInt(strlen(c)), requestId)
                    }
                }
            }
            return true

        default:
            return false
        }
    }
}
