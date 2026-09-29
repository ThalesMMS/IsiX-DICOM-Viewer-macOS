#!/usr/bin/env python3
"""A viewer opened before OSIEnvironmentActivated was turned on closes without
aborting the Debug build (#772).

+[OSIEnvironment sharedEnvironment] creates the environment only once the
OSIEnvironmentActivated default is on, and -[ViewerController initWithPix:...]
adds itself to it through that accessor. A viewer opened while the default was
off was therefore never added. When it closed after the default was turned
on, -[ViewerController windowWillClose:] asked the new environment to remove
it, and -[OSIEnvironment(Private) removeViewerController:] failed its
`assert` "make sure this one was added!": __assert_rtn, and the Debug build
aborted. Release, with NDEBUG, went on with a nil volume window and still told
KVO and notification observers that the open volume windows had changed.

The fix: removing a viewer that was never added returns before touching
anything, so nothing aborts and observers hear nothing. A viewer that was
added is removed as before.

OSIEnvironment and OSIVolumeWindow are compiled as they are, without NDEBUG
and unoptimized as in the Debug build, under AddressSanitizer, with doubles for
ViewerController, DCMView, OSIROIManager and OSIFloatVolumeData. Since #828 they
are Swift: OSIEnvironment.swift, OSIVolumeWindow.swift and their +CAPI.m, with
their headers, compiled by swiftc against a bridging header of the doubles; the
driver and the doubles stay Objective-C with manual retain/release. A revision
before #828 compiles the former Objective-C sources. The driver calls the environment as ViewerController does:
the accessor, then -addViewerController: at the end of init and
-removeViewerController: in -windowWillClose:. The default lives only in the
harness's registration domain; nothing is written to disk.
- before-activation: the sequence of the issue. A viewer opens with the
  default off, the default goes on, a second viewer opens, the first closes,
  then the second. The first must close without an abort and without a change
  notice; the second must be removed with one.
- after-activation: a viewer opened and closed with the default on is added
  and removed, its volume window reports closed, and observers hear each
  change once. This passes before the fix too.
- closed-twice: a second -windowWillClose: for the same viewer is ignored.
- alloc-init (#857): +allocWithZone: answers the shared environment, and
  -init ran again on it and emptied its list of volume windows. With a viewer
  open, [[OSIEnvironment alloc] init] must return the shared environment with
  the viewer's volume window still listed, and closing the viewer must remove
  it with one change heard.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(SKIPPED)

REAL_SOURCES = [
    'Horos/Sources/OSIEnvironment.m',
    'Horos/Sources/OSIVolumeWindow.m',
]
# Since #828.
SWIFT_SOURCES = [
    'Horos/Sources/OSIEnvironment.swift',
    'Horos/Sources/OSIVolumeWindow.swift',
]
SWIFT_CAPI = [
    'Horos/Sources/OSIEnvironment+CAPI.m',
    'Horos/Sources/OSIVolumeWindow+CAPI.m',
]


def exists(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision}:{path}'],
                              capture_output=True).returncode == 0
    return (root / path).is_file()


swift = not exists(REAL_SOURCES[0])
REAL_HEADERS = [
    'Horos/Sources/OSIEnvironment.h',
    'Horos/Sources/OSIEnvironment+Private.h',
    'Horos/Sources/OSIVolumeWindow.h',
    'Horos/Sources/OSIVolumeWindow+Private.h',
]

# The app headers the real sources import, reduced to what they use.
STUB_HEADERS = {
    'ViewerController.h': r'''
#import <Cocoa/Cocoa.h>
@class DCMView;
@interface ViewerController : NSWindowController
- (BOOL)isEverythingLoaded;
- (short)maxMovieIndex;
- (NSMutableArray *)pixList:(long)i;
- (NSData *)volumeData:(long)i;
- (void)computeInterval;
- (DCMView *)imageView;
- (NSArray *)imageViews;
@end
''',
    'DCMView.h': r'''
#import <Cocoa/Cocoa.h>
@interface DCMView : NSView
- (id)windowController;
@end
''',
    'OSIROIManager.h': r'''
#import <Cocoa/Cocoa.h>
@interface OSIROI : NSObject
@end
@class OSIVolumeWindow;
@protocol OSIROIManagerDelegate <NSObject>
@optional
@end
@interface OSIROIManager : NSObject
@property (nonatomic, readwrite, assign) id <OSIROIManagerDelegate> delegate;
- (id)initWithVolumeWindow:(OSIVolumeWindow *)volumeWindow;
@end
''',
    'OSIROIManager+Private.h': r'''
#import "OSIROIManager.h"
@class DCMView;
@interface OSIROIManager (Private)
- (void)drawInDCMView:(DCMView *)dcmView;
@end
''',
    'OSIFloatVolumeData.h': r'''
#import <Cocoa/Cocoa.h>
@interface OSIFloatVolumeData : NSObject
- (id)initWithWithPixList:(NSArray *)pixList volume:(NSData *)volume;
- (BOOL)isDataValid;
- (void)invalidateData;
@end
''',
    'Notifications.h': r'''
#import <Cocoa/Cocoa.h>
extern NSString * const OsirixViewerControllerDidLoadImagesNotification;
extern NSString * const OsirixViewerControllerWillFreeVolumeDataNotification;
extern NSString * const OsirixViewerControllerDidAllocateVolumeDataNotification;
''',
    # The app's one brings in ViewerController.h, which OSIVolumeWindow.m relies on.
    'pluginSDKAdditions.h': '#import "ViewerController.h"\n',
}

DOUBLES = r'''
#import "ViewerController.h"
#import "DCMView.h"
#import "OSIROIManager+Private.h"
#import "OSIFloatVolumeData.h"
#import "Notifications.h"

NSString * const OsirixViewerControllerDidLoadImagesNotification = @"OsirixViewerControllerDidLoadImagesNotification";
NSString * const OsirixViewerControllerWillFreeVolumeDataNotification = @"OsirixViewerControllerWillFreeVolumeDataNotification";
NSString * const OsirixViewerControllerDidAllocateVolumeDataNotification = @"OsirixViewerControllerDidAllocateVolumeDataNotification";

@implementation ViewerController
- (BOOL)isEverythingLoaded { return YES; }
- (short)maxMovieIndex { return 1; }
- (NSMutableArray *)pixList:(long)i { return nil; }
- (NSData *)volumeData:(long)i { return nil; }
- (void)computeInterval {}
- (DCMView *)imageView { return nil; }
- (NSArray *)imageViews { return @[]; }
@end

@implementation DCMView
- (id)windowController { return nil; }
@end

@implementation OSIROIManager
@synthesize delegate;
- (id)initWithVolumeWindow:(OSIVolumeWindow *)volumeWindow { return [super init]; }
- (void)drawInDCMView:(DCMView *)dcmView {}
@end

#ifndef HOROS_SWIFT_HARNESS
@implementation OSIFloatVolumeData
- (id)initWithWithPixList:(NSArray *)pixList volume:(NSData *)volume { return [super init]; }
- (BOOL)isDataValid { return NO; }
- (void)invalidateData {}
@end
#endif

@implementation OSIROI
@end
'''

# OSIFloatVolumeData is Swift in the application; its stand-in has its selectors.
FLOAT_VOLUME_SWIFT = r'''
import Foundation

@objc(OSIFloatVolumeData)
public final class OSIFloatVolumeData: NSObject {
    @objc(initWithWithPixList:volume:)
    public init(withPixList pixList: NSArray?, volume: NSData?) { super.init() }
    @objc public func isDataValid() -> Bool { return false }
    @objc public func invalidateData() {}
}
'''

BRIDGE = r'''
#define HOROS_BRIDGING_HEADER 1
#import "ViewerController.h"
#import "DCMView.h"
#import "OSIROIManager.h"
#import "OSIROIManager+Private.h"
#import "Notifications.h"
#import "OSIEnvironment.h"
#import "OSIVolumeWindow.h"
'''

DRIVER = r'''
#import "OSIEnvironment.h"
#import "OSIEnvironment+Private.h"
#import "OSIVolumeWindow.h"
#import "ViewerController.h"
#include <stdio.h>
#include <stdlib.h>

static void fail(NSString *message)
{
    printf("FAIL: %s\n", message.UTF8String);
    fflush(stdout);
    exit(1);
}

static void step(const char *what)
{
    // Printed before each call, so an abort shows where it happened.
    printf("step: %s\n", what);
    fflush(stdout);
}

// Counts what observers of the environment hear.
@interface Listener : NSObject {
@public
    int kvo, updates, closes;
}
@end

@implementation Listener
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    kvo++;
}
- (void)updated:(NSNotification *)notification { updates++; }
- (void)closed:(NSNotification *)notification { closes++; }
@end

static void setActivated(BOOL on)
{
    // The registration domain is volatile: nothing reaches a preferences file.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ @"OSIEnvironmentActivated": @(on) }];
}

// As the end of -[ViewerController initWithPix:withFiles:withVolume:] does.
static ViewerController *openViewer(void)
{
    ViewerController *viewer = [[ViewerController alloc] init];
    [[OSIEnvironment sharedEnvironment] addViewerController:viewer];
    return viewer;
}

// As -[ViewerController windowWillClose:] does.
static void closeViewer(ViewerController *viewer)
{
    [[OSIEnvironment sharedEnvironment] removeViewerController:viewer];
}

static Listener *startListening(OSIEnvironment *environment)
{
    Listener *listener = [[Listener alloc] init];
    [environment addObserver:listener forKeyPath:@"openVolumeWindows" options:0 context:NULL];
    [[NSNotificationCenter defaultCenter] addObserver:listener selector:@selector(updated:) name:OSIEnvironmentOpenVolumeWindowsDidUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:listener selector:@selector(closed:) name:OSIVolumeWindowDidCloseNotification object:nil];
    return listener;
}

static void stopListening(OSIEnvironment *environment, Listener *listener)
{
    [environment removeObserver:listener forKeyPath:@"openVolumeWindows"];
    [[NSNotificationCenter defaultCenter] removeObserver:listener];
    [listener release];
}

static void expectHeard(Listener *listener, int kvo, int updates, int closes, NSString *when)
{
    if (listener->kvo != kvo || listener->updates != updates || listener->closes != closes)
        fail([NSString stringWithFormat:@"%@: observers heard %d KVO changes, %d update and %d close notifications; expected %d, %d and %d",
              when, listener->kvo, listener->updates, listener->closes, kvo, updates, closes]);
}

// Opens and closes a viewer with the environment active; returns its listener
// with one add and one removal heard.
static Listener *openAndClose(OSIEnvironment *environment, ViewerController **outViewer)
{
    Listener *listener = startListening(environment);
    step("open a viewer with the environment active");
    ViewerController *viewer = openViewer();
    OSIVolumeWindow *volumeWindow = [[environment volumeWindowForViewerController:viewer] retain];
    if (volumeWindow == nil || [[environment openVolumeWindows] count] != 1)
        fail(@"a viewer opened with the environment active was not added");
    if (![volumeWindow isOpen] || [volumeWindow viewerController] != viewer)
        fail(@"the added volume window is not open on its viewer");
    expectHeard(listener, 1, 1, 0, @"after the add");

    step("close it");
    closeViewer(viewer);
    if ([[environment openVolumeWindows] count] != 0 || [environment volumeWindowForViewerController:viewer])
        fail(@"the closed viewer is still in the environment");
    if ([volumeWindow isOpen] || [volumeWindow viewerController] != nil)
        fail(@"the volume window of the closed viewer still reports open");
    expectHeard(listener, 2, 2, 1, @"after the removal");
    [volumeWindow release];
    *outViewer = viewer;
    return listener;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2)
            fail(@"no case given");
        NSString *which = @(argv[1]);
        if ([[NSUserDefaults standardUserDefaults] objectForKey:@"OSIEnvironmentActivated"])
            fail(@"OSIEnvironmentActivated is already set outside the registration domain; the harness cannot control it");

        if ([which isEqualToString:@"before-activation"]) {
            setActivated(NO);
            step("open a viewer with OSIEnvironmentActivated off");
            ViewerController *early = openViewer();
            if ([OSIEnvironment sharedEnvironment] != nil)
                fail(@"the environment exists with OSIEnvironmentActivated off");

            setActivated(YES);
            OSIEnvironment *environment = [OSIEnvironment sharedEnvironment];
            if (environment == nil)
                fail(@"no environment with OSIEnvironmentActivated on");
            if ([[environment openVolumeWindows] count] != 0)
                fail(@"the new environment lists viewers it was never given");
            Listener *listener = startListening(environment);

            step("open a second viewer with it on");
            ViewerController *late = openViewer();
            OSIVolumeWindow *lateWindow = [environment volumeWindowForViewerController:late];
            if (lateWindow == nil)
                fail(@"the viewer opened after activation was not added");
            expectHeard(listener, 1, 1, 0, @"after the second viewer opened");

            step("close the viewer opened before activation");
            closeViewer(early);
            if ([[environment openVolumeWindows] count] != 1 || [environment volumeWindowForViewerController:late] != lateWindow)
                fail(@"closing the unregistered viewer changed the registered ones");
            if ([environment volumeWindowForViewerController:early] != nil)
                fail(@"the unregistered viewer has a volume window after closing");
            if (![lateWindow isOpen])
                fail(@"closing the unregistered viewer closed the other one's volume window");
            expectHeard(listener, 1, 1, 0, @"after the unregistered viewer closed");

            step("close the viewer opened after activation");
            closeViewer(late);
            if ([[environment openVolumeWindows] count] != 0)
                fail(@"the registered viewer was not removed");
            expectHeard(listener, 2, 2, 1, @"after the registered viewer closed");

            stopListening(environment, listener);
            [early release];
            [late release];
            printf("the unregistered viewer closed unheard; the registered one was removed with one change\n");
        } else if ([which isEqualToString:@"after-activation"]) {
            setActivated(YES);
            OSIEnvironment *environment = [OSIEnvironment sharedEnvironment];
            if (environment == nil)
                fail(@"no environment with OSIEnvironmentActivated on");
            ViewerController *viewer = nil;
            Listener *listener = openAndClose(environment, &viewer);
            stopListening(environment, listener);
            [viewer release];
            printf("added and removed, with one change heard each time\n");
        } else if ([which isEqualToString:@"closed-twice"]) {
            setActivated(YES);
            OSIEnvironment *environment = [OSIEnvironment sharedEnvironment];
            if (environment == nil)
                fail(@"no environment with OSIEnvironmentActivated on");
            ViewerController *viewer = nil;
            Listener *listener = openAndClose(environment, &viewer);
            step("close the same viewer again");
            closeViewer(viewer);
            expectHeard(listener, 2, 2, 1, @"after the second close");
            stopListening(environment, listener);
            [viewer release];
            printf("the second close was ignored\n");
        } else if ([which isEqualToString:@"alloc-init"]) {
            setActivated(YES);
            OSIEnvironment *environment = [OSIEnvironment sharedEnvironment];
            if (environment == nil)
                fail(@"no environment with OSIEnvironmentActivated on");
            ViewerController *viewer = openViewer();
            OSIVolumeWindow *volumeWindow = [environment volumeWindowForViewerController:viewer];
            if (volumeWindow == nil)
                fail(@"the viewer was not added");

            step("alloc and init an environment");
            OSIEnvironment *again = [[OSIEnvironment alloc] init];
            if (again != environment)
                fail(@"[[OSIEnvironment alloc] init] is not the shared environment");
            if ([[environment openVolumeWindows] count] != 1 || [environment volumeWindowForViewerController:viewer] != volumeWindow)
                fail([NSString stringWithFormat:@"after [[OSIEnvironment alloc] init] the environment lists %lu volume windows, and the viewer's is %@",
                      (unsigned long)[[environment openVolumeWindows] count],
                      [environment volumeWindowForViewerController:viewer] == volumeWindow ? @"there" : @"gone"]);
            [again release];

            Listener *listener = startListening(environment);
            step("close the viewer");
            closeViewer(viewer);
            if ([[environment openVolumeWindows] count] != 0)
                fail(@"the viewer was not removed");
            expectHeard(listener, 1, 1, 1, @"after the viewer closed");
            stopListening(environment, listener);
            [viewer release];
            printf("alloc/init answered the shared environment, which kept the viewer's volume window\n");
        } else {
            fail([NSString stringWithFormat:@"unknown case %@", which]);
        }
    }
    return 0;
}
'''

CASES = [
    ('before-activation', 'a viewer opened before activation closes without an abort or a change notice'),
    ('after-activation', 'a viewer opened after activation is added and removed'),
    ('closed-twice', 'a second close of the same viewer is ignored'),
    ('alloc-init', '[[OSIEnvironment alloc] init] answers the shared environment without emptying it'),
]


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


failures = []
with tempfile.TemporaryDirectory(prefix='horos-osienvironment-') as tmp:
    tmp = Path(tmp)
    objc_sources = SWIFT_CAPI if swift else REAL_SOURCES
    for path in REAL_HEADERS + objc_sources + (SWIFT_SOURCES if swift else []):
        (tmp / Path(path).name).write_bytes(source(path))
    for name, text in STUB_HEADERS.items():
        if swift and name == 'OSIFloatVolumeData.h':
            # The class is Swift: headers name it, the generated header declares it.
            text = '#import <Cocoa/Cocoa.h>\n@class OSIFloatVolumeData;\n'
        (tmp / name).write_text(text)
    (tmp / 'Doubles.m').write_text(DOUBLES)
    (tmp / 'main.m').write_text(DRIVER)
    # A name of its own, so its defaults domain is nobody else's.
    harness = tmp / 'horos-osienvironment-harness'
    objects = []
    defines = ['-DHOROS_SWIFT_HARNESS=1'] if swift else []
    try:
        if swift:
            (tmp / 'bridge.h').write_text(BRIDGE)
            (tmp / 'OSIFloatVolumeData.swift').write_text(FLOAT_VOLUME_SWIFT)
            # The Debug build: unoptimized, so Swift's asserts are live.
            run(['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-module-name', 'Horos', '-Onone', '-g',
                 '-sanitize=address', '-import-objc-header', str(tmp / 'bridge.h'), '-Xcc', '-I' + str(tmp),
                 '-emit-objc-header', '-emit-objc-header-path', str(tmp / 'Horos-Swift.h'),
                 '-c', *[str(tmp / Path(path).name) for path in SWIFT_SOURCES], str(tmp / 'OSIFloatVolumeData.swift'),
                 '-o', str(tmp / 'swift.o')])
            objects.append(str(tmp / 'swift.o'))
        for name in [Path(path).name for path in objc_sources] + ['Doubles.m', 'main.m']:
            obj = tmp / (Path(name).stem + '.o')
            # The Debug build: manual retain/release, DEBUG=1 and no NDEBUG, so
            # the asserts are live; the app's prefix header brings in Cocoa.
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-fno-objc-arc',
                 '-DDEBUG=1', *defines, '-O0', '-g', '-fsanitize=address', '-iquote', str(tmp), '-I', str(tmp),
                 '-c', str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        linker = ['xcrun', 'swiftc', '-sanitize=address'] if swift else ['xcrun', 'clang', '-fsanitize=address']
        run([*linker, *objects, '-framework', 'Cocoa', '-o', str(harness)])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
    for case, claim in CASES:
        try:
            result = subprocess.run([str(harness), case], capture_output=True, text=True, timeout=60, env=env)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        if result.returncode == 0:
            lines = result.stdout.strip().splitlines()
            print('ok:', claim, '-', lines[-1] if lines else 'exit 0')
            continue
        lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
        steps = [line[len('step: '):] for line in lines if line.startswith('step: ')]
        where = f' at "{steps[-1]}"' if steps else ''
        detail = next((line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')), None) or \
            next((line.strip() for line in lines if 'Assertion failed' in line), None) or \
            next((line for line in lines if 'ERROR: AddressSanitizer' in line), None) or \
            (lines[-1] if lines else f'exit {result.returncode}')
        failures.append(f'{claim}{where}: {detail} (exit {result.returncode})')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a viewer the environment never added closes without an abort; added viewers are removed as before; '
      '[[OSIEnvironment alloc] init] answers the shared environment and keeps its volume windows')
