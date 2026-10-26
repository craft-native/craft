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
