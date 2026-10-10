#!/usr/bin/env python3
"""Dragging the docked series list's divider sizes the list on every edge.

The viewer's split view delegate took the divider's position for the list's
thickness. That holds only with the list before the image pane, on the left or
the top. With the list on the right or at the bottom the image pane comes
first: a drag snapped the image pane to a thumbnail's width or height, or to
nothing, and the list took the rest. -splitView:canCollapseSubview: refused to
collapse the second pane, which is the list there, so the image pane could be
collapsed instead.

The viewer's own methods (the list's thickness, mode and visibility, and the
split view delegate methods) are taken from ViewerController.m and compiled
with clang into a stand-in ViewerController, over the real SeriesListLayout
compiled with swiftc, in a window that is never shown. On each edge the
divider is dragged with synthetic mouse events, through NSSplitView's own
tracking: a little toward the image, all the way across the image, and past
the list's own edge. The list keeps its thickness or hides, and the image pane
takes the rest and is never collapsed. Every edge is checked before the result
is given, so left and top show they behave as before. `<git revision>` as an
optional argument reads both sources from that revision, the negative control.
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
    '- (void)splitViewDidResizeSubviews:(NSNotification *) notification',
    '- (BOOL)splitView: (NSSplitView *)sender canCollapseSubview: (NSView *)subview',
    '- (CGFloat)splitView:(NSSplitView *)sender constrainSplitPosition:',
    '-(BOOL) matrixIsVisible',
    '-(void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize',
))
# File-level state the methods share, declared among them.
region = viewer[viewer.index('- (CGFloat) horosSeriesListThickness'):viewer.index('-(void) splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:')]
statics = '\n'.join(re.findall(r'^static [A-Za-z]+ \w+ = [^;]+;$', region, re.M))

objc = r'''#import <Cocoa/Cocoa.h>
#import "SeriesListLayoutCheck-Swift.h"

static int failures = 0;
static void check(BOOL value, NSString *message)
{
    if( !value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

@interface ThumbnailCell : NSButtonCell
+ (float) thumbnailCellWidth;
@end
@implementation ThumbnailCell
+ (float) thumbnailCellWidth { return 100; }
// A thumbnail's size, which a strip across the top or bottom is as thick as.
- (NSSize) cellSize { return NSMakeSize( 100, 120); }
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
    NSWindow *window;
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
        // A window server window, so the split view tracks the mouse events
        // posted to it; it is never ordered in.
        window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 800, 600) styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered defer: NO];
        [window setReleasedWhenClosed: NO];
        splitView = [[NSSplitView alloc] initWithFrame: NSMakeRect(0, 0, 800, 600)];
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
    }
    return self;
}

METHODS
@end

static BOOL across( HorosSeriesListPlacement placement)
{
    return placement == HorosSeriesListPlacementTop || placement == HorosSeriesListPlacementBottom;
}

static CGFloat extent( NSView *view, HorosSeriesListPlacement placement)
{
    if( [view isHidden]) return 0;
    return across( placement) ? view.frame.size.height : view.frame.size.width;
}

static NSEvent *mouse( NSEventType type, NSPoint point, NSWindow *window)
{
    return [NSEvent mouseEventWithType: type location: point modifierFlags: 0 timestamp: [[NSProcessInfo processInfo] systemUptime]
                          windowNumber: [window windowNumber] context: nil eventNumber: 0 clickCount: 1 pressure: type == NSEventTypeLeftMouseUp ? 0 : 1];
}

/// Drags the divider, as the user does, so that its middle ends at `to`
/// along the strip's axis, in the split view's own coordinates. The split
/// view's tracking loop takes the posted drag and release from the queue and
/// asks the delegate where the divider may go.
static void drag( ViewerController *v, HorosSeriesListPlacement placement, CGFloat to)
{
    NSSplitView *split = v->splitView;
    NSView *first = [[split subviews] objectAtIndex: 0];
    CGFloat divider = [split dividerThickness];
    CGFloat from = ([first isHidden] ? 0 : (across( placement) ? NSMaxY( first.frame) : NSMaxX( first.frame))) + divider / 2;
    NSPoint start = across( placement) ? NSMakePoint( split.bounds.size.width / 2, from) : NSMakePoint( from, split.bounds.size.height / 2);
    NSPoint end = across( placement) ? NSMakePoint( start.x, to) : NSMakePoint( to, start.y);
    start = [split convertPoint: start toView: nil];
    end = [split convertPoint: end toView: nil];
    [NSApp postEvent: mouse( NSEventTypeLeftMouseDragged, end, v->window) atStart: NO];
    [NSApp postEvent: mouse( NSEventTypeLeftMouseUp, end, v->window) atStart: NO];
    [split mouseDown: mouse( NSEventTypeLeftMouseDown, start, v->window)];
}

/// After the drag the list keeps its thickness and the image pane, shown and
/// not collapsed, takes the rest of the split view.
static void checkShown( ViewerController *v, HorosSeriesListPlacement placement, NSString *step)
{
    NSString *where = [NSString stringWithFormat: @"%@, %@", [HorosSeriesListLayout nameOfPlacement: placement], step];
    NSView *dock = [v->previewMatrixScrollView superview];
    CGFloat thickness = [v horosSeriesListThickness];
    CGFloat whole = across( placement) ? v->splitView.bounds.size.height : v->splitView.bounds.size.width;
    CGFloat list = extent( dock, placement), image = extent( v->imagePane, placement);
    check( ![v->imagePane isHiddenOrHasHiddenAncestor] && ![v->splitView isSubviewCollapsed: v->imagePane], [where stringByAppendingString: @": the image pane is shown, not collapsed"]);
    // Down a side the divider position adds a point, or a legacy scroller's width.
    check( list >= thickness && list < thickness + 20, [where stringByAppendingFormat: @": the list keeps its thickness (%g, not %g)", list, thickness]);
    check( fabs( image + list + [v->splitView dividerThickness] - whole) < 1, [where stringByAppendingFormat: @": the image pane takes the rest (%g, list %g, of %g)", image, list, whole]);
    check( [v matrixIsVisible], [where stringByAppendingString: @": the viewer sees its list shown"]);
}

static void checkHidden( ViewerController *v, HorosSeriesListPlacement placement, NSString *step)
{
    NSString *where = [NSString stringWithFormat: @"%@, %@", [HorosSeriesListLayout nameOfPlacement: placement], step];
    NSView *dock = [v->previewMatrixScrollView superview];
    CGFloat whole = across( placement) ? v->splitView.bounds.size.height : v->splitView.bounds.size.width;
    CGFloat list = extent( dock, placement), image = extent( v->imagePane, placement);
    check( ![v->imagePane isHiddenOrHasHiddenAncestor] && ![v->splitView isSubviewCollapsed: v->imagePane], [where stringByAppendingString: @": the image pane is shown, not collapsed"]);
    check( list < 1, [where stringByAppendingFormat: @": the list is hidden (%g)", list]);
    check( image >= whole - [v->splitView dividerThickness] - 0.5, [where stringByAppendingFormat: @": the image pane takes the viewer (%g of %g)", image, whole]);
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
        [defaults setBool: NO forKey: @"UseFloatingThumbnailsList"];
        [defaults setBool: YES forKey: @"SeriesListVisible"];
        [defaults setBool: NO forKey: @"AUTOHIDEMATRIX"];
        viewers = [NSMutableArray array];
        ViewerController *v = [[ViewerController alloc] init];
        [viewers addObject: v];

        HorosSeriesListPlacement placements[] = { HorosSeriesListPlacementRight, HorosSeriesListPlacementBottom, HorosSeriesListPlacementLeft, HorosSeriesListPlacementTop };
        for( int p = 0; p < 4; p++)
        {
            HorosSeriesListPlacement placement = placements[p];
            int before = failures;
            BOOL first = placement == HorosSeriesListPlacementLeft || placement == HorosSeriesListPlacementTop;
            CGFloat whole = across( placement) ? v->splitView.bounds.size.height : v->splitView.bounds.size.width;
            [HorosSeriesListLayout storePlacement: placement in: defaults];
            [defaults setBool: YES forKey: @"SeriesListVisible"];
            [v updateSeriesListMode];
            [v setMatrixVisible: YES];
            checkShown( v, placement, @"docked");
            NSView *dock = [v->previewMatrixScrollView superview];

            // The image pane never collapses; the list may.
            check( ![v splitView: v->splitView canCollapseSubview: v->imagePane], [[HorosSeriesListLayout nameOfPlacement: placement] stringByAppendingString: @": the image pane cannot be collapsed"]);
            check( [v splitView: v->splitView canCollapseSubview: dock], [[HorosSeriesListLayout nameOfPlacement: placement] stringByAppendingString: @": the list can be collapsed"]);

            // A little toward the image: the list snaps back to its thickness.
            CGFloat thickness = extent( dock, placement);
            CGFloat divider = [v->splitView dividerThickness];
            CGFloat middle = first ? thickness + divider / 2 : whole - thickness - divider / 2;
            drag( v, placement, first ? middle + 30 : middle - 30);
            checkShown( v, placement, @"divider dragged a little toward the image");

            // All the way across the image pane, to the viewer's other edge.
            drag( v, placement, first ? whole : 0);
            checkShown( v, placement, @"divider dragged across the image");

            // Past the list's own edge: the list hides, the image takes the viewer.
            drag( v, placement, first ? 0 : whole);
            checkHidden( v, placement, @"divider dragged past the list");

            printf( "%s: %s\n", [[HorosSeriesListLayout nameOfPlacement: placement] UTF8String],
                    failures == before ? "the divider sizes the list; the image pane takes the rest and cannot collapse" : "FAILED");
        }
        if( failures) return 1;
        printf( "PASS: dragging the divider sizes the list on every edge and never collapses the image pane\n");
    }
    return 0;
}
'''.replace('METHODS', statics + '\n\n' + methods)

with tempfile.TemporaryDirectory(prefix='horos-series-list-divider-') as folder:
    folder = Path(folder)
    (folder / 'SeriesListLayout.swift').write_text(layout)
    (folder / 'check.m').write_text(objc + harness_defaults.OBJC, encoding='latin1')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'SeriesListLayoutCheck',
                    '-c', str(folder / 'SeriesListLayout.swift'), '-o', str(folder / 'layout.o'),
                    '-emit-objc-header-path', str(folder / 'SeriesListLayoutCheck-Swift.h')], check=True)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-fmodules', '-Wno-objc-method-access', '-I', str(folder),
                    str(folder / 'check.m'), '-o', str(folder / 'check.o')], check=True)
    binary = folder / 'horos-series-list-divider-check'
    subprocess.run(['xcrun', 'swiftc', str(folder / 'layout.o'), str(folder / 'check.o'), '-o', str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)], timeout=60).returncode)
