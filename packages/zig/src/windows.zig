const std = @import("std");
const bridge_error = @import("bridge_error.zig");
const desktop_bridge_envelope = @import("desktop_bridge_envelope.zig");
const desktop_bridge_text = @import("desktop_bridge_text.zig");
const desktop_window_controls = @import("desktop_window_controls.zig");
const desktop_script_encoding = @import("desktop_script_encoding.zig");
const desktop_window_events = @import("desktop_window_events.zig");
const desktop_window_reads = @import("desktop_window_reads.zig");
const desktop_window_registry = @import("desktop_window_registry.zig");
const json_utils = @import("json_utils.zig");
const request_context = @import("request_context.zig");
const window_context = @import("window_context.zig");
const window_registry = @import("window_registry.zig");
const window_reply_target = @import("window_reply_target.zig");

// Windows implementation using Win32 API and WebView2
// Requires: Microsoft.Web.WebView2 NuGet package

// Windows API types
pub const HWND = *anyopaque;
pub const HINSTANCE = *anyopaque;
pub const HMENU = *anyopaque;
pub const LPVOID = ?*anyopaque;
pub const LPCWSTR = [*:0]const u16;
pub const LPWSTR = [*:0]u16;
pub const UINT = c_uint;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const DWORD = c_ulong;
pub const BOOL = c_int;
pub const HRESULT = c_long;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?*anyopaque,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: extern struct {
        x: c_long,
        y: c_long,
    },
};

pub const RECT = extern struct {
    left: c_long,
    top: c_long,
    right: c_long,
    bottom: c_long,
};
pub const POINT = extern struct { x: c_long, y: c_long };
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

// COM base type
pub const GUID = extern struct {
    Data1: c_ulong,
    Data2: c_ushort,
    Data3: c_ushort,
    Data4: [8]u8,
};

pub const EventRegistrationToken = extern struct {
    value: i64,
};

// Constants
pub const S_OK: HRESULT = 0;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
pub const SW_SHOW: c_int = 5;
pub const SW_HIDE: c_int = 0;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_MINIMIZE: c_int = 6;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_QUIT: UINT = 0x0012;
const WM_CRAFT_OPEN_WINDOW: UINT = 0x8001; // WM_APP + 1
pub const PM_REMOVE: UINT = 0x0001;
pub const GWLP_USERDATA: c_int = -21;
const GWL_STYLE: c_int = -16;
const SWP_NOSIZE: UINT = 0x0001;
const SWP_NOMOVE: UINT = 0x0002;
const SWP_NOZORDER: UINT = 0x0004;
const SWP_FRAMECHANGED: UINT = 0x0020;
const SWP_NOACTIVATE: UINT = 0x0010;
const MONITOR_DEFAULTTONEAREST: DWORD = 2;

// Win32 API functions
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) u16;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: LPVOID,
) callconv(.c) ?HWND;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.c) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.c) BOOL;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.c) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.c) LRESULT;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.c) void;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) BOOL;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.c) BOOL;
pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.c) c_int;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: LPWSTR, nMaxCount: c_int) callconv(.c) c_int;
pub extern "user32" fn GetForegroundWindow() callconv(.c) ?HWND;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: UINT) callconv(.c) BOOL;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.c) ?*anyopaque;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.c) isize;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.c) isize;
pub extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: DWORD) callconv(.c) ?*anyopaque;
pub extern "user32" fn GetMonitorInfoW(hMonitor: *anyopaque, lpmi: *MONITORINFO) callconv(.c) BOOL;
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.c) ?HINSTANCE;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.c) void;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.c) void;

// ============================================================================
// WebView2 COM vtable interfaces
// ============================================================================
//
// WebView2 uses COM (Component Object Model). Each interface is accessed
// through a pointer to a vtable of function pointers. The layout matches
// the C ABI produced by the WebView2 SDK headers:
//   struct ICoreWebView2Foo {
//       ICoreWebView2FooVtbl* lpVtbl;
//   };
//
// In Zig we model this as a struct whose first (and only) field is a pointer
// to an extern struct full of function pointers.
// ============================================================================

// -- IUnknown base (shared by every COM interface) ---------------------------

pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.c) c_ulong,
    Release: *const fn (*anyopaque) callconv(.c) c_ulong,
};

// -- ICoreWebView2Environment ------------------------------------------------

pub const ICoreWebView2EnvironmentVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ICoreWebView2Environment, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*ICoreWebView2Environment) callconv(.c) c_ulong,
    Release: *const fn (*ICoreWebView2Environment) callconv(.c) c_ulong,
    // ICoreWebView2Environment
    CreateCoreWebView2Controller: *const fn (*ICoreWebView2Environment, HWND, *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(.c) HRESULT,
};

pub const ICoreWebView2Environment = extern struct {
    lpVtbl: *ICoreWebView2EnvironmentVtbl,
};

// -- ICoreWebView2Controller -------------------------------------------------

pub const ICoreWebView2ControllerVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ICoreWebView2Controller, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*ICoreWebView2Controller) callconv(.c) c_ulong,
    Release: *const fn (*ICoreWebView2Controller) callconv(.c) c_ulong,
    // ICoreWebView2Controller
    get_IsVisible: *const fn (*ICoreWebView2Controller, *BOOL) callconv(.c) HRESULT,
    put_IsVisible: *const fn (*ICoreWebView2Controller, BOOL) callconv(.c) HRESULT,
    get_Bounds: *const fn (*ICoreWebView2Controller, *RECT) callconv(.c) HRESULT,
    put_Bounds: *const fn (*ICoreWebView2Controller, RECT) callconv(.c) HRESULT,
    get_ZoomFactor: *const fn (*ICoreWebView2Controller, *f64) callconv(.c) HRESULT,
    put_ZoomFactor: *const fn (*ICoreWebView2Controller, f64) callconv(.c) HRESULT,
    add_ZoomFactorChanged: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ZoomFactorChanged: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
    SetBoundsAndZoomFactor: *const fn (*ICoreWebView2Controller, RECT, f64) callconv(.c) HRESULT,
    MoveFocus: *const fn (*ICoreWebView2Controller, c_int) callconv(.c) HRESULT,
    add_MoveFocusRequested: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_MoveFocusRequested: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
    add_GotFocus: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_GotFocus: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
    add_LostFocus: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_LostFocus: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
    add_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_AcceleratorKeyPressed: *const fn (*ICoreWebView2Controller, EventRegistrationToken) callconv(.c) HRESULT,
    get_ParentWindow: *const fn (*ICoreWebView2Controller, *HWND) callconv(.c) HRESULT,
    put_ParentWindow: *const fn (*ICoreWebView2Controller, HWND) callconv(.c) HRESULT,
    NotifyParentWindowPositionChanged: *const fn (*ICoreWebView2Controller) callconv(.c) HRESULT,
    Close: *const fn (*ICoreWebView2Controller) callconv(.c) HRESULT,
    get_CoreWebView2: *const fn (*ICoreWebView2Controller, **ICoreWebView2) callconv(.c) HRESULT,
};

pub const ICoreWebView2Controller = extern struct {
    lpVtbl: *ICoreWebView2ControllerVtbl,
};

// -- ICoreWebView2 -----------------------------------------------------------

pub const ICoreWebView2Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ICoreWebView2, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*ICoreWebView2) callconv(.c) c_ulong,
    Release: *const fn (*ICoreWebView2) callconv(.c) c_ulong,
    // ICoreWebView2 – only the methods we need, padded with placeholders for
    // the ones we skip so vtable offsets stay correct.
    get_Settings: *const fn (*ICoreWebView2, **ICoreWebView2Settings) callconv(.c) HRESULT,
    get_Source: *const fn (*ICoreWebView2, *LPWSTR) callconv(.c) HRESULT,
    Navigate: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT,
    NavigateToString: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT,
    add_NavigationStarting: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_NavigationStarting: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_ContentLoading: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ContentLoading: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_SourceChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_SourceChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_HistoryChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_HistoryChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_NavigationCompleted: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_NavigationCompleted: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_FrameNavigationStarting: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_FrameNavigationStarting: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_FrameNavigationCompleted: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_FrameNavigationCompleted: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_ScriptDialogOpening: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ScriptDialogOpening: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_PermissionRequested: *const fn (*ICoreWebView2, *ICoreWebView2PermissionRequestedEventHandler, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_PermissionRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_ProcessFailed: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ProcessFailed: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    AddScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, LPCWSTR, ?*anyopaque) callconv(.c) HRESULT,
    RemoveScriptToExecuteOnDocumentCreated: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT,
    ExecuteScript: *const fn (*ICoreWebView2, LPCWSTR, ?*ICoreWebView2ExecuteScriptCompletedHandler) callconv(.c) HRESULT,
    CapturePreview: *const fn (*ICoreWebView2, c_int, *anyopaque, *anyopaque) callconv(.c) HRESULT,
    Reload: *const fn (*ICoreWebView2) callconv(.c) HRESULT,
    PostWebMessageAsJson: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT,
    PostWebMessageAsString: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT,
    add_WebMessageReceived: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_WebMessageReceived: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    CallDevToolsProtocolMethod: *const fn (*ICoreWebView2, LPCWSTR, LPCWSTR, *anyopaque) callconv(.c) HRESULT,
    get_BrowserProcessId: *const fn (*ICoreWebView2, *c_ulong) callconv(.c) HRESULT,
    get_CanGoBack: *const fn (*ICoreWebView2, *BOOL) callconv(.c) HRESULT,
    get_CanGoForward: *const fn (*ICoreWebView2, *BOOL) callconv(.c) HRESULT,
    GoBack: *const fn (*ICoreWebView2) callconv(.c) HRESULT,
    GoForward: *const fn (*ICoreWebView2) callconv(.c) HRESULT,
    GetDevToolsProtocolEventReceiver: *const fn (*ICoreWebView2, LPCWSTR, *?*anyopaque) callconv(.c) HRESULT,
    Stop: *const fn (*ICoreWebView2) callconv(.c) HRESULT,
    add_NewWindowRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_NewWindowRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    add_DocumentTitleChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_DocumentTitleChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    get_DocumentTitle: *const fn (*ICoreWebView2, *LPWSTR) callconv(.c) HRESULT,
    AddHostObjectToScript: *const fn (*ICoreWebView2, LPCWSTR, *anyopaque) callconv(.c) HRESULT,
    RemoveHostObjectFromScript: *const fn (*ICoreWebView2, LPCWSTR) callconv(.c) HRESULT,
    OpenDevToolsWindow: *const fn (*ICoreWebView2) callconv(.c) HRESULT,
    add_ContainsFullScreenElementChanged: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_ContainsFullScreenElementChanged: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    get_ContainsFullScreenElement: *const fn (*ICoreWebView2, *BOOL) callconv(.c) HRESULT,
    add_WebResourceRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_WebResourceRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
    AddWebResourceRequestedFilter: *const fn (*ICoreWebView2, LPCWSTR, c_int) callconv(.c) HRESULT,
    RemoveWebResourceRequestedFilter: *const fn (*ICoreWebView2, LPCWSTR, c_int) callconv(.c) HRESULT,
    add_WindowCloseRequested: *const fn (*ICoreWebView2, *anyopaque, *EventRegistrationToken) callconv(.c) HRESULT,
    remove_WindowCloseRequested: *const fn (*ICoreWebView2, EventRegistrationToken) callconv(.c) HRESULT,
};

pub const ICoreWebView2 = extern struct {
    lpVtbl: *ICoreWebView2Vtbl,
};

pub const ICoreWebView2WebMessageReceivedEventArgsVtbl = extern struct {
    QueryInterface: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) c_ulong,
    Release: *const fn (*ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) c_ulong,
    get_Source: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.c) HRESULT,
    get_WebMessageAsJson: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.c) HRESULT,
    TryGetWebMessageAsString: *const fn (*ICoreWebView2WebMessageReceivedEventArgs, *?LPWSTR) callconv(.c) HRESULT,
};

pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    lpVtbl: *ICoreWebView2WebMessageReceivedEventArgsVtbl,
};

// -- ICoreWebView2Settings ---------------------------------------------------

pub const ICoreWebView2SettingsVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ICoreWebView2Settings, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*ICoreWebView2Settings) callconv(.c) c_ulong,
    Release: *const fn (*ICoreWebView2Settings) callconv(.c) c_ulong,
    // ICoreWebView2Settings
    get_IsScriptEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_IsScriptEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_IsWebMessageEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_IsWebMessageEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_AreDefaultScriptDialogsEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_AreDefaultScriptDialogsEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_IsStatusBarEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_IsStatusBarEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_AreDevToolsEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_AreDevToolsEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_AreDefaultContextMenusEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_AreDefaultContextMenusEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_AreHostObjectsAllowed: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_AreHostObjectsAllowed: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_IsZoomControlEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_IsZoomControlEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
    get_IsBuiltInErrorPageEnabled: *const fn (*ICoreWebView2Settings, *BOOL) callconv(.c) HRESULT,
    put_IsBuiltInErrorPageEnabled: *const fn (*ICoreWebView2Settings, BOOL) callconv(.c) HRESULT,
};

pub const ICoreWebView2Settings = extern struct {
    lpVtbl: *ICoreWebView2SettingsVtbl,
};

// -- ICoreWebView2PermissionRequestedEventArgs -------------------------------

pub const ICoreWebView2PermissionRequestedEventArgsVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ICoreWebView2PermissionRequestedEventArgs, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
    AddRef: *const fn (*ICoreWebView2PermissionRequestedEventArgs) callconv(.c) c_ulong,
    Release: *const fn (*ICoreWebView2PermissionRequestedEventArgs) callconv(.c) c_ulong,
    // ICoreWebView2PermissionRequestedEventArgs
    get_Uri: *const fn (*ICoreWebView2PermissionRequestedEventArgs, *LPWSTR) callconv(.c) HRESULT,
    get_PermissionKind: *const fn (*ICoreWebView2PermissionRequestedEventArgs, *COREWEBVIEW2_PERMISSION_KIND) callconv(.c) HRESULT,
    get_IsUserInitiated: *const fn (*ICoreWebView2PermissionRequestedEventArgs, *BOOL) callconv(.c) HRESULT,
    get_State: *const fn (*ICoreWebView2PermissionRequestedEventArgs, *COREWEBVIEW2_PERMISSION_STATE) callconv(.c) HRESULT,
    put_State: *const fn (*ICoreWebView2PermissionRequestedEventArgs, COREWEBVIEW2_PERMISSION_STATE) callconv(.c) HRESULT,
    GetDeferral: *const fn (*ICoreWebView2PermissionRequestedEventArgs, *?*anyopaque) callconv(.c) HRESULT,
};

pub const ICoreWebView2PermissionRequestedEventArgs = extern struct {
    lpVtbl: *ICoreWebView2PermissionRequestedEventArgsVtbl,
};

// Permission types for WebView2
pub const COREWEBVIEW2_PERMISSION_KIND = enum(c_int) {
    UNKNOWN_PERMISSION = 0,
    MICROPHONE = 1,
    CAMERA = 2,
    GEOLOCATION = 3,
    NOTIFICATIONS = 4,
    OTHER_SENSORS = 5,
    CLIPBOARD_READ = 6,
};

pub const COREWEBVIEW2_PERMISSION_STATE = enum(c_int) {
    DEFAULT = 0,
    ALLOW = 1,
    DENY = 2,
};

// ============================================================================
// COM callback handler implementations
// ============================================================================
//
// WebView2 initialization is asynchronous. We create small COM objects whose
// vtables point to our Zig functions so the runtime can call us back.
//
// Each handler struct has:
//   - A vtable pointer (first field, required by COM ABI)
//   - A reference count
//   - Pointers back to the shared WebView2InitContext so callbacks can store
//     results and signal completion
// ============================================================================

/// Shared mutable state used during async WebView2 initialization.
const WebView2InitContext = struct {
    hwnd: HWND,
    controller: ?*ICoreWebView2Controller = null,
    webview: ?*ICoreWebView2 = null,
    init_done: bool = false,
    init_failed: bool = false,
    dev_tools: bool = true,
};

// -- Environment completed handler -------------------------------------------

const EnvironmentCompletedHandler = extern struct {
    lpVtbl: *const EnvironmentCompletedHandlerVtbl,
    ref_count: c_ulong,
    ctx: *WebView2InitContext,

    const EnvironmentCompletedHandlerVtbl = extern struct {
        QueryInterface: *const fn (*EnvironmentCompletedHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*EnvironmentCompletedHandler) callconv(.c) c_ulong,
        Release: *const fn (*EnvironmentCompletedHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*EnvironmentCompletedHandler, HRESULT, ?*ICoreWebView2Environment) callconv(.c) HRESULT,
    };

    const vtbl_instance = EnvironmentCompletedHandlerVtbl{
        .QueryInterface = &envQueryInterface,
        .AddRef = &envAddRef,
        .Release = &envRelease,
        .Invoke = &envInvoke,
    };

    fn envQueryInterface(self: *EnvironmentCompletedHandler, _: *const GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
        ppv.* = @ptrCast(self);
        _ = envAddRef(self);
        return S_OK;
    }

    fn envAddRef(self: *EnvironmentCompletedHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn envRelease(self: *EnvironmentCompletedHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) std.heap.c_allocator.destroy(self);
        return remaining;
    }

    fn envInvoke(self: *EnvironmentCompletedHandler, hr: HRESULT, env: ?*ICoreWebView2Environment) callconv(.c) HRESULT {
        if (hr != S_OK) {
            std.debug.print("[WebView2] Environment creation failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            self.ctx.init_failed = true;
            return hr;
        }
        const environment = env orelse {
            std.debug.print("[WebView2] Environment creation returned null\n", .{});
            self.ctx.init_failed = true;
            return -1; // E_FAIL
        };

        const ctrl_handler = std.heap.c_allocator.create(ControllerCompletedHandler) catch {
            self.ctx.init_failed = true;
            return -1;
        };
        ctrl_handler.* = .{
            .lpVtbl = &ControllerCompletedHandler.vtbl_instance,
            .ref_count = 1,
            .ctx = self.ctx,
        };

        const result = environment.lpVtbl.CreateCoreWebView2Controller(
            environment,
            self.ctx.hwnd,
            ctrl_handler,
        );
        _ = ControllerCompletedHandler.ctrlRelease(ctrl_handler);
        if (result != S_OK) {
            std.debug.print("[WebView2] CreateCoreWebView2Controller call failed: 0x{x}\n", .{@as(u32, @bitCast(result))});
            self.ctx.init_failed = true;
        }
        return result;
    }
};

// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler is used by the
// extern CreateCoreWebView2EnvironmentWithOptions. We redefine it here as
// a concrete type alias so the extern declaration is satisfied.
pub const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = EnvironmentCompletedHandler;

// -- Controller completed handler --------------------------------------------

const ControllerCompletedHandler = extern struct {
    lpVtbl: *const ControllerCompletedHandlerVtbl,
    ref_count: c_ulong,
    ctx: *WebView2InitContext,

    const ControllerCompletedHandlerVtbl = extern struct {
        QueryInterface: *const fn (*ControllerCompletedHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ControllerCompletedHandler) callconv(.c) c_ulong,
        Release: *const fn (*ControllerCompletedHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*ControllerCompletedHandler, HRESULT, ?*ICoreWebView2Controller) callconv(.c) HRESULT,
    };

    const vtbl_instance = ControllerCompletedHandlerVtbl{
        .QueryInterface = &ctrlQueryInterface,
        .AddRef = &ctrlAddRef,
        .Release = &ctrlRelease,
        .Invoke = &ctrlInvoke,
    };

    fn ctrlQueryInterface(self: *ControllerCompletedHandler, _: *const GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
        ppv.* = @ptrCast(self);
        _ = ctrlAddRef(self);
        return S_OK;
    }

    fn ctrlAddRef(self: *ControllerCompletedHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn ctrlRelease(self: *ControllerCompletedHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) std.heap.c_allocator.destroy(self);
        return remaining;
    }

    fn ctrlInvoke(self: *ControllerCompletedHandler, hr: HRESULT, ctrl: ?*ICoreWebView2Controller) callconv(.c) HRESULT {
        if (hr != S_OK) {
            std.debug.print("[WebView2] Controller creation failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            self.ctx.init_failed = true;
            return hr;
        }

        const controller = ctrl orelse {
            std.debug.print("[WebView2] Controller creation returned null\n", .{});
            self.ctx.init_failed = true;
            return -1;
        };

        // Get the ICoreWebView2 from the controller
        var webview: *ICoreWebView2 = undefined;
        var get_hr = controller.lpVtbl.get_CoreWebView2(controller, &webview);
        if (get_hr != S_OK) {
            std.debug.print("[WebView2] get_CoreWebView2 failed: 0x{x}\n", .{@as(u32, @bitCast(get_hr))});
            self.ctx.init_failed = true;
            return get_hr;
        }

        // Configure settings
        var settings: *ICoreWebView2Settings = undefined;
        get_hr = webview.lpVtbl.get_Settings(webview, &settings);
        if (get_hr == S_OK) {
            _ = settings.lpVtbl.put_IsScriptEnabled(settings, 1);
            _ = settings.lpVtbl.put_IsWebMessageEnabled(settings, 1);
            _ = settings.lpVtbl.put_AreDefaultContextMenusEnabled(settings, 1);
            _ = settings.lpVtbl.put_AreDevToolsEnabled(settings, if (self.ctx.dev_tools) @as(BOOL, 1) else @as(BOOL, 0));
            _ = settings.lpVtbl.put_IsStatusBarEnabled(settings, 0);
            _ = settings.lpVtbl.put_IsZoomControlEnabled(settings, 0);
        }

        // Size the webview to fill the client area
        var bounds: RECT = undefined;
        _ = GetClientRect(self.ctx.hwnd, &bounds);
        _ = controller.lpVtbl.put_Bounds(controller, bounds);
        _ = controller.lpVtbl.put_IsVisible(controller, 1);

        // Register permission handler for camera/microphone
        const perm_handler = std.heap.c_allocator.create(PermissionRequestedHandler) catch {
            self.ctx.init_failed = true;
            return -1;
        };
        perm_handler.* = .{
            .lpVtbl = &PermissionRequestedHandler.vtbl_instance,
            .ref_count = 1,
        };
        var perm_token: EventRegistrationToken = .{ .value = 0 };
        const perm_hr = webview.lpVtbl.add_PermissionRequested(webview, perm_handler, &perm_token);
        _ = PermissionRequestedHandler.permRelease(perm_handler);
        if (!succeeded(perm_hr)) {
            self.ctx.init_failed = true;
            return perm_hr;
        }

        // The callback only lends us the controller. Keep our own reference
        // past Invoke so WebView2 does not close before Window.create uses it.
        _ = controller.lpVtbl.AddRef(controller);

        // Store results
        self.ctx.controller = controller;
        self.ctx.webview = webview;
        self.ctx.init_done = true;

        std.debug.print("[WebView2] Initialization complete\n", .{});
        return S_OK;
    }
};

pub const ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = ControllerCompletedHandler;

// -- Permission requested event handler --------------------------------------

const PermissionRequestedHandler = extern struct {
    lpVtbl: *const PermissionRequestedHandlerVtbl,
    ref_count: c_ulong,

    const PermissionRequestedHandlerVtbl = extern struct {
        QueryInterface: *const fn (*PermissionRequestedHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*PermissionRequestedHandler) callconv(.c) c_ulong,
        Release: *const fn (*PermissionRequestedHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*PermissionRequestedHandler, *ICoreWebView2, *ICoreWebView2PermissionRequestedEventArgs) callconv(.c) HRESULT,
    };

    const vtbl_instance = PermissionRequestedHandlerVtbl{
        .QueryInterface = &permQueryInterface,
        .AddRef = &permAddRef,
        .Release = &permRelease,
        .Invoke = &permInvoke,
    };

    fn permQueryInterface(self: *PermissionRequestedHandler, _: *const GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
        ppv.* = @ptrCast(self);
        _ = permAddRef(self);
        return S_OK;
    }

    fn permAddRef(self: *PermissionRequestedHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn permRelease(self: *PermissionRequestedHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) std.heap.c_allocator.destroy(self);
        return remaining;
    }

    fn permInvoke(_: *PermissionRequestedHandler, _: *ICoreWebView2, args: *ICoreWebView2PermissionRequestedEventArgs) callconv(.c) HRESULT {
        var kind: COREWEBVIEW2_PERMISSION_KIND = .UNKNOWN_PERMISSION;
        _ = args.lpVtbl.get_PermissionKind(args, &kind);

        // Auto-allow camera and microphone access
        if (kind == .CAMERA or kind == .MICROPHONE) {
            _ = args.lpVtbl.put_State(args, .ALLOW);
            std.debug.print("[Media] Auto-allowed permission: {}\n", .{kind});
        }
        return S_OK;
    }
};

pub const ICoreWebView2PermissionRequestedEventHandler = PermissionRequestedHandler;

// -- Page-to-host message handler --------------------------------------------

const WebMessageReceivedHandler = extern struct {
    lpVtbl: *const WebMessageReceivedHandlerVtbl,
    ref_count: c_ulong,
    window_id: u32,

    const WebMessageReceivedHandlerVtbl = extern struct {
        QueryInterface: *const fn (*WebMessageReceivedHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*WebMessageReceivedHandler) callconv(.c) c_ulong,
        Release: *const fn (*WebMessageReceivedHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*WebMessageReceivedHandler, *ICoreWebView2, *ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) HRESULT,
    };

    const vtbl_instance = WebMessageReceivedHandlerVtbl{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &release,
        .Invoke = &invoke,
    };

    fn queryInterface(self: *WebMessageReceivedHandler, _: *const GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
        ppv.* = @ptrCast(self);
        _ = addRef(self);
        return S_OK;
    }

    fn addRef(self: *WebMessageReceivedHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *WebMessageReceivedHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) std.heap.c_allocator.destroy(self);
        return remaining;
    }

    fn invoke(self: *WebMessageReceivedHandler, _: *ICoreWebView2, args: *ICoreWebView2WebMessageReceivedEventArgs) callconv(.c) HRESULT {
        // The handler is registered on exactly one native WebView2 instance.
        // Bind its live registry id rather than comparing raw COM interface
        // pointers, which need not have the same address for one object.
        const entry = desktop_windows.byId(self.window_id) orelse return S_OK;
        var message_wide: ?LPWSTR = null;
        if (!succeeded(args.lpVtbl.get_WebMessageAsJson(args, &message_wide))) return S_OK;
        const wide = message_wide orelse return S_OK;
        defer CoTaskMemFree(@ptrCast(wide));
        const wide_text = std.mem.span(wide);
        const message = desktop_bridge_text.fromUtf16(std.heap.c_allocator, wide_text) catch return S_OK;
        defer std.heap.c_allocator.free(message);

        var envelope = desktop_bridge_envelope.parse(std.heap.c_allocator, message) catch return S_OK;
        defer envelope.deinit();
        window_context.push(entry.window, entry.webview);
        defer window_context.pop();
        request_context.push(envelope.request_id);
        defer request_context.pop();

        if (!std.mem.eql(u8, envelope.kind, "window")) {
            bridge_error.sendErrorToJS(std.heap.c_allocator, envelope.action, error.PlatformNotSupported);
            return S_OK;
        }
        if (std.mem.eql(u8, envelope.action, "open") or std.mem.eql(u8, envelope.action, "create")) {
            // WebView2 does not deliver async completion callbacks inside its
            // own event callback. Window.create pumps until such a callback,
            // so run it from a posted Win32 message after Invoke returns.
            queueWindowOpen(entry, envelope.action, envelope.data, envelope.request_id) catch |err| {
                bridge_error.sendErrorToJS(std.heap.c_allocator, envelope.action, bridge_error.fromHandlerError(err));
            };
            return S_OK;
        }
        handleWindowAction(envelope.action, envelope.data) catch |err| {
            bridge_error.sendErrorToJS(std.heap.c_allocator, envelope.action, bridge_error.fromHandlerError(err));
        };
        return S_OK;
    }
};

// -- ExecuteScript completed handler (fire-and-forget) -----------------------

const ExecuteScriptCompletedHandler = extern struct {
    lpVtbl: *const ExecuteScriptCompletedHandlerVtbl,
    ref_count: c_ulong,

    const ExecuteScriptCompletedHandlerVtbl = extern struct {
        QueryInterface: *const fn (*ExecuteScriptCompletedHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ExecuteScriptCompletedHandler) callconv(.c) c_ulong,
        Release: *const fn (*ExecuteScriptCompletedHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*ExecuteScriptCompletedHandler, HRESULT, LPCWSTR) callconv(.c) HRESULT,
    };

    const vtbl_instance = ExecuteScriptCompletedHandlerVtbl{
        .QueryInterface = &esQueryInterface,
        .AddRef = &esAddRef,
        .Release = &esRelease,
        .Invoke = &esInvoke,
    };

    fn esQueryInterface(self: *ExecuteScriptCompletedHandler, _: *const GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
        ppv.* = @ptrCast(self);
        _ = esAddRef(self);
        return S_OK;
    }

    fn esAddRef(self: *ExecuteScriptCompletedHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn esRelease(self: *ExecuteScriptCompletedHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) std.heap.c_allocator.destroy(self);
        return remaining;
    }

    fn esInvoke(_: *ExecuteScriptCompletedHandler, hr: HRESULT, _: LPCWSTR) callconv(.c) HRESULT {
        if (hr != S_OK) {
            std.debug.print("[WebView2] ExecuteScript completed with error: 0x{x}\n", .{@as(u32, @bitCast(hr))});
        }
        return S_OK;
    }
};

pub const ICoreWebView2ExecuteScriptCompletedHandler = ExecuteScriptCompletedHandler;

// -- Document-start script completed handler ---------------------------------

const ScriptInstallContext = struct {
    done: bool = false,
    result: HRESULT = -1,
};

const ScriptInstallCompletedHandler = extern struct {
    lpVtbl: *const ScriptInstallCompletedHandlerVtbl,
    ref_count: c_ulong,
    ctx: *ScriptInstallContext,

    const ScriptInstallCompletedHandlerVtbl = extern struct {
        QueryInterface: *const fn (*ScriptInstallCompletedHandler, *const GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*ScriptInstallCompletedHandler) callconv(.c) c_ulong,
        Release: *const fn (*ScriptInstallCompletedHandler) callconv(.c) c_ulong,
        Invoke: *const fn (*ScriptInstallCompletedHandler, HRESULT, LPCWSTR) callconv(.c) HRESULT,
    };

    const vtbl_instance = ScriptInstallCompletedHandlerVtbl{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &release,
        .Invoke = &invoke,
    };

    fn queryInterface(self: *ScriptInstallCompletedHandler, _: *const GUID, ppv: *?*anyopaque) callconv(.c) HRESULT {
        ppv.* = @ptrCast(self);
        _ = addRef(self);
        return S_OK;
    }

    fn addRef(self: *ScriptInstallCompletedHandler) callconv(.c) c_ulong {
        self.ref_count += 1;
        return self.ref_count;
    }

    fn release(self: *ScriptInstallCompletedHandler) callconv(.c) c_ulong {
        if (self.ref_count > 0) self.ref_count -= 1;
        const remaining = self.ref_count;
        if (remaining == 0) std.heap.c_allocator.destroy(self);
        return remaining;
    }

    fn invoke(self: *ScriptInstallCompletedHandler, hr: HRESULT, _: LPCWSTR) callconv(.c) HRESULT {
        self.ctx.result = hr;
        self.ctx.done = true;
        return S_OK;
    }
};

// ============================================================================
// WebView2Loader — loaded dynamically at runtime to avoid link-time dependency
// ============================================================================

pub extern "kernel32" fn LoadLibraryW(lpLibFileName: LPCWSTR) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;

const CreateCoreWebView2EnvironmentWithOptionsFn = *const fn (
    browserExecutableFolder: ?LPCWSTR,
    userDataFolder: ?LPCWSTR,
    options: ?*anyopaque,
    environmentCreatedHandler: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
) callconv(.c) HRESULT;

var webview2_create_fn: ?CreateCoreWebView2EnvironmentWithOptionsFn = null;

/// Dynamically load WebView2Loader.dll and resolve CreateCoreWebView2EnvironmentWithOptions.
/// Returns null if WebView2 runtime is not installed.
fn loadWebView2() ?CreateCoreWebView2EnvironmentWithOptionsFn {
    if (webview2_create_fn) |f| return f;
    const dll_name: [:0]const u16 = &[_:0]u16{ 'W', 'e', 'b', 'V', 'i', 'e', 'w', '2', 'L', 'o', 'a', 'd', 'e', 'r', '.', 'd', 'l', 'l' };
    const dll = LoadLibraryW(dll_name.ptr) orelse return null;
    const proc = GetProcAddress(dll, "CreateCoreWebView2EnvironmentWithOptions") orelse return null;
    webview2_create_fn = @ptrCast(proc);
    return webview2_create_fn;
}

// ============================================================================
// Helpers
// ============================================================================

/// Convert a UTF-8 slice to a stack-allocated null-terminated UTF-16 buffer.
fn utf8ToUtf16Z(comptime max_len: usize, input: []const u8) ![max_len]u16 {
    var buf: [max_len]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&buf, input);
    if (len >= max_len) return error.StringTooLong;
    buf[len] = 0;
    return buf;
}

fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

// ============================================================================
// Application state
// ============================================================================

var app_running = false;
var window_class_registered = false;
const CLASS_NAME: [:0]const u16 = &[_:0]u16{ 'Z', 'y', 't', 'e', 'W', 'i', 'n', 'd', 'o', 'w' };

// Native callbacks arrive with an HWND, not the stack value returned by
// Window.create. Keep stable handles for every live window here.
var desktop_windows: desktop_window_registry.Registry = .{};

const PendingWindowOpen = struct {
    next: ?*PendingWindowOpen = null,
    owner_id: u32,
    request_id: ?u64,
    action: []const u8,
    data: ?[]u8,
};

var pending_open_head: ?*PendingWindowOpen = null;
var pending_open_tail: ?*PendingWindowOpen = null;
var pending_open_count: usize = 0;
var processing_open = false;

fn freePendingOpen(task: *PendingWindowOpen) void {
    if (task.data) |data| std.heap.c_allocator.free(data);
    std.heap.c_allocator.destroy(task);
}

fn queueWindowOpen(owner: desktop_window_registry.Entry, action: []const u8, data: ?[]const u8, request_id: ?u64) !void {
    if (pending_open_count >= desktop_window_registry.capacity) return error.TooManyWindows;
    const copied_data: ?[]u8 = if (data) |value| try std.heap.c_allocator.dupe(u8, value) else null;
    errdefer if (copied_data) |value| std.heap.c_allocator.free(value);
    const task = try std.heap.c_allocator.create(PendingWindowOpen);
    errdefer std.heap.c_allocator.destroy(task);
    task.* = .{
        .owner_id = owner.id,
        .request_id = request_id,
        .action = if (std.mem.eql(u8, action, "open")) "open" else "create",
        .data = copied_data,
    };
    const owner_hwnd: HWND = @ptrFromInt(owner.window);
    if (PostMessageW(owner_hwnd, WM_CRAFT_OPEN_WINDOW, 0, 0) == 0)
        return error.NativeCallFailed;
    if (pending_open_tail) |tail| tail.next = task else pending_open_head = task;
    pending_open_tail = task;
    pending_open_count += 1;
}

fn discardPendingOpens(owner_id: u32) void {
    var previous: ?*PendingWindowOpen = null;
    var current = pending_open_head;
    while (current) |task| {
        const next = task.next;
        if (task.owner_id == owner_id) {
            if (previous) |prior| prior.next = next else pending_open_head = next;
            if (pending_open_tail != null and pending_open_tail.? == task) pending_open_tail = previous;
            pending_open_count -= 1;
            freePendingOpen(task);
        } else {
            previous = task;
        }
        current = next;
    }
}

fn processPendingOpens() void {
    if (processing_open) return;
    processing_open = true;
    defer processing_open = false;

    while (pending_open_head) |task| {
        pending_open_head = task.next;
        if (pending_open_head == null) pending_open_tail = null;
        pending_open_count -= 1;
        if (desktop_windows.byId(task.owner_id)) |owner| {
            window_context.push(owner.window, owner.webview);
            request_context.push(task.request_id);
            const data: ?[]const u8 = if (task.data) |value| value else null;
            openNamedWindow(task.action, data) catch |err| {
                if (desktop_windows.byId(task.owner_id) != null)
                    bridge_error.sendErrorToJS(std.heap.c_allocator, task.action, bridge_error.fromHandlerError(err));
            };
            request_context.pop();
            window_context.pop();
        }
        freePendingOpen(task);
    }
}

fn deliverToWebview(webview_handle: usize, name: []const u8, detail_json: []const u8, window_name: ?[]const u8) void {
    const script = desktop_window_events.format(std.heap.c_allocator, name, detail_json, window_name) catch return;
    defer std.heap.c_allocator.free(script);
    var wide = desktop_script_encoding.encode(std.heap.c_allocator, script) catch return;
    defer wide.deinit(std.heap.c_allocator);
    const webview: *ICoreWebView2 = @ptrFromInt(webview_handle);
    const handler = std.heap.c_allocator.create(ExecuteScriptCompletedHandler) catch return;
    handler.* = .{ .lpVtbl = &ExecuteScriptCompletedHandler.vtbl_instance, .ref_count = 1 };
    _ = webview.lpVtbl.ExecuteScript(webview, wide.ptr(), handler);
    _ = ExecuteScriptCompletedHandler.esRelease(handler);
}

fn deliverWindowEvent(entry: desktop_window_registry.Entry, name: []const u8, detail_json: []const u8) void {
    deliverToWebview(entry.webview, name, detail_json, null);
    const owner = window_registry.ownerWebViewOf(entry.window) orelse return;
    if (owner == entry.webview or desktop_windows.byWebview(owner) == null) return;
    const window_name = window_registry.nameOf(entry.window) orelse return;
    deliverToWebview(owner, name, detail_json, window_name);
}

fn observeWindowGeometry(entry: desktop_window_registry.Entry) void {
    var rect: RECT = undefined;
    if (GetWindowRect(@ptrFromInt(entry.window), &rect) == 0) return;
    const width = @as(i64, rect.right) - @as(i64, rect.left);
    const height = @as(i64, rect.bottom) - @as(i64, rect.top);
    if (width < 0 or height < 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return;
    const change = desktop_windows.observeGeometry(entry.window, .{
        .x = @intCast(rect.left),
        .y = @intCast(rect.top),
        .width = @intCast(width),
        .height = @intCast(height),
    }) orelse return;
    var detail_buf: [96]u8 = undefined;
    if (change.moved) {
        const detail = std.fmt.bufPrint(&detail_buf, "{{\"x\":{d},\"y\":{d}}}", .{ rect.left, rect.top }) catch return;
        deliverWindowEvent(entry, "move", detail);
    }
    if (change.resized) {
        const detail = std.fmt.bufPrint(&detail_buf, "{{\"width\":{d},\"height\":{d}}}", .{ width, height }) catch return;
        deliverWindowEvent(entry, "resize", detail);
    }
}

fn namedWindowResult(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"name\":\"");
    try bridge_error.appendJsonEscaped(allocator, &json, name);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn openNamedWindow(action: []const u8, data: ?[]const u8) !void {
    const allocator = std.heap.c_allocator;
    const json = data orelse return error.MissingData;
    const explicit_name = try json_utils.getStringDecoded(allocator, json, "name");
    defer if (explicit_name) |name| allocator.free(name);
    const fallback_id = if (explicit_name == null)
        try json_utils.getStringDecoded(allocator, json, "id")
    else
        null;
    defer if (fallback_id) |name| allocator.free(name);
    const name = explicit_name orelse fallback_id orelse return error.InvalidParameter;
    if (name.len == 0 or name.len > window_registry.max_name or
        std.mem.eql(u8, name, "main") or std.mem.indexOfScalar(u8, name, 0) != null)
        return error.InvalidParameter;

    const url = try json_utils.getStringDecoded(allocator, json, "url");
    defer if (url) |text| allocator.free(text);
    const html = try json_utils.getStringDecoded(allocator, json, "html");
    defer if (html) |text| allocator.free(text);
    if (url == null and html == null) return error.InvalidParameter;
    const title = try json_utils.getStringDecoded(allocator, json, "title");
    defer if (title) |text| allocator.free(text);
    for ([_]?[]const u8{ url, html, title }) |value| {
        if (value) |text| if (std.mem.indexOfScalar(u8, text, 0) != null)
            return error.InvalidParameter;
    }

    const result = try namedWindowResult(allocator, name);
    defer allocator.free(result);
    const owner = window_context.currentWebView() orelse return error.WebViewHandleNotSet;
    if (window_registry.byName(name)) |existing| {
        if (desktop_windows.byWindow(existing) == null) return error.WindowHandleNotSet;
        if (!window_registry.rememberNamedOwned(existing, name, owner)) return error.InvalidParameter;
        _ = ShowWindow(@ptrFromInt(existing), SW_SHOW);
        _ = UpdateWindow(@ptrFromInt(existing));
        bridge_error.sendResultToJS(allocator, action, result);
        return;
    }

    const width = json_utils.getInt(u32, json, "width") orelse 800;
    const height = json_utils.getInt(u32, json, "height") orelse 600;
    const limits = try desktop_window_controls.parseCreateLimits(json);
    if (width == 0 or height == 0 or width > @as(u32, std.math.maxInt(c_int)) or height > @as(u32, std.math.maxInt(c_int)))
        return error.InvalidParameter;
    var created = try Window.create(.{
        .title = title orelse name,
        .width = width,
        .height = height,
        .x = json_utils.getInt(i32, json, "x"),
        .y = json_utils.getInt(i32, json, "y"),
        .resizable = json_utils.getBool(json, "resizable") orelse true,
        .frameless = json_utils.getBool(json, "frameless") orelse false,
        .always_on_top = json_utils.getBool(json, "alwaysOnTop") orelse false,
        .fullscreen = json_utils.getBool(json, "fullscreen") orelse false,
        .dev_tools = json_utils.getBool(json, "devTools") orelse false,
    });
    errdefer created.close();
    if (limits.minimum != null or limits.maximum != null)
        try setWindowLimits(desktop_windows.byWindow(@intFromPtr(created.hwnd)) orelse return error.WindowHandleNotSet, limits);
    if (url) |text| try created.loadURL(text) else if (html) |text| try created.loadHTML(text);
    if (desktop_windows.byWebview(owner) == null) return error.WindowHandleNotSet;
    if (!window_registry.rememberNamedOwned(@intFromPtr(created.hwnd), name, owner))
        return error.TooManyWindows;
    created.show();
    bridge_error.sendResultToJS(allocator, action, result);
}

fn targetWindow(data: ?[]const u8) !desktop_window_registry.Entry {
    if (data) |json| {
        const name = try json_utils.getStringDecoded(std.heap.c_allocator, json, "windowId");
        defer if (name) |text| std.heap.c_allocator.free(text);
        if (name) |text| {
            if (!std.mem.eql(u8, text, "main")) {
                const handle = window_registry.byName(text) orelse return error.NotFound;
                return desktop_windows.byWindow(handle) orelse error.NotFound;
            }
        }
    }
    return desktop_windows.byWindow(window_context.current() orelse return error.WindowHandleNotSet) orelse error.WindowHandleNotSet;
}

fn windowGeometry(hwnd: HWND) !desktop_window_registry.Geometry {
    var rect: RECT = undefined;
    if (GetWindowRect(hwnd, &rect) == 0) return error.NativeCallFailed;
    const width = @as(i64, rect.right) - @as(i64, rect.left);
    const height = @as(i64, rect.bottom) - @as(i64, rect.top);
    if (width < 0 or height < 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32))
        return error.NativeCallFailed;
    return .{ .x = @intCast(rect.left), .y = @intCast(rect.top), .width = @intCast(width), .height = @intCast(height) };
}

fn windowStyle(hwnd: HWND) DWORD {
    return @truncate(@as(usize, @bitCast(GetWindowLongPtrW(hwnd, GWL_STYLE))));
}

fn setWindowStyle(hwnd: HWND, style: DWORD) void {
    _ = SetWindowLongPtrW(hwnd, GWL_STYLE, @bitCast(@as(usize, style)));
}

fn monitorInfo(hwnd: HWND) !MONITORINFO {
    const monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) orelse return error.NativeCallFailed;
    var info: MONITORINFO = .{ .cbSize = @sizeOf(MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
    if (GetMonitorInfoW(monitor, &info) == 0) return error.NativeCallFailed;
    return info;
}

fn centerWindow(hwnd: HWND) !void {
    const info = try monitorInfo(hwnd);
    const bounds = try windowGeometry(hwnd);
    const work_width = @as(i64, info.rcWork.right) - @as(i64, info.rcWork.left);
    const work_height = @as(i64, info.rcWork.bottom) - @as(i64, info.rcWork.top);
    if (work_width <= 0 or work_height <= 0) return error.NativeCallFailed;
    const position = try desktop_window_controls.centerIn(
        .{ .x = @intCast(info.rcWork.left), .y = @intCast(info.rcWork.top), .width = @intCast(work_width), .height = @intCast(work_height) },
        .{ .width = bounds.width, .height = bounds.height },
    );
    if (SetWindowPos(hwnd, null, position.x, position.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) == 0)
        return error.NativeCallFailed;
}

fn setWindowLimits(entry: desktop_window_registry.Entry, limits: desktop_window_controls.Limits) !void {
    if (!desktop_windows.setLimits(entry.window, limits)) return error.WindowHandleNotSet;
    const hwnd: HWND = @ptrFromInt(entry.window);
    const current = try windowGeometry(hwnd);
    const clamped = limits.clamp(.{ .width = current.width, .height = current.height });
    if (clamped.width != current.width or clamped.height != current.height) {
        if (SetWindowPos(hwnd, null, 0, 0, @intCast(clamped.width), @intCast(clamped.height), SWP_NOMOVE | SWP_NOZORDER) == 0)
            return error.NativeCallFailed;
    }
}

fn setWindowResizable(entry: desktop_window_registry.Entry, resizable: bool) !void {
    const hwnd: HWND = @ptrFromInt(entry.window);
    const current = entry.windowed_style orelse @as(isize, @bitCast(@as(usize, windowStyle(hwnd))));
    const previous: DWORD = @truncate(@as(usize, @bitCast(current)));
    var style: DWORD = @truncate(@as(usize, @bitCast(current)));
    if (resizable) style |= WS_THICKFRAME | WS_MAXIMIZEBOX else style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    if (entry.fullscreen) {
        if (!desktop_windows.setWindowedState(entry.window, entry.windowed_geometry, @bitCast(@as(usize, style)))) return error.WindowHandleNotSet;
        return;
    }
    setWindowStyle(hwnd, style);
    if (SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE) == 0) {
        setWindowStyle(hwnd, previous);
        _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
        return error.NativeCallFailed;
    }
}

fn setWindowFullscreen(entry: desktop_window_registry.Entry, fullscreen: bool) !void {
    if (entry.fullscreen == fullscreen) return;
    const hwnd: HWND = @ptrFromInt(entry.window);
    if (fullscreen) {
        const bounds = try windowGeometry(hwnd);
        const info = try monitorInfo(hwnd);
        const style = windowStyle(hwnd);
        if (!desktop_windows.setWindowedState(entry.window, bounds, @bitCast(@as(usize, style)))) return error.WindowHandleNotSet;
        setWindowStyle(hwnd, (style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
        const width = @as(i64, info.rcMonitor.right) - @as(i64, info.rcMonitor.left);
        const height = @as(i64, info.rcMonitor.bottom) - @as(i64, info.rcMonitor.top);
        if (width <= 0 or height <= 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int) or
            SetWindowPos(hwnd, null, @intCast(info.rcMonitor.left), @intCast(info.rcMonitor.top), @intCast(width), @intCast(height), SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE) == 0)
        {
            setWindowStyle(hwnd, style);
            _ = SetWindowPos(hwnd, null, bounds.x, bounds.y, @intCast(bounds.width), @intCast(bounds.height), SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
            _ = desktop_windows.setWindowedState(entry.window, null, null);
            return error.NativeCallFailed;
        }
    } else {
        const style = entry.windowed_style orelse return error.NativeCallFailed;
        const bounds = entry.windowed_geometry orelse return error.NativeCallFailed;
        const fullscreen_style = windowStyle(hwnd);
        setWindowStyle(hwnd, @truncate(@as(usize, @bitCast(style))));
        const size = entry.limits.clamp(.{ .width = bounds.width, .height = bounds.height });
        if (SetWindowPos(hwnd, null, bounds.x, bounds.y, @intCast(size.width), @intCast(size.height), SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE) == 0) {
            setWindowStyle(hwnd, fullscreen_style);
            _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
            return error.NativeCallFailed;
        }
        _ = desktop_windows.setWindowedState(entry.window, null, null);
    }
    if (desktop_windows.observeState(entry.window, entry.minimized, fullscreen)) |change| {
        if (change.fullscreen) |now_fullscreen|
            deliverWindowEvent(entry, if (now_fullscreen) "enter-fullscreen" else "leave-fullscreen", "");
    }
}

fn windowTitle(allocator: std.mem.Allocator, hwnd: HWND) ![:0]u8 {
    const length = GetWindowTextLengthW(hwnd);
    if (length < 0) return error.NativeCallFailed;
    if (@as(usize, @intCast(length)) >= desktop_bridge_envelope.max_message_bytes)
        return error.MessageTooLarge;
    const wide = try allocator.alloc(u16, @as(usize, @intCast(length)) + 1);
    defer allocator.free(wide);
    const copied = GetWindowTextW(hwnd, @ptrCast(wide.ptr), @intCast(wide.len));
    if (copied < 0) return error.NativeCallFailed;
    const utf8 = try desktop_bridge_text.fromUtf16(allocator, wide[0..@intCast(copied)]);
    return utf8;
}

fn sendWindowRead(action: []const u8, data: ?[]const u8) !void {
    const allocator = std.heap.c_allocator;
    const entry = try targetWindow(data);
    const hwnd: HWND = @ptrFromInt(entry.window);
    const json = if (std.mem.eql(u8, action, "getTitle")) blk: {
        const title = try windowTitle(allocator, hwnd);
        defer allocator.free(title);
        break :blk try desktop_window_reads.string(allocator, title);
    } else if (std.mem.eql(u8, action, "getFocused")) blk: {
        const focused = if (GetForegroundWindow()) |window| @intFromPtr(window) else 0;
        const name = desktop_window_reads.focusedName(&desktop_windows, entry.window, focused, window_registry.nameOf(focused));
        break :blk try desktop_window_reads.string(allocator, name);
    } else try desktop_window_reads.geometry(allocator, action, try windowGeometry(hwnd));
    defer allocator.free(json);
    bridge_error.sendResultToJS(allocator, action, json);
}

fn handleWindowAction(action: []const u8, data: ?[]const u8) !void {
    if (std.mem.eql(u8, action, "open") or std.mem.eql(u8, action, "create"))
        return openNamedWindow(action, data);
    if (std.mem.eql(u8, action, "getTitle") or std.mem.eql(u8, action, "getSize") or
        std.mem.eql(u8, action, "getPosition") or std.mem.eql(u8, action, "getBounds") or
        std.mem.eql(u8, action, "getFocused"))
        return sendWindowRead(action, data);

    const entry = try targetWindow(data);
    const hwnd: HWND = @ptrFromInt(entry.window);
    const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
    if (std.mem.eql(u8, action, "show") or std.mem.eql(u8, action, "focus")) {
        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);
    } else if (std.mem.eql(u8, action, "hide")) {
        _ = ShowWindow(hwnd, SW_HIDE);
    } else if (std.mem.eql(u8, action, "close") or std.mem.eql(u8, action, "destroy")) {
        if (DestroyWindow(hwnd) == 0) return error.NativeCallFailed;
    } else if (std.mem.eql(u8, action, "minimize")) {
        _ = ShowWindow(hwnd, SW_MINIMIZE);
    } else if (std.mem.eql(u8, action, "maximize")) {
        _ = ShowWindow(hwnd, SW_MAXIMIZE);
    } else if (std.mem.eql(u8, action, "restore") or std.mem.eql(u8, action, "unmaximize")) {
        _ = ShowWindow(hwnd, 9); // SW_RESTORE
    } else if (std.mem.eql(u8, action, "reload")) {
        if (!succeeded(webview.lpVtbl.Reload(webview))) return error.NativeCallFailed;
    } else if (std.mem.eql(u8, action, "setTitle")) {
        const json = data orelse return error.MissingData;
        const title = (try json_utils.getStringDecoded(std.heap.c_allocator, json, "title")) orelse return error.InvalidParameter;
        defer std.heap.c_allocator.free(title);
        if (std.mem.indexOfScalar(u8, title, 0) != null) return error.InvalidParameter;
        const title_wide = utf8ToUtf16Z(256, title) catch return error.InvalidParameter;
        if (SetWindowTextW(hwnd, @ptrCast(&title_wide)) == 0) return error.NativeCallFailed;
    } else if (std.mem.eql(u8, action, "setSize")) {
        const size = entry.limits.clamp(try desktop_window_controls.parseSize(data));
        if (SetWindowPos(hwnd, null, 0, 0, @intCast(size.width), @intCast(size.height), SWP_NOMOVE | SWP_NOZORDER) == 0) return error.NativeCallFailed;
    } else if (std.mem.eql(u8, action, "setPosition")) {
        const json = data orelse return error.MissingData;
        const x = json_utils.getInt(i32, json, "x") orelse return error.InvalidParameter;
        const y = json_utils.getInt(i32, json, "y") orelse return error.InvalidParameter;
        if (SetWindowPos(hwnd, null, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER) == 0) return error.NativeCallFailed;
    } else if (std.mem.eql(u8, action, "setBounds")) {
        const update = try desktop_window_controls.parseBounds(data);
        const current = try windowGeometry(hwnd);
        const size = entry.limits.clamp(.{ .width = update.width orelse current.width, .height = update.height orelse current.height });
        const flags: UINT = SWP_NOZORDER | SWP_NOACTIVATE |
            (if (update.x == null and update.y == null) SWP_NOMOVE else @as(UINT, 0)) |
            (if (update.width == null and update.height == null) SWP_NOSIZE else @as(UINT, 0));
        if (SetWindowPos(hwnd, null, update.x orelse current.x, update.y orelse current.y, @intCast(size.width), @intCast(size.height), flags) == 0)
            return error.NativeCallFailed;
    } else if (std.mem.eql(u8, action, "center")) {
        try centerWindow(hwnd);
    } else if (std.mem.eql(u8, action, "setResizable")) {
        try setWindowResizable(entry, try desktop_window_controls.parseBool(data, "resizable"));
    } else if (std.mem.eql(u8, action, "isResizable")) {
        const style: DWORD = if (entry.windowed_style) |saved| @truncate(@as(usize, @bitCast(saved))) else windowStyle(hwnd);
        bridge_error.sendResultToJS(std.heap.c_allocator, action, if ((style & WS_THICKFRAME) != 0) "true" else "false");
    } else if (std.mem.eql(u8, action, "setFullscreen") or std.mem.eql(u8, action, "toggleFullscreen")) {
        const fullscreen = if (std.mem.eql(u8, action, "toggleFullscreen")) !entry.fullscreen else try desktop_window_controls.parseBool(data, "fullscreen");
        try setWindowFullscreen(entry, fullscreen);
    } else if (std.mem.eql(u8, action, "setMinimumSize") or std.mem.eql(u8, action, "setMaximumSize")) {
        const size = try desktop_window_controls.parseSize(data);
        const limits = if (std.mem.eql(u8, action, "setMinimumSize")) try entry.limits.withMinimum(size) else try entry.limits.withMaximum(size);
        try setWindowLimits(entry, limits);
    } else if (std.mem.eql(u8, action, "loadURL") or std.mem.eql(u8, action, "loadHTML")) {
        const json = data orelse return error.MissingData;
        const key: []const u8 = if (std.mem.eql(u8, action, "loadURL")) "url" else "html";
        const value = (try json_utils.getStringDecoded(std.heap.c_allocator, json, key)) orelse return error.InvalidParameter;
        defer std.heap.c_allocator.free(value);
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidParameter;
        var native = Window{ .id = entry.id, .hwnd = hwnd, .controller = @ptrFromInt(entry.context), .webview = webview, .title = "", .width = 0, .height = 0, .x = 0, .y = 0 };
        if (std.mem.eql(u8, action, "loadURL")) try native.loadURL(value) else try native.loadHTML(value);
    } else {
        return error.PlatformNotSupported;
    }
}

test "Windows portable controls require an authenticated live sender" {
    try std.testing.expectError(error.WindowHandleNotSet, handleWindowAction("setBounds", "{}"));
}

pub const WindowStyle = struct {
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
    resizable: bool = true,
    closable: bool = true,
    miniaturizable: bool = true,
    fullscreen: bool = false,
    x: ?i32 = null,
    y: ?i32 = null,
    dark_mode: ?bool = null,
    enable_hot_reload: bool = false,
    dev_tools: bool = true,
};

pub const Window = struct {
    id: u32,
    hwnd: HWND,
    controller: ?*ICoreWebView2Controller,
    webview: ?*ICoreWebView2,
    title: []const u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,

    pub fn create(options: @import("api.zig").WindowOptions) !Window {
        const hInstance = GetModuleHandleW(null) orelse return error.WindowCreationFailed;

        // Register window class if not already done
        if (!window_class_registered) {
            const wc = WNDCLASSEXW{
                .cbSize = @sizeOf(WNDCLASSEXW),
                .style = 0,
                .lpfnWndProc = WindowProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = hInstance,
                .hIcon = null,
                .hCursor = LoadCursorW(null, @ptrFromInt(32512)), // IDC_ARROW
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = CLASS_NAME.ptr,
                .hIconSm = null,
            };

            if (RegisterClassExW(&wc) == 0) {
                return error.WindowCreationFailed;
            }
            window_class_registered = true;
        }

        // Determine window style
        var style: DWORD = if (options.frameless) WS_POPUP | WS_THICKFRAME else WS_OVERLAPPEDWINDOW;
        if (!options.resizable) {
            style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
        }
        style |= WS_VISIBLE;

        const ex_style: DWORD = if (options.always_on_top) WS_EX_TOPMOST else 0;

        // Convert title to wide string
        const title_wide = utf8ToUtf16Z(256, options.title) catch return error.WindowCreationFailed;
        const title_ptr: LPCWSTR = @ptrCast(&title_wide);

        // Calculate window position
        const x = options.x orelse CW_USEDEFAULT;
        const y = options.y orelse CW_USEDEFAULT;

        // Create window
        const hwnd = CreateWindowExW(
            ex_style,
            CLASS_NAME.ptr,
            title_ptr,
            style,
            x,
            y,
            @intCast(options.width),
            @intCast(options.height),
            null,
            null,
            hInstance,
            null,
        ) orelse return error.WindowCreationFailed;
        errdefer _ = DestroyWindow(hwnd);

        // ----------------------------------------------------------------
        // Async WebView2 initialization
        // ----------------------------------------------------------------
        //
        // CreateCoreWebView2EnvironmentWithOptions is asynchronous: it
        // returns immediately and delivers the result via a COM callback
        // handler. The callback is dispatched through the Win32 message
        // pump, so we spin a local message loop until init_done or
        // init_failed is set by our handler chain.
        // ----------------------------------------------------------------

        var init_ctx = WebView2InitContext{
            .hwnd = hwnd,
            .dev_tools = options.dev_tools,
        };

        const env_handler = try std.heap.c_allocator.create(EnvironmentCompletedHandler);
        env_handler.* = .{
            .lpVtbl = &EnvironmentCompletedHandler.vtbl_instance,
            .ref_count = 1,
            .ctx = &init_ctx,
        };

        const createEnv = loadWebView2() orelse {
            std.debug.print("[WebView2] WebView2Loader.dll not found — WebView2 runtime not installed\n", .{});
            return error.WebView2InitFailed;
        };

        const create_hr = createEnv(
            null, // default browser executable
            null, // default user data folder
            null, // no special options
            env_handler,
        );
        _ = EnvironmentCompletedHandler.envRelease(env_handler);

        if (!succeeded(create_hr)) {
            std.debug.print("[WebView2] CreateCoreWebView2EnvironmentWithOptions failed: 0x{x}\n", .{@as(u32, @bitCast(create_hr))});
            return error.WebView2InitFailed;
        }

        // Pump messages until the async chain finishes
        var msg: MSG = undefined;
        while (!init_ctx.init_done and !init_ctx.init_failed) {
            if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
                _ = TranslateMessage(&msg);
                _ = DispatchMessageW(&msg);
            } else {
                // Yield CPU while waiting for the async callback
                Sleep(1);
            }
        }

        if (init_ctx.init_failed) {
            std.debug.print("[WebView2] Initialization failed\n", .{});
            return error.WebView2InitFailed;
        }

        std.debug.print("[Media] Windows WebView2 configured for camera/microphone access\n", .{});

        const controller = init_ctx.controller orelse return error.WebView2InitFailed;
        const webview = init_ctx.webview orelse return error.WebView2InitFailed;
        const window_id = desktop_windows.rememberWithContext(@intFromPtr(hwnd), @intFromPtr(webview), @intFromPtr(controller)) orelse {
            _ = controller.lpVtbl.Close(controller);
            _ = webview.lpVtbl.Release(webview);
            _ = controller.lpVtbl.Release(controller);
            return error.TooManyWindows;
        };

        const message_handler = try std.heap.c_allocator.create(WebMessageReceivedHandler);
        message_handler.* = .{ .lpVtbl = &WebMessageReceivedHandler.vtbl_instance, .ref_count = 1, .window_id = window_id };
        var message_token: EventRegistrationToken = .{ .value = 0 };
        const message_hr = webview.lpVtbl.add_WebMessageReceived(webview, @ptrCast(message_handler), &message_token);
        _ = WebMessageReceivedHandler.release(message_handler);
        if (!succeeded(message_hr)) {
            std.debug.print("[WebView2] Page message registration failed: 0x{x}\n", .{@as(u32, @bitCast(message_hr))});
            return error.WebMessageRegistrationFailed;
        }
        if (!desktop_windows.setMessageToken(@intFromPtr(hwnd), message_token.value)) {
            _ = webview.lpVtbl.remove_WebMessageReceived(webview, message_token);
            return error.WebMessageRegistrationFailed;
        }
        observeWindowGeometry(desktop_windows.byId(window_id).?);
        if (options.fullscreen) try setWindowFullscreen(desktop_windows.byId(window_id).?, true);

        var window = Window{
            .id = window_id,
            .hwnd = hwnd,
            .controller = controller,
            .webview = webview,
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .x = x,
            .y = y,
        };

        // Install before the first Navigate/NavigateToString so every page
        // starts with the same bridge surface as a macOS Craft window.
        try window.injectScript(@embedFile("js/craft-bridge.js"));
        return window;
    }

    fn liveEntry(self: *const Window) ?desktop_window_registry.Entry {
        const entry = desktop_windows.byId(self.id) orelse return null;
        return if (entry.window == @intFromPtr(self.hwnd)) entry else null;
    }

    pub fn show(self: *Window) void {
        if (self.liveEntry() == null) return;
        _ = ShowWindow(self.hwnd, SW_SHOW);
        _ = UpdateWindow(self.hwnd);
    }

    pub fn hide(self: *Window) void {
        if (self.liveEntry() == null) return;
        _ = ShowWindow(self.hwnd, SW_HIDE);
    }

    pub fn close(self: *Window) void {
        if (self.liveEntry() == null) {
            self.controller = null;
            self.webview = null;
            return;
        }
        if (DestroyWindow(self.hwnd) != 0) {
            self.controller = null;
            self.webview = null;
        }
    }

    pub fn setSize(self: *Window, width: u32, height: u32) void {
        if (self.liveEntry() == null) return;
        _ = SetWindowPos(self.hwnd, null, 0, 0, @intCast(width), @intCast(height), 0x0002); // SWP_NOMOVE
        self.width = width;
        self.height = height;
        self.resizeWebView();
    }

    pub fn setPosition(self: *Window, x_pos: i32, y_pos: i32) void {
        if (self.liveEntry() == null) return;
        _ = SetWindowPos(self.hwnd, null, @intCast(x_pos), @intCast(y_pos), 0, 0, 0x0001); // SWP_NOSIZE
        self.x = x_pos;
        self.y = y_pos;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        if (self.liveEntry() == null) return;
        const title_wide_buf = utf8ToUtf16Z(256, title) catch return;
        _ = SetWindowTextW(self.hwnd, @ptrCast(&title_wide_buf));
        self.title = title;
    }

    pub fn loadURL(self: *Window, url: []const u8) !void {
        const entry = self.liveEntry() orelse return error.NoWebView;
        const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
        var url_wide = try utf8ToUtf16Z(4096, url);
        const url_ptr: LPCWSTR = @ptrCast(&url_wide);
        const hr = webview.lpVtbl.Navigate(webview, url_ptr);
        if (!succeeded(hr)) {
            std.debug.print("[WebView2] Navigate failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.NavigationFailed;
        }
    }

    pub fn loadHTML(self: *Window, html: []const u8) !void {
        const entry = self.liveEntry() orelse return error.NoWebView;
        const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
        // NavigateToString needs null-terminated UTF-16.
        // For large HTML we allocate on the heap.
        const wide_len = html.len + 1; // rough upper bound for ASCII-heavy content
        const buf = try std.heap.page_allocator.alloc(u16, wide_len);
        defer std.heap.page_allocator.free(buf);

        const encoded = std.unicode.utf8ToUtf16Le(buf, html) catch return error.EncodingFailed;
        buf[encoded] = 0;
        const html_ptr: LPCWSTR = @ptrCast(buf.ptr);

        const hr = webview.lpVtbl.NavigateToString(webview, html_ptr);
        if (!succeeded(hr)) {
            std.debug.print("[WebView2] NavigateToString failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.NavigationFailed;
        }
    }

    pub fn maximize(self: *Window) void {
        if (self.liveEntry() == null) return;
        _ = ShowWindow(self.hwnd, SW_MAXIMIZE);
    }

    pub fn minimize(self: *Window) void {
        if (self.liveEntry() == null) return;
        _ = ShowWindow(self.hwnd, SW_MINIMIZE);
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        const entry = self.liveEntry() orelse return;
        setWindowFullscreen(entry, fullscreen) catch {};
    }

    pub fn executeJavaScript(self: *Window, script: []const u8) !void {
        const entry = self.liveEntry() orelse return error.NoWebView;
        const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
        var script_wide = try utf8ToUtf16Z(16384, script);
        const script_ptr: LPCWSTR = @ptrCast(&script_wide);

        // Use a fire-and-forget completed handler
        const handler = try std.heap.c_allocator.create(ExecuteScriptCompletedHandler);
        handler.* = .{
            .lpVtbl = &ExecuteScriptCompletedHandler.vtbl_instance,
            .ref_count = 1,
        };

        const hr = webview.lpVtbl.ExecuteScript(webview, script_ptr, handler);
        _ = ExecuteScriptCompletedHandler.esRelease(handler);
        if (!succeeded(hr)) {
            std.debug.print("[WebView2] ExecuteScript failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.ScriptExecutionFailed;
        }
    }

    pub fn injectScript(self: *Window, script: []const u8) !void {
        const entry = self.liveEntry() orelse return error.NoWebView;
        const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
        var script_wide = try desktop_script_encoding.encode(std.heap.c_allocator, script);
        defer script_wide.deinit(std.heap.c_allocator);

        var install: ScriptInstallContext = .{};
        const handler = try std.heap.c_allocator.create(ScriptInstallCompletedHandler);
        handler.* = .{ .lpVtbl = &ScriptInstallCompletedHandler.vtbl_instance, .ref_count = 1, .ctx = &install };
        const hr = webview.lpVtbl.AddScriptToExecuteOnDocumentCreated(webview, script_wide.ptr(), handler);
        _ = ScriptInstallCompletedHandler.release(handler);
        if (!succeeded(hr)) {
            std.debug.print("[WebView2] AddScriptToExecuteOnDocumentCreated failed: 0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.ScriptInjectionFailed;
        }

        // WebView2 installs this asynchronously. Navigate immediately after
        // the API call and the first page can miss the bridge entirely.
        var msg: MSG = undefined;
        var quit_requested = false;
        while (!install.done) {
            if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
                if (msg.message == WM_QUIT) {
                    quit_requested = true;
                } else {
                    _ = TranslateMessage(&msg);
                    _ = DispatchMessageW(&msg);
                }
            } else {
                Sleep(1);
            }
        }
        if (quit_requested) PostQuitMessage(0);
        if (!succeeded(install.result)) return error.ScriptInjectionFailed;
    }

    pub fn enableGPUAcceleration(self: *Window, enable: bool) !void {
        _ = self;
        _ = enable;
        // WebView2 has hardware acceleration enabled by default
        // Can be controlled through environment options
    }

    pub fn openDevTools(self: *Window) void {
        const entry = self.liveEntry() orelse return;
        const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
        _ = webview.lpVtbl.OpenDevToolsWindow(webview);
    }

    // Resize the WebView2 control to match the current client area
    fn resizeWebView(self: *Window) void {
        const entry = self.liveEntry() orelse return;
        const controller: *ICoreWebView2Controller = @ptrFromInt(entry.context);
        var bounds: RECT = undefined;
        _ = GetClientRect(self.hwnd, &bounds);
        _ = controller.lpVtbl.put_Bounds(controller, bounds);
    }
};

fn WindowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT {
    switch (msg) {
        WM_GETMINMAXINFO => {
            if (desktop_windows.byWindow(@intFromPtr(hwnd))) |entry| {
                const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
                if (entry.limits.minimum) |min| {
                    info.ptMinTrackSize = .{ .x = @intCast(min.width), .y = @intCast(min.height) };
                }
                if (entry.limits.maximum) |max| {
                    info.ptMaxTrackSize = .{ .x = @intCast(max.width), .y = @intCast(max.height) };
                }
                return 0;
            }
        },
        WM_CRAFT_OPEN_WINDOW => {
            processPendingOpens();
            return 0;
        },
        WM_SIZE => {
            // A resize belongs to this HWND, not whichever window was created last.
            if (desktop_windows.byWindow(@intFromPtr(hwnd))) |entry| {
                const controller: *ICoreWebView2Controller = @ptrFromInt(entry.context);
                var bounds: RECT = undefined;
                _ = GetClientRect(hwnd, &bounds);
                _ = controller.lpVtbl.put_Bounds(controller, bounds);
                const minimized = wParam == 1; // SIZE_MINIMIZED
                if (desktop_windows.observeState(entry.window, minimized, entry.fullscreen)) |change| {
                    if (change.minimized) |now_minimized|
                        deliverWindowEvent(entry, if (now_minimized) "minimize" else "restore", "");
                }
                if (!minimized) observeWindowGeometry(entry);
            }
            return 0;
        },
        WM_MOVE => {
            if (desktop_windows.byWindow(@intFromPtr(hwnd))) |entry| {
                if (!entry.minimized) observeWindowGeometry(entry);
            }
            return 0;
        },
        WM_ACTIVATE => {
            if (desktop_windows.byWindow(@intFromPtr(hwnd))) |entry|
                deliverWindowEvent(entry, if ((wParam & 0xffff) == 0) "blur" else "focus", "");
        },
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            if (desktop_windows.byWindow(@intFromPtr(hwnd))) |entry| deliverWindowEvent(entry, "close", "");
            if (desktop_windows.forgetWindow(@intFromPtr(hwnd))) |entry| {
                discardPendingOpens(entry.id);
                const controller: *ICoreWebView2Controller = @ptrFromInt(entry.context);
                const webview: *ICoreWebView2 = @ptrFromInt(entry.webview);
                window_registry.forgetOwner(entry.webview);
                window_registry.forget(entry.window);
                if (entry.message_token) |token| {
                    _ = webview.lpVtbl.remove_WebMessageReceived(webview, .{ .value = token });
                }
                _ = controller.lpVtbl.Close(controller);
                _ = webview.lpVtbl.Release(webview);
                _ = controller.lpVtbl.Release(controller);
                // Closing a child window must not end every window's event loop.
                if (app_running and desktop_windows.count() == 0) PostQuitMessage(0);
            }
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

pub const App = struct {
    pub fn run() !void {
        app_running = true;
        defer app_running = false;
        var msg: MSG = undefined;

        while (GetMessageW(&msg, null, 0, 0) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }

    pub fn quit() void {
        app_running = false;
        PostQuitMessage(0);
    }
};

/// Evaluate a reply in the authenticated sender, if that webview is still live.
/// Native callers without a sender use the most recently created live window.
pub fn evalJS(script: []const u8) !void {
    var handles: [desktop_window_registry.capacity]usize = undefined;
    const live = desktop_windows.liveWebviews(&handles);
    const latest = desktop_windows.latest();
    const target = window_reply_target.select(live, window_context.currentWebView(), if (latest) |entry| entry.webview else null) orelse
        return error.NoWebView;
    const webview: *ICoreWebView2 = @ptrFromInt(target);
    var script_wide = try utf8ToUtf16Z(16384, script);
    const handler = try std.heap.c_allocator.create(ExecuteScriptCompletedHandler);
    handler.* = .{ .lpVtbl = &ExecuteScriptCompletedHandler.vtbl_instance, .ref_count = 1 };
    const hr = webview.lpVtbl.ExecuteScript(webview, @ptrCast(&script_wide), handler);
    _ = ExecuteScriptCompletedHandler.esRelease(handler);
    if (!succeeded(hr)) return error.ScriptExecutionFailed;
}

// Legacy API compatibility
pub fn createWindow(title: []const u8, width: u32, height: u32, html: []const u8) !*anyopaque {
    var window = try Window.create(.{
        .title = title,
        .width = width,
        .height = height,
    });
    try window.loadHTML(html);
    window.show();
    return window.hwnd;
}

pub fn createWindowWithURL(title: []const u8, width: u32, height: u32, url: []const u8, style: WindowStyle) !*anyopaque {
    return createStyledWindow(title, width, height, url, style, true);
}

pub fn createWindowWithHTML(title: []const u8, width: u32, height: u32, html: []const u8, style: WindowStyle) !*anyopaque {
    return createStyledWindow(title, width, height, html, style, false);
}

fn createStyledWindow(title: []const u8, width: u32, height: u32, content: []const u8, style: WindowStyle, comptime is_url: bool) !*anyopaque {
    var window = try Window.create(.{
        .title = title,
        .width = width,
        .height = height,
        .x = style.x,
        .y = style.y,
        .resizable = style.resizable,
        .frameless = style.frameless,
        .transparent = style.transparent,
        .always_on_top = style.always_on_top,
        .fullscreen = style.fullscreen,
        .dark_mode = style.dark_mode,
        .dev_tools = style.dev_tools,
    });
    errdefer window.close();
    if (is_url) try window.loadURL(content) else try window.loadHTML(content);
    window.show();
    return window.hwnd;
}

pub fn runApp() void {
    App.run() catch |err| {
        std.debug.print("Error running Windows app: {}\n", .{err});
    };
}

// Notifications using Windows Toast
pub extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *anyopaque) callconv(.c) BOOL;

pub fn showNotification(title: []const u8, message: []const u8) !void {
    _ = title;
    _ = message;
    // Would use Windows Toast Notifications API
    // This requires COM initialization and WinRT APIs
}

// Clipboard using Windows API
pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.c) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.c) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.c) BOOL;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.c) LPVOID;
pub extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.c) BOOL;
pub extern "kernel32" fn GlobalSize(hMem: *anyopaque) callconv(.c) usize;

const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

pub fn setClipboard(text: []const u8) !void {
    // Convert UTF-8 to UTF-16
    var text_wide_buf: [4096]u16 = undefined;
    const text_len = try std.unicode.utf8ToUtf16Le(&text_wide_buf, text);

    const byte_size = (text_len + 1) * 2; // +1 for null terminator, *2 for u16

    const hMem = GlobalAlloc(GMEM_MOVEABLE, byte_size) orelse return error.ClipboardError;
    const pMem = GlobalLock(hMem) orelse return error.ClipboardError;

    // Copy text to global memory
    const dest: [*]u16 = @ptrCast(@alignCast(pMem));
    @memcpy(dest[0..text_len], text_wide_buf[0..text_len]);
    dest[text_len] = 0; // Null terminator

    _ = GlobalUnlock(hMem);

    if (OpenClipboard(null) == 0) return error.ClipboardError;
    defer _ = CloseClipboard();

    _ = EmptyClipboard();
    _ = SetClipboardData(CF_UNICODETEXT, hMem);
}

pub fn getClipboard(allocator: std.mem.Allocator) ![]u8 {
    if (OpenClipboard(null) == 0) return error.ClipboardError;
    defer _ = CloseClipboard();

    const hMem = GetClipboardData(CF_UNICODETEXT) orelse return "";
    const pMem = GlobalLock(hMem) orelse return "";
    defer _ = GlobalUnlock(hMem);

    const text_wide: [*:0]const u16 = @ptrCast(@alignCast(pMem));
    const text_len = std.mem.indexOfSentinel(u16, 0, text_wide);

    // Convert UTF-16 to UTF-8
    const utf8_len = std.unicode.utf16LeToUtf8AllocZ(allocator, text_wide[0..text_len]) catch return "";
    return utf8_len;
}
