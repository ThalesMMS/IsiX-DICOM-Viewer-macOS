#!/usr/bin/env python3
"""Dragging the docked series list's divider sizes the list on every edge.

The viewer's split view delegate took the divider's position for the list's
thickness. That holds only with the list before the image pane, on the left or
the top. With the list on the right or at the bottom the image pane comes
first: a drag snapped the image pane to a thumbnail's width or height, or to
nothing, and the list took the rest. -splitView:canCollapseSubview: refused to
collapse the second pane, which is the list there, so the image pane could be
collapsed instead.

The viewer's own code of the dock (the list's thickness, mode and
visibility, and the split view delegate methods) runs in a stand-in
ViewerController, over the real SeriesListLayout, in a window that is never
shown (series_list_dock_harness.py): the Swift of
ViewerController+SeriesListDock.swift, or the Objective-C of
ViewerController.m in a revision that still has it. On each edge the
divider is dragged with synthetic mouse events, through NSSplitView's own
tracking: a little toward the image, all the way across the image, and past
the list's own edge. The list keeps its thickness or hides, and the image pane
takes the rest and is never collapsed. Every edge is checked before the result
is given, so left and top show they behave as before. `<git revision>` as an
optional argument reads the sources from that revision, the negative control.
"""
import shutil
import subprocess
import sys
import tempfile
import series_list_dock_harness

revision = sys.argv[1] if len(sys.argv) > 1 else None

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(2)

scenario = r'''
static int failures = 0;
static void check(BOOL value, NSString *message)
{
    if( !value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}

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
    [NSApp postEvent: mouse( NSEventTypeLeftMouseDragged, end, [v harnessWindow]) atStart: NO];
    [NSApp postEvent: mouse( NSEventTypeLeftMouseUp, end, [v harnessWindow]) atStart: NO];
    [split mouseDown: mouse( NSEventTypeLeftMouseDown, start, [v harnessWindow])];
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
        ViewerController *v = [[ViewerController alloc] initWithSplitViewClass: [NSSplitView class] deferWindow: NO observesVisibility: NO];
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
'''

with tempfile.TemporaryDirectory(prefix='horos-series-list-divider-') as folder:
    binary = series_list_dock_harness.build(revision, scenario, folder)
    sys.exit(subprocess.run([str(binary)], timeout=60).returncode)
