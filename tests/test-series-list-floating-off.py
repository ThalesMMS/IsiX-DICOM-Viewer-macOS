#!/usr/bin/env python3
"""Turning the floating series list off docks the list on any edge without a crash.

With two viewers, the floating list and the list's placement at the bottom,
writing UseFloatingThumbnailsList = NO crashed the app in a recursion between
the viewers: each re-placed list resized its split view, -splitViewDidResizeSubviews:
showed or hid the other viewer's list to match, and its guard was reset by the
reentrant call it was meant to stop, so the other viewer answered back. The
show and hide of -setMatrixVisible: still took the split view's first pane for
the dock and set its width: with the list on the right or at the bottom it hid
the image pane.

The viewer's own methods (-updateSeriesListMode, -setMatrixVisible:,
-matrixIsVisible, the KVO observer of SeriesListVisible and the split view
delegate methods) are taken from ViewerController.m and compiled with clang
into a stand-in ViewerController, over the real SeriesListLayout compiled with
swiftc. Two viewers switch from the floating list to the docked list, as the
app's preference handler does, on each edge; then one viewer hides and shows
its list. A split view resize nested deeper than the switch needs is the
recursion. `<git revision>` as an optional argument reads both sources from
that revision, the negative control.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import harness_defaults  # the harness's preferences stay in its own process

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    encoding = 'utf-8' if path.endswith('.swift') else 'latin1'
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode(encoding)
    return (root / path).read_bytes().decode(encoding)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(2)

layout = read('Horos/Sources/SeriesListLayout.swift')
viewer = read('Horos/Sources/ViewerController.m')


def method(signature):
    match = re.search(r'\n(' + re.escape(signature) + r'.*?\n\})\n', viewer, re.S)
    if match is None:
        print(f'FAIL: {signature} is gone from ViewerController.m; this test needs a new look')
        sys.exit(1)
    return match.group(1)


methods = '\n\n'.join(method(s) for s in (
    '- (CGFloat) horosSeriesListThickness',
    '- (void) updateSeriesListMode',
    '- (void) setMatrixVisible: (BOOL) visible',
    '-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object',
    '- (void)splitViewDidResizeSubviews:(NSNotification *) notification',
    '- (CGFloat)splitView:(NSSplitView *)sender constrainSplitPosition:',
    '-(BOOL) matrixIsVisible',
    '-(void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize',
))
# File-level state the methods share, declared among them.
region = viewer[viewer.index('- (CGFloat) horosSeriesListThickness'):viewer.index('-(void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:')]
statics = '\n'.join(re.findall(r'^static [A-Za-z]+ \w+ = [^;]+;$', region, re.M))

objc = r'''#import <Cocoa/Cocoa.h>
#import "SeriesListLayoutCheck-Swift.h"

static void check(BOOL value, NSString *message)
{
    if( !value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

/// Counts nested split view resizes: switching the list's mode needs a few,
/// a recursion between the viewers needs thousands.
static int depth = 0;
@interface CountingSplitView : NSSplitView
@end
@implementation CountingSplitView
- (void) resizeSubviewsWithOldSize: (NSSize) oldSize
{
    if( ++depth > 12) { fprintf(stderr, "FAIL: the viewers resize each other's split view in a recursion\n"); exit(1); }
    [super resizeSubviewsWithOldSize: oldSize];
    depth--;
}
@end

@interface ThumbnailCell : NSButtonCell
+ (float) thumbnailCellWidth;
@end
@implementation ThumbnailCell
+ (float) thumbnailCellWidth { return 100; }
@end

@interface BrowserController : NSObject
+ (int) _scrollerStyle: (NSScroller*) scroller;
@end
@implementation BrowserController
+ (int) _scrollerStyle: (NSScroller*) scroller { return 1; }
@end

static NSMutableArray *viewers = nil;

@interface ViewerController : NSObject <NSSplitViewDelegate>
{
@public
    NSSplitView *splitView;
    NSMatrix *previewMatrix;
    NSScrollView *previewMatrixScrollView;
    NSView *imagePane;
    BOOL windowWillClose, FullScreenOn, needsToBuildSeriesMatrix;
}
@end

@implementation ViewerController
+ (NSMutableArray*) get2DViewers { return viewers; }
+ (NSMutableArray*) getDisplayed2DViewers { return viewers; }
- (void) buildMatrixPreview: (BOOL) showSelected { needsToBuildSeriesMatrix = NO; }

- (id) init
{
    if( self = [super init])
    {
        NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 800, 600) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: YES];
        [window setReleasedWhenClosed: NO];
        splitView = [[CountingSplitView alloc] initWithFrame: NSMakeRect(0, 0, 800, 600)];
        [splitView setVertical: YES];
        NSView *dock = [[NSView alloc] initWithFrame: NSMakeRect(0, 0, 100, 600)];
        imagePane = [[NSView alloc] initWithFrame: NSMakeRect(109, 0, 691, 600)];
        [splitView addSubview: dock];
        [splitView addSubview: imagePane];
        previewMatrixScrollView = [[NSScrollView alloc] initWithFrame: NSMakeRect(0, 0, 100, 600)];
        previewMatrix = [[NSMatrix alloc] initWithFrame: NSMakeRect(0, 0, 100, 600) mode: NSRadioModeMatrix cellClass: [ThumbnailCell class] numberOfRows: 5 numberOfColumns: 1];
        [previewMatrix setCellSize: NSMakeSize(100, 120)];
        [previewMatrixScrollView setDocumentView: previewMatrix];
        [dock addSubview: previewMatrixScrollView];
        [[window contentView] addSubview: splitView];
        [self updateSeriesListMode];
        [splitView setDelegate: self];
        [splitView adjustSubviews];
        [[NSUserDefaults standardUserDefaults] addObserver: self forKeyPath: @"SeriesListVisible" options: NSKeyValueObservingOptionNew context: nil];
    }
    return self;
}

METHODS
@end

/// The list as the user sees it on that edge: the dock that holds the list is
/// shown with its thickness, and the image pane takes the rest.
static void checkShown( ViewerController *v, int i, HorosSeriesListPlacement placement, NSString *step)
{
    NSString *where = [NSString stringWithFormat: @"%@, %@, viewer %d", step, [HorosSeriesListLayout nameOfPlacement: placement], i];
    NSArray *panes = [v->splitView subviews];
    NSView *dock = [v->previewMatrixScrollView superview];
    BOOL across = placement == HorosSeriesListPlacementTop || placement == HorosSeriesListPlacementBottom;
    BOOL first = placement == HorosSeriesListPlacementLeft || placement == HorosSeriesListPlacementTop;
    check( [panes count] == 2 && dock == [panes objectAtIndex: first ? 0 : 1], [where stringByAppendingString: @": the list is docked on its edge"]);
    check( ![v->imagePane isHiddenOrHasHiddenAncestor], [where stringByAppendingString: @": the image pane is visible"]);
    check( ![dock isHidden], [where stringByAppendingString: @": the dock is shown"]);
    CGFloat thickness = [v horosSeriesListThickness];
    CGFloat shown = across ? dock.frame.size.height : dock.frame.size.width;
    // Down a side, the divider position adds a point, or a legacy scroller's width.
    check( thickness > 0 && shown >= thickness && shown < thickness + 20, [where stringByAppendingFormat: @": the dock is as thick as the strip (%g, not %g)", shown, thickness]);
    CGFloat image = across ? v->imagePane.frame.size.height : v->imagePane.frame.size.width;
    CGFloat whole = across ? v->splitView.bounds.size.height : v->splitView.bounds.size.width;
    check( image > whole / 2, [where stringByAppendingFormat: @": the image pane takes the rest (%g of %g)", image, whole]);
    check( [v matrixIsVisible], [where stringByAppendingString: @": the viewer sees its list shown"]);
}

static void checkHidden( ViewerController *v, int i, HorosSeriesListPlacement placement, NSString *step)
{
    NSString *where = [NSString stringWithFormat: @"%@, %@, viewer %d", step, [HorosSeriesListLayout nameOfPlacement: placement], i];
    BOOL across = placement == HorosSeriesListPlacementTop || placement == HorosSeriesListPlacementBottom;
    check( ![v->imagePane isHiddenOrHasHiddenAncestor], [where stringByAppendingString: @": the image pane is visible, not the list hidden in its place"]);
    check( [[v->previewMatrixScrollView superview] isHidden], [where stringByAppendingString: @": the dock is hidden"]);
    CGFloat image = across ? v->imagePane.frame.size.height : v->imagePane.frame.size.width;
    CGFloat whole = across ? v->splitView.bounds.size.height : v->splitView.bounds.size.width;
    check( fabs( image - whole) < 1, [where stringByAppendingFormat: @": the image pane fills the viewer (%g of %g)", image, whole]);
    check( ![v matrixIsVisible], [where stringByAppendingString: @": the viewer sees its list hidden"]);
}

static void forget( void)
{
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName: [[NSProcessInfo processInfo] processName]];
}

int main( void)
{
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        atexit( forget);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
        [defaults setBool: YES forKey: @"SeriesListVisible"];
        [defaults setBool: NO forKey: @"AUTOHIDEMATRIX"];
        viewers = [NSMutableArray array];
        [viewers addObject: [[ViewerController alloc] init]];
        [viewers addObject: [[ViewerController alloc] init]];

        HorosSeriesListPlacement placements[] = { HorosSeriesListPlacementBottom, HorosSeriesListPlacementTop, HorosSeriesListPlacementRight, HorosSeriesListPlacementLeft };
        for( int p = 0; p < 4; p++)
        {
            HorosSeriesListPlacement placement = placements[p];
            // The floating list, with the list placed on that edge.
            [defaults setBool: YES forKey: @"UseFloatingThumbnailsList"];
            [HorosSeriesListLayout storePlacement: placement in: defaults];
            for( ViewerController *v in viewers) [v updateSeriesListMode];

            // The preference turned off, as the app's preference handler does:
            // every viewer re-places its list, then shows it as stored.
            [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
            for( ViewerController *v in viewers) [v updateSeriesListMode];
            for( ViewerController *v in viewers) [v setMatrixVisible: [defaults integerForKey: @"SeriesListVisible"] != 0];
            for( int i = 0; i < 2; i++) checkShown( viewers[i], i, placement, @"floating list off");
            check( [defaults boolForKey: @"SeriesListVisible"], @"the list stays stored as shown");

            // Hiding and showing one viewer's docked list.
            [viewers[0] setMatrixVisible: NO];
            for( int i = 0; i < 2; i++) checkHidden( viewers[i], i, placement, @"list hidden");
            [viewers[0] setMatrixVisible: YES];
            for( int i = 0; i < 2; i++) checkShown( viewers[i], i, placement, @"list shown again");
            printf( "%s: turning the floating list off docks both lists; hide and show act on the dock\n", [[HorosSeriesListLayout nameOfPlacement: placement] UTF8String]);
        }
        printf( "PASS: no recursion, and the docked list shows and hides on every edge without touching the image pane\n");
    }
    return 0;
}
'''.replace('METHODS', statics + '\n\n' + methods)

with tempfile.TemporaryDirectory(prefix='horos-series-list-floating-off-') as folder:
    folder = Path(folder)
    (folder / 'SeriesListLayout.swift').write_text(layout)
    (folder / 'check.m').write_text(objc + harness_defaults.OBJC, encoding='latin1')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'SeriesListLayoutCheck',
                    '-c', str(folder / 'SeriesListLayout.swift'), '-o', str(folder / 'layout.o'),
                    '-emit-objc-header-path', str(folder / 'SeriesListLayoutCheck-Swift.h')], check=True)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-fmodules', '-Wno-objc-method-access', '-I', str(folder),
                    str(folder / 'check.m'), '-o', str(folder / 'check.o')], check=True)
    binary = folder / 'horos-series-list-floating-off-check'
    subprocess.run(['xcrun', 'swiftc', str(folder / 'layout.o'), str(folder / 'check.o'), '-o', str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)], timeout=60).returncode)
