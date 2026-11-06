#!/usr/bin/env python3
"""The Swift Nitrogen helpers give what the Objective-C and C++ gave.

N2MinMax.mm, N2ProportionallyScaleSize and N2FlipRect of N2Operators.mm,
N2Shell.mm, N2Debug.mm, NSException+N2.mm, NSManagedObject+N2.mm and
NSUserDefaultsController+N2.mm became Swift (Nitrogen/Sources and the
IsiXGeometry module). One Objective-C driver, compiled against each side's
headers, runs the same cases on both and prints the results; the outputs must
be equal, bit for bit for the numbers.

- min/max: the unconstrained value, composition, constraining and the two
  sums, on seeded random values and the special ones (signed zeros, NaN,
  infinities, CGFLOAT_MIN and CGFLOAT_MAX, which the sums absorb). The C++
  is C++, which a C driver cannot call, and the Swift is a Swift extension:
  each side gets a small adapter with the same C functions over its own code.
- proportional scaling of sizes and flipping of rectangles, the same way.
- N2Shell: output trimming, termination statuses, output that is not UTF-8,
  the expected-status exception, an executable that does not exist, the host
  name and the serial number. Only on the Swift side, an output larger than a
  pipe holds, which the Objective-C left blocked.
- NSUserDefaultsController (N2): string, array, dictionary, data, integer,
  float, double and bool values of every type, the setters (a nil object
  raises), valuesKeyPath, and observing and removing an observer through the
  values proxy, including the removal of one that is not registered, which
  raises and is logged; the accessors also from a background thread.
- N2Debug: the lines _N2LogExceptionImpl, N2LogStackTraceMessage,
  _N2LogErrorImpl and N2LogStackTrace write (their first line; a stack trace
  must follow where one did), and the debug flag.
- NSException (N2): -stackTrace is backtrace_symbols of the exception's
  return addresses, joined with carriage returns.
- NSManagedObject (N2): -XID is the object URI without its scheme,
  -XIDFilename has no slash, and +UidForXid: finds the object again.

The reference is the last revision that has N2Shell.mm. Exit 2 when the
history does not reach it.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import history_reference  # noqa: E402
import n3_geometry_harness as harness  # noqa: E402

SKIPPED = 2
SEEDS = 400

HEADERS = ['N2MinMax.h', 'N2Shell.h', 'N2Debug.h', 'NSException+N2.h', 'NSManagedObject+N2.h',
           'NSUserDefaultsController+N2.h']

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#include <execinfo.h>
#include <unistd.h>
#import "N2MinMax.h"
#import "N2Shell.h"
#import "N2Debug.h"
#import "NSException+N2.h"
#import "NSManagedObject+N2.h"
#import "NSUserDefaultsController+N2.h"

/* The values-key observation is a Swift extension, which no header declares. */
@interface NSObject (N2ValuesBindingProbe)
- (void)addObserver:(NSObject *)observer forValuesKey:(NSString *)key options:(NSKeyValueObservingOptions)options context:(void *)context;
- (void)removeObserver:(NSObject *)observer forValuesKey:(NSString *)key;
@end

N2MinMax N2ProbeUnconstrained(void);
N2MinMax N2ProbeCompose(N2MinMax a, N2MinMax b);
CGFloat N2ProbeConstrain(N2MinMax a, CGFloat value);
N2MinMax N2ProbeAdd(N2MinMax a, N2MinMax b);
N2MinMax N2ProbeAddValue(N2MinMax a, CGFloat value);
NSSize N2ProbeScale(NSSize size, NSSize target);
NSRect N2ProbeFlip(NSRect frame, NSRect bounds);

static uint64_t seed;
static uint64_t next64(void) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; }
static double value(void) {
    switch (next64() % 12) {
        case 0: return 0.0;
        case 1: return -0.0;
        case 2: return NAN;
        case 3: return INFINITY;
        case 4: return -INFINITY;
        case 5: return CGFLOAT_MIN;
        case 6: return CGFLOAT_MAX;
        case 7: return -CGFLOAT_MAX;
        case 8: return (double)(int64_t)(next64() % 2001) - 1000.0;
        default: return ((double)(next64() >> 11) * 0x1p-53 - 0.5) * 2000.0;
    }
}
static N2MinMax minmax(void) { N2MinMax m = {value(), value()}; return m; }
static void out(const char *label, double v) { printf("%s %a\n", label, v); }
static void outmm(const char *label, N2MinMax m) { printf("%s %a %a\n", label, m.min, m.max); }

static NSString *line(NSString *s) { return s ? [NSString stringWithFormat:@"\"%@\"", [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]] : @"nil"; }

static void shell(NSString *path, NSArray *arguments) {
    int status = -1;
    @try {
        NSString *r = [N2Shell execute:path arguments:arguments outStatus:&status];
        printf("shell %s -> %s status %d\n", path.UTF8String, line(r).UTF8String, status);
    } @catch (NSException *e) {
        printf("shell %s raised %s\n", path.UTF8String, e.name.UTF8String);
    }
}

/* The NSLog lines written while `block` runs, without NSLog's prefix. */
static NSArray *captured(void (^block)(void)) {
    char path[] = "/tmp/n2-helpers-log.XXXXXX";
    int fd = mkstemp(path);
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    dup2(fd, STDERR_FILENO);
    block();
    fflush(stderr);
    dup2(saved, STDERR_FILENO);
    close(saved);
    close(fd);
    NSString *text = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil] ?: @"";
    unlink(path);
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
        NSRange r = [l rangeOfString:@"] "];
        if ([l hasPrefix:@"20"] && r.location != NSNotFound) [lines addObject:@[[l substringFromIndex:NSMaxRange(r)], @0]];
        else if (lines.count && l.length) { NSArray *last = lines.lastObject; [lines replaceObjectAtIndex:lines.count-1 withObject:@[last[0], @([last[1] intValue]+1)]]; }
    }
    return lines;
}

static void printLog(const char *label, NSArray *lines) {
    for (NSArray *l in lines)
        printf("%s: %s%s\n", label, [l[0] UTF8String], [l[1] intValue] > 0 ? " [+stack]" : "");
}

@interface Observer : NSObject
@property NSInteger count;
@end
@implementation Observer
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context { self.count += 1; }
@end

int main(void) {
    @autoreleasepool {
        /* min/max */
        outmm("unconstrained", N2ProbeUnconstrained());
        for (int s = 1; s <= SEEDS; ++s) {
            seed = 0x9E3779B97F4A7C15ull * (uint64_t)s;
            N2MinMax a = minmax(), b = minmax();
            double v = value();
            outmm("compose", N2ProbeCompose(a, b));
            out("constrain", N2ProbeConstrain(a, v));
            outmm("add", N2ProbeAdd(a, b));
            outmm("addValue", N2ProbeAddValue(a, v));
            NSSize size = NSMakeSize(value(), value()), target = NSMakeSize(value(), value());
            if (s % 5 == 0) target = size;
            NSSize scaled = N2ProbeScale(size, target);
            NSRect flipped = N2ProbeFlip(NSMakeRect(value(), value(), value(), value()), NSMakeRect(value(), value(), value(), value()));
            printf("flip %a %a %a %a\n", flipped.origin.x, flipped.origin.y, flipped.size.width, flipped.size.height);
            printf("scale %a %a\n", scaled.width, scaled.height);
        }

        /* N2Shell */
        shell(@"/bin/echo", @[@"  hello", @"world  "]);
        shell(@"/bin/sh", @[@"-c", @"printf '\\n\\n a\\nb \\n\\n'; exit 3"]);
        shell(@"/bin/sh", @[@"-c", @"printf '\\377\\376'"]);
        shell(@"/usr/bin/true", nil);
        shell(@"/usr/bin/false", @[]);
        shell(@"/bin/sh", @[@"-c", @"echo out; echo err 1>&2"]);
        shell(@"/nonexistent/n2-shell-probe", @[]);
        printf("execute: %s\n", line([N2Shell execute:@"/bin/echo"]).UTF8String);
        printf("execute:arguments: %s\n", line([N2Shell execute:@"/bin/echo" arguments:@[@"x"]]).UTF8String);
        @try {
            [N2Shell execute:@"/bin/sh" arguments:@[@"-c", @"exit 4"] expectedStatus:0];
            printf("expectedStatus: no exception\n");
        } @catch (NSException *e) {
            printf("expectedStatus: %s %s\n", e.name.UTF8String, e.reason.UTF8String);
        }
        printf("expectedStatus 4: %s\n", line([N2Shell execute:@"/bin/sh" arguments:@[@"-c", @"echo four; exit 4"] expectedStatus:4]).UTF8String);
        printf("hostname %s\n", line([N2Shell hostname]).UTF8String);
        printf("serialNumber %s\n", line([N2Shell serialNumber]).UTF8String);
#ifdef SWIFT_SIDE
        NSString *large = [N2Shell execute:@"/bin/sh" arguments:@[@"-c", @"head -c 1048576 /dev/zero | tr '\\0' a"]];
        printf("new-only: large output %lu\n", (unsigned long)large.length);
#endif

        /* NSUserDefaultsController (N2) */
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDictionary *registered = @{@"n2s": @"text", @"n2n": @42, @"n2f": @2.75, @"n2b": @YES, @"n2sn": @"17", @"n2sb": @"yes",
                                     @"n2sz": @"0", @"n2d": @{@"a": @1}, @"n2a": @[@1, @2], @"n2data": [NSData dataWithBytes:"ab" length:2],
                                     @"n2date": [NSDate dateWithTimeIntervalSince1970:0]};
        [defaults registerDefaults:registered];
        NSUserDefaultsController *controller = [[[NSUserDefaultsController alloc] initWithDefaults:defaults initialValues:nil] autorelease];
        controller.appliesImmediately = NO;
        for (NSString *key in @[@"n2s", @"n2n", @"n2f", @"n2b", @"n2sn", @"n2sb", @"n2sz", @"n2d", @"n2a", @"n2data", @"n2date", @"n2missing"]) {
            NSDictionary *d = [controller dictionaryForKey:key];
            printf("defaults %s: string %s dictionary %s integer %ld bool %d\n", key.UTF8String, line([controller stringForKey:key]).UTF8String,
                   d ? [[d description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String : "nil",
                   (long)[controller integerForKey:key], (int)[controller boolForKey:key]);
            NSArray *array = [controller arrayForKey:key];
            NSData *data = [controller dataForKey:key];
            printf("defaults %s: array %ld data %ld float %a double %a\n", key.UTF8String, array ? (long)array.count : -1L,
                   data ? (long)data.length : -1L, [controller floatForKey:key], [controller doubleForKey:key]);
        }
        [controller setString:@"set" forKey:@"n2s2"];
        [controller setArray:@[@"x"] forKey:@"n2a2"];
        [controller setDictionary:@{@"k": @"v"} forKey:@"n2d2"];
        [controller setData:[NSData dataWithBytes:"xyz" length:3] forKey:@"n2data2"];
        [controller setInteger:-12 forKey:@"n2i2"];
        [controller setFloat:1.5f forKey:@"n2f2"];
        [controller setDouble:0.1 forKey:@"n2db2"];
        for (NSString *key in @[@"n2s2", @"n2a2", @"n2d2", @"n2data2", @"n2i2", @"n2f2", @"n2db2"])
            printf("set %s: %s\n", key.UTF8String, [[[[controller.values valueForKey:key] description]
                                                    stringByReplacingOccurrencesOfString:@"\n" withString:@" "] UTF8String]);
        @try { [controller setString:nil forKey:@"n2s3"]; printf("setString nil: no exception\n"); }
        @catch (NSException *e) { printf("setString nil: %s %s\n", e.name.UTF8String, e.reason.UTF8String); }
        @try { [controller setArray:nil forKey:@"n2a3"]; printf("setArray nil: no exception\n"); }
        @catch (NSException *e) { printf("setArray nil: %s %s\n", e.name.UTF8String, e.reason.UTF8String); }
        [controller setBool:NO forKey:@"n2b"];
        [controller setBool:YES forKey:@"n2new"];
        printf("setBool: %d %d %s\n", (int)[controller boolForKey:@"n2b"], (int)[controller boolForKey:@"n2new"],
               [[[controller.values valueForKey:@"n2new"] className] UTF8String]);
        __block NSString *background = nil;
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            background = [[NSString alloc] initWithFormat:@"%@ %ld %d", [controller stringForKey:@"n2s"], (long)[controller integerForKey:@"n2n"], (int)[controller boolForKey:@"n2b"]];
        });
        printf("background: %s\n", background.UTF8String);
        [background release];
        printf("valuesKeyPath %s\n", valuesKeyPath(@"n2s").UTF8String);
        Observer *observer = [[[Observer alloc] init] autorelease];
        [controller addObserver:observer forValuesKey:@"n2s" options:NSKeyValueObservingOptionInitial context:NULL];
        [controller setValue:@"changed" forKeyPath:valuesKeyPath(@"n2s")];
        [controller removeObserver:observer forValuesKey:@"n2s"];
        [controller setValue:@"again" forKeyPath:valuesKeyPath(@"n2s")];
        printf("observed %ld\n", (long)observer.count);
        printLog("removeObserver unregistered", captured(^{ [controller removeObserver:observer forValuesKey:@"n2s"]; }));
        NSObject *plain = [[[NSObject alloc] init] autorelease];
        printLog("removeObserver unregistered from an object", captured(^{ [plain removeObserver:observer forValuesKey:@"n2s"]; }));
        [controller revert:nil];

        /* N2Debug */
        printf("debug active %d\n", (int)[N2Debug isActive]);
        [N2Debug setActive:YES];
        printf("debug active %d\n", (int)[N2Debug isActive]);
        [N2Debug setActive:NO];
        NSException *raised = nil;
        @try { [NSException raise:@"N2ProbeException" format:@"probe %d", 7]; } @catch (NSException *e) { raised = [e retain]; }
        printLog("exception", captured(^{ _N2LogExceptionImpl(raised, NO, "probe function"); }));
        printLog("exception with stack", captured(^{ _N2LogExceptionImpl(raised, YES, "probe function"); }));
        printLog("stack trace message", captured(^{ N2LogStackTraceMessage(@"message 1"); }));
        printLog("stack trace message nil", captured(^{ N2LogStackTraceMessage(nil); }));
        printLog("stack trace format", captured(^{ N2LogStackTrace(@"format %d %@", 3, @"x"); }));
        printLog("error string", captured(^{ _N2LogErrorImpl("pf", "file.m", 12, @"error %d", 5); }));
        printLog("error NSError", captured(^{ _N2LogErrorImpl("pf", "file.m", 13, [NSError errorWithDomain:N2ErrorDomain code:3 userInfo:nil]); }));
        printLog("error other", captured(^{ _N2LogErrorImpl("pf", "file.m", 14, @42); }));
        printf("N2ErrorDomain %s\n", N2ErrorDomain.UTF8String);

        /* NSException (N2) */
        NSArray *addresses = raised.callStackReturnAddresses;
        void **frames = malloc(addresses.count * sizeof(void *));
        for (NSUInteger i = 0; i < addresses.count; ++i) frames[i] = (void *)[addresses[i] unsignedLongValue];
        char **symbols = backtrace_symbols(frames, (int)addresses.count);
        NSMutableArray *expected = [NSMutableArray array];
        for (NSUInteger i = 0; i < addresses.count; ++i) [expected addObject:@(symbols[i])];
        free(symbols);
        free(frames);
        printf("stackTrace equals backtrace_symbols joined by CR: %d (frames > 0: %d)\n",
               (int)[[raised stackTrace] isEqualToString:[expected componentsJoinedByString:@"\r"]], (int)(addresses.count > 0));
        NSException *unraised = [NSException exceptionWithName:@"n" reason:@"r" userInfo:nil];
        printf("stackTrace of an exception never raised: %s\n", line([unraised stackTrace]).UTF8String);
        __block NSString *printed = nil;
        NSArray *printedLines = captured(^{ printed = [[raised printStackTrace] retain]; });
        /* The frames name the binary, so only how they relate is compared. */
        printf("printStackTrace returns -stackTrace: %d, logs one entry: %d, beginning with its first frame: %d\n",
               (int)[printed isEqualToString:[raised stackTrace]], (int)(printedLines.count == 1),
               (int)(printedLines.count == 1 && [printedLines[0][0] hasPrefix:[[raised stackTrace] componentsSeparatedByString:@"\r"].firstObject]));
        [printed release];
        [raised release];

        /* NSManagedObject (N2) */
        NSEntityDescription *entity = [[[NSEntityDescription alloc] init] autorelease];
        entity.name = @"Thing";
        NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
        model.entities = @[entity];
        NSPersistentStoreCoordinator *coordinator = [[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model] autorelease];
        [coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:nil];
        NSManagedObjectContext *context = [[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType] autorelease];
        context.persistentStoreCoordinator = coordinator;
        NSManagedObject *thing = [NSEntityDescription insertNewObjectForEntityForName:@"Thing" inManagedObjectContext:context];
        [context obtainPermanentIDsForObjects:@[thing] error:nil];
        NSString *uri = thing.objectID.URIRepresentation.absoluteString;
        printf("XID is the URI without x-coredata://: %d %d\n", (int)[[thing XID] isEqualToString:[uri substringFromIndex:13]], (int)[uri hasPrefix:@"x-coredata://"]);
        printf("XIDFilename has no slash and maps back: %d %d\n", (int)([[thing XIDFilename] rangeOfString:@"/"].location == NSNotFound),
               (int)[[thing XIDFilename] isEqualToString:[[thing XID] stringByReplacingOccurrencesOfString:@"/" withString:@"-"]]);
        printf("UidForXid: %s, finds the object: %d\n", [NSManagedObject UidForXid:@"store/Thing/p1"].UTF8String,
               (int)([coordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:[NSManagedObject UidForXid:[thing XID]]]] != nil));
    }
    return 0;
}
'''.replace('SEEDS', str(SEEDS))

REFERENCE_ADAPTER = r'''
#import <Cocoa/Cocoa.h>
#import "N2MinMax.h"
#import "N2Operators.h"
extern "C" {
N2MinMax N2ProbeUnconstrained(void) { return N2MakeMinMax(); }
N2MinMax N2ProbeCompose(N2MinMax a, N2MinMax b) { return N2ComposeMinMax(a, b); }
CGFloat N2ProbeConstrain(N2MinMax a, CGFloat value) { return N2MinMaxConstrainedValue(a, value); }
N2MinMax N2ProbeAdd(N2MinMax a, N2MinMax b) { return a + b; }
N2MinMax N2ProbeAddValue(N2MinMax a, CGFloat value) { return a + value; }
NSSize N2ProbeScale(NSSize size, NSSize target) { return N2ProportionallyScaleSize(size, target); }
NSRect N2ProbeFlip(NSRect frame, NSRect bounds) { return N2FlipRect(frame, bounds); }
}
'''

SWIFT_ADAPTER = r'''
import Foundation
import IsiXGeometry

@_cdecl("N2ProbeUnconstrained") func probeUnconstrained() -> N2MinMax { .unconstrained }
@_cdecl("N2ProbeCompose") func probeCompose(_ a: N2MinMax, _ b: N2MinMax) -> N2MinMax { a.composed(with: b) }
@_cdecl("N2ProbeConstrain") func probeConstrain(_ a: N2MinMax, _ value: CGFloat) -> CGFloat { a.constrained(value) }
@_cdecl("N2ProbeAdd") func probeAdd(_ a: N2MinMax, _ b: N2MinMax) -> N2MinMax { a + b }
@_cdecl("N2ProbeAddValue") func probeAddValue(_ a: N2MinMax, _ value: CGFloat) -> N2MinMax { a + value }
@_cdecl("N2ProbeScale") func probeScale(_ size: CGSize, _ target: CGSize) -> CGSize { size.scaledProportionally(toFit: target) }
@_cdecl("N2ProbeFlip") func probeFlip(_ frame: CGRect, _ bounds: CGRect) -> CGRect { frame.flipped(in: bounds) }
'''

SWIFT_FILES = ['N2MinMax.swift', 'N2Shell.swift', 'N2Debug.swift', 'NSException+N2.swift', 'NSManagedObject+N2.swift',
               'NSUserDefaultsController+N2.swift']


def run(command, **kwargs):
    result = subprocess.run([str(c) for c in command], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise SystemExit('FAIL: %s\n%s%s' % (' '.join(map(str, command[:3])), result.stdout, result.stderr))
    return result.stdout


def reference_side(folder, revision):
    folder.mkdir()
    sources = []
    for name in ('N2MinMax', 'N2Operators', 'N2Shell', 'N2Debug', 'NSException+N2', 'NSManagedObject+N2',
                 'NSUserDefaultsController+N2'):
        (folder / (name + '.h')).write_bytes(history_reference.show(revision, f'Nitrogen/Sources/{name}.h'))
        (folder / (name + '.mm')).write_bytes(history_reference.show(revision, f'Nitrogen/Sources/{name}.mm'))
        sources.append(folder / (name + '.mm'))
    (folder / 'adapter.mm').write_text(REFERENCE_ADAPTER)
    objects = []
    for source in sources + [folder / 'adapter.mm']:
        obj = source.with_suffix('.o')
        run(['xcrun', 'clang', '-c', '-x', 'objective-c++', '-std=c++17', '-fno-objc-arc', '-fobjc-exceptions', '-O0',
             *harness.TARGET, '-I', folder, '-w', source, '-o', obj])
        objects.append(obj)
    return objects, ['-lc++']


def swift_side(folder):
    folder.mkdir()
    module = folder / 'module'
    module.mkdir()
    run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone', *harness.TARGET,
         '-module-name', 'IsiXGeometry', '-emit-library', '-static', '-emit-module', '-emit-module-path',
         module / 'IsiXGeometry.swiftmodule', '-o', module / 'libIsiXGeometry.a',
         *sorted((ROOT / 'Modules/IsiXGeometry/Sources').glob('*.swift'))])
    for name in HEADERS:
        (folder / name).write_bytes((ROOT / 'Nitrogen/Sources' / name).read_bytes())
    (folder / 'HorosObjCException.h').write_bytes((ROOT / 'Horos/Sources/HorosObjCException.h').read_bytes())
    bridge = folder / 'bridge.h'
    bridge.write_text('#import <Cocoa/Cocoa.h>\n' + ''.join(f'#import "{name}"\n' for name in HEADERS)
                      + '#import "HorosObjCException.h"\n')
    (folder / 'adapter.swift').write_text(SWIFT_ADAPTER)
    library = folder / 'libHelpers.a'
    run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone', *harness.TARGET,
         '-module-name', 'Horos', '-I', module, '-import-objc-header', bridge, '-Xcc', '-I' + str(folder),
         '-emit-library', '-static', '-o', library, folder / 'adapter.swift',
         *[ROOT / 'Nitrogen/Sources' / name for name in SWIFT_FILES]])
    objects = [library, module / 'libIsiXGeometry.a']
    for source in (ROOT / 'Nitrogen/Sources/N2Debug+CAPI.m', ROOT / 'Horos/Sources/HorosObjCException.m'):
        obj = folder / (source.stem + '.o')
        run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fobjc-exceptions', '-O0', *harness.TARGET,
             '-I', folder, source, '-o', obj])
        objects.append(obj)
    # -ObjC: the categories are in a static library that nothing else references.
    return objects, ['-ObjC', *harness.swift_runtime_flags()]


def output(folder, side, objects, link_flags, swift):
    driver = folder / (side + '-driver.m')
    driver.write_text(DRIVER)
    binary = folder / (side + '-driver')
    run(['xcrun', 'clang', '-x', 'objective-c', '-fno-objc-arc', '-fobjc-exceptions', '-O0', *harness.TARGET,
         *(['-DSWIFT_SIDE=1'] if swift else []), '-I', folder / side, driver, '-x', 'none', *objects,
         '-framework', 'Cocoa', '-framework', 'CoreData', '-framework', 'IOKit', *link_flags, '-o', binary])
    return run([binary], timeout=600)


def unaddressed(line):
    """The line without the object addresses a description carries, which
    differ between the two processes (hexadecimal floats keep their point)."""
    return re.sub(r'0x[0-9a-f]{6,}\b', '0x…', line)


def main():
    revision = history_reference.before_removal('Nitrogen/Sources/N2Shell.mm')
    if not revision:
        # Before the commit that removes it, the reference is HEAD.
        try:
            history_reference.show('HEAD', 'Nitrogen/Sources/N2Shell.mm')
            revision = 'HEAD'
        except subprocess.CalledProcessError:
            pass
    if not revision:
        print('SKIP: the history does not reach N2Shell.mm', file=sys.stderr)
        return SKIPPED
    with tempfile.TemporaryDirectory(prefix='n2-helpers-') as tmp:
        tmp = Path(tmp)
        reference = output(tmp, 'reference', *reference_side(tmp / 'reference', revision), swift=False)
        swift = output(tmp, 'swift', *swift_side(tmp / 'swift'), swift=True)
    new_only = [l for l in swift.splitlines() if l.startswith('new-only:')]
    swift_lines = [unaddressed(l) for l in swift.splitlines() if not l.startswith('new-only:')]
    reference_lines = [unaddressed(l) for l in reference.splitlines()]
    failures = []
    for index, (a, b) in enumerate(zip(reference_lines, swift_lines)):
        if a != b:
            failures.append(f'line {index + 1}:\n  reference: {a}\n  swift:     {b}')
    if len(reference_lines) != len(swift_lines):
        failures.append(f'{len(reference_lines)} reference lines, {len(swift_lines)} Swift lines')
    if new_only != ['new-only: large output 1048576']:
        failures.append(f'large output: {new_only}')
    for needle in ('exception with stack: N2ProbeException (in probe function): probe 7 [+stack]',
                   'stack trace message: message 1 (in ):  [+stack]', 'XID is the URI without x-coredata://: 1 1',
                   'stackTrace equals backtrace_symbols joined by CR: 1 (frames > 0: 1)'):
        if needle not in swift_lines:
            failures.append('missing: ' + needle)
    if failures:
        print('FAIL:\n' + '\n'.join(failures[:20]))
        return 1
    print(f'PASS: {len(swift_lines)} lines equal to the reference ({revision[:9]}), {SEEDS} seeds of min/max and scaling; '
          'large output read in full')
    return 0


if __name__ == '__main__':
    sys.exit(main())
