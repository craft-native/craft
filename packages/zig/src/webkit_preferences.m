#import <WebKit/WebKit.h>

typedef void (*CraftDataStoreCompletion)(void *, void *);

API_AVAILABLE(macos(14.0))
static void remove_released_store(NSUUID *uuid, void *context, CraftDataStoreCompletion completion, unsigned attempts) {
    [WKWebsiteDataStore removeDataStoreForIdentifier:uuid completionHandler:^(NSError *error) {
        if (error && attempts > 1 && error.code == WKErrorUnknown) {
            // WebKit can still hold the data store in its network process
            // after all views release it. Keep the profile locked and wait
            // for the session to close before attempting the same removal.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                remove_released_store(uuid, context, completion, attempts - 1);
            });
            return;
        }
        completion(context, (__bridge void *)error);
    }];
}

void craft_webview_remove_data_store(const unsigned char *identifier, void *context, CraftDataStoreCompletion completion) {
    if (@available(macOS 14.0, *)) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:identifier];
        [WKWebsiteDataStore fetchAllDataStoreIdentifiers:^(NSArray<NSUUID *> *identifiers) {
            if (![identifiers containsObject:uuid]) {
                // Confirm removal with WebKit without creating a new store
                // to clear when the profile has already been removed.
                remove_released_store(uuid, context, completion, 8);
                return;
            }
            @autoreleasepool {
                WKWebsiteDataStore *store = [WKWebsiteDataStore dataStoreForIdentifier:uuid];
                // Clear network storage as well as the store files. Reopening
                // the identifier must not resurrect cached cookies.
                [store removeDataOfTypes:[WKWebsiteDataStore allWebsiteDataTypes]
                           modifiedSince:[NSDate distantPast]
                      completionHandler:^{
                    // Let WebKit return from the callback and release its
                    // last reference before asking it to remove the store.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        remove_released_store(uuid, context, completion, 8);
                    });
                }];
            }
        }];
    } else {
        NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil];
        completion(context, (__bridge void *)error);
    }
}

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
