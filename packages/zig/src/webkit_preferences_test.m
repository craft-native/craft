#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static int trayWindowResult;
static NSUInteger trayWindowGeneration;

void craft_test_tray_window_begin(void *windowPointer, void *viewPointer, bool hidden, bool hideDock) {
    NSWindow *window = (__bridge NSWindow *)windowPointer;
    WKWebView *webview = (__bridge WKWebView *)viewPointer;
    trayWindowResult = 0;
    NSUInteger generation = ++trayWindowGeneration;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    __block BOOL sentClick = NO;
    __block BOOL evaluating = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        BOOL expired = deadline.timeIntervalSinceNow <= 0;
        if (hidden) {
            trayWindowResult = NSApp.activationPolicy == NSApplicationActivationPolicyAccessory &&
                NSApp.keyWindow == nil && (!window || !window.visible) ? 1 : -1;
        } else if (NSApp.active && window.keyWindow && !webview.loading && !evaluating) {
            NSApplicationActivationPolicy expected = hideDock ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
            if (NSApp.activationPolicy != expected) {
                trayWindowResult = -2;
            } else if (!sentClick) {
                NSPoint point = [webview convertPoint:NSMakePoint(NSMidX(webview.bounds), NSMidY(webview.bounds)) toView:nil];
                for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
                    NSEvent *event = [NSEvent mouseEventWithType:type.unsignedIntegerValue location:point modifierFlags:0
                        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
                        eventNumber:1 clickCount:1 pressure:1];
                    [NSApp sendEvent:event];
                }
                sentClick = YES;
            } else {
                evaluating = YES;
                [webview evaluateJavaScript:@"document.querySelector('button').dataset.clicked === 'yes'" completionHandler:^(id result, NSError *error) {
                    if (generation != trayWindowGeneration) return;
                    if (!error && [result boolValue]) trayWindowResult = 1;
                    evaluating = NO;
                }];
            }
        }
        if (trayWindowResult || expired) {
            if (!trayWindowResult) {
                NSLog(@"Tray input timed out: policy=%ld active=%d key=%d visible=%d clicked=%d", (long)NSApp.activationPolicy, NSApp.active, window.keyWindow, window.visible, sentClick);
                trayWindowResult = -3;
            }
            [timer invalidate];
            [NSApp stop:nil];
            // Wake the event loop so App.run returns after stop:.
            [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
        }
    }];
}

int craft_test_tray_window_result(void) { return trayWindowResult; }

static id trayEvaluate(WKWebView *view, NSString *script) {
    __block BOOL done = NO;
    __block id answer = nil;
    [view evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error) NSLog(@"Tray evaluation failed: %@", error);
        else answer = result;
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return answer;
}

static BOOL prepareTrayListeners(WKWebView *view) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (view.loading && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if (view.loading) return NO;
    return [trayEvaluate(view, @"globalThis.trayUnsubscribe?.forEach(f => f()); globalThis.trayClicks=[]; globalThis.trayActions=[]; globalThis.trayUnsubscribe=[craft.tray.onClick(d => trayClicks.push(d.button)),craft.tray.onMenuAction(d => trayActions.push(d.action))]; true") boolValue];
}

int craft_test_tray_callbacks(void *viewPointer, void *otherPointer, void *itemPointer, void *menuPointer) {
    WKWebView *view = (__bridge WKWebView *)viewPointer;
    WKWebView *other = (__bridge WKWebView *)otherPointer;
    NSStatusItem *item = (__bridge NSStatusItem *)itemPointer;
    NSMenu *menu = (__bridge NSMenu *)menuPointer;
    if (!prepareTrayListeners(view) || (other && !prepareTrayListeners(other))) return -1;
    // This invokes the actual installed AppKit target/action, not a direct
    // call to the Zig callback or the JavaScript delivery function. It does
    // not automate menu tracking or require Accessibility authorization.
    if (item.menu != nil) return -2; // An attached menu would consume left clicks.
    [item.button performClick:nil];
    [menu performActionForItemAtIndex:0];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    BOOL received = NO;
    while (deadline.timeIntervalSinceNow > 0) {
        received = [trayEvaluate(view, @"JSON.stringify(trayClicks) === '[\"left\"]' && JSON.stringify(trayActions) === '[\"hello\"]'") boolValue];
        if (received) break;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (!received) {
        NSLog(@"Tray callbacks missing: %@", trayEvaluate(view, @"JSON.stringify({clicks:trayClicks,actions:trayActions})"));
        return -3;
    }
    // Give the 100ms polling fallback time to expose accidental duplicates.
    NSDate *quietUntil = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while (quietUntil.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if (![trayEvaluate(view, @"trayClicks.length === 1 && trayActions.length === 1") boolValue]) return -4;
    if (other && ![trayEvaluate(other, @"trayClicks.length === 0 && trayActions.length === 0") boolValue]) return -5;
    return 1;
}

int craft_test_webkit_pixel(void *view, double rgba[4]) {
    WKWebView *webview = (__bridge WKWebView *)view;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (webview.loading && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    if (webview.loading) return 0;

    __block BOOL completed = NO;
    __block NSImage *snapshot = nil;
    WKSnapshotConfiguration *configuration = [WKSnapshotConfiguration new];
    configuration.afterScreenUpdates = YES;
    [webview takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *error) {
        if (!error) snapshot = image;
        completed = YES;
    }];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    if (!snapshot) return 0;
    NSRect rect = NSMakeRect(0, 0, snapshot.size.width, snapshot.size.height);
    CGImageRef image = [snapshot CGImageForProposedRect:&rect context:nil hints:nil];
    if (!image) return 0;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    if (bitmap.pixelsWide < 48 || bitmap.pixelsHigh < 8) return 0;
    // Sample blank page content, away from the text at the upper-left corner.
    NSColor *color = [[bitmap colorAtX:bitmap.pixelsWide - 24 y:bitmap.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!color) return 0;
    [color getRed:&rgba[0] green:&rgba[1] blue:&rgba[2] alpha:&rgba[3]];
    return 1;
}
