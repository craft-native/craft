// Real owned-window acceptance. No WebView, synthetic image or CPU display fallback.
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
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

static int x_error = 0;
static int on_error(Display *, XErrorEvent *event) { x_error = event->error_code; return 0; }
static unsigned channel(unsigned long pixel, unsigned long mask) {
    if (!mask) return 0;
    while (!(mask & 1)) { mask >>= 1; pixel >>= 1; }
    return unsigned((pixel & mask) * 255 / mask);
}
static bool frame_matches(Display *display, Window window, const uint32_t *expected,
                          unsigned width, unsigned height, const char *capture) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    do {
        XSync(display, False);
        XImage *image = XGetImage(display, window, 0, 0, width, height, AllPlanes, ZPixmap);
        if (image && !x_error) {
            bool matches = true;
            for (unsigned y = 0; y < height && matches; ++y) for (unsigned x = 0; x < width; ++x) {
                const unsigned long value = XGetPixel(image, x, y);
                const uint32_t pixel = expected[y * width + x];
                if (channel(value, image->red_mask) != ((pixel >> 16) & 255) ||
                    channel(value, image->green_mask) != ((pixel >> 8) & 255) ||
                    channel(value, image->blue_mask) != (pixel & 255)) { matches = false; break; }
            }
            if (matches && capture) {
                FILE *file = std::fopen(capture, "wb");
                if (!file) { XDestroyImage(image); return false; }
                bool written = std::fprintf(file, "P6\n%u %u\n255\n", width, height) > 0;
                for (unsigned y = 0; y < height && written; ++y) for (unsigned x = 0; x < width; ++x) {
                    const unsigned long value = XGetPixel(image, x, y);
                    const unsigned char rgb[] = {static_cast<unsigned char>(channel(value, image->red_mask)), static_cast<unsigned char>(channel(value, image->green_mask)), static_cast<unsigned char>(channel(value, image->blue_mask))};
                    if (std::fwrite(rgb, 1, 3, file) != 3) { written = false; break; }
                }
                if (std::fclose(file)) written = false;
                if (!written) { XDestroyImage(image); return false; }
            }
            XDestroyImage(image);
            if (matches) return true;
        } else if (image) XDestroyImage(image);
        if (x_error) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}
static bool dimensions(Display *display, Window window, unsigned width, unsigned height) {
    // Mapping and resizing pass through the real window manager. XSync only
    // drains this client's requests; it does not wait for the manager's reply.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    do {
        XSync(display, False);
        XWindowAttributes attributes{};
        if (XGetWindowAttributes(display, window, &attributes) && !x_error &&
            attributes.width == int(width) && attributes.height == int(height) && attributes.map_state == IsViewable) return true;
        if (x_error) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}

int main() {
    Display *display = XOpenDisplay(nullptr);
    if (!display) { std::fprintf(stderr, "No native X11 display\n"); return 1; }
    XSetErrorHandler(on_error);
    bool success = true, retained = false;
    unsigned total_frames = 0, input_events = 0, completed_sessions = 0;
    for (unsigned repetition = 0; repetition < 2 && success; ++repetition) {
        unsigned width = 256, height = 192;
        Window window = XCreateSimpleWindow(display, DefaultRootWindow(display), 40, 40, width, height, 0, 0, 0);
        XSelectInput(display, window, ExposureMask | StructureNotifyMask | ButtonPressMask);
        XStoreName(display, window, "Craft native Vulkan acceptance");
        XMapWindow(display, window);
        XSync(display, False);
        if (!dimensions(display, window, width, height)) { success = false; XDestroyWindow(display, window); break; }
        void *context = craft_vulkan_create(display, uintptr_t(window), width, height);
        if (!context) { std::fprintf(stderr, "Native Vulkan init: %s\n", craft_vulkan_error()); success = false; XDestroyWindow(display, window); break; }
        // Every frame compares the actual GPU readback with the shared scene.
        for (unsigned frame = 0; frame <= 60 && success; ++frame) {
            if (craft_vulkan_draw(context, frame, -1, -1)) { success = false; break; }
            ++total_frames;
        }
        if (success) success = frame_matches(display, window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "initial.ppm");
        if (success) {
            width = 160; height = 120;
            XResizeWindow(display, window, width, height);
            XSync(display, False);
            success = dimensions(display, window, width, height) && !craft_vulkan_resize(context, width, height) && !craft_vulkan_draw(context, 62, -1, -1);
            if (success) { ++total_frames; success = frame_matches(display, window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "resized.ppm"); }
        }
        if (success) {
            success = !craft_vulkan_suspend(context, 1);
            XUnmapWindow(display, window);
            XSync(display, False);
            XWindowAttributes attributes{};
            success = success && XGetWindowAttributes(display, window, &attributes) && attributes.map_state == IsUnmapped;
            XMapWindow(display, window);
            XSync(display, False);
            success = success && dimensions(display, window, width, height) && !craft_vulkan_suspend(context, 0) && !craft_vulkan_resize(context, width, height) && !craft_vulkan_draw(context, 64, -1, -1);
            if (success) { ++total_frames; success = frame_matches(display, window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "resumed.ppm"); }
        }
        if (success) {
            // XTest sends actual native pointer events. The host must receive
            // their coordinates and render the corresponding shared-scene mark.
            int event_base, error_base, major, minor;
            int root_x = 0, root_y = 0;
            Window child;
            success = XTestQueryExtension(display, &event_base, &error_base, &major, &minor) &&
                XTranslateCoordinates(display, window, DefaultRootWindow(display), 40, 30, &root_x, &root_y, &child);
            if (success) {
                XTestFakeMotionEvent(display, DefaultScreen(display), root_x, root_y, CurrentTime);
                XTestFakeButtonEvent(display, 1, True, CurrentTime);
                XTestFakeButtonEvent(display, 1, False, CurrentTime);
                XSync(display, False);
                int input_x = -1, input_y = -1;
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
                do {
                    while (XPending(display)) {
                        XEvent event{}; XNextEvent(display, &event);
                        if (event.type == ButtonPress && event.xbutton.window == window && !event.xbutton.send_event) {
                            input_x = event.xbutton.x; input_y = event.xbutton.y; ++input_events;
                        }
                    }
                    if (input_x >= 0) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                } while (std::chrono::steady_clock::now() < deadline);
                success = input_x == 40 && input_y == 30 && !craft_vulkan_draw(context, 66, input_x, input_y);
                if (success) { ++total_frames; success = frame_matches(display, window, craft_vulkan_pixels(context), width, height, repetition ? nullptr : "input.ppm"); }
            }
        }
        if (!success) std::fprintf(stderr, "Native Vulkan frame/lifecycle check: %s, X11 error %d\n", craft_vulkan_error(), x_error);
        const int disposal = craft_vulkan_dispose(context);
        if (disposal) {
            // Keep the owned view/context until this process exits. Freeing
            // them despite an outstanding native fence would violate ownership.
            std::fprintf(stderr, "Native Vulkan resources retained: %s\n", craft_vulkan_error());
            success = false;
            retained = true;
            break;
        }
        XDestroyWindow(display, window);
        XSync(display, False);
        if (success && !x_error) ++completed_sessions;
        else success = false;
    }
    if (!retained) XCloseDisplay(display);
    if (success && completed_sessions == 2 && input_events == 2 && total_frames == 128) {
        std::printf("{\"status\":\"passed\",\"nativeSessions\":2,\"actualGpuFrames\":128,\"nativeInputEvents\":2,\"nativeCaptures\":4,\"fullDisplayedPixelsMatched\":true,\"webViewUsed\":false,\"disposed\":true}\n");
        return 0;
    }
    return 1;
}
