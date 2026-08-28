// The host shim, in Swift, presenting the contract `CraftApp.swift` will.
//
// This replaces an Objective-C stand-in. The stand-in proved the runtime
// mechanism — `objc_getClass` plus a message send — but not that *Swift*
// presents that mechanism the way Zig expects: that `@objc(CraftSwiftShim)`
// really does register under that name, that a `static func` becomes a class
// method reachable by selector, that `String` parameters bridge from NSString,
// and that `Bool` comes back as the ObjC BOOL Zig reads.
//
// Those are exactly the assumptions the real wiring will rest on, so they are
// worth testing against the real compiler rather than assumed from a language
// that shares an ABI with it.
import Foundation

// Zig owns the reply path. The shim decides *what* the answer is and hands it
// back; the wire format, the request id and the escaping stay on the other
// side. `@_silgen_name` reaches the exported symbol without needing a bridging
// header, which keeps the harness to one swiftc invocation.
@_silgen_name("craft_ios_deliver_result")
func craft_ios_deliver_result(
    _ action: UnsafePointer<CChar>, _ actionLen: UInt,
    _ json: UnsafePointer<CChar>, _ jsonLen: UInt,
    _ requestId: Int64
)

@objc(CraftSwiftShim)
public class CraftSwiftShim: NSObject {
    // Selector: handleAction:payload:requestId:  — which is what
    // `ios_dispatch.handOffToHost` sends. A mismatch here is not a compile
    // error on either side, so the simulator assertion is what catches it.
    @objc public static func handleAction(
        _ action: String,
        payload: String,
        requestId: Int64
    ) -> Bool {
        // Exactly one action, to prove the seam. A real shim dispatches the
        // ~105 the Swift template still owns.
        guard action == "hostOnlyPing" else {
            // Not ours. Zig answers UnknownAction, which is the same path a
            // fully-migrated app with no shim at all takes.
            return false
        }

        let json = "{\"servedBy\":\"host-shim\",\"language\":\"swift\",\"payloadBytes\":\(payload.utf8.count)}"

        action.withCString { a in
            json.withCString { j in
                craft_ios_deliver_result(
                    a, UInt(strlen(a)),
                    j, UInt(strlen(j)),
                    requestId
                )
            }
        }
        return true
    }
}
