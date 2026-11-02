// Debug probe only. Leave the real Craft writer and Java Files.move unchanged.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define DIRECTORY "/data/user/0/dev.craft.checkpointprobe/files"
#define TARGET DIRECTORY "/craft-snapshots/craft-interrupted-checkpoint.json"

__attribute__((constructor)) static void loaded(void) {
    mkdir(DIRECTORY, 0700);
    int descriptor = open(DIRECTORY "/checkpoint-probe.loaded", O_CREAT | O_WRONLY | O_TRUNC, 0600);
    if (descriptor >= 0) {
        dprintf(descriptor, "pid=%d\n", getpid());
        fsync(descriptor);
        close(descriptor);
    }
}

int rename(const char *source, const char *destination) {
    int (*original)(const char *, const char *) = dlsym(RTLD_NEXT, "rename");
    if (!original) _exit(93);
    if (strcmp(destination, TARGET) == 0) {
        int arm = open(DIRECTORY "/checkpoint-probe.arm", O_RDONLY);
        if (arm >= 0) {
            char mode[16] = {0};
            ssize_t length = read(arm, mode, sizeof(mode) - 1);
            close(arm);
            unlink(DIRECTORY "/checkpoint-probe.arm");
            if (length > 0 && (strcmp(mode, "hold") == 0 || strcmp(mode, "pass") == 0)) {
                int record = open(DIRECTORY "/checkpoint-probe.boundary", O_CREAT | O_WRONLY | O_TRUNC, 0600);
                if (record < 0) _exit(94);
                dprintf(record, "%s\n%d\n%ld\n%s\n%s\n", mode, getpid(), syscall(SYS_gettid), source, destination);
                fsync(record);
                close(record);
                if (strcmp(mode, "hold") == 0) for (;;) pause();
            }
        }
    }
    return original(source, destination);
}
