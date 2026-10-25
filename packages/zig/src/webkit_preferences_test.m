#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

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
