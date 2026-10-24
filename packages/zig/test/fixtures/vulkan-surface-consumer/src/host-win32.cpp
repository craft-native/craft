// Actual Win32 window pixels and SendInput events. The host never paints a frame.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>

extern "C" {
void *craft_vulkan_create(void *, uintptr_t, uint32_t, uint32_t);
int craft_vulkan_resize(void *, uint32_t, uint32_t);
int craft_vulkan_draw(void *, uint32_t, int32_t, int32_t);
int craft_vulkan_suspend(void *, int);
const uint32_t *craft_vulkan_pixels(void *);
int craft_vulkan_dispose(void *);
const char *craft_vulkan_error();
}

static int input_x = -1, input_y = -1;
static unsigned input_events = 0;
static bool closed = false;
static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_LBUTTONDOWN) {
        input_x = int(short(LOWORD(lparam)));
        input_y = int(short(HIWORD(lparam)));
        ++input_events;
        return 0;
    }
    if (message == WM_CLOSE) { closed = true; return 0; }
    if (message == WM_ERASEBKGND) return 1;
    if (message == WM_PAINT) {
        PAINTSTRUCT paint{};
        BeginPaint(window, &paint);
        EndPaint(window, &paint);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
static void pump() {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}
static bool dimensions(HWND window, unsigned width, unsigned height) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    do {
        pump();
        RECT rect{};
        if (closed || !IsWindow(window)) return false;
        if (GetClientRect(window, &rect) && unsigned(rect.right) == width && unsigned(rect.bottom) == height &&
            IsWindowVisible(window) && !IsIconic(window)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}
static bool resize_client(HWND window, unsigned width, unsigned height) {
    RECT rect{0, 0, LONG(width), LONG(height)};
    const UINT dpi = GetDpiForWindow(window);
    if (!dpi || !AdjustWindowRectExForDpi(&rect, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_TOPMOST, dpi)) return false;
    return SetWindowPos(window, HWND_TOPMOST, 0, 0, rect.right - rect.left, rect.bottom - rect.top,
                        SWP_NOMOVE | SWP_SHOWWINDOW) && dimensions(window, width, height);
}
static bool capture_matches(HWND window, const uint32_t *expected, unsigned width, unsigned height, const char *file_name) {
    // Capture the desktop's actual displayed owned client rectangle. Reading
    // its window DC or asking WM_PRINT to repaint would not establish that a
    // compositor-backed hardware swapchain reached the screen.
    HDC screen = GetDC(nullptr);
    if (!screen) return false;
    HDC memory = CreateCompatibleDC(screen);
    if (!memory) { ReleaseDC(nullptr, screen); return false; }
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = LONG(width);
    info.bmiHeader.biHeight = -LONG(height);
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !pixels) {
        if (bitmap) DeleteObject(bitmap);
        DeleteDC(memory); ReleaseDC(nullptr, screen); return false;
    }
    HGDIOBJ previous = SelectObject(memory, bitmap);
    bool matched = false;
    if (previous && previous != HGDI_ERROR) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        do {
            pump();
            POINT origin{};
            if (closed || !ClientToScreen(window, &origin)) break;
            if (BitBlt(memory, 0, 0, int(width), int(height), screen, origin.x, origin.y, SRCCOPY | CAPTUREBLT) && GdiFlush()) {
                const uint32_t *captured = static_cast<const uint32_t *>(pixels);
                matched = true;
                for (size_t index = 0; index < size_t(width) * height; ++index) {
                    if ((captured[index] & 0x00ffffff) != (expected[index] & 0x00ffffff)) { matched = false; break; }
                }
                if (matched && file_name) {
                    FILE *file = std::fopen(file_name, "wb");
                    if (!file) { matched = false; break; }
                    matched = std::fprintf(file, "P6\n%u %u\n255\n", width, height) > 0;
                    for (size_t index = 0; index < size_t(width) * height && matched; ++index) {
                        const uint32_t value = captured[index];
                        const unsigned char rgb[]{static_cast<unsigned char>(value >> 16), static_cast<unsigned char>(value >> 8), static_cast<unsigned char>(value)};
                        matched = std::fwrite(rgb, 1, 3, file) == 3;
                    }
                    if (std::fclose(file)) matched = false;
                    break;
                }
                if (matched) break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        } while (std::chrono::steady_clock::now() < deadline);
        SelectObject(memory, previous);
    }
    DeleteObject(bitmap);
    DeleteDC(memory);
    ReleaseDC(nullptr, screen);
    return matched;
}
static bool click(HWND window, int x, int y) {
    POINT point{x, y};
    if (!ClientToScreen(window, &point)) return false;
    // Set the real cursor in physical screen coordinates rather than rounding
    // the 16-bit normalized SendInput motion range back onto a display pixel.
    if (!SetCursorPos(point.x, point.y)) return false;
    POINT actual{};
    if (!GetCursorPos(&actual) || actual.x != point.x || actual.y != point.y) return false;
    INPUT events[2]{};
    for (auto &event : events) event.type = INPUT_MOUSE;
    events[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    events[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    input_x = input_y = -1;
    if (SendInput(2, events, sizeof(INPUT)) != 2) return false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    do {
        pump();
        if (input_x >= 0) return input_x == x && input_y == y;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (!closed && std::chrono::steady_clock::now() < deadline);
    return false;
}

int main() {
    if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
        std::fprintf(stderr, "Cannot establish physical native window coordinates: %lu\n", GetLastError());
        return 1;
    }
    HINSTANCE instance = GetModuleHandleW(nullptr);
    const wchar_t *name = L"CraftNativeVulkanAcceptance";
    WNDCLASSW klass{};
    klass.hInstance = instance;
    klass.lpfnWndProc = window_proc;
    klass.lpszClassName = name;
    if (!RegisterClassW(&klass)) return 1;
    bool success = true;
    unsigned total_frames = 0, sessions = 0;
    for (unsigned repetition = 0; repetition < 2 && success; ++repetition) {
        unsigned width = 256, height = 192;
        closed = false;
        HWND window = CreateWindowExW(WS_EX_TOPMOST, name, L"Craft native Vulkan acceptance", WS_OVERLAPPEDWINDOW,
                                      40, 40, 300, 240, nullptr, nullptr, instance, nullptr);
        if (!window) { success = false; break; }
        ShowWindow(window, SW_SHOW);
        if (!resize_client(window, width, height)) { DestroyWindow(window); success = false; break; }
        void *context = craft_vulkan_create(instance, reinterpret_cast<uintptr_t>(window), width, height);
        if (!context) {
            std::fprintf(stderr, "Native Win32 Vulkan init: %s\n", craft_vulkan_error());
            DestroyWindow(window); success = false; break;
        }
        for (unsigned frame = 0; frame <= 60 && success; ++frame) {
            pump();
            if (closed || craft_vulkan_draw(context, frame, -1, -1)) { success = false; break; }
            ++total_frames;
        }
        if (success) success = capture_matches(window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "initial.ppm");
        if (success) {
            width = 160; height = 120;
            success = resize_client(window, width, height) && !craft_vulkan_resize(context, width, height) && !craft_vulkan_draw(context, 62, -1, -1);
            if (success) { ++total_frames; success = capture_matches(window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "resized.ppm"); }
        }
        if (success) {
            success = !craft_vulkan_suspend(context, 1);
            ShowWindow(window, SW_HIDE); pump();
            success = success && !IsWindowVisible(window);
            ShowWindow(window, SW_SHOW);
            success = success && dimensions(window, width, height) && !craft_vulkan_suspend(context, 0) &&
                !craft_vulkan_resize(context, width, height) && !craft_vulkan_draw(context, 64, -1, -1);
            if (success) { ++total_frames; success = capture_matches(window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "resumed.ppm"); }
        }
        if (success) {
            success = click(window, 40, 30) && !craft_vulkan_draw(context, 66, input_x, input_y);
            if (success) { ++total_frames; success = capture_matches(window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "input.ppm"); }
        }
        if (!success) std::fprintf(stderr, "Native Win32 frame/lifecycle check: %s, OS error %lu\n", craft_vulkan_error(), GetLastError());
        if (craft_vulkan_dispose(context)) {
            // Retain the view and context until process exit when presentation
            // still owns work. A failed disposal cannot become a success.
            std::fprintf(stderr, "Native Vulkan resources retained: %s\n", craft_vulkan_error());
            success = false;
            break;
        }
        DestroyWindow(window); pump();
        if (success) ++sessions;
    }
    if (success && sessions == 2 && input_events == 2 && total_frames == 128) {
        UnregisterClassW(name, instance);
        std::printf("{\"status\":\"passed\",\"nativeSessions\":2,\"actualGpuFrames\":128,\"nativeInputEvents\":2,\"nativeCaptures\":4,\"fullDisplayedPixelsMatched\":true,\"webViewUsed\":false,\"disposed\":true}\n");
        return 0;
    }
    return 1;
}
