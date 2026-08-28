// A stand-in for the host shim, so the hand-off path can be exercised.
//
// Written in Objective-C rather than Swift on purpose. The contract Zig
// depends on is a runtime one — `objc_getClass("CraftSwiftShim")` plus a
// message send — and a `@objc` Swift class presents exactly that same
// contract. Using ObjC here keeps the harness to a single clang invocation
// with no swiftc, while testing the identical mechanism.
//
// The shape being proven is the important part: the shim answers *what*, never
// *how*. It produces a payload and hands it back through
// `craft_ios_deliver_result`, so the wire format, the request id and the
// escaping all stay on the Zig side. Two components replying to one page by
// two different routes is how this codebase accumulated five envelopes.
#import <Foundation/Foundation.h>

extern void craft_ios_deliver_result(const char *action, unsigned long action_len,
                                     const char *json, unsigned long json_len,
                                     long long request_id);

@interface CraftSwiftShim : NSObject
@end

@implementation CraftSwiftShim

+ (BOOL)handleAction:(NSString *)action
             payload:(NSString *)payload
           requestId:(long long)requestId {
    // Exactly one action, to prove the seam. A real shim dispatches the
    // ~105 the Swift template still owns.
    if (![action isEqualToString:@"hostOnlyPing"]) {
        return NO;  // Not ours. Zig answers with UnknownAction.
    }

    NSString *json = [NSString stringWithFormat:
        @"{\"servedBy\":\"host-shim\",\"echo\":%@}",
        payload.length ? [NSString stringWithFormat:@"\"%lu\"", (unsigned long)payload.length] : @"null"];

    const char *actionBytes = action.UTF8String;
    const char *jsonBytes = json.UTF8String;
    craft_ios_deliver_result(actionBytes, strlen(actionBytes),
                             jsonBytes, strlen(jsonBytes),
                             requestId);
    return YES;
}

@end
