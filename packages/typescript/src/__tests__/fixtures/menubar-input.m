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

static BOOL matchesControl(AXUIElementRef element, NSString *selector) {
    NSString *description = textAttribute(element, kAXDescriptionAttribute);
    NSString *help = textAttribute(element, kAXHelpAttribute);
    return [selector isEqualToString:@"arrow"]
        ? [description isEqualToString:@"Hide menu bar items"] || [description isEqualToString:@"Show menu bar items"]
        : [help isEqualToString:@"Craft grouping boundary target"];
}

static AXUIElementRef findControl(AXUIElementRef element, NSString *selector, NSUInteger depth) {
    if (depth > 7) return NULL;
    if (matchesControl(element, selector)) return (AXUIElementRef)CFRetain(element);
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

static NSTimeInterval inputReleasedAt;

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
        @"inputReleasedAt": @(inputReleasedAt),
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
    CGEventSetType(commandDown, kCGEventFlagsChanged);
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
    CGEventSetType(commandUp, kCGEventFlagsChanged);
    CGEventSetFlags(commandUp, 0);
    CGEventPost(kCGHIDEventTap, commandUp);
    CFRelease(commandDown);
    CFRelease(commandUp);
    CFRelease(source);
    usleep(300000);
}

static void traceClick(AXUIElementRef arrow, AXUIElementRef tray, NSUInteger duration) {
    pid_t owner = 0;
    AXUIElementGetPid(arrow, &owner);
    CGRect target = tray ? frame(tray) : CGRectZero;
    CGPoint targetCenter = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    CGRect bounds = frame(arrow);
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    AXUIElementRef system = AXUIElementCreateSystemWide();
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    mouse(source, kCGEventMouseMoved, center, 0);
    usleep(100000);
    NSMutableArray *samples = [NSMutableArray array];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    void (^sample)(void) = ^{
        CGRect arrowFrame = frame(arrow);
        CGRect trayFrame = tray ? frame(tray) : CGRectZero;
        AXUIElementRef hit = NULL;
        BOOL visible = tray && AXUIElementCopyElementAtPosition(system, targetCenter.x, targetCenter.y, &hit) == kAXErrorSuccess
            && [textAttribute(hit, kAXHelpAttribute) isEqualToString:@"Craft grouping boundary target"];
        pid_t targetOwner = 0;
        if (hit) { AXUIElementGetPid(hit, &targetOwner); CFRelease(hit); }
        visible = visible && targetOwner == owner;
        hit = NULL;
        BOOL arrowVisible = AXUIElementCopyElementAtPosition(system, center.x, center.y, &hit) == kAXErrorSuccess
            && ([textAttribute(hit, kAXDescriptionAttribute) isEqualToString:@"Hide menu bar items"] || [textAttribute(hit, kAXDescriptionAttribute) isEqualToString:@"Show menu bar items"]);
        pid_t hitOwner = 0;
        if (hit) { AXUIElementGetPid(hit, &hitOwner); CFRelease(hit); }
        arrowVisible = arrowVisible && hitOwner == owner;
        [samples addObject:@{
            @"ms": @((NSProcessInfo.processInfo.systemUptime - start) * 1000),
            @"arrowVisible": @(arrowVisible), @"arrowX": @(arrowFrame.origin.x), @"arrowWidth": @(arrowFrame.size.width),
            @"trayX": @(trayFrame.origin.x), @"trayVisible": @(visible),
        }];
    };
    // Querying AX during AppKit's mouse tracking can block until mouse-up.
    // Capture the baseline first, then sample after a normal physical click.
    sample();
    mouse(source, kCGEventLeftMouseDown, center, 0);
    usleep(100000);
    mouse(source, kCGEventLeftMouseUp, center, 0);
    do {
        usleep(20000);
        sample();
    } while ((NSProcessInfo.processInfo.systemUptime - start) * 1000 < duration);
    NSData *json = [NSJSONSerialization dataWithJSONObject:samples options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    CFRelease(source);
    CFRelease(system);
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
        if ([operation isEqualToString:@"app-pid"] && argc == 3) {
            NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@(argv[2])];
            if (apps.count != 1) return 4;
            printf("%d\n", apps.firstObject.processIdentifier);
            return 0;
        }
        if (argc < 4) return 2;
        AXUIElementRef app = AXUIElementCreateApplication(atoi(argv[2]));
        AXUIElementRef element = findControl(app, @(argv[3]), 0);
        // A visible status button can be reparented into MenuBarAgent's AX
        // scene while its app's other items overflow. Resolve the last known
        // physical point, requiring both the original owner and exact control.
        if (!element && argc >= 6) {
            AXUIElementRef system = AXUIElementCreateSystemWide(), hit = NULL;
            if (AXUIElementCopyElementAtPosition(system, atof(argv[argc - 2]), atof(argv[argc - 1]), &hit) == kAXErrorSuccess && hit) {
                pid_t owner = 0;
                AXUIElementGetPid(hit, &owner);
                if (owner == atoi(argv[2]) && matchesControl(hit, @(argv[3]))) element = hit;
                else CFRelease(hit);
            }
            CFRelease(system);
        }
        if (element && [operation isEqualToString:@"trace-click"]) {
            if (!CGPreflightPostEventAccess()) { CFRelease(element); CFRelease(app); return 3; }
            AXUIElementRef tray = findControl(app, @"tray", 0);
            if (!tray && argc >= 9) {
                AXUIElementRef system = AXUIElementCreateSystemWide(), hit = NULL;
                if (AXUIElementCopyElementAtPosition(system, atof(argv[5]), atof(argv[6]), &hit) == kAXErrorSuccess && hit) {
                    pid_t owner = 0;
                    AXUIElementGetPid(hit, &owner);
                    if (owner == atoi(argv[2]) && matchesControl(hit, @"tray")) tray = hit;
                    else CFRelease(hit);
                }
                CFRelease(system);
            }
            NSUInteger duration = argc >= 5 ? strtoul(argv[4], NULL, 10) : 8000;
            traceClick(element, tray, MIN(MAX(duration, 100), 12000));
            if (tray) CFRelease(tray);
            CFRelease(element);
            CFRelease(app);
            return 0;
        }
        CFRelease(app);
        if (!element) { fputs("Owned status control not found\n", stderr); return 4; }
        CGRect bounds = frame(element);
        CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        if ([operation isEqualToString:@"drag"] && argc >= 5) {
            if (!CGPreflightPostEventAccess()) return 3;
            drag(center, CGPointMake(atof(argv[4]), center.y));
        } else if ([operation isEqualToString:@"click"] || [operation isEqualToString:@"command-click"]) {
            if (!CGPreflightPostEventAccess()) return 3;
            BOOL command = [operation isEqualToString:@"command-click"];
            CGEventFlags flags = command ? kCGEventFlagMaskCommand : 0;
            CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            if (command) {
                CGEventRef down = CGEventCreateKeyboardEvent(source, 55, true);
                CGEventSetType(down, kCGEventFlagsChanged);
                CGEventSetFlags(down, flags);
                CGEventPost(kCGHIDEventTap, down);
                CFRelease(down);
                usleep(150000);
            }
            mouse(source, kCGEventMouseMoved, center, flags);
            usleep(100000);
            mouse(source, kCGEventLeftMouseDown, center, flags);
            usleep(command ? 300000 : 100000);
            inputReleasedAt = NSDate.date.timeIntervalSince1970 * 1000;
            mouse(source, kCGEventLeftMouseUp, center, flags);
            if (command) {
                CGEventRef up = CGEventCreateKeyboardEvent(source, 55, false);
                CGEventSetType(up, kCGEventFlagsChanged);
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
