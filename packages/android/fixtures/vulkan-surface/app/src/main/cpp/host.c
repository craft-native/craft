// Test-only JNI transport. Drawing and presentation stay in Craft's public module.
#include <jni.h>
#include <android/native_window_jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <time.h>
#include <stdio.h>

extern void *craft_vulkan_create(void *, uintptr_t, uint32_t, uint32_t);
extern int craft_vulkan_resize(void *, uint32_t, uint32_t);
extern int craft_vulkan_draw(void *, uint32_t, int32_t, int32_t);
extern int craft_vulkan_suspend(void *, int);
extern const uint32_t *craft_vulkan_pixels(void *);
extern int craft_vulkan_dispose(void *);
extern const char *craft_vulkan_error(void);
extern uint32_t craft_vulkan_width(void *);
extern uint32_t craft_vulkan_height(void *);

typedef struct { void *scene; ANativeWindow *window; uint32_t width, height; uint64_t created_ns, cpu_ns, present_ns, readback_ns; uint32_t frames; } Owned;
static _Thread_local uint64_t marks[6];
void craft_vulkan_trace(int stage) {
    struct timespec now;
    if (stage >= 0 && stage < 6 && clock_gettime(CLOCK_MONOTONIC, &now) == 0)
        marks[stage] = (uint64_t)now.tv_sec * 1000000000 + (uint64_t)now.tv_nsec;
}
static _Atomic int live_contexts = 0;
static void fail(JNIEnv *env, const char *message) {
    jclass error = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (error) (*env)->ThrowNew(env, error, message);
}
JNIEXPORT jlong JNICALL Java_dev_craft_vulkantest_NativeSurface_create(JNIEnv *env, jobject self, jobject surface, jint width, jint height) {
    (void)self;
    Owned *owner = calloc(1, sizeof(*owner));
    if (!owner) { fail(env, "Native transport allocation failed"); return 0; }
    owner->window = ANativeWindow_fromSurface(env, surface);
    if (!owner->window) { free(owner); fail(env, "No acquired ANativeWindow"); return 0; }
    owner->scene = craft_vulkan_create(NULL, (uintptr_t)owner->window, width, height);
    if (!owner->scene) { ANativeWindow_release(owner->window); free(owner); fail(env, craft_vulkan_error()); return 0; }
    owner->width = width; owner->height = height;
    owner->created_ns = marks[1] - marks[0];
    atomic_fetch_add(&live_contexts, 1);
    return (jlong)(uintptr_t)owner;
}
JNIEXPORT void JNICALL Java_dev_craft_vulkantest_NativeSurface_resize(JNIEnv *env, jobject self, jlong handle, jobject surface, jint width, jint height) {
    (void)self; Owned *owner = (Owned *)(uintptr_t)handle;
    ANativeWindow *current = ANativeWindow_fromSurface(env, surface);
    int before_width = ANativeWindow_getWidth(owner->window), before_height = ANativeWindow_getHeight(owner->window);
    int current_width = current ? ANativeWindow_getWidth(current) : -1, current_height = current ? ANativeWindow_getHeight(current) : -1;
    int same_window = current == owner->window;
    if (current) ANativeWindow_release(current);
    if (craft_vulkan_resize(owner->scene, width, height)) {
        char message[512];
        snprintf(message, sizeof(message), "%s: requested=%dx%d, actual=%ux%u, nativeBefore=%dx%d, nativeAfter=%dx%d, currentSurface=%dx%d, sameWindow=%d", craft_vulkan_error(), width, height,
            craft_vulkan_width(owner->scene), craft_vulkan_height(owner->scene), before_width, before_height, ANativeWindow_getWidth(owner->window), ANativeWindow_getHeight(owner->window), current_width, current_height, same_window);
        fail(env, message); return;
    }
    owner->width = width; owner->height = height;
}
JNIEXPORT void JNICALL Java_dev_craft_vulkantest_NativeSurface_draw(JNIEnv *env, jobject self, jlong handle, jint frame, jint x, jint y) {
    (void)self; Owned *owner = (Owned *)(uintptr_t)handle;
    if (craft_vulkan_draw(owner->scene, frame, x, y)) { fail(env, craft_vulkan_error()); return; }
    owner->cpu_ns = marks[3] - marks[2]; owner->present_ns = marks[4] - marks[3]; owner->readback_ns = marks[5] - marks[4]; owner->frames++;

}
JNIEXPORT void JNICALL Java_dev_craft_vulkantest_NativeSurface_suspend(JNIEnv *env, jobject self, jlong handle, jboolean suspended) {
    (void)self; Owned *owner = (Owned *)(uintptr_t)handle;
    if (craft_vulkan_suspend(owner->scene, suspended ? 1 : 0)) fail(env, craft_vulkan_error());
}
JNIEXPORT jintArray JNICALL Java_dev_craft_vulkantest_NativeSurface_pixels(JNIEnv *env, jobject self, jlong handle) {
    (void)self; Owned *owner = (Owned *)(uintptr_t)handle;
    jsize length = (jsize)(owner->width * owner->height);
    jintArray output = (*env)->NewIntArray(env, length);
    if (output) (*env)->SetIntArrayRegion(env, output, 0, length, (const jint *)craft_vulkan_pixels(owner->scene));
    return output;
}
JNIEXPORT void JNICALL Java_dev_craft_vulkantest_NativeSurface_close(JNIEnv *env, jobject self, jlong handle) {
    (void)self; Owned *owner = (Owned *)(uintptr_t)handle;
    // A timeout retains the context and ANativeWindow. Acceptance fails; never
    // release a window while pending presentation may still refer to it.
    if (craft_vulkan_dispose(owner->scene)) { fail(env, craft_vulkan_error()); return; }
    ANativeWindow_release(owner->window);
    atomic_fetch_sub(&live_contexts, 1);
    free(owner);
}
JNIEXPORT jint JNICALL Java_dev_craft_vulkantest_NativeSurface_active(JNIEnv *env, jobject self) {
    (void)env; (void)self; return atomic_load(&live_contexts);
}

JNIEXPORT jstring JNICALL Java_dev_craft_vulkantest_NativeSurface_diagnostics(JNIEnv *env, jobject self, jlong handle) {
    (void)self; Owned *owner = (Owned *)(uintptr_t)handle;
    char text[512];
    snprintf(text, sizeof(text), "frames=%u, extent=%dx%d, requested=%ux%u, create_ns=%llu, cpu_ns=%llu, present_ns=%llu, readback_ns=%llu",
        owner->frames, ANativeWindow_getWidth(owner->window), ANativeWindow_getHeight(owner->window), owner->width, owner->height,
        (unsigned long long)owner->created_ns, (unsigned long long)owner->cpu_ns,
        (unsigned long long)owner->present_ns, (unsigned long long)owner->readback_ns);
    return (*env)->NewStringUTF(env, text);
}
