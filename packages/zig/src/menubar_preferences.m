// Read-only access to an already approved macOS menu bar arrangement.
#import <Foundation/Foundation.h>
#include <stdbool.h>

#if CRAFT_PUBLIC_APIS_ONLY
bool craft_menubar_layout_available(void) { return false; }
void *craft_menubar_copy_layout_positions(void) { return NULL; }
void craft_menubar_request_layout_access(void (*selected)(void *)) { (void)selected; }
#else
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#include <stdlib.h>

typedef CFPropertyListRef (*CraftCopyPreferenceWithContainer)(CFStringRef, CFStringRef, CFStringRef, CFStringRef, CFStringRef);

static CraftCopyPreferenceWithContainer layoutReader(void) {
    static CraftCopyPreferenceWithContainer reader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reader = (CraftCopyPreferenceWithContainer)dlsym(RTLD_DEFAULT, "_CFPreferencesCopyValueWithContainer");
    });
    return reader;
}

bool craft_menubar_layout_available(void) {
    if (getenv("APP_SANDBOX_CONTAINER_ID")) return false;
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){27, 0, 0}]
        && layoutReader() != NULL;
}

// Do not nest an AppKit modal loop inside a WebKit bridge invocation. Remote
// file-picker views and Accessibility must keep processing their main-loop work.
void craft_menubar_request_layout_access(void (*selected)(void *)) {
    static NSOpenPanel *pendingPanel;
    if (!craft_menubar_layout_available() || pendingPanel) return;
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    pendingPanel = panel;
    panel.title = @"Menu Bar Arrangement Access";
    panel.message = @"Allow read-only access to your menu bar arrangement so the arrow can smoothly hide only the icons to its left.";
    panel.prompt = @"Allow Read Access";
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.directoryURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Group Containers/com.apple.MenuBar/Library/Preferences"] isDirectory:YES];
    [NSApp activateIgnoringOtherApps:YES];
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) selected((__bridge void *)panel.URL);
        pendingPanel = nil;
    }];
}

// The caller must hold read-only security-scoped access to the arrangement
// file before calling. Return a retained dictionary; no preference is written
// or synchronized. Disk plists can lag a completed drag by several seconds.
void *craft_menubar_copy_layout_positions(void) {
    if (!craft_menubar_layout_available()) return NULL;
    NSString *container = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Group Containers/com.apple.MenuBar"];
    CFPropertyListRef positions = layoutReader()(CFSTR("TrailingItemPreferredPositions"), CFSTR("com.apple.MenuBar"),
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost, (__bridge CFStringRef)container);
    if (!positions) return NULL;
    if (CFGetTypeID(positions) != CFDictionaryGetTypeID()) {
        CFRelease(positions);
        return NULL;
    }
    return (void *)positions;
}
#endif
