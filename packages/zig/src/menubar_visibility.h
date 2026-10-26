// Craft's opt-in macOS 27 native status-item visibility backend.
#pragma once
#include <stdbool.h>

bool craft_menubar_visibility_available(void);
void craft_menubar_visibility_init(void *marker, void (*changed)(void), bool preserve_system_items);
void craft_menubar_visibility_collapse(void);
void craft_menubar_visibility_expand(void);
void craft_menubar_visibility_cleanup(void);
void craft_menubar_visibility_request_permission(void);
bool craft_menubar_visibility_collapsed(void);
bool craft_menubar_visibility_busy(void);
const char *craft_menubar_visibility_state(void);
