#!/usr/bin/env python3
"""A DICOM load that raises is counted out, and the next purge does not wait.

`DCMPix.loadDICOM()` counts the loads in progress in
`DCMPixParsedFileCache.loads`, a `LoadsInProgress` of IsiXImaging, and
`DCMPixParsedFileCache.purge()` waits on the main thread, ten seconds at most,
until that count is zero. The load was
counted out by a `defer`, which does not run when an NSException unwinds the
Swift frame: what the counted scope raises outside its own guards (the cache,
an attribute of the parsed file) is caught by -CheckLoad, the thread lives on,
and the count stayed one too high for ever. Every later purge then held the
main thread for ten seconds, logged that it had given up, and dropped nothing.

Source level: the load runs in `DCMPixParsedFileCache.counted`, which runs it
in `LoadsInProgress.counted` under the application's exception guard and
raises again what that answers; the module's scope is the only caller of
`countIn()` and of `countOut()`, one call of each around the guarded body, so
that every way out of the scope counts the load out once. The purge waits in
`LoadsInProgress.whenNoneInProgress`, and the application holds no count of
its own.

Object level, on the class as the build compiled it (DCMPix.o and the Swift
of its loading, tests/app_object_probe.py): the probe gives a pix a file and
calls -loadDICOMWithDCMTK
  * with nothing to read in the file: the load answers NO by an early return
    and the count is back to zero;
  * with an entry of the parsed-file cache that raises when the load counts
    its new user, which is inside the counted scope and inside a region of
    PapyrusLock: the exception reaches the caller with its reason, the count
    is zero, another thread takes PapyrusLock, and +purgeCachedDictionaries
    on the main thread returns at once with the cache empty;
  * and again after the purge: the count still works.

It needs a Debug or Release build of the app (DCMPix.o and DCMPix+Loading.o);
without one the test reports itself skipped (exit 2). `HOROS_PROBE_OBJECT`
names another DCMPix.o, whose folder then gives the other objects: against a
build from before the change the probe must fail, with a count of one and a
purge of ten seconds.

    python3 tests/test-dcmpix-load-count-exception.py [--configuration Release]
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
import object_probe  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', default='Debug', choices=('Debug', 'Release'))
arguments = parser.parse_args()

LOADING = 'Horos/Sources/DCMPix+Loading.swift'
failures = []

# --- source level: one way in and one way out of the count ---------------------------------------
loading_source = (ROOT / LOADING).read_text()


def code(text):
    return '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))


def body(text, signature):
    """The declaration that starts with `signature`, to the brace that closes it."""
    start = text.find(signature)
    if start < 0:
        return ''
    depth, index = 0, text.index('{', start)
    while True:
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
        index += 1


COUNTER = 'Modules/IsiXImaging/Sources/LoadsInProgress.swift'
counter_source = (ROOT / COUNTER).read_text(errors='replace') if (ROOT / COUNTER).is_file() else ''
counter = code(counter_source)

counted = code(body(loading_source, '    static func counted<T>(_ body: () -> T) -> T {'))
load = code(body(loading_source, '    final func loadDICOM() -> Bool {'))
purge = code(body(loading_source, '    static func purge() {'))
scope = code(body(counter_source, '    public func counted(_ body: () -> Void) -> NSException? {'))
wait = code(body(counter_source, '    public func whenNoneInProgress(_ body: () -> Void) -> Wait {'))
if not counted:
    failures.append('DCMPixParsedFileCache.counted(_:) is gone from %s' % LOADING)
else:
    order = [counted.find(step) for step in ('loads.counted(', '.raise()')]
    if -1 in order or order != sorted(order):
        failures.append('counted(_:) must run its body in the counted scope of the loads in progress and raise again '
                        'what that scope answers')
    if 'defer' in counted:
        failures.append('counted(_:) leaves its scope by a defer, which an NSException skips')
if 'static let loads = LoadsInProgress { HorosObjCException.caught($0) }' not in code(loading_source):
    failures.append('the loads in progress are not counted under the exception guard of the application')
if 'NSConditionLock' in code(loading_source):
    failures.append('%s keeps a count of its own beside the one of the module' % LOADING)
if not scope:
    failures.append('LoadsInProgress.counted(_:) is gone from %s' % COUNTER)
else:
    order = [scope.find(step) for step in ('countIn()', 'caught(body)', 'countOut()', 'return raised')]
    if -1 in order or order != sorted(order):
        failures.append('LoadsInProgress.counted(_:) must count the load in, run the body under the guard, count the '
                        'load out and only then answer what the body raised')
    if 'defer' in scope:
        failures.append('LoadsInProgress.counted(_:) counts the load out by a defer, which an NSException skips')
if not wait:
    failures.append('LoadsInProgress.whenNoneInProgress(_:) is gone from %s' % COUNTER)
else:
    order = [wait.find(step) for step in ('count.lock(whenCondition: 0, before: Date(timeIntervalSinceNow: limit))',
                                          'caught(body)', 'count.unlock()', 'return .ran(raised: raised)')]
    if -1 in order or order != sorted(order) or 'defer' in wait:
        failures.append('whenNoneInProgress(_:) must wait for no load, run the body under the guard, leave the count and '
                        'only then answer what the body raised')
if 'public static let purgeLimit: TimeInterval = 10' not in counter:
    failures.append('the purge no longer waits ten seconds at most')
if 'loads.whenNoneInProgress {' not in purge or 'during 10 secs : purgeCacheLock condition: %d' not in purge:
    failures.append('purge() no longer waits for the loads in progress, or no longer logs that it gave up')
if 'DCMPixParsedFileCache.counted {' not in load:
    failures.append('loadDICOM() no longer runs its load in DCMPixParsedFileCache.counted')
for call in ('countIn()', 'countOut()'):
    found = len(re.findall(r'(?<!func )\b%s' % re.escape(call), counter))
    if found != 1 or scope.count(call) != 1:
        failures.append('%s must be called once, by LoadsInProgress.counted(_:): found %d' % (call, found))
callers = {}
for path in sorted((ROOT / 'Horos/Sources').glob('*.swift')):
    found = len(re.findall(r'\bloads\s*\.\s*counted\s*\(', code(path.read_text(errors='replace'))))
    if found:
        callers[path.name] = found
if callers != {'DCMPix+Loading.swift': 1}:
    failures.append('the counted scope of the loads must have one caller, DCMPixParsedFileCache.counted(_:): found %s'
                    % (callers or 'no call'))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)

# --- object level ---------------------------------------------------------------------------------
PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
#include <cstdio>
#include <cstdlib>

extern "C" NSMutableDictionary **ProbeParsedFiles( void) __asm__( "PARSED_FILES");
// The loads in progress: IsiXImaging's count, or the condition lock of a
// build from before the count was the module's.
@interface NSObject (ProbeLoadsInProgress)
- (NSInteger) inProgress;
@end
extern "C" id *ProbeLoads( void) __asm__( "LOADS");
// The application defines the lock beside its controller, which is not linked here.
NSRecursiveLock *PapyrusLock = nil;

// An entry of the cache that raises when the load counts its new user.
@interface RaisingGroup : NSMutableDictionary { NSMutableDictionary *backing; }
@end
@implementation RaisingGroup
- (instancetype) init { if( (self = [super init])) backing = [[NSMutableDictionary alloc] init]; return self; }
- (void) dealloc { [backing release]; [super dealloc]; }
- (NSUInteger) count { return backing.count; }
- (id) objectForKey:(id) key { return [backing objectForKey: key]; }
- (NSEnumerator*) keyEnumerator { return [backing keyEnumerator]; }
- (void) removeObjectForKey:(id) key { [backing removeObjectForKey: key]; }
- (void) setObject:(id) object forKey:(id<NSCopying>) key
{
    [NSException raise: NSInternalInconsistencyException format: @"the entry of the cache raised"];
}
@end

static int failures = 0;
static void expect( bool ok, const char *what) { if( !ok) { fprintf( stderr, "FAIL: %s\n", what); failures++; } }
static long loads( void)
{
    id count = *ProbeLoads();
    return (long) ([count respondsToSelector: @selector(inProgress)] ? [count inProgress] : [(NSConditionLock*) count condition]);
}

static bool anotherThreadTakesPapyrusLock( void)
{
    __block BOOL taken = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create( 0);
    [NSThread detachNewThreadWithBlock: ^{
        taken = [PapyrusLock tryLock];
        if( taken) [PapyrusLock unlock];
        dispatch_semaphore_signal( done);
    }];
    dispatch_semaphore_wait( done, DISPATCH_TIME_FOREVER);
    return taken;
}

static DCMPix *pixOf( NSString *path)
{
    DCMPix *pix = [[DCMPix alloc] init];
    pix.srcFile = path;
    return pix;
}

int main( int argc, char *argv[]) {
    @autoreleasepool {
        PapyrusLock = [[NSRecursiveLock alloc] init];
        NSString *folder = [NSString stringWithUTF8String: argv[1]];
        NSString *unreadable = [folder stringByAppendingPathComponent: @"unreadable.dcm"];
        NSString *cached = [folder stringByAppendingPathComponent: @"cached.dcm"];
        [[@"nothing a DICOM parser reads" dataUsingEncoding: NSUTF8StringEncoding] writeToFile: unreadable atomically: YES];
        [[@"never read: its entry is in the cache" dataUsingEncoding: NSUTF8StringEncoding] writeToFile: cached atomically: YES];

        expect( loads() == 0, "a load is counted before any started");

        // An early return: the file gives no parsed object.
        @autoreleasepool {
            DCMPix *pix = pixOf( unreadable);
            BOOL loaded = YES;
            @try { loaded = [pix loadDICOMWithDCMTK]; }
            @catch( NSException *exception) { expect( false, "a file that gives no parsed object raised out of its load"); }
            expect( !loaded, "a file that is not DICOM was loaded");
            expect( loads() == 0, "a load that returned early is still counted");
            [pix release];
        }

        // An exception inside the counted scope, twice.
        for( int round = 0; round < 2; round++) @autoreleasepool {
            DCMPix *pix = pixOf( cached);
            NSString *key = [pix parsedFileCacheKey];
            expect( key.length > 0, "the pix has no key for its parsed file");
            RaisingGroup *group = [[RaisingGroup alloc] init];
            [*ProbeParsedFiles() setObject: group forKey: key];
            [group release];

            NSException *raised = nil;
            @try { [pix loadDICOMWithDCMTK]; }
            @catch( NSException *exception) { raised = exception; }
            expect( raised != nil, "the load did not raise what its counted scope raised");
            expect( [raised.reason isEqualToString: @"the entry of the cache raised"], "the exception lost its reason");
            if( loads() != 0) fprintf( stderr, "the count of loads is %ld\n", loads());
            expect( loads() == 0, "a load that raised is still counted");
            expect( anotherThreadTakesPapyrusLock(), "a load that raised inside a region of PapyrusLock left the lock with its thread");

            NSDate *start = [NSDate date];
            [DCMPix purgeCachedDictionaries];
            NSTimeInterval waited = -[start timeIntervalSinceNow];
            fprintf( stderr, "the purge took %.2f s\n", waited);
            expect( waited < 3, "the purge that follows a load that raised waited for it");
            expect( (*ProbeParsedFiles()).count == 0, "the purge that follows a load that raised dropped nothing");
            expect( loads() == 0, "the purge left the count of loads taken");
            expect( anotherThreadTakesPapyrusLock(), "the purge left PapyrusLock taken");
            [pix release];
        }
    }
    if( failures) { fprintf( stderr, "FAIL: %d check%s\n", failures, failures == 1 ? "" : "s"); return 1; }
    printf( "a load that returns early and two that raise inside the counted scope leave no load counted, PapyrusLock free "
            "and the purge immediate");
    return 0;
}
'''

import app_object_probe  # noqa: E402

override = os.environ.get('HOROS_PROBE_OBJECT')
obj = Path(override) if override else object_probe.app_object('DCMPix', arguments.configuration)
loading = obj.parent / 'DCMPix+Loading.o' if obj else None
if loading is None or not obj.is_file() or not loading.is_file():
    print('needs a %s build of the app: DCMPix.o and DCMPix+Loading.o' % arguments.configuration, file=sys.stderr)
    raise SystemExit(2)
listing = subprocess.run(['nm', '-g', '--defined-only', '-j', str(loading)], capture_output=True, text=True, check=True).stdout
probe = PROBE
for placeholder, member in (('PARSED_FILES', '11parsedFiles'), ('LOADS', '5loads')):
    addressor = re.search(r'^(_\$s\w*DCMPixParsedFileCache\w*%s\w*vau)$' % member, listing, re.M)
    if addressor is None:
        print('FAIL: DCMPix+Loading.o has no DCMPixParsedFileCache.%s' % member.lstrip('0123456789'))
        raise SystemExit(1)
    probe = probe.replace(placeholder, addressor.group(1))

with tempfile.TemporaryDirectory(prefix='horos-load-count-') as name:
    work = Path(name)
    (work / 'files').mkdir()
    (work / 'probe.mm').write_text(probe)
    run = app_object_probe.link_and_run(work, [work / 'probe.mm'], [obj], [work / 'files'], probe_classes=('RaisingGroup',))
if run.returncode:
    sys.stderr.write(run.stdout[-2000:] + run.stderr[-6000:] + '\n(exit %d)\n' % run.returncode)
    print('FAIL: a load that raises inside its counted scope stays counted (%s)' % arguments.configuration)
    raise SystemExit(1)
print('PASS: %s (%s)' % (run.stdout.strip(), arguments.configuration))
