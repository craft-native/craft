#import <WebKit/WebKit.h>

int craft_webview_supports_transparency(void) {
#if defined(CRAFT_PUBLIC_APIS_ONLY)
    return 0;
#else
    return 1;
#endif
}

int craft_webview_make_transparent(void *view) {
#if defined(CRAFT_PUBLIC_APIS_ONLY)
    (void)view;
    return 0;
#else
    @try {
        [(__bridge WKWebView *)view setValue:@NO forKey:@"drawsBackground"];
        return 1;
    } @catch (NSException *exception) {
        (void)exception;
        return 0;
    }
#endif
}
