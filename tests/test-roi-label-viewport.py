#!/usr/bin/env python3
"""Exercise production label placement including offscreen anchors/collisions.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py), on a view whose frame and conversions the probe sets;
its contour is replaced, in the probe, by a given one. Without a build the
test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

@interface ViewportView : ProbeView
@property NSRect frameRect;
@end
@implementation ViewportView
- (NSRect) drawingFrameRect { return self.frameRect; }
- (NSPoint) ConvertFromView2GL:(NSPoint) point { return NSMakePoint( point.y / 2, -point.x / 2); }
@end

static NSRect gContour;

static ROI *labelled( ViewportView *v)
{
    ROI *r = newROI( tMesure);
    [r setCurView: (DCMView*) v];
    return r;
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    method_setImplementation( class_getInstanceMethod( [ROI class], @selector( textualDataContourRect)),
                              imp_implementationWithBlock( ^NSRect( id self) { return gContour; }));
    ViewportView *v = [[ViewportView alloc] initWithFrame: NSMakeRect( 0, 0, 100, 100)];
    window.contentView = v;
    for( int scale = 1; scale <= 2; scale++) for( int columns = 1; columns <= 3; columns++)
    {
        gContour = NSZeroRect;
        ROI *r = labelled( v); NSRect frame = NSMakeRect( 0, 0, 1200.0 * scale / columns, 800 * scale); v.frameRect = frame;
        NSRect viewport = NSMakeRect( -frame.size.width / 2, -frame.size.height / 2, frame.size.width, frame.size.height);
        for( int x = -1; x <= 1; x++) for( int y = -1; y <= 1; y++) for( int registry = 0; registry < 2; registry++)
        {
            v.rectArray = registry ? [NSMutableArray array] : nil; BOOL moved = NO;
            NSRect input = NSMakeRect( x * 3000, y * 3000, 150 * scale, 70 * scale);
            NSRect placed = [r findAnEmptySpaceForMyRect: input : &moved];
            check( NSContainsRect( viewport, placed)); check( NSEqualSizes( input.size, placed.size));
            if( x || y) check( moved);
            else check( !moved && placed.origin.x == 8 && placed.origin.y == 8);
        }
        v.rectArray = [NSMutableArray arrayWithObject: [NSValue valueWithRect: viewport]];
        BOOL moved = NO; NSRect result = [r findAnEmptySpaceForMyRect: NSMakeRect( 0, 0, 150 * scale, 70 * scale) : &moved];
        check( NSContainsRect( viewport, result));
        check( NSEqualRects( [v.rectArray.lastObject rectValue], result));
        NSRect annotation = NSMakeRect( viewport.origin.x, NSMaxY( viewport) - 100 * scale, viewport.size.width, 100 * scale);
        v.rectArray = [NSMutableArray arrayWithObject: [NSValue valueWithRect: annotation]];
        result = [r findAnEmptySpaceForMyRect: NSMakeRect( 0, 3000, 150 * scale, 70 * scale) : &moved];
        check( NSContainsRect( viewport, result) && !NSIntersectsRect( annotation, result));
    }
    for( int scale = 1; scale <= 2; scale++)
    {
        gContour = NSZeroRect;
        ROI *r = labelled( v); v.frameRect = NSMakeRect( 0, 0, 200 * scale, 200 * scale);
        NSRect vertical = NSMakeRect( -10 * scale, -100 * scale, 20 * scale, 200 * scale);
        NSRect horizontal = NSMakeRect( -100 * scale, -10 * scale, 200 * scale, 20 * scale);
        v.rectArray = [NSMutableArray arrayWithObjects: [NSValue valueWithRect: vertical], [NSValue valueWithRect: horizontal], nil];
        BOOL moved = NO; NSRect result = [r findAnEmptySpaceForMyRect: NSMakeRect( -8, -8, 40 * scale, 40 * scale) : &moved];
        check( !NSIntersectsRect( result, vertical) && !NSIntersectsRect( result, horizontal));
        check( NSContainsRect( NSMakeRect( -100 * scale, -100 * scale, 200 * scale, 200 * scale), result) && moved);
    }
    // Small ROIs at every viewport edge retain a clear contour.
    for( int scale = 1; scale <= 2; scale++) for( int x = -1; x <= 1; x++) for( int y = -1; y <= 1; y++)
    {
        ROI *r = labelled( v); v.frameRect = NSMakeRect( 0, 0, 400 * scale, 300 * scale);
        v.rectArray = [NSMutableArray array];
        NSRect viewport = NSMakeRect( -200 * scale, -150 * scale, 400 * scale, 300 * scale);
        gContour = NSMakeRect( x * 175 * scale - 10 * scale, y * 125 * scale - 10 * scale, 20 * scale, 20 * scale);
        NSRect input = NSMakeRect( NSMinX( gContour) - 8, NSMinY( gContour) - 8, 100 * scale, 40 * scale);
        BOOL moved = NO; NSRect result = [r findAnEmptySpaceForMyRect: input : &moved];
        check( NSContainsRect( viewport, result) && !NSIntersectsRect( result, gContour) && moved);
        // Freeze the displayed position into the persisted image-space offset.
        r.drawRect = result; r.originAnchor = input.origin;
        NSPoint anchor = [v ConvertFromView2GL: r.originAnchor];
        NSPoint displayed = [v ConvertFromView2GL: NSMakePoint( result.origin.x - 8, result.origin.y - 8)];
        [r setTextBoxOffset: NSMakePoint( 2, 3)];
        check( fabs( r.offsetTextBox_x - (displayed.x - anchor.x + 2)) < 0.001);
        check( fabs( r.offsetTextBox_y - (displayed.y - anchor.y + 3)) < 0.001);
        [r setTextBoxOffset: NSMakePoint( 1, 1)];
        check( fabs( r.offsetTextBox_x - (displayed.x - anchor.x + 3)) < 0.001);
        // Manual placement remains authoritative even over the contour/annotations.
        v.rectArray = [NSMutableArray arrayWithObject: [NSValue valueWithRect: viewport]];
        result = [r findAnEmptySpaceForMyRect: input : &moved];
        check( NSEqualRects( result, [HorosROILabelPresentation constrainLabelRect: NSOffsetRect( input, 8, 8) toViewport: viewport]));
    }
    // The widest available side wins when the original label covers the ROI.
    NSRect vp = NSMakeRect( 0, 0, 500, 300), roi = NSMakeRect( 80, 130, 20, 20), label = NSMakeRect( 80, 130, 100, 40);
    NSRect placed = [HorosROILabelPresentation placeLabelRect: label inViewport: vp avoiding: @[] roiBounds: roi manuallyPlaced: NO];
    check( NSMinX( placed) >= NSMaxX( roi) && NSContainsRect( vp, placed));
    // An occupied preferred side falls back to a free alternative.
    NSRect right = NSMakeRect( 100, 0, 400, 300);
    placed = [HorosROILabelPresentation placeLabelRect: label inViewport: vp avoiding: @[[NSValue valueWithRect: right]] roiBounds: roi manuallyPlaced: NO];
    check( !NSIntersectsRect( placed, roi));
    [window release];
    printf( "PASS: viewport edges/corners, small ROI avoidance, largest side, manual placement/first drag, offscreen anchors, annotations, one/three panes and 1x/2x\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
