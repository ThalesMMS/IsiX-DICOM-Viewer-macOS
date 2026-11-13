// The cost of a typed read of the preferences, in two revisions of the catalog
// loaded in one process and alternated batch by batch
// (tools/measure-object-interleaved.py, with tools/probe-preference-read-shim.swift).
//
//   probe interleave <dylib A> <dylib B> <batches> <reads per batch>
//
// Prints {"A": {"read_ns": [...], "held_read_ns": [...]}, "B": {...}}: the
// nanoseconds of one read of two keys, per batch, with no work in course and
// while work gives a third key a value of its own. HOROS_AB_FIRST names the
// variant that goes first; the order inside a pair alternates (ABBA).

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <time.h>

typedef struct {
    void (*prepare)(void);
    long (*batch)(long);
    void (*hold)(void);
    void (*release)(void);
} Catalog;

static Catalog load(const char *path) {
    void *image = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!image) { fprintf(stderr, "dlopen %s: %s\n", path, dlerror()); exit(2); }
    Catalog catalog = { dlsym(image, "preference_read_prepare"), dlsym(image, "preference_read_batch"),
                        dlsym(image, "preference_read_hold"), dlsym(image, "preference_read_release") };
    if (!catalog.prepare || !catalog.batch || !catalog.hold || !catalog.release) {
        fprintf(stderr, "%s lacks an entry point\n", path);
        exit(2);
    }
    return catalog;
}

static double timed(Catalog catalog, long reads, long *sum) {
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    *sum += catalog.batch(reads);
    return (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / (double)reads;
}

static void print(const char *name, NSArray *plain, NSArray *held, BOOL last) {
    printf("\"%s\": {\"read_ns\": [%s], \"held_read_ns\": [%s]}%s", name, [plain componentsJoinedByString:@", "].UTF8String,
           [held componentsJoinedByString:@", "].UTF8String, last ? "" : ", ");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 6 || strcmp(argv[1], "interleave") != 0) {
            fprintf(stderr, "usage: probe interleave <dylib A> <dylib B> <batches> <reads per batch>\n");
            return 2;
        }
        Catalog catalogs[2] = { load(argv[2]), load(argv[3]) };
        long batches = atol(argv[4]), reads = atol(argv[5]), sum = 0;
        const char *first = getenv("HOROS_AB_FIRST");
        int start = first && strcmp(first, "B") == 0 ? 1 : 0;
        NSMutableArray *plain[2] = { [NSMutableArray array], [NSMutableArray array] };
        NSMutableArray *held[2] = { [NSMutableArray array], [NSMutableArray array] };
        for (int slot = 0; slot < 2; slot++) {
            catalogs[slot].prepare();
            sum += catalogs[slot].batch(reads);
        }
        for (long batch = 0; batch < batches; batch++) {
            // AB BA AB BA from the variant the round names first.
            for (int position = 0; position < 2; position++) {
                int slot = (start + (int)(batch & 1) + position) & 1;
                [plain[slot] addObject:@(timed(catalogs[slot], reads, &sum))];
            }
            for (int position = 0; position < 2; position++) {
                int slot = (start + (int)(batch & 1) + position) & 1;
                catalogs[slot].hold();
                [held[slot] addObject:@(timed(catalogs[slot], reads, &sum))];
                catalogs[slot].release();
            }
        }
        printf("{");
        print("A", plain[0], held[0], NO);
        print("B", plain[1], held[1], YES);
        printf("}\n");
        fprintf(stderr, "checksum %ld\n", sum);
    }
    return 0;
}
