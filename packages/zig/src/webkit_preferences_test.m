#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

// A real loopback origin exercises URL loading and the public page -> native
// setMenu bridge. No production hooks, native menu construction, or JS event
// delivery functions are used by this fixture.
static dispatch_source_t trayHTTPServer;

unsigned short craft_test_tray_http_start(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return 0;
    struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK), .sin_port = 0 };
    socklen_t size = sizeof(address);
    if (bind(listener, (struct sockaddr *)&address, size) || listen(listener, 8) ||
        getsockname(listener, (struct sockaddr *)&address, &size)) {
        close(listener);
        return 0;
    }
    dispatch_queue_t queue = dispatch_queue_create("craft.test.tray.http", DISPATCH_QUEUE_SERIAL);
    trayHTTPServer = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listener, 0, queue);
    dispatch_source_set_event_handler(trayHTTPServer, ^{
        int client = accept(listener, NULL, NULL);
        if (client < 0) return;
        struct timeval timeout = { .tv_sec = 2 };
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int noSignal = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        char request[4096];
        if (recv(client, request, sizeof(request), 0) > 0) {
            NSString *page = @"<!doctype html><title>Tray HTTP regression</title><script>"
                "globalThis.trayClicks=[]; globalThis.trayActions=[];"
                "craft.tray.onClick(d=>trayClicks.push(d.button));"
                "craft.tray.onMenuAction(d=>trayActions.push(d.action));"
                "craft.tray.setMenu([{label:'HTTP Hello',action:'http-hello'}]);"
                "globalThis.trayHTTPReady=true;</script>Tray HTTP regression";
            NSData *body = [page dataUsingEncoding:NSUTF8StringEncoding];
            NSMutableData *response = [[[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", (unsigned long)body.length]
                dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            [response appendData:body];
            NSUInteger sent = 0;
            while (sent < response.length) {
                ssize_t count = send(client, (const char *)response.bytes + sent, response.length - sent, 0);
                if (count <= 0) break;
                sent += (NSUInteger)count;
            }
        }
        close(client);
    });
    dispatch_source_set_cancel_handler(trayHTTPServer, ^{ close(listener); });
    dispatch_resume(trayHTTPServer);
    return ntohs(address.sin_port);
}

void craft_test_tray_http_stop(void) {
    if (trayHTTPServer) dispatch_source_cancel(trayHTTPServer);
    trayHTTPServer = nil;
}

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

static void postTrayMouse(NSStatusItem *item, BOOL right) {
    NSPoint point = [item.button convertPoint:NSMakePoint(NSMidX(item.button.bounds), NSMidY(item.button.bounds)) toView:nil];
    for (NSNumber *type in right ? @[@(NSEventTypeRightMouseDown), @(NSEventTypeRightMouseUp)] :
                                   @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
        [NSApp postEvent:[NSEvent mouseEventWithType:type.unsignedIntegerValue location:point modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:item.button.window.windowNumber
            context:nil eventNumber:1 clickCount:1 pressure:1] atStart:NO];
    }
}

static void pumpTrayEvent(void) {
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
        inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
}

int craft_test_tray_http_callbacks(void *viewPointer, void *itemPointer) {
    WKWebView *view = (__bridge WKWebView *)viewPointer;
    NSStatusItem *item = (__bridge NSStatusItem *)itemPointer;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (view.loading && deadline.timeIntervalSinceNow > 0) pumpTrayEvent();
    if (![trayEvaluate(view, @"location.protocol === 'http:' && globalThis.trayHTTPReady === true") boolValue]) return -10;
    if (item.menu) return -11;
    __block NSMenu *trackedMenu = nil;
    __block BOOL selected = NO;
    __block BOOL ended = NO;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    id opened = [notifications addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSMenu *menu = note.object;
        if (!menu.numberOfItems || ![[menu itemAtIndex:0].title isEqualToString:@"HTTP Hello"]) return;
        trackedMenu = menu;
        // Selection goes through AppKit's tracking loop, not performAction or
        // the native callback. Keyboard events avoid global pointer injection
        // and do not require Accessibility permission on CI.
        NSTimer *select = [NSTimer timerWithTimeInterval:0.15 repeats:NO block:^(NSTimer *timer) {
            for (NSString *key in @[@"\uF701", @"\r"]) {
                [NSApp postEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                    timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:0 context:nil characters:key
                    charactersIgnoringModifiers:key isARepeat:NO keyCode:[key isEqualToString:@"\r"] ? 36 : 125] atStart:NO];
            }
        }];
        [[NSRunLoop currentRunLoop] addTimer:select forMode:NSEventTrackingRunLoopMode];
    }];
    id action = [notifications addObserverForName:NSMenuDidSendActionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (note.object == trackedMenu) selected = YES;
    }];
    id closed = [notifications addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if (note.object == trackedMenu) ended = YES;
    }];
    // Bound even a broken menu-tracking path; the timer also runs in AppKit's
    // nested tracking mode, where the outer test deadline cannot run.
    NSTimer *cancel = [NSTimer timerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) { [item.menu cancelTracking]; }];
    [[NSRunLoop currentRunLoop] addTimer:cancel forMode:NSEventTrackingRunLoopMode];
    postTrayMouse(item, YES);
    while (!ended && deadline.timeIntervalSinceNow > 0) pumpTrayEvent();
    [cancel invalidate];
    [notifications removeObserver:opened];
    [notifications removeObserver:action];
    [notifications removeObserver:closed];
    if (!trackedMenu || !selected || !ended || item.menu) {
        NSLog(@"Tray tracking failed: menu=%@ selected=%d ended=%d attached=%@", trackedMenu, selected, ended, item.menu);
        return -12;
    }
    postTrayMouse(item, NO); // A closed right-click menu must not swallow this.
    deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    BOOL received = NO;
    while (deadline.timeIntervalSinceNow > 0) {
        pumpTrayEvent();
        received = [trayEvaluate(view, @"JSON.stringify(trayClicks)==='[\"left\"]' && JSON.stringify(trayActions)==='[\"http-hello\"]'") boolValue];
        if (received) break;
    }
    if (!received) {
        NSLog(@"HTTP tray callbacks missing: %@", trayEvaluate(view, @"JSON.stringify({clicks:trayClicks,actions:trayActions})"));
        return -13;
    }
    NSDate *quietUntil = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while (quietUntil.timeIntervalSinceNow > 0) pumpTrayEvent();
    return [trayEvaluate(view, @"trayClicks.length===1 && trayActions.length===1") boolValue] ? 1 : -14;
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
