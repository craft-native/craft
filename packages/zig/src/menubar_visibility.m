// Native visibility contract researched in Hidden Bar (MIT), Copyright (c) 2019
// Dwarves Foundation. See third-party/hidden-bar-LICENSE. Native code belongs in
// Craft so consumers need no platform sources or private-framework knowledge.
#import "menubar_visibility.h"
#if CRAFT_PUBLIC_APIS_ONLY
// macOS has no public API for suppressing another application's status items.
// Exclude the private implementation entirely from the App Store runtime.
bool craft_menubar_visibility_available(void) { return false; }
void craft_menubar_visibility_init(void *item, void (*callback)(void), bool preserve_system_items) { (void)item; (void)callback; (void)preserve_system_items; }
void craft_menubar_visibility_request_permission(void) {}
void craft_menubar_visibility_collapse(void) {}
void craft_menubar_visibility_expand(void) {}
void craft_menubar_visibility_cleanup(void) {}
bool craft_menubar_visibility_collapsed(void) { return false; }
bool craft_menubar_visibility_busy(void) { return false; }
const char *craft_menubar_visibility_state(void) {
    return "{\"backend\":\"nativeVisibility\",\"initialized\":false,\"collapsed\":false,\"separatorHidden\":false,\"available\":false,\"authorized\":false,\"busy\":false,\"hiddenAppCount\":0,\"hiddenSystemItemCount\":0,\"preserveSystemItems\":false,\"markerWidth\":0,\"error\":\"unavailable\"}";
}
#else
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Security/Security.h>
#import <dlfcn.h>
#include <unistd.h>

@protocol CraftVisibilityConfiguration
- (id)initWithAllowedSystemItems:(NSArray *)systemItems allowedBundleIdentifiers:(NSArray *)bundles;
@end
@protocol CraftVisibilityAssertion
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

static NSStatusItem *marker;
static void (*changed)(void);
static id<CraftVisibilityAssertion> assertion;
static id<CraftVisibilityAssertion> pendingAssertion;
static NSUInteger generation;
static BOOL busy;
static BOOL requestedPermission;
static BOOL preserveSystemItems = YES;
static NSString *failure;
static NSUInteger hiddenAppCount;
static NSUInteger hiddenSystemItemCount;
static NSTimeInterval operationStarted;
static Class configurationClass;
static Class assertionClass;

static NSString *identifierForCode(SecCodeRef code) {
    CFDictionaryRef information = NULL;
    NSString *identifier = nil;
    if (SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &information) == errSecSuccess) {
        id value = (__bridge id)CFDictionaryGetValue(information, kSecCodeInfoIdentifier);
        if ([value isKindOfClass:NSString.class]) identifier = [value copy];
        CFRelease(information);
    }
    return identifier;
}

static NSString *signingIdentifier(void) {
    SecCodeRef code = NULL;
    NSString *identifier = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess) {
        identifier = identifierForCode(code);
        CFRelease(code);
    }
    return identifier;
}

static NSString *processSigningIdentifier(pid_t pid) {
    SecCodeRef code = NULL;
    NSString *identifier = nil;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) == errSecSuccess) {
        identifier = identifierForCode(code);
        CFRelease(code);
    }
    return identifier;
}

static NSDictionary *applicationIdentities(NSArray<NSRunningApplication *> *apps) {
    NSMutableDictionary *identities = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in apps) {
        NSString *bundle = app.bundleIdentifier;
        NSString *signedIdentity = processSigningIdentifier(app.processIdentifier);
        if (!bundle.length && !signedIdentity.length) continue;
        // An unbundled GUI process still has a native signing identity. Its
        // unknown position stays visible; this process key is inventory-only.
        NSString *key = bundle.length ? bundle : [NSString stringWithFormat:@"process:%d", app.processIdentifier];
        NSMutableSet *aliases = identities[key];
        if (!aliases) identities[key] = aliases = [NSMutableSet set];
        if (bundle.length) [aliases addObject:bundle];
        if (signedIdentity.length) [aliases addObject:signedIdentity];
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *bundle in identities) result[bundle] = [identities[bundle] allObjects];
    return result;
}

static NSArray<NSString *> *ownIdentifiers(void) {
    NSMutableOrderedSet *identifiers = [NSMutableOrderedSet orderedSet];
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *registered = NSRunningApplication.currentApplication.bundleIdentifier;
    NSString *signedIdentity = signingIdentifier();
    if (bundle.length) [identifiers addObject:bundle];
    if (registered.length) [identifiers addObject:registered];
    // MenuBarAgent identifies a separately signed native helper by its sealed
    // signing identifier, even when LaunchServices reports its enclosing app ID.
    if (signedIdentity.length) [identifiers addObject:signedIdentity];
    return identifiers.array;
}

static BOOL available(void) {
    // Sandboxed/App Store consumers must never activate this private backend.
    if (getenv("APP_SANDBOX_CONTAINER_ID")) return NO;
    if (![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){27, 0, 0}]) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL)) {
            configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
            assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
        }
    });
    return [configurationClass instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [assertionClass instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [assertionClass instancesRespondToSelector:@selector(invalidate)];
}

static void invalidate(id<CraftVisibilityAssertion> value) {
    @try { [value invalidate]; }
    @catch (NSException *exception) { NSLog(@"Craft menu bar: invalidate failed: %@", exception); }
}

static void notify(void) {
    if (changed) changed();
}

static void fail(NSString *reason) {
    generation++;
    invalidate(pendingAssertion);
    pendingAssertion = nil;
    invalidate(assertion);
    assertion = nil;
    busy = NO;
    hiddenAppCount = 0;
    hiddenSystemItemCount = 0;
    failure = reason;
    notify();
}

bool craft_menubar_visibility_available(void) { return available(); }

void craft_menubar_visibility_init(void *item, void (*callback)(void), bool preserve_system_items) {
    marker = (__bridge NSStatusItem *)item;
    changed = callback;
    preserveSystemItems = preserve_system_items;
    failure = available() ? nil : @"unavailable";
}

void craft_menubar_visibility_request_permission(void) {
    if (!available() || AXIsProcessTrusted()) return;
    if (!requestedPermission) {
        requestedPermission = YES;
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    }
    // A denied request may no longer show a prompt. An explicit user action
    // always opens the OS permission pane; it never grants access itself.
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    notify();
}

// Keep incomplete geometry visible. A bundle with icons on both sides belongs
// to the visible group, because macOS hides by owning application.
static void recordItem(NSMutableDictionary *sections, id bundle, CGRect frame, double boundary, BOOL rtl) {
    BOOL valid = !CGRectIsNull(frame) && frame.size.width > 0 && frame.size.height > 0
        && isfinite(frame.origin.x) && isfinite(frame.size.width);
    BOOL visible = !valid || (rtl ? CGRectGetMidX(frame) < boundary : CGRectGetMidX(frame) > boundary);
    sections[bundle] = @([sections[bundle] boolValue] || visible);
}

// Native MBSystemItemIdentifier raw values in MenuBarClientCore. These are
// system item identities, distinct from the owning MenuBarAgent process.
static NSNumber *systemItemIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return nil;
    NSDictionary *identifiers = @{
        @"com.apple.menuextra.battery": @0,
        @"com.apple.menuextra.bluetooth": @1,
        @"com.apple.menuextra.clock": @2,
        @"com.apple.menuextra.displays": @3,
        @"com.apple.menuextra.textinput": @4,
        @"com.apple.menuextra.volume": @5,
        @"com.apple.menuextra.wifi": @6,
        @"com.apple.menuextra.screenmirroring": @7,
        @"com.apple.menuextra.controlcenter": @8,
    };
    return identifiers[identifier];
}

static NSArray *allowedSystemItems(NSDictionary *sections, NSUInteger *hiddenCount) {
    NSMutableArray *allowed = [NSMutableArray array];
    *hiddenCount = 0;
    // Unknown and unreadable items stay allowed, including future native IDs.
    for (NSUInteger i = 0; i < 64; i++) {
        if (!preserveSystemItems && sections[@(i)] && ![sections[@(i)] boolValue]) (*hiddenCount)++;
        else [allowed addObject:@(i)];
    }
    return allowed;
}

static NSArray *allowedBundles(NSArray<NSString *> *bundles, NSDictionary *sections, NSDictionary *identities,
    NSArray<NSString *> *ownBundles, NSUInteger *hiddenCount) {
    NSSet *system = [NSSet setWithArray:@[@"com.apple.MenuBarAgent", @"com.apple.controlcenter", @"com.apple.systemuiserver"]];
    NSSet *protected = [NSSet setWithArray:ownBundles];
    NSMutableSet *allowed = [protected mutableCopy];
    [allowed addObjectsFromArray:system.allObjects];
    NSMutableSet *hidden = [NSMutableSet set];
    for (NSString *bundle in bundles) {
        if (sections[bundle] && ![sections[bundle] boolValue] && ![protected containsObject:bundle] && ![system containsObject:bundle])
            [hidden addObject:bundle];
        else [allowed addObjectsFromArray:identities[bundle] ?: @[bundle]];
    }
    // Native helpers can share a signing identifier, including helpers from
    // different app bundles. If any member must remain visible, allow the
    // complete connected group. Hiding one side must never hide the other.
    BOOL updated;
    do {
        updated = NO;
        for (NSString *bundle in hidden.allObjects) {
            NSArray *aliases = identities[bundle] ?: @[bundle];
            if ([allowed intersectsSet:[NSSet setWithArray:aliases]]) {
                [allowed addObjectsFromArray:aliases];
                [hidden removeObject:bundle];
                updated = YES;
            }
        }
    } while (updated);
    *hiddenCount = hidden.count;
    return allowed.allObjects;
}

// Use MenuBarAgent's displayed positions for grouping and verification alike.
// Per-app AXExtrasMenuBar geometry can be stale after native reordering.
static NSDictionary<NSString *, NSNumber *> *inventory(NSArray<NSRunningApplication *> *apps, NSDictionary *owners) {
    NSMutableDictionary *sections = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in apps) {
        NSString *bundle = app.bundleIdentifier;
        NSNumber *visible = owners[@(app.processIdentifier)];
        if (!bundle.length || !visible) continue;
        sections[bundle] = @([sections[bundle] boolValue] || visible.boolValue);
    }
    return sections;
}

static void activationDeadline(NSUInteger ticket) {
    if (ticket == generation && busy) fail(@"activationTimeout");
}

static id attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static id (*readAttribute)(AXUIElementRef, CFStringRef) = attribute;
static AXError (*readOwner)(AXUIElementRef, pid_t *) = AXUIElementGetPid;

// Capture the displayed bar; derive grouping and protection from this one layout.
// A private allow-list can silently omit an allowed app (notably a mismatched
// helper bundle), or suppress a system indicator. System preservation is an
// explicit consumer policy; unselected application icons are always protected.
static CGRect itemFrame(AXUIElementRef node) {
    id position = readAttribute(node, kAXPositionAttribute), size = readAttribute(node, kAXSizeAttribute);
    CGPoint point = CGPointZero;
    CGSize dimensions = CGSizeZero;
    if (!position || !size || CFGetTypeID((__bridge CFTypeRef)position) != AXValueGetTypeID()
        || CFGetTypeID((__bridge CFTypeRef)size) != AXValueGetTypeID()
        || !AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &point)
        || !AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &dimensions)
        || !isfinite(point.x) || !isfinite(point.y) || !isfinite(dimensions.width)
        || !isfinite(dimensions.height) || dimensions.width <= 0 || dimensions.height <= 0 || dimensions.height > 64)
        return CGRectNull;
    return (CGRect){point, dimensions};
}

static BOOL collectHostedSnapshotItems(AXUIElementRef node, NSUInteger depth, BOOL root, double boundary, BOOL rtl,
    BOOL protectedOnly, pid_t agent, CGRect display, CGRect hostedFrame, NSMutableDictionary *items, NSMutableDictionary *owners, NSMutableDictionary *systemSections, NSUInteger *remaining) {
    if (!depth || !*remaining) return NO;
    (*remaining)--;
    AXUIElementSetMessagingTimeout(node, 0.1);
    NSString *role = readAttribute(node, kAXRoleAttribute);
    // MenuBarAgent's remote app nodes expose the entire app, including its
    // windows and application menus. Only its extras belong to this bar.
    // Walking a webview here can exhaust the budget or count unrelated buttons.
    const BOOL remoteApplication = !root && [role isEqual:(__bridge NSString *)kAXApplicationRole];
    if (remoteApplication && CGRectIsNull(hostedFrame)) {
        id extras = readAttribute(node, CFSTR("AXExtrasMenuBar"));
        if (extras && CFGetTypeID((__bridge CFTypeRef)extras) == AXUIElementGetTypeID())
            return collectHostedSnapshotItems((__bridge AXUIElementRef)extras, depth - 1, NO, boundary, rtl, protectedOnly, agent, display, CGRectNull, items, owners, systemSections, remaining);
        // Keep an unreadable remote app protected by its native presence.
        // Its ordinary window controls cannot stand in for a status item.
        pid_t owner = 0;
        if (readOwner(node, &owner) != kAXErrorSuccess || owner <= 0) return NO;
        NSString *key = [NSString stringWithFormat:@"application:%d", owner];
        items[key] = @([items[key] unsignedIntegerValue] + 1);
        owners[@(owner)] = @YES;
        return YES;
    }
    // An open status menu is below the bar, not another status item.
    if ([role isEqual:(__bridge NSString *)kAXMenuRole]) return YES;
    NSString *identifier = readAttribute(node, kAXIdentifierAttribute);
    BOOL system = [identifier isKindOfClass:NSString.class] && [identifier hasPrefix:@"com.apple.menuextra."];
    // MenuBarClientCore can suppress Apple modules even when allowed. Consumers
    // may explicitly accept that behavior without disabling app verification.
    if (system || [role isEqual:(__bridge NSString *)kAXButtonRole]
        || [role isEqual:(__bridge NSString *)kAXMenuBarItemRole] || remoteApplication) {
        const CGRect frame = CGRectIsNull(hostedFrame) ? itemFrame(node) : hostedFrame;
        if (!CGRectIsNull(frame)) {
            CGPoint point = frame.origin;
            CGSize dimensions = frame.size;
            double middle = CGRectGetMidX(frame);
            // MenuBarAgent exposes controls from every connected display. A
            // copy on another screen cannot override this arrow's selection.
            if (!CGRectContainsPoint(display, CGPointMake(middle, point.y + dimensions.height / 2))) return YES;
            // The arrow changes its label after activation. Its own native
            // identity remains protected by the allow-list, not by text.
            pid_t owner = 0;
            // MenuBarAgent also owns anonymous Apple modules without a
            // com.apple.menuextra identifier (for example Focus). Apply the
            // same explicit system-item policy to those native owners.
            if (readOwner(node, &owner) != kAXErrorSuccess || owner <= 0) return NO;
            system = system || owner == agent;
            NSNumber *systemIdentifier = systemItemIdentifier(identifier);
            if (systemIdentifier) recordItem(systemSections, systemIdentifier, (CGRect){point, dimensions}, boundary, rtl);
            if (protectedOnly && system && !preserveSystemItems) return YES;
            BOOL arrow = owner == getpid() && fabs(middle - boundary) < 2;
            // Collapsed native overflow reports several icons stacked at the
            // same x coordinate. Those frames cannot identify a section. Refuse
            // the capture before applying any restriction; a visible arrow can
            // never overlap another status button's horizontal interior.
            if (protectedOnly && !system && !arrow && point.x < boundary && point.x + dimensions.width > boundary) return NO;
            BOOL visibleSide = rtl ? middle < boundary : middle > boundary;
            recordItem(owners, @(owner), (CGRect){point, dimensions}, boundary, rtl);
            if (!arrow && (!protectedOnly || system || owner == getpid() || visibleSide)) {
                if ([identifier isKindOfClass:NSString.class] && identifier.length && owner > 0) {
                    // Descriptions, titles and help can change while a status
                    // meter updates. The native identifier and owner do not.
                    NSString *key = [NSString stringWithFormat:@"item:%d:%@", owner, identifier];
                    items[key] = @([items[key] unsignedIntegerValue] + 1);
                } else {
                    // MenuBarAgent can recreate an anonymous AX proxy while its
                    // app stays visible. Visibility is controlled per owning
                    // application, so verify its native owner and icon count,
                    // not a proxy object, changing label or screen position.
                    NSString *key = [NSString stringWithFormat:@"anonymous:%d", owner];
                    items[key] = @([items[key] unsignedIntegerValue] + 1);
                }
            }
            // A status item with valid bar geometry is one entry. Its custom
            // subviews and popup content cannot add another owner or section.
            // Nonvisual system hosts still need traversal to their actual item.
            return YES;
        }
    }
    // MenuBarAgent's roleless slot is the displayed status item's geometry.
    // Remote apps can report AXExtrasMenuBar coordinates from a different
    // display or from before a reorder. Carry the native slot to its owner,
    // counting that slot once instead of traversing every app-owned extra.
    CGRect childFrame = hostedFrame;
    if (CGRectIsNull(childFrame) && !role.length && agent > 0) {
        pid_t host = 0;
        if (readOwner(node, &host) == kAXErrorSuccess && host == agent)
            childFrame = itemFrame(node);
    }
    id children = readAttribute(node, kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class]) {
        for (id child in children) {
            if (CFGetTypeID((__bridge CFTypeRef)child) == AXUIElementGetTypeID()
                && !collectHostedSnapshotItems((__bridge AXUIElementRef)child, depth - 1, NO, boundary, rtl, protectedOnly, agent, display, childFrame, items, owners, systemSections, remaining)) return NO;
        }
    }
    return YES;
}

static BOOL collectSnapshotItems(AXUIElementRef node, NSUInteger depth, BOOL root, double boundary, BOOL rtl,
    BOOL protectedOnly, pid_t agent, CGRect display, NSMutableDictionary *items, NSMutableDictionary *owners, NSMutableDictionary *systemSections, NSUInteger *remaining) {
    return collectHostedSnapshotItems(node, depth, root, boundary, rtl, protectedOnly, agent, display, CGRectNull, items, owners, systemSections, remaining);
}

static NSDictionary *barLayout(pid_t agent, double boundary, BOOL rtl, BOOL protectedOnly, CGRect display) {
    if (!agent) return nil;
    AXUIElementRef element = AXUIElementCreateApplication(agent);
    NSMutableDictionary *items = [NSMutableDictionary dictionary], *owners = [NSMutableDictionary dictionary], *systemSections = [NSMutableDictionary dictionary];
    NSUInteger remaining = 256;
    BOOL complete = collectSnapshotItems(element, 8, YES, boundary, rtl, protectedOnly, agent, display, items, owners, systemSections, &remaining);
    CFRelease(element);
    return complete && items.count ? @{ @"items": [items copy], @"owners": [owners copy], @"system": [systemSections copy] } : nil;
}

static NSDictionary *barSnapshot(pid_t agent, double boundary, BOOL rtl, BOOL protectedOnly, CGRect display) {
    return barLayout(agent, boundary, rtl, protectedOnly, display)[@"items"];
}

static NSDictionary *(*readBarSnapshot)(pid_t, double, BOOL, BOOL, CGRect) = barSnapshot;

static BOOL preservesItems(NSDictionary *expected, NSDictionary *actual) {
    if (!expected.count || !actual.count) return NO;
    for (NSString *key in expected) {
        if ([actual[key] unsignedIntegerValue] < [expected[key] unsignedIntegerValue]) {
            NSArray *identity = [key componentsSeparatedByString:@":"];
            pid_t owner = identity.count > 1 ? [identity[1] intValue] : 0;
            NSLog(@"Craft menu bar: protected owner %d lost status items (expected %lu, actual %lu)",
                owner, (unsigned long)[expected[key] unsignedIntegerValue], (unsigned long)[actual[key] unsignedIntegerValue]);
            return NO;
        }
    }
    return YES;
}

static NSSet<NSNumber *> *selectedOwners(NSArray<NSRunningApplication *> *apps, NSDictionary *sections,
    NSDictionary *identities, NSArray *allowed) {
    NSMutableSet *selected = [NSMutableSet set];
    NSSet *visibleIdentities = [NSSet setWithArray:allowed];
    for (NSRunningApplication *app in apps) {
        NSString *bundle = app.bundleIdentifier;
        if (!bundle.length || !sections[bundle] || [sections[bundle] boolValue]) continue;
        NSArray *aliases = identities[bundle] ?: @[bundle];
        if (![visibleIdentities intersectsSet:[NSSet setWithArray:aliases]])
            [selected addObject:@(app.processIdentifier)];
    }
    return selected;
}

static BOOL hidesSelectedOwners(NSDictionary *actual, NSSet<NSNumber *> *selected) {
    for (NSString *key in actual) {
        NSArray *identity = [key componentsSeparatedByString:@":"];
        if (identity.count < 2) continue;
        NSNumber *owner = @([identity[1] intValue]);
        if ([selected containsObject:owner] && [actual[key] unsignedIntegerValue] > 0) {
            NSLog(@"Craft menu bar: selected owner %@ remains visible", owner);
            return NO;
        }
    }
    return YES;
}

static void verifyActivation(id<CraftVisibilityAssertion> pending, NSUInteger ticket, pid_t agent, double boundary,
    BOOL rtl, NSDictionary *protectedItems, CGRect display, NSSet<NSNumber *> *selected,
    NSUInteger hidden, NSUInteger systemHidden, NSTimeInterval deadline) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *actual = readBarSnapshot(agent, boundary, rtl, NO, display);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ticket != generation) { invalidate(pending); return; }
            if (!AXIsProcessTrusted()) return fail(@"permissionRequired");
            if (!preservesItems(protectedItems, actual)) return fail(@"visibilityMismatch");
            if (!hidesSelectedOwners(actual, selected)) {
                // Native activation completes before MenuBarAgent necessarily
                // publishes its new layout. Wait for the observed result, with
                // a bounded deadline; never report success while a target stays.
                if (NSProcessInfo.processInfo.systemUptime >= deadline) return fail(@"visibilityMismatch");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    if (ticket == generation) verifyActivation(pending, ticket, agent, boundary, rtl, protectedItems,
                        display, selected, hidden, systemHidden, deadline);
                });
                return;
            }
            assertion = pending;
            pendingAssertion = nil;
            busy = NO;
            hiddenAppCount = hidden;
            hiddenSystemItemCount = systemHidden;
            if (operationStarted > 0)
                NSLog(@"Craft menu bar: grouped %lu apps and %lu system controls at x=%.1f in %.3fs",
                    (unsigned long)hidden, (unsigned long)systemHidden, boundary,
                    NSProcessInfo.processInfo.systemUptime - operationStarted);
            notify();
        });
    });
}

static void activate(NSArray *systemItems, NSArray *allowed, NSUInteger hidden, NSUInteger systemHidden, NSUInteger ticket,
    pid_t agent, double boundary, BOOL rtl, NSDictionary *protectedItems, CGRect display, NSSet<NSNumber *> *selected) {
    // Assessment mode can suppress system indicators even with all apps allowed.
    // Never activate a global restriction when there is no selected app to hide.
    if (!hidden && !systemHidden) return fail(@"emptyGroup");
    if (!protectedItems.count) return fail(@"layoutUnavailable");
    @try {
        id configuration = [(id<CraftVisibilityConfiguration>)[configurationClass alloc]
            initWithAllowedSystemItems:[systemItems copy] allowedBundleIdentifiers:[allowed copy]];
        id<CraftVisibilityAssertion> pending = [[assertionClass alloc] init];
        if (!configuration || !pending) return fail(@"activationFailed");
        pendingAssertion = pending;
        [pending activateWithConfiguration:configuration completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ticket != generation) { invalidate(pending); return; }
                if (error) {
                    invalidate(pending);
                    NSLog(@"Craft menu bar activation: %@", error);
                    return fail(@"activationFailed");
                }
                verifyActivation(pending, ticket, agent, boundary, rtl, protectedItems, display, selected,
                    hidden, systemHidden, NSProcessInfo.processInfo.systemUptime + 2.0);
            });
        }];
    } @catch (NSException *exception) {
        NSLog(@"Craft menu bar activation: %@", exception);
        fail(@"activationFailed");
    }
}

static NSRect buttonScreenFrame(NSView *button) {
    if (!button.window) return NSZeroRect;
    // A native status host can contain several buttons. Its window frame is
    // not the arrow's position, and changes meaning when the user reorders
    // the arrow and the app icon. Convert the button's own bounds instead.
    return [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
}

// Accessibility coordinates start at the primary display's top-left;
// AppKit screen coordinates start at its bottom-left, including other screens.
static CGRect accessibilityScreenBounds(NSRect screen, NSRect primary) {
    return CGRectMake(NSMinX(screen), NSMaxY(primary) - NSMaxY(screen), NSWidth(screen), NSHeight(screen));
}

void craft_menubar_visibility_collapse(void) {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    if (assertion || busy) return;
    if (!available()) return fail(@"unavailable");
    if (!AXIsProcessTrusted()) return fail(@"permissionRequired");
    NSString *ownBundle = NSBundle.mainBundle.bundleIdentifier;
    NSArray *ownBundles = ownIdentifiers();
    NSRect frame = buttonScreenFrame(marker.button);
    NSScreen *screen = marker.button.window.screen;
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!ownBundle.length || !screen || !primary || NSWidth(frame) <= 0) return fail(@"layoutUnavailable");
    const CGRect display = accessibilityScreenBounds(screen.frame, primary.frame);
    operationStarted = started;
    busy = YES;
    failure = nil;
    const NSUInteger ticket = ++generation;
    const double boundary = NSMidX(frame);
    const BOOL rtl = NSApp.userInterfaceLayoutDirection == NSUserInterfaceLayoutDirectionRightToLeft;
    // Unknown helpers stay allowed too. Omitting one from a native allow-list
    // can hide its item even when its owning application is on the right.
    NSArray *apps = [NSWorkspace.sharedWorkspace.runningApplications copy];
    pid_t agent = 0;
    for (NSRunningApplication *app in apps)
        if ([app.bundleIdentifier isEqual:@"com.apple.MenuBarAgent"]) agent = app.processIdentifier;
    notify();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        activationDeadline(ticket);
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSDictionary *layout = barLayout(agent, boundary, rtl, YES, display);
            NSDictionary *sections = inventory(apps, layout[@"owners"]);
            NSDictionary *identities = applicationIdentities(apps);
            NSDictionary *protectedItems = layout[@"items"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ticket != generation) return;
                if (!AXIsProcessTrusted()) return fail(@"permissionRequired");
                if (!layout) return fail(@"layoutUnavailable");
                NSArray *bundles = identities.allKeys;
                NSUInteger hidden = 0;
                NSArray *allowed = allowedBundles(bundles, sections, identities, ownBundles, &hidden);
                NSUInteger systemHidden = 0;
                NSArray *systemItems = allowedSystemItems(layout[@"system"], &systemHidden);
                activate(systemItems, allowed, hidden, systemHidden, ticket, agent, boundary, rtl, protectedItems, display,
                    selectedOwners(apps, sections, identities, allowed));
            });
        }
    });
}

void craft_menubar_visibility_expand(void) {
    generation++;
    invalidate(pendingAssertion);
    pendingAssertion = nil;
    invalidate(assertion);
    assertion = nil;
    busy = NO;
    failure = nil;
    hiddenAppCount = 0;
    hiddenSystemItemCount = 0;
    notify();
}

void craft_menubar_visibility_cleanup(void) {
    craft_menubar_visibility_expand();
    changed = NULL;
    marker = nil;
}

bool craft_menubar_visibility_collapsed(void) { return assertion != nil; }
bool craft_menubar_visibility_busy(void) { return busy; }

const char *craft_menubar_visibility_state(void) {
    if (assertion && !AXIsProcessTrusted()) fail(@"permissionRequired");
    NSDictionary *state = @{
        @"backend": @"nativeVisibility", @"initialized": @((bool)(marker != nil)),
        @"collapsed": @((bool)(assertion != nil)), @"separatorHidden": @NO,
        @"available": @(available()), @"authorized": @((bool)AXIsProcessTrusted()),
        @"busy": @(busy), @"hiddenAppCount": @(hiddenAppCount), @"hiddenSystemItemCount": @(hiddenSystemItemCount),
        @"preserveSystemItems": @(preserveSystemItems),
        @"markerWidth": @(marker.length), @"error": failure ?: (id)NSNull.null,
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    // A C caller must not observe an ARC temporary after its final release.
    static NSString *serialized;
    serialized = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    return serialized.UTF8String;
}
#endif
