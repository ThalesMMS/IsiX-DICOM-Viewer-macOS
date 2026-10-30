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

The viewer's own code of the dock (-updateSeriesListMode, -setMatrixVisible:,
-matrixIsVisible, the KVO observer of SeriesListVisible and the split view
delegate methods) runs in a stand-in ViewerController, over the real
SeriesListLayout (series_list_dock_harness.py): the Swift of
ViewerController+SeriesListDock.swift, or the Objective-C of
ViewerController.m in a revision that still has it. Two viewers switch from the floating list to the docked list, as the
app's preference handler does, on each edge; then one viewer hides and shows
its list. A split view resize nested deeper than the switch needs is the
recursion. `<git revision>` as an optional argument reads the sources from
that revision, the negative control.
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
        [viewers addObject: [[ViewerController alloc] initWithSplitViewClass: [CountingSplitView class] deferWindow: YES observesVisibility: YES]];
        [viewers addObject: [[ViewerController alloc] initWithSplitViewClass: [CountingSplitView class] deferWindow: YES observesVisibility: YES]];

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
'''

with tempfile.TemporaryDirectory(prefix='horos-series-list-floating-off-') as folder:
    binary = series_list_dock_harness.build(revision, scenario, folder)
    sys.exit(subprocess.run([str(binary)], timeout=60).returncode)
