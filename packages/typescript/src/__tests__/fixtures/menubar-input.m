#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>

static CFTypeRef attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, key, &value);
    return value;
}

static NSString *textAttribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = attribute(element, key);
    return value ? CFBridgingRelease(value) : @"";
}

static AXUIElementRef findControl(AXUIElementRef element, NSString *selector, NSUInteger depth) {
    if (depth > 7) return NULL;
    NSString *description = textAttribute(element, kAXDescriptionAttribute);
    NSString *help = textAttribute(element, kAXHelpAttribute);
    BOOL match = [selector isEqualToString:@"arrow"]
        ? [description isEqualToString:@"Hide menu bar items"] || [description isEqualToString:@"Show menu bar items"]
        : [help isEqualToString:@"Craft grouping boundary target"];
    if (match) return (AXUIElementRef)CFRetain(element);
    for (id key in @[(__bridge id)kAXChildrenAttribute, (__bridge id)kAXExtrasMenuBarAttribute]) {
        CFTypeRef children = attribute(element, (__bridge CFStringRef)key);
        if (!children) continue;
        AXUIElementRef found = NULL;
        if (CFGetTypeID(children) == CFArrayGetTypeID()) {
            for (id child in (__bridge NSArray *)children) {
                found = findControl((__bridge AXUIElementRef)child, selector, depth + 1);
                if (found) break;
            }
        } else if (CFGetTypeID(children) == AXUIElementGetTypeID()) {
            found = findControl((AXUIElementRef)children, selector, depth + 1);
        }
        CFRelease(children);
        if (found) return found;
    }
    return NULL;
}

static CGRect frame(AXUIElementRef element) {
    CGPoint origin = CGPointZero;
    CGSize size = CGSizeZero;
    CFTypeRef position = attribute(element, kAXPositionAttribute);
    CFTypeRef dimensions = attribute(element, kAXSizeAttribute);
    if (position) { AXValueGetValue(position, kAXValueCGPointType, &origin); CFRelease(position); }
    if (dimensions) { AXValueGetValue(dimensions, kAXValueCGSizeType, &size); CFRelease(dimensions); }
    return (CGRect){origin, size};
}

static void emit(AXUIElementRef element) {
    pid_t owner = 0;
    AXUIElementGetPid(element, &owner);
    CGRect bounds = frame(element);
    NSDictionary *result = @{
        @"pid": @(owner), @"title": textAttribute(element, kAXTitleAttribute),
        @"description": textAttribute(element, kAXDescriptionAttribute),
        @"help": textAttribute(element, kAXHelpAttribute),
        @"x": @(bounds.origin.x), @"y": @(bounds.origin.y),
        @"width": @(bounds.size.width), @"height": @(bounds.size.height),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
}

static void mouse(CGEventSourceRef source, CGEventType type, CGPoint position, CGEventFlags flags) {
    CGEventRef event = CGEventCreateMouseEvent(source, type, position, kCGMouseButtonLeft);
    CGEventSetFlags(event, flags);
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void drag(CGPoint from, CGPoint to) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef commandDown = CGEventCreateKeyboardEvent(source, 55, true);
    CGEventSetFlags(commandDown, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, commandDown);
    usleep(150000);
    mouse(source, kCGEventMouseMoved, from, kCGEventFlagMaskCommand);
    mouse(source, kCGEventLeftMouseDown, from, kCGEventFlagMaskCommand);
    usleep(200000);
    for (int step = 1; step <= 40; step++) {
        double fraction = step / 40.0;
        CGPoint point = CGPointMake(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction);
        mouse(source, kCGEventLeftMouseDragged, point, kCGEventFlagMaskCommand);
        usleep(25000);
    }
    usleep(200000);
    mouse(source, kCGEventLeftMouseUp, to, kCGEventFlagMaskCommand);
    usleep(150000);
    CGEventRef commandUp = CGEventCreateKeyboardEvent(source, 55, false);
    CGEventSetFlags(commandUp, 0);
    CGEventPost(kCGHIDEventTap, commandUp);
    CFRelease(commandDown);
    CFRelease(commandUp);
    CFRelease(source);
    usleep(300000);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *operation = @(argv[1]);
        if ([operation isEqualToString:@"permissions"]) {
            BOOL permitted = CGPreflightPostEventAccess() && AXIsProcessTrusted();
            puts(permitted ? "ready" : "Native drag E2E requires existing Accessibility and input-event permission.");
            return permitted ? 0 : 3;
        }
        if ([operation isEqualToString:@"hit"] && argc == 4) {
            AXUIElementRef system = AXUIElementCreateSystemWide(), element = NULL;
            AXError result = AXUIElementCopyElementAtPosition(system, atof(argv[2]), atof(argv[3]), &element);
            CFRelease(system);
            if (result != kAXErrorSuccess || !element) return 4;
            emit(element);
            CFRelease(element);
            return 0;
        }
        if (argc < 4) return 2;
        AXUIElementRef app = AXUIElementCreateApplication(atoi(argv[2]));
        AXUIElementRef element = findControl(app, @(argv[3]), 0);
        CFRelease(app);
        if (!element) { fputs("Owned status control not found\n", stderr); return 4; }
        CGRect bounds = frame(element);
        CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        if ([operation isEqualToString:@"drag"] && argc == 5) {
            if (!CGPreflightPostEventAccess()) return 3;
            drag(center, CGPointMake(atof(argv[4]), center.y));
        } else if ([operation isEqualToString:@"click"] || [operation isEqualToString:@"command-click"]) {
            if (!CGPreflightPostEventAccess()) return 3;
            BOOL command = [operation isEqualToString:@"command-click"];
            CGEventFlags flags = command ? kCGEventFlagMaskCommand : 0;
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            if (command) {
                CGEventRef down = CGEventCreateKeyboardEvent(source, 55, true);
                CGEventSetFlags(down, flags);
                CGEventPost(kCGHIDEventTap, down);
                CFRelease(down);
                usleep(150000);
            }
            mouse(source, kCGEventMouseMoved, center, flags);
            usleep(100000);
            mouse(source, kCGEventLeftMouseDown, center, flags);
            usleep(command ? 300000 : 100000);
            mouse(source, kCGEventLeftMouseUp, center, flags);
            if (command) {
                CGEventRef up = CGEventCreateKeyboardEvent(source, 55, false);
                CGEventSetFlags(up, 0);
                CGEventPost(kCGHIDEventTap, up);
                CFRelease(up);
            }
            CFRelease(source);
        } else if (![operation isEqualToString:@"inspect"]) {
            CFRelease(element);
            return 2;
        }
        emit(element);
        CFRelease(element);
    }
    return 0;
}
