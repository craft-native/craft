// Linked only into the generated simulator fixture, never a shipped host.
// Intercept Foundation's actual atomic rename, not Craft's writer: the test
// must observe a real staged file before it terminates the app process.
#include <TargetConditionals.h>
#if TARGET_OS_SIMULATOR
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern void craft_checkpoint_before_replace(const char *, const char *);
static atomic_bool armed = 0;

void craft_checkpoint_arm(void) {
    atomic_store(&armed, 1);
}

static const char *absolute_path(int directory, const char *path, char *buffer) {
    if (path[0] == '/') return path;
    char parent[PATH_MAX];
    if (directory == AT_FDCWD) {
        if (!getcwd(parent, sizeof(parent))) return NULL;
    } else if (fcntl(directory, F_GETPATH, parent) == -1) {
        return NULL;
    }
    int length = snprintf(buffer, PATH_MAX, "%s/%s", parent, path);
    return length > 0 && length < PATH_MAX ? buffer : NULL;
}

static void before_replace(int from_dir, const char *from, int to_dir, const char *to) {
    if (!atomic_load(&armed) || !from || !to) return;
    char source_buffer[PATH_MAX], target_buffer[PATH_MAX];
    const char *source = absolute_path(from_dir, from, source_buffer);
    const char *target = absolute_path(to_dir, to, target_buffer);
    const char *suffix = "/craft-snapshots/craft-interrupted-checkpoint.json";
    if (!source || !target || strlen(target) < strlen(suffix)
        || strcmp(target + strlen(target) - strlen(suffix), suffix) != 0) return;
    if (!atomic_exchange(&armed, 0)) return;
    craft_checkpoint_before_replace(source, target);
    // Only the snapshot worker blocks. The UI stays responsive so XCTest can
    // confirm the boundary, then terminate this process before the real rename.
    dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
}

static int checkpoint_rename(const char *from, const char *to) {
    before_replace(AT_FDCWD, from, AT_FDCWD, to);
    return rename(from, to);
}

static int checkpoint_renameat(int from_dir, const char *from, int to_dir, const char *to) {
    before_replace(from_dir, from, to_dir, to);
    return renameat(from_dir, from, to_dir, to);
}

static int checkpoint_renamex_np(const char *from, const char *to, unsigned int flags) {
    before_replace(AT_FDCWD, from, AT_FDCWD, to);
    return renamex_np(from, to, flags);
}

static int checkpoint_renameatx_np(int from_dir, const char *from, int to_dir, const char *to, unsigned int flags) {
    before_replace(from_dir, from, to_dir, to);
    return renameatx_np(from_dir, from, to_dir, to, flags);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_function; const void *old_function; } \
    interpose_##original = { (const void *)&replacement, (const void *)&original };

INTERPOSE(checkpoint_rename, rename)
INTERPOSE(checkpoint_renameat, renameat)
INTERPOSE(checkpoint_renamex_np, renamex_np)
INTERPOSE(checkpoint_renameatx_np, renameatx_np)
#endif
