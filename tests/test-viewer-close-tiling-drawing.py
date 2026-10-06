#!/usr/bin/env python3
"""Closing a tiled viewer stops every view's drawing before its volume goes.

-[ViewerController windowWillClose:] posts OsirixCloseViewerNotification, on
which a 3D MPR opened on the viewer closes, and then -finalizeSeriesViewing
releases the viewer's volume: the fImage of every view's curDCM points into it.
Before the fix only `imageView`, the first view of the tiling, stopped drawing.
With the viewer in a 1 x 2 tiling and the MPR open, the second view still drew
a frame after the close, and copied the released volume in
-horosPlanarSnapshotDrawnIn: (SIGSEGV).

The check runs the real -windowWillClose: of ViewerController.m, compiled into
an Objective-C double of the viewer (manual retain/release, as the app) with
the instance variables and collaborators the method reaches. The views are
doubles whose -drawRect: begins with the real first statement of
-[DCMView drawRect:], the `drawing` guard, and then reads their image. The
viewer has a 1 x 2 tiling over one volume; an observer of the close notification
stands for the MPR and marks every view of the viewer for display, and the
driver then draws the marked views, as the run loop's display pass would.

- Control: before the close, both views draw, reading the live volume, so the
  probe sees a draw.
- After the close: the volume was released, no view read it, and no view of
  the tiling is left drawable.

`--revision <git revision>` reads both sources at that revision: the negative
control (a revision from before the fix fails on the second view).
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--revision')
args = parser.parse_args()


def read(path):
    if args.revision:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{args.revision}:{path}']).decode('latin1')
    return (ROOT/path).read_bytes().decode('latin1')


viewer = read('Horos/Sources/ViewerController.m')
view = read('Horos/Sources/DCMView.m')


def method(source, signature):
    at = source.index(signature)
    end = re.search(r'\n[-+]\s*\(', source[at+len(signature):])
    assert end, signature
    return source[at:at+len(signature)+end.start()]


close = method(viewer, '- (void)windowWillClose:(NSNotification *)notification')
draw = method(view, '- (void) drawRect:(NSRect) r')
guard = draw[draw.index('{')+1:].strip().split('\n', 1)[0].strip()
assert re.fullmatch(r'if\(\s*drawing\s*==\s*NO\s*\)\s*return;', guard), guard

source = r"""
#pragma clang diagnostic ignored "-Wobjc-method-access"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#define MAXSCREENS 10

NSString * const OsirixCloseViewerNotification = @"CloseViewerNotification";

// The volume the viewer releases in -finalizeSeriesViewing. It stays allocated
// so that a read after the release is counted, not a crash.
static float *volume;
static BOOL volumeReleased;
static unsigned drawsOfLiveVolume, readsOfReleasedVolume;

@interface DCMPix : NSObject
@property(nonatomic) float *fImage;
@end
@implementation DCMPix
@end

@interface DCMView : NSObject {
    BOOL drawing;
}
@property BOOL drawing;
@property(retain) DCMPix *curDCM;
@property BOOL marked;
- (void)stopROIEditingForce:(BOOL)force;
- (void)setWLWW:(float)wl :(float)ww;
- (void)drawRect:(NSRect)r;
@end
@implementation DCMView
@synthesize drawing;
- (void)stopROIEditingForce:(BOOL)force {}
- (void)setWLWW:(float)wl :(float)ww {}
// -[DCMView drawRect:]'s own first statement, then the image's pixels, as
// -horosPlanarSnapshotDrawnIn: copies them.
- (void)drawRect:(NSRect)r
{
    GUARD
    volatile float first = self.curDCM.fImage[0]; (void)first;
    if (volumeReleased) ++readsOfReleasedVolume; else ++drawsOfLiveVolume;
}
@end

@interface SeriesView : NSObject
@property(retain) NSMutableArray *imageViews;
@end
@implementation SeriesView
@end

@interface HorosViewerSeriesLoad : NSObject
- (void)requestCancel;
- (void)close;
@end
@implementation HorosViewerSeriesLoad
- (void)requestCancel {}
- (void)close {}
@end

@interface OSIEnvironment : NSObject
+ (instancetype)sharedEnvironment;
- (void)removeViewerController:(id)viewer;
@end
@implementation OSIEnvironment
+ (instancetype)sharedEnvironment { return nil; }
- (void)removeViewerController:(id)viewer {}
@end

@interface HorosViewerBindingTeardown : NSObject
+ (void)unbindFileOwnerBindingsOn:(id)owner;
@end
@implementation HorosViewerBindingTeardown
+ (void)unbindFileOwnerBindingsOn:(id)owner {}
@end
static void HorosDetachAutounbinder(id owner) {}

@interface AppController : NSObject
+ (instancetype)sharedAppController;
+ (void)setUSETOOLBARPANEL:(BOOL)value;
@end
@implementation AppController
+ (instancetype)sharedAppController { return nil; }
+ (void)setUSETOOLBARPANEL:(BOOL)value {}
@end

@interface WindowLayoutManager : NSObject
+ (instancetype)sharedWindowLayoutManager;
- (void)setCurrentHangingProtocolForModality:(id)modality description:(id)description;
@end
@implementation WindowLayoutManager
+ (instancetype)sharedWindowLayoutManager { return nil; }
- (void)setCurrentHangingProtocolForModality:(id)modality description:(id)description {}
@end

@interface ThumbnailsListPanel : NSWindowController
- (void)thumbnailsListWillClose:(id)view;
@end
@implementation ThumbnailsListPanel
- (void)thumbnailsListWillClose:(id)view {}
@end

static ThumbnailsListPanel *thumbnailsListPanel[MAXSCREENS];
static int delayedTileWindows = NO;
static BOOL SYNCSERIES = NO;
static int numberOf2DViewer = 1;
static NSMutableArray *arrayOf2DViewers = nil;

@interface ViewerController : NSWindowController {
@public
    NSScrollView *previewMatrixScrollView;
    NSSplitView *splitView;
    ViewerController *blendingController;
    DCMView *imageView;
    SeriesView *seriesView;
    BOOL FullScreenOn, windowWillClose;
    NSButton *subCtrlOnOff;
    NSTimer *highLightedTimer, *movieTimer, *timer, *t12BitTimer;
    NSWindowController *toolbarPanel;
    NSMatrix *previewMatrix;
}
@property(retain) HorosViewerSeriesLoad *horosSeriesLoad;
@property(retain) id flagListPODComparatives;
+ (void)clearFrontMost2DViewerCache;
- (void)cancelOpeningScaleToFit;
- (void)fullScreenMenu:(id)sender;
- (void)SyncSeries:(id)sender;
- (void)finalizeSeriesViewing;
@end

@implementation ViewerController
+ (void)clearFrontMost2DViewerCache {}
- (void)cancelOpeningScaleToFit {}
- (void)fullScreenMenu:(id)sender {}
- (void)SyncSeries:(id)sender {}
// What the app's releases for the views: the volume their fImage points into.
- (void)finalizeSeriesViewing { volumeReleased = YES; }

CLOSE

@end

static void fail(const char *message) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }

// The run loop's display pass: every view marked for display draws.
static void displayPass(NSArray *views) {
    for (DCMView *v in views)
        if (v.marked) { v.marked = NO; [v drawRect:NSZeroRect]; }
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    volume = calloc(2 * 16, sizeof(float));
    ViewerController *viewer = [[ViewerController alloc] initWithWindow:nil];
    viewer.horosSeriesLoad = [[HorosViewerSeriesLoad new] autorelease];
    NSMutableArray *views = [NSMutableArray array];
    for (int i = 0; i < 2; ++i) {
        DCMPix *pix = [[DCMPix new] autorelease]; pix.fImage = volume + 16 * i;
        DCMView *v = [[DCMView new] autorelease]; v.curDCM = pix; v.drawing = YES;
        [views addObject:v];
    }
    viewer->seriesView = [SeriesView new]; viewer->seriesView.imageViews = views;
    viewer->imageView = [views[0] retain];
    arrayOf2DViewers = [[NSMutableArray alloc] initWithObjects:viewer, nil];

    // The MPR opened on the viewer: it closes on the viewer's close notice, and
    // its closing marks the viewer's views for display.
    id mpr = [NSNotificationCenter.defaultCenter addObserverForName:OsirixCloseViewerNotification object:viewer queue:nil
        usingBlock:^(NSNotification *note) { for (DCMView *v in views) v.marked = YES; }];

    for (DCMView *v in views) v.marked = YES;
    displayPass(views);
    if (drawsOfLiveVolume != 2) fail("the probe did not see both views draw the live volume");

    [viewer retain];  // the reference -windowWillClose: gives up with its autorelease
    [viewer windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:nil]];
    [NSNotificationCenter.defaultCenter removeObserver:mpr];
    if (!volumeReleased) fail("the close did not release the volume");
    displayPass(views);
    if (readsOfReleasedVolume) {
        fprintf(stderr, "FAIL: %u view(s) of the tiling drew the released volume after the close\n", readsOfReleasedVolume);
        exit(1);
    }
    for (DCMView *v in views)
        if (v.drawing) fail("a view of the tiling is still drawable after the close");
    printf("PASS: closing a 1 x 2 tiling stops both views before the volume is released\n");
} return 0; }
""".replace('GUARD', guard).replace('CLOSE', close)

with tempfile.TemporaryDirectory(prefix='horos-close-tiling-') as tmp:
    folder = Path(tmp)
    (folder/'Check.m').write_text(source, encoding='latin1')
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-g', '-w', str(folder/'Check.m'),
                    '-framework', 'Cocoa', '-o', str(folder/'check')], check=True)
    result = subprocess.run([str(folder/'check')], timeout=30)
    sys.exit(1 if result.returncode else 0)
