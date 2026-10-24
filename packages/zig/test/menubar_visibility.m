// Exercises the production native lifecycle with controlled asynchronous replies.
// No Accessibility grant or live menu-bar restriction is used by this fixture.
#import <ApplicationServices/ApplicationServices.h>
static Boolean trusted = true;
static Boolean testTrusted(void) { return trusted; }
#define AXIsProcessTrusted testTrusted
#import "../src/menubar_visibility.m"
#include <assert.h>
#include <spawn.h>
#include <sys/wait.h>

static BOOL snapshotItems(AXUIElementRef node, NSUInteger depth, BOOL root, double boundary, BOOL rtl,
    BOOL protectedOnly, NSMutableDictionary *items, NSUInteger *remaining) {
    return collectSnapshotItems(node, depth, root, boundary, rtl, protectedOnly, 0, CGRectInfinite, items, nil, nil, remaining);
}

@interface TestRunningApplication : NSObject
@property (copy) NSString *bundleIdentifier;
@property pid_t processIdentifier;
@end
@implementation TestRunningApplication
@end

@interface TestConfiguration : NSObject <CraftVisibilityConfiguration>
@end
@implementation TestConfiguration
- (id)initWithAllowedSystemItems:(NSArray *)systemItems allowedBundleIdentifiers:(NSArray *)bundles {
    assert([systemItems isKindOfClass:NSArray.class]);
    assert([bundles isKindOfClass:NSArray.class]);
    return [super init];
}
@end

static BOOL throwOnActivation;
static NSMutableArray *created;
static NSDictionary *snapshot = nil;
static NSUInteger retainedSelectionReads;
static NSDictionary *testSnapshot(pid_t agent, double boundary, BOOL rtl, BOOL protectedOnly, CGRect display) {
    (void)agent; (void)boundary; (void)rtl; (void)protectedOnly; (void)display;
    if (retainedSelectionReads) {
        retainedSelectionReads--;
        return @{@"anonymous:1234": @1, @"right": @1};
    }
    return snapshot;
}

static NSMutableDictionary *nodeAttributes;
static id testAttribute(AXUIElementRef node, CFStringRef name) {
    return nodeAttributes[[NSValue valueWithPointer:node]][(__bridge NSString *)name];
}
static id testNode(NSDictionary *attributes) {
    static pid_t next = 1000000;
    id node = CFBridgingRelease(AXUIElementCreateApplication(next++));
    nodeAttributes[[NSValue valueWithPointer:(__bridge void *)node]] = attributes;
    return node;
}
static AXError testOwner(AXUIElementRef node, pid_t *pid) {
    NSNumber *owner = nodeAttributes[[NSValue valueWithPointer:node]][@"testOwner"];
    if (!owner) return AXUIElementGetPid(node, pid);
    *pid = owner.intValue;
    return kAXErrorSuccess;
}
static void verifyDisplayCoordinates(void) {
    NSRect primary = NSMakeRect(0, 0, 1000, 800);
    assert(CGRectEqualToRect(accessibilityScreenBounds(primary, primary), CGRectMake(0, 0, 1000, 800)));
    assert(CGRectEqualToRect(accessibilityScreenBounds(NSMakeRect(1000, 0, 1200, 900), primary), CGRectMake(1000, -100, 1200, 900)));
    assert(CGRectEqualToRect(accessibilityScreenBounds(NSMakeRect(0, 800, 1000, 800), primary), CGRectMake(0, -800, 1000, 800)));
    assert(CGRectEqualToRect(accessibilityScreenBounds(NSMakeRect(-1000, -800, 1000, 800), primary), CGRectMake(-1000, 800, 1000, 800)));
}

static void verifySystemGrouping(void) {
    assert([systemItemIdentifier(@"com.apple.menuextra.battery") isEqual:@0]);
    assert([systemItemIdentifier(@"com.apple.menuextra.wifi") isEqual:@6]);
    assert([systemItemIdentifier(@"com.apple.menuextra.controlcenter") isEqual:@8]);
    assert(!systemItemIdentifier(@"com.apple.menuextra.future"));
    NSUInteger hidden = 0;
    preserveSystemItems = NO;
    NSArray *allowed = allowedSystemItems(@{@0: @NO, @6: @NO, @2: @YES}, &hidden);
    assert(hidden == 2 && ![allowed containsObject:@0] && ![allowed containsObject:@6]);
    assert([allowed containsObject:@2] && [allowed containsObject:@8] && [allowed containsObject:@63]);
    preserveSystemItems = YES;
    allowed = allowedSystemItems(@{@0: @NO, @6: @NO}, &hidden);
    assert(hidden == 0 && allowed.count == 64);
}

static void verifyRecreatedAnonymousItems(void) {
    nodeAttributes = [NSMutableDictionary dictionary];
    CGPoint point = CGPointMake(200, 0);
    CGSize size = CGSizeMake(20, 24);
    NSMutableDictionary *attributes = [@{
        (__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXMenuBarItemRole,
        (__bridge NSString *)kAXTitleAttribute: @"Original meter",
        (__bridge NSString *)kAXPositionAttribute: CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point)),
        (__bridge NSString *)kAXSizeAttribute: CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &size)),
        @"testOwner": @1234,
    } mutableCopy];
    id before = testNode([attributes copy]);
    point.x = 300;
    attributes[(__bridge NSString *)kAXPositionAttribute] = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point));
    attributes[(__bridge NSString *)kAXTitleAttribute] = @"Updated meter";
    id after = testNode([attributes copy]);
    assert(!CFEqual((__bridge CFTypeRef)before, (__bridge CFTypeRef)after));
    NSMutableDictionary *overlapAttributes = [attributes mutableCopy];
    CGPoint overlapped = CGPointMake(95, 0);
    overlapAttributes[(__bridge NSString *)kAXPositionAttribute] = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &overlapped));
    id overlapping = testNode(overlapAttributes);
    readAttribute = testAttribute;
    readOwner = testOwner;
    NSMutableDictionary *overlappingItems = [NSMutableDictionary dictionary];
    NSUInteger overlapRemaining = 256;
    assert(!collectSnapshotItems((__bridge AXUIElementRef)overlapping, 8, NO, 100, NO, YES, 0, CGRectInfinite, overlappingItems, nil, nil, &overlapRemaining));

    NSMutableDictionary *systemAttributes = [attributes mutableCopy];
    systemAttributes[(__bridge NSString *)kAXIdentifierAttribute] = @"com.apple.menuextra.wifi";
    id wifi = testNode(systemAttributes);
    NSMutableDictionary *systemSections = [NSMutableDictionary dictionary];
    NSUInteger wifiRemaining = 256;
    preserveSystemItems = NO;
    id systemHost = testNode(@{
        (__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXGroupRole,
        (__bridge NSString *)kAXIdentifierAttribute: @"com.apple.menuextra.wifi",
        (__bridge NSString *)kAXChildrenAttribute: @[wifi],
    });
    assert(collectSnapshotItems((__bridge AXUIElementRef)systemHost, 8, NO, 400, NO, YES, 1234, CGRectInfinite, overlappingItems, nil, systemSections, &wifiRemaining));
    assert(systemSections[@6] && ![systemSections[@6] boolValue]);
    wifiRemaining = 256;
    assert(collectSnapshotItems((__bridge AXUIElementRef)wifi, 8, NO, 100, NO, YES, 1234, CGRectInfinite, overlappingItems, nil, systemSections, &wifiRemaining));
    assert([systemSections[@6] boolValue]);
    // A mirrored control on another screen must not keep this screen's hidden
    // item visible. Only the arrow's display determines group membership.
    [systemSections removeAllObjects];
    systemAttributes[(__bridge NSString *)kAXPositionAttribute] = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &(CGPoint){20, 0}));
    id localWifi = testNode([systemAttributes copy]);
    systemAttributes[(__bridge NSString *)kAXPositionAttribute] = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &(CGPoint){200, 0}));
    id remoteWifi = testNode([systemAttributes copy]);
    for (id item in @[localWifi, remoteWifi]) {
        wifiRemaining = 256;
        assert(collectSnapshotItems((__bridge AXUIElementRef)item, 8, NO, 100, NO, YES, 1234, CGRectMake(0, 0, 150, 100), overlappingItems, nil, systemSections, &wifiRemaining));
    }
    assert(systemSections[@6] && ![systemSections[@6] boolValue]);

    NSMutableDictionary *systemItems = [NSMutableDictionary dictionary];
    readAttribute = testAttribute;
    readOwner = testOwner;
    preserveSystemItems = NO;
    NSUInteger systemRemaining = 256;
    assert(collectSnapshotItems((__bridge AXUIElementRef)before, 8, NO, 100, NO, YES, 1234, CGRectInfinite, systemItems, nil, nil, &systemRemaining));
    assert(!systemItems.count);
    preserveSystemItems = YES;
    systemRemaining = 256;
    assert(collectSnapshotItems((__bridge AXUIElementRef)before, 8, NO, 100, NO, YES, 1234, CGRectInfinite, systemItems, nil, nil, &systemRemaining));
    assert(systemItems.count == 1);

    readAttribute = testAttribute;
    readOwner = testOwner;
    NSMutableDictionary *expected = [NSMutableDictionary dictionary], *actual = [NSMutableDictionary dictionary];
    NSUInteger remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)before, 8, NO, 100, NO, YES, expected, &remaining));
    remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)after, 8, NO, 100, NO, NO, actual, &remaining));
    assert(preservesItems(expected, actual));
    // Grouping consumes the exact displayed owner positions used to protect
    // icons. An app's separate, potentially stale AX geometry is never read.
    NSMutableDictionary *owners = [NSMutableDictionary dictionary];
    [expected removeAllObjects]; remaining = 256;
    assert(collectSnapshotItems((__bridge AXUIElementRef)before, 8, NO, 100, NO, YES, 0, CGRectInfinite, expected, owners, nil, &remaining));
    assert([owners[@1234] boolValue]);
    TestRunningApplication *visibleApp = [TestRunningApplication new];
    visibleApp.bundleIdentifier = @"visible.app"; visibleApp.processIdentifier = 1234;
    point.x = 20;
    attributes[(__bridge NSString *)kAXPositionAttribute] = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point));
    attributes[@"testOwner"] = @7890;
    id left = testNode([attributes copy]);
    remaining = 256;
    assert(collectSnapshotItems((__bridge AXUIElementRef)left, 8, NO, 100, NO, YES, 0, CGRectInfinite, expected, owners, nil, &remaining));
    assert(owners[@7890] && ![owners[@7890] boolValue]);
    TestRunningApplication *hiddenApp = [TestRunningApplication new];
    hiddenApp.bundleIdentifier = @"hidden.app"; hiddenApp.processIdentifier = 7890;
    NSDictionary *sections = inventory((id)@[visibleApp, hiddenApp], owners);
    assert([sections[@"visible.app"] boolValue] && ![sections[@"hidden.app"] boolValue]);
    hiddenApp.bundleIdentifier = @"visible.app";
    sections = inventory((id)@[visibleApp, hiddenApp], owners);
    assert([sections[@"visible.app"] boolValue]);
    hiddenApp.processIdentifier = 9876;
    hiddenApp.bundleIdentifier = @"unknown.app";
    sections = inventory((id)@[hiddenApp], owners);
    assert(!sections[@"unknown.app"]);
    expected[@"anonymous:1234"] = @2;
    assert(!preservesItems(expected, actual));
    expected[@"anonymous:1234"] = @1;
    attributes[@"testOwner"] = @5678;
    id unrelated = testNode(attributes);
    [actual removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)unrelated, 8, NO, 100, NO, NO, actual, &remaining));
    assert(!preservesItems(expected, actual));
    readOwner = AXUIElementGetPid;
    readAttribute = attribute;
    nodeAttributes = nil;
}
static void verifyNativeHostedGeometry(void) {
    nodeAttributes = [NSMutableDictionary dictionary];
    CGPoint stale = CGPointMake(20, 0);
    CGSize size = CGSizeMake(24, 24);
    // App extras are stale on the primary display; its authoritative native
    // slot is on the second display to the LEFT of that display's arrow.
    id extra = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXMenuBarItemRole,
        (__bridge NSString *)kAXPositionAttribute: CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &stale)),
        (__bridge NSString *)kAXSizeAttribute: CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &size)), @"testOwner": @1234});
    id extras = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXMenuBarRole,
        (__bridge NSString *)kAXChildrenAttribute: @[extra]});
    id remote = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXApplicationRole,
        @"AXExtrasMenuBar": extras, @"testOwner": @1234});
    CGPoint displayed = CGPointMake(1200, 0);
    id host = testNode(@{(__bridge NSString *)kAXPositionAttribute: CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &displayed)),
        (__bridge NSString *)kAXSizeAttribute: CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &size)),
        (__bridge NSString *)kAXChildrenAttribute: @[remote], @"testOwner": @99});
    readAttribute = testAttribute; readOwner = testOwner;
    for (BOOL readable = NO; ; readable = YES) {
        NSMutableDictionary *remoteAttributes = [nodeAttributes[[NSValue valueWithPointer:(__bridge void *)remote]] mutableCopy];
        if (!readable) [remoteAttributes removeObjectForKey:@"AXExtrasMenuBar"];
        else remoteAttributes[@"AXExtrasMenuBar"] = extras;
        nodeAttributes[[NSValue valueWithPointer:(__bridge void *)remote]] = remoteAttributes;
        NSMutableDictionary *owners = [NSMutableDictionary dictionary], *items = [NSMutableDictionary dictionary];
        NSUInteger remaining = 256;
        assert(collectSnapshotItems((__bridge AXUIElementRef)host, 8, NO, 1300, NO, YES, 99,
            CGRectMake(1000, 0, 1000, 800), items, owners, nil, &remaining));
        assert(owners[@1234] && ![owners[@1234] boolValue] && !items.count);
        // The same remote application on the visible side must remain visible,
        // including when stale app coordinates would place it in the group.
        remaining = 256; [owners removeAllObjects];
        assert(collectSnapshotItems((__bridge AXUIElementRef)host, 8, NO, 1100, NO, YES, 99,
            CGRectMake(1000, 0, 1000, 800), items, owners, nil, &remaining));
        assert([owners[@1234] boolValue] && [items[@"anonymous:1234"] unsignedIntegerValue] == 1);
        if (readable) break;
    }
    // Native button proxies use the displayed slot too; stale child geometry
    // must not duplicate or move an icon to a different display.
    NSMutableDictionary *hostAttributes = [nodeAttributes[[NSValue valueWithPointer:(__bridge void *)host]] mutableCopy];
    hostAttributes[(__bridge NSString *)kAXChildrenAttribute] = @[extra];
    nodeAttributes[[NSValue valueWithPointer:(__bridge void *)host]] = hostAttributes;
    NSMutableDictionary *owners = [NSMutableDictionary dictionary], *items = [NSMutableDictionary dictionary];
    NSUInteger remaining = 256;
    assert(collectSnapshotItems((__bridge AXUIElementRef)host, 8, NO, 1300, NO, YES, 99,
        CGRectMake(1000, 0, 1000, 800), items, owners, nil, &remaining));
    assert(owners[@1234] && ![owners[@1234] boolValue]);
    readOwner = AXUIElementGetPid; readAttribute = attribute; nodeAttributes = nil;
}

static void verifyButtonBoundary(void) {
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 200, 24)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(12, 0, 180, 24)];
    [window.contentView addSubview:container];
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(8, 0, 20, 24)];
    [container addSubview:button];
    // The hosting window can span both status items. The group boundary is
    // the arrow's own button, whichever side of the app icon it occupies.
    for (NSNumber *offset in @[@8, @108]) {
        button.frame = NSMakeRect(offset.doubleValue, 0, 20, 24);
        NSRect frame = buttonScreenFrame(button);
        assert(fabs(frame.origin.x - (112 + offset.doubleValue)) < 0.01);
        assert(fabs(frame.size.width - 20) < 0.01);
        NSMutableDictionary *sections = [NSMutableDictionary dictionary];
        recordItem(sections, @"left", CGRectMake(NSMinX(frame) - 30, 0, 20, 24), NSMidX(frame), NO);
        recordItem(sections, @"right", CGRectMake(NSMaxX(frame) + 10, 0, 20, 24), NSMidX(frame), NO);
        assert(![sections[@"left"] boolValue] && [sections[@"right"] boolValue]);
    }
    [button removeFromSuperview];
    assert(NSIsEmptyRect(buttonScreenFrame(button)));
    [window close];
}
static void verifyStatusItemScope(void) {
    nodeAttributes = [NSMutableDictionary dictionary];
    CGPoint point = CGPointMake(200, 0);
    CGSize size = CGSizeMake(20, 24);
    id position = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point));
    id dimensions = CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &size));
    id status = testNode(@{
        (__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXMenuBarItemRole,
        (__bridge NSString *)kAXIdentifierAttribute: @"right.status",
        (__bridge NSString *)kAXTitleAttribute: @"Right",
        (__bridge NSString *)kAXPositionAttribute: position,
        (__bridge NSString *)kAXSizeAttribute: dimensions,
    });
    NSMutableArray *windowButtons = [NSMutableArray array];
    for (NSUInteger i = 0; i < 300; i++) {
        [windowButtons addObject:testNode(@{
            (__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXButtonRole,
            (__bridge NSString *)kAXIdentifierAttribute: [NSString stringWithFormat:@"window.%lu", (unsigned long)i],
            (__bridge NSString *)kAXPositionAttribute: position,
            (__bridge NSString *)kAXSizeAttribute: dimensions,
        })];
    }
    id window = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXWindowRole,
        (__bridge NSString *)kAXChildrenAttribute: windowButtons});
    id menu = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXMenuRole,
        (__bridge NSString *)kAXChildrenAttribute: windowButtons});
    id extras = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXMenuBarRole,
        (__bridge NSString *)kAXChildrenAttribute: @[status, menu]});
    id app = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXApplicationRole,
        (__bridge NSString *)kAXChildrenAttribute: @[window, menu, extras], @"AXExtrasMenuBar": extras});
    id root = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXApplicationRole,
        (__bridge NSString *)kAXChildrenAttribute: @[app]});
    // A roleless native host still exposes its actual status-item descendants.
    id roleless = testNode(@{(__bridge NSString *)kAXChildrenAttribute: @[app]});
    root = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXApplicationRole,
        (__bridge NSString *)kAXChildrenAttribute: @[roleless]});
    NSMutableDictionary *statusWithSubview = [nodeAttributes[[NSValue valueWithPointer:(__bridge void *)status]] mutableCopy];
    statusWithSubview[(__bridge NSString *)kAXChildrenAttribute] = windowButtons;
    nodeAttributes[[NSValue valueWithPointer:(__bridge void *)status]] = statusWithSubview;
    readAttribute = testAttribute;
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    NSUInteger remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, YES, items, &remaining));
    assert(remaining > 240 && items.count == 1);
    pid_t statusOwner = 0;
    assert(AXUIElementGetPid((__bridge AXUIElementRef)status, &statusOwner) == kAXErrorSuccess);
    NSString *key = [NSString stringWithFormat:@"item:%d:right.status", statusOwner];
    assert([items[key] unsignedIntegerValue] == 1);
    NSDictionary *expected = [items copy];
    NSMutableDictionary *statusAttributes = [nodeAttributes[[NSValue valueWithPointer:(__bridge void *)status]] mutableCopy];
    statusAttributes[(__bridge NSString *)kAXTitleAttribute] = @"Right changed";
    statusAttributes[(__bridge NSString *)kAXDescriptionAttribute] = @"Updated meter";
    nodeAttributes[[NSValue valueWithPointer:(__bridge void *)status]] = statusAttributes;
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, NO, items, &remaining));
    assert(preservesItems(expected, items));

    // Without an identifier, a changing title still describes the same item.
    NSMutableDictionary *meterAttributes = [statusAttributes mutableCopy];
    [meterAttributes removeObjectForKey:(__bridge NSString *)kAXIdentifierAttribute];
    id meter = testNode(meterAttributes);
    NSMutableDictionary *extrasAttributes = [nodeAttributes[[NSValue valueWithPointer:(__bridge void *)extras]] mutableCopy];
    extrasAttributes[(__bridge NSString *)kAXChildrenAttribute] = @[status, meter, menu];
    nodeAttributes[[NSValue valueWithPointer:(__bridge void *)extras]] = extrasAttributes;
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, YES, items, &remaining));
    expected = [items copy];
    meterAttributes[(__bridge NSString *)kAXTitleAttribute] = @"Meter changed again";
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, NO, items, &remaining));
    assert(preservesItems(expected, items));
    extrasAttributes[(__bridge NSString *)kAXChildrenAttribute] = @[status, menu];
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, NO, items, &remaining));
    assert(!preservesItems(expected, items));
    // Apple module suppression is opt-in; right-side apps remain protected
    // under either policy. Actual snapshots still observe system modules.
    NSMutableDictionary *systemAttributes = [statusAttributes mutableCopy];
    systemAttributes[(__bridge NSString *)kAXIdentifierAttribute] = @"com.apple.menuextra.focusmode";
    id system = testNode(systemAttributes);
    extrasAttributes[(__bridge NSString *)kAXChildrenAttribute] = @[status, system];
    [items removeAllObjects]; remaining = 256;
    assert(preserveSystemItems);
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, YES, items, &remaining));
    NSDictionary *strict = [items copy];
    assert(strict.count == 2);
    craft_menubar_visibility_init(NULL, NULL, false);
    assert(!preserveSystemItems);
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, YES, items, &remaining));
    NSDictionary *appsOnly = [items copy];
    assert(appsOnly.count == 1 && [appsOnly[key] unsignedIntegerValue] == 1);
    extrasAttributes[(__bridge NSString *)kAXChildrenAttribute] = @[status];
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, NO, items, &remaining));
    assert(preservesItems(appsOnly, items) && !preservesItems(strict, items));
    extrasAttributes[(__bridge NSString *)kAXChildrenAttribute] = @[system];
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)root, 8, YES, 100, NO, NO, items, &remaining));
    assert(!preservesItems(appsOnly, items));
    craft_menubar_visibility_init(NULL, NULL, true);
    // Unreadable extras preserve the app's native presence, never its window
    // controls. This keeps an unknown app protected without walking its UI.
    id ordinaryApp = testNode(@{(__bridge NSString *)kAXRoleAttribute: (__bridge NSString *)kAXApplicationRole,
        (__bridge NSString *)kAXChildrenAttribute: @[window, menu]});
    [items removeAllObjects]; remaining = 256;
    assert(snapshotItems((__bridge AXUIElementRef)ordinaryApp, 8, NO, 100, NO, NO, items, &remaining));
    assert(items.count == 1 && remaining == 255);
    pid_t owner = 0;
    assert(AXUIElementGetPid((__bridge AXUIElementRef)ordinaryApp, &owner) == kAXErrorSuccess);
    NSString *applicationKey = [NSString stringWithFormat:@"application:%d", owner];
    assert([items[applicationKey] unsignedIntegerValue] == 1);
    readAttribute = attribute;
    nodeAttributes = nil;
}
@interface TestAssertion : NSObject <CraftVisibilityAssertion>
@property (copy) void (^completion)(NSError *);
@property BOOL invalidated;
@end
@implementation TestAssertion
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion {
    (void)configuration;
    [created addObject:self];
    self.completion = completion;
    if (throwOnActivation) [NSException raise:@"TestException" format:@"Activation failed"];
}
- (void)invalidate { self.invalidated = YES; }
@end

static TestAssertion *begin(void) {
    busy = YES;
    activate(@[@0, @1], @[@"own.app"], 2, 0, ++generation, 1, 100, NO, @{@"right": @1}, CGRectInfinite, [NSSet set]);
    return created.lastObject;
}
static void drain(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.35, false);
}
static NSDictionary *state(void) {
    const char *json = craft_menubar_visibility_state();
    return [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}
int main(int argc, char *argv[]) {
    if (argc == 2 && strcmp(argv[1], "--identity-fixture") == 0) {
        pause();
        return 0;
    }
    @autoreleasepool {
        verifyButtonBoundary();
        verifyDisplayCoordinates();
        verifySystemGrouping();
        verifyRecreatedAnonymousItems();
        verifyStatusItemScope();
        verifyNativeHostedGeometry();
        (void)available(); // Resolve once before substituting the test classes.
        configurationClass = TestConfiguration.class;
        assertionClass = TestAssertion.class;
        created = [NSMutableArray array];
        snapshot = @{@"right": @1, @"system": @1};
        readBarSnapshot = testSnapshot;
        assert(preservesItems(@{@"right": @1}, snapshot));
        assert(!preservesItems(@{@"right": @2}, snapshot));
        assert(!preservesItems(@{@"missing": @1}, snapshot));
        assert(!preservesItems(nil, snapshot));
        assert(hidesSelectedOwners(@{@"anonymous:1234": @1}, [NSSet setWithObject:@5678]));
        assert(!hidesSelectedOwners(@{@"anonymous:1234": @1}, [NSSet setWithObject:@1234]));
        assert(!hidesSelectedOwners(@{@"item:1234:stable": @1}, [NSSet setWithObject:@1234]));
        assert(hidesSelectedOwners(@{@"anonymous:1234": @0}, [NSSet setWithObject:@1234]));
        TestRunningApplication *selectedApp = [TestRunningApplication new];
        selectedApp.bundleIdentifier = @"selected.app"; selectedApp.processIdentifier = 1234;
        assert([selectedOwners((id)@[selectedApp], @{@"selected.app": @NO}, @{}, @[]) containsObject:@1234]);
        assert(!selectedOwners((id)@[selectedApp], @{@"selected.app": @YES}, @{}, @[]).count);
        assert(!selectedOwners((id)@[selectedApp], @{@"selected.app": @NO},
            @{@"selected.app": @[@"selected.app", @"shared.runtime"]}, @[@"shared.runtime"]).count);

        // A helper's sealed identifier differs from its app/LaunchServices ID.
        // It must stay allowed even when its icon sits in the hidden section.
        NSString *signedIdentity = @"dev.craft.visibility.fixture.runtime";
        assert([signingIdentifier() isEqual:signedIdentity]);
        assert([processSigningIdentifier(getpid()) isEqual:signedIdentity]);
        assert(processSigningIdentifier(-1) == nil);
        // Reading another live process must work without task-port access or
        // a matching LaunchServices app bundle. Reap only this owned fixture.
        pid_t guest;
        char *guestArgs[] = {argv[0], "--identity-fixture", NULL};
        extern char **environ;
        assert(posix_spawn(&guest, argv[0], NULL, NULL, guestArgs, environ) == 0);
        NSString *guestIdentity = processSigningIdentifier(guest);
        assert(kill(guest, SIGTERM) == 0);
        assert(waitpid(guest, NULL, 0) == guest);
        assert([guestIdentity isEqual:signedIdentity]);
        NSArray *protectedIdentifiers = ownIdentifiers();
        assert([protectedIdentifiers containsObject:signedIdentity]);
        NSUInteger selfHidden = 0;
        NSArray *selfAllowed = allowedBundles(@[signedIdentity, @"other.app"],
            @{signedIdentity: @NO, @"other.app": @NO}, @{}, protectedIdentifiers, &selfHidden);
        assert(selfHidden == 1 && [selfAllowed containsObject:signedIdentity]);
        assert(![selfAllowed containsObject:@"other.app"]);
        NSMutableDictionary *sections = [NSMutableDictionary dictionary];
        CGRect left = CGRectMake(20, 0, 20, 24), right = CGRectMake(200, 0, 20, 24);
        recordItem(sections, @"left", left, 100, NO);
        recordItem(sections, @"right", right, 100, NO);
        recordItem(sections, @"both", left, 100, NO);
        recordItem(sections, @"both", right, 100, NO);
        recordItem(sections, @"both", left, 100, NO);
        recordItem(sections, @"unknown", left, 100, NO);
        recordItem(sections, @"unknown", CGRectNull, 100, NO);
        recordItem(sections, @"rtl-left", left, 100, YES);
        recordItem(sections, @"rtl-right", right, 100, YES);
        assert(![sections[@"left"] boolValue] && [sections[@"right"] boolValue]);
        assert([sections[@"both"] boolValue] && [sections[@"unknown"] boolValue]);
        assert([sections[@"rtl-left"] boolValue] && ![sections[@"rtl-right"] boolValue]);
        sections[@"own.app"] = @NO;
        sections[@"native.helper"] = @NO;
        sections[@"com.apple.controlcenter"] = @NO;
        NSUInteger hidden = 0;
        NSArray *allowed = allowedBundles(@[@"left", @"left", @"right", @"both", @"new", @"unknown", @"own.app", @"native.helper", @"com.apple.controlcenter"], sections, @{}, @[@"own.app", @"native.helper"], &hidden);
        assert(hidden == 1 && ![allowed containsObject:@"left"]);
        for (NSString *bundle in @[@"right", @"both", @"new", @"unknown", @"own.app", @"native.helper", @"com.apple.controlcenter"]) assert([allowed containsObject:bundle]);

        // Allow a right-side native helper by its actual signing identity.
        // An independent left-side app keeps both of its identities excluded.
        NSDictionary *identities = @{
            @"left": @[@"left", @"left.runtime"],
            @"right": @[@"right", @"right.runtime"],
            @"new": @[@"new", @"new.runtime"],
        };
        NSArray *nativeAllowed = allowedBundles(@[@"left", @"right", @"new"], sections, identities, @[], &hidden);
        assert(hidden == 1 && ![nativeAllowed containsObject:@"left"] && ![nativeAllowed containsObject:@"left.runtime"]);
        for (NSString *identifier in @[@"right", @"right.runtime", @"new", @"new.runtime"]) assert([nativeAllowed containsObject:identifier]);

        // Two apps sharing a signed runtime cannot be hidden independently.
        // The visible member protects all aliases, including chained groups.
        NSDictionary *shared = @{
            @"left": @[@"left", @"shared.first"],
            @"also.left": @[@"also.left", @"shared.first", @"shared.second"],
            @"right": @[@"right", @"shared.second"],
            @"independent": @[@"independent", @"independent.runtime"],
        };
        NSArray *sharedAllowed = allowedBundles(@[@"left", @"also.left", @"right", @"independent"],
            @{@"left": @NO, @"also.left": @NO, @"right": @YES, @"independent": @NO}, shared, @[], &hidden);
        assert(hidden == 1 && ![sharedAllowed containsObject:@"independent"] && ![sharedAllowed containsObject:@"independent.runtime"]);
        for (NSString *identifier in @[@"left", @"also.left", @"right", @"shared.first", @"shared.second"]) assert([sharedAllowed containsObject:identifier]);
        NSArray *sharedHidden = allowedBundles(@[@"left", @"also.left"],
            @{@"left": @NO, @"also.left": @NO}, shared, @[], &hidden);
        assert(hidden == 2 && ![sharedHidden containsObject:@"shared.first"] && ![sharedHidden containsObject:@"shared.second"]);

        busy = YES;
        activate(@[@0, @1], ownIdentifiers(), 0, 0, ++generation, 1, 100, NO, snapshot, CGRectInfinite, [NSSet set]);
        assert(!busy && !assertion && created.count == 0 && [failure isEqual:@"emptyGroup"]);

        TestAssertion *first = begin();
        assert(busy && !assertion);
        first.completion(nil); drain();
        assert(assertion == first && !busy && hiddenAppCount == 2);
        assert(CFGetTypeID((__bridge CFTypeRef)state()[@"collapsed"]) == CFBooleanGetTypeID());
        craft_menubar_visibility_expand();
        assert(first.invalidated && !assertion && !busy && hiddenAppCount == 0);

        busy = YES;
        activate(@[@1, @2], ownIdentifiers(), 0, 1, ++generation, 1, 100, NO, snapshot, CGRectInfinite, [NSSet set]);
        TestAssertion *systemOnly = created.lastObject;
        systemOnly.completion(nil); drain();
        assert(assertion == systemOnly && !busy && hiddenAppCount == 0 && hiddenSystemItemCount == 1);
        assert([state()[@"hiddenSystemItemCount"] unsignedIntegerValue] == 1);
        craft_menubar_visibility_expand();
        assert(systemOnly.invalidated && hiddenAppCount == 0 && hiddenSystemItemCount == 0);

        snapshot = @{@"unexpected": @1};
        TestAssertion *unsafe = begin();
        unsafe.completion(nil); drain();
        assert(unsafe.invalidated && !assertion && !busy && [failure isEqual:@"visibilityMismatch"]);
        snapshot = @{@"right": @1, @"system": @1};

        TestAssertion *checking = begin();
        checking.completion(nil);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        craft_menubar_visibility_expand();
        drain();
        assert(checking.invalidated && !assertion && !busy);

        TestAssertion *stale = begin();
        craft_menubar_visibility_expand();
        TestAssertion *current = begin();
        stale.completion(nil); drain();
        assert(stale.invalidated && !assertion && busy);
        current.completion(nil); drain();
        assert(assertion == current && !current.invalidated);
        trusted = false;
        assert([state()[@"error"] isEqual:@"permissionRequired"]);
        assert(current.invalidated && !assertion && !busy);
        trusted = true;

        // Native success alone is insufficient: a selected app must disappear.
        snapshot = @{@"anonymous:1234": @1, @"right": @1};
        busy = YES;
        activate(@[], @[@"own.app"], 1, 0, ++generation, 1, 100, NO,
            @{@"right": @1}, CGRectInfinite, [NSSet setWithObject:@1234]);
        TestAssertion *visibleSelection = created.lastObject;
        visibleSelection.completion(nil);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2.5, false);
        assert(visibleSelection.invalidated && !assertion && !busy && [failure isEqual:@"visibilityMismatch"]);
        snapshot = @{@"right": @1, @"system": @1};

        // A completed assertion can precede the native layout update. Keep
        // waiting for actual disappearance instead of accepting stale success.
        snapshot = @{@"right": @1, @"system": @1};
        retainedSelectionReads = 2; busy = YES;
        activate(@[], @[@"own.app"], 1, 0, ++generation, 1, 100, NO,
            @{@"right": @1}, CGRectInfinite, [NSSet setWithObject:@1234]);
        TestAssertion *settling = created.lastObject;
        settling.completion(nil); drain();
        assert(assertion == settling && !busy && !settling.invalidated && !retainedSelectionReads);
        craft_menubar_visibility_expand();

        TestAssertion *failed = begin();
        failed.completion([NSError errorWithDomain:@"test" code:1 userInfo:nil]); drain();
        assert(failed.invalidated && !assertion && !busy && [failure isEqual:@"activationFailed"]);
        TestAssertion *timed = begin();
        activationDeadline(generation);
        assert(timed.invalidated && !busy && [failure isEqual:@"activationTimeout"]);
        timed.completion(nil); drain();
        assert(!assertion);

        throwOnActivation = YES;
        TestAssertion *exception = begin();
        assert(exception.invalidated && !assertion && !busy && [failure isEqual:@"activationFailed"]);
        throwOnActivation = NO;
        TestAssertion *quitting = begin();
        craft_menubar_visibility_cleanup();
        quitting.completion(nil); drain();
        assert(quitting.invalidated && !assertion && !pendingAssertion && !busy && !marker);

        // Unbundled native GUI processes are unknown, visible owners. Their
        // inventory keys must never be sent to the native bundle allow-list.
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSRunningApplication *selfApp = NSRunningApplication.currentApplication;
        NSDictionary *selfIdentities = applicationIdentities(@[selfApp]);
        NSString *selfKey = selfApp.bundleIdentifier.length ? selfApp.bundleIdentifier
            : [NSString stringWithFormat:@"process:%d", getpid()];
        assert([selfIdentities[selfKey] containsObject:signedIdentity]);
        NSUInteger rawHidden = 0;
        NSArray *rawAllowed = allowedBundles(@[@"left", @"process:42"], @{@"left": @NO},
            @{@"left": @[@"left", @"shared.runtime"], @"process:42": @[@"shared.runtime"]}, @[], &rawHidden);
        assert(rawHidden == 0 && [rawAllowed containsObject:@"left"] && [rawAllowed containsObject:@"shared.runtime"]);
        assert(![rawAllowed containsObject:@"process:42"]);
        puts("native visibility: grouping, protected owners, JSON booleans, cancellation, permission revocation, errors, timeout and quit passed");
    }
}
