#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

// Keep an existing file intact until the writer reports a complete replacement.
static inline BOOL HorosWriteFileAtomically(NSString *destination, BOOL (^writer)(NSString *))
{
    if (!destination.length || !writer) return NO;
    const char *target = destination.fileSystemRepresentation;
    if (!target) return NO;
    struct stat original;
    if (lstat(target, &original) == 0) {
        if (!S_ISREG(original.st_mode)) return NO;
    } else if (errno != ENOENT) return NO;

    // A secure sibling file needs no per-write directory or recursive cleanup.
    // mkstemp creates it exclusively with owner-only permissions; keeping it
    // on the destination filesystem allows one atomic rename after close.
    const char *slash = strrchr(target, '/');
    size_t parentLength = slash ? (size_t)(slash - target + 1) : 0;
    const char suffix[] = ".horos-write-XXXXXX";
    char *prepared = (char *)malloc(parentLength + sizeof(suffix));
    if (!prepared) return NO;
    memcpy(prepared, target, parentLength);
    memcpy(prepared + parentLength, suffix, sizeof(suffix));
    int descriptor = mkstemp(prepared);
    if (descriptor < 0) { free(prepared); return NO; }
    if (close(descriptor) != 0) {
        unlink(prepared);
        free(prepared);
        return NO;
    }
    BOOL published = NO;
    @try {
        NSString *path = [NSFileManager.defaultManager stringWithFileSystemRepresentation:prepared length:strlen(prepared)];
        if (!path || !writer(path)) return NO;
        struct stat replacement;
        if (lstat(prepared, &replacement) != 0 || !S_ISREG(replacement.st_mode) || replacement.st_size <= 0) return NO;
        // Writers that reopen the mkstemp file already preserve mode 0600.
        // Enforce it when a writer replaces the output, without a redundant
        // metadata update for every ordinary save.
        if ((replacement.st_mode & 07777) != 0600 && chmod(prepared, 0600) != 0) return NO;
        published = rename(prepared, target) == 0;
        return published;
    } @finally {
        if (!published && unlink(prepared) != 0 && errno != ENOENT) {
            // An invalid writer may have replaced its output with a directory.
            // Keep recursive cleanup only for this exceptional output shape.
            NSString *path = [NSFileManager.defaultManager stringWithFileSystemRepresentation:prepared length:strlen(prepared)];
            if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        }
        free(prepared);
    }
}
