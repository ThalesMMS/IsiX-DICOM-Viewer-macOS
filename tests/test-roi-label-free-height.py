#!/usr/bin/env python3
"""The production ROI label height selection, with real AppKit text metrics.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py). Its lines, the width of a line and its contour are
replaced, in the probe, by fixed lines, widths measured with the system font
and a given contour, so that -fitTextualDataToAvailableSpace is asked alone;
without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

@interface ROI (FreeHeight)
- (NSArray*) fitTextualDataToAvailableSpace;
- (NSArray*) renderedTextualLines;
- (long) maxStringWidth:(NSString*) text max:(long) width;
@end

@interface HeightView : ProbeView
@property NSRect frameRect;
@end
@implementation HeightView
- (NSRect) drawingFrameRect { return self.frameRect; }
@end

static NSArray *gSource;
static NSRect gContour;

/// What the label is made of, replaced in the ROI class for this probe.
static void replaceLabelInputs( void)
{
    Class roi = [ROI class];
    method_setImplementation( class_getInstanceMethod( roi, @selector( renderedTextualLines)),
                              imp_implementationWithBlock( ^NSArray*( id self) { return gSource; }));
    method_setImplementation( class_getInstanceMethod( roi, @selector( textualDataContourRect)),
                              imp_implementationWithBlock( ^NSRect( id self) { return gContour; }));
    method_setImplementation( class_getInstanceMethod( roi, @selector( maxStringWidth:max:)),
                              imp_implementationWithBlock( ^long( id self, NSString *text, long width) {
        if( !text.length) return width;
        CGFloat measured = [text sizeWithAttributes: @{NSFontAttributeName: [NSFont systemFontOfSize: 12]}].width;
        return MAX( width, (long) ceil( (measured + 8) * gBacking));
    }));
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    [ROI setFontHeight: 20];
    replaceLabelInputs();
    HeightView *peer = [[HeightView alloc] initWithFrame: NSMakeRect( 0, 0, 100, 100)];
    window.contentView = peer;
    for( NSNumber *sf in @[@1, @2])
    {
        CGFloat scale = sf.doubleValue;
        gBacking = scale;
        ROI *r = [[ROI alloc] initWithType: tMesure : 1 : NSZeroPoint];
        [r setCurView: (DCMView*) peer];
        gSource = @[@"QA Height", @"", @"Line 01", @"Line 02", @"Line 03", @"Line 04", @"Value: 81", @"Coordinates"];
        r.drawRect = NSMakeRect( 0, 0, 100, 142);
        peer.frameRect = NSMakeRect( 0, 0, 400 * scale, 200 * scale);
        NSRect viewport = NSMakeRect( -200 * scale, -100 * scale, 400 * scale, 200 * scale);
        peer.rectArray = [NSMutableArray arrayWithObjects: [NSValue valueWithRect: NSMakeRect( -200 * scale, -100 * scale, 400 * scale, 60 * scale)],
                          [NSValue valueWithRect: NSMakeRect( -200 * scale, 40 * scale, 400 * scale, 60 * scale)], nil];
        NSArray *limited = [r fitTextualDataToAvailableSpace];
        check( limited.count == 3 && [limited.lastObject isEqual: @"…"]);
        check( [limited[ 0] isEqual: @"QA Height"] && [limited[ 1] isEqual: @"Line 01"]);
        NSRect placed = [HorosROILabelPresentation placeLabelRect: NSOffsetRect( r.drawRect, 8, 8) inViewport: viewport avoiding: peer.rectArray];
        check( NSContainsRect( viewport, placed));
        for( NSValue *v in peer.rectArray) check( !NSIntersectsRect( placed, v.rectValue));
        // Removing annotations restores complete fields on the next layout.
        peer.rectArray = [NSMutableArray array];
        check( [[r fitTextualDataToAvailableSpace] isEqual: gSource]);
        check( r.drawRect.size.height == 7 * 20 * scale + 2);
        // A small contour in a short pane reduces the label before overlapping it.
        r.drawRect = NSMakeRect( -8, -8, r.drawRect.size.width, r.drawRect.size.height);
        gContour = NSMakeRect( -200 * scale, -10 * scale, 400 * scale, 20 * scale);
        NSArray *outside = [r fitTextualDataToAvailableSpace];
        check( outside.count < gSource.count);
        NSRect outsideRect = [HorosROILabelPresentation placeLabelRect: NSOffsetRect( r.drawRect, 8, 8) inViewport: viewport avoiding: @[]
                                                             roiBounds: gContour manuallyPlaced: NO];
        check( NSContainsRect( viewport, outsideRect) && !NSIntersectsRect( outsideRect, gContour));
        // An explicit user placement restores fields without automatic contour avoidance.
        r.offsetTextBox_x = 1;
        check( [[r fitTextualDataToAvailableSpace] isEqual: gSource]);
        r.offsetTextBox_x = 0; gContour = NSZeroRect;
        // Completely occupied panes retain an explicit, minimum-size indicator.
        peer.rectArray = [NSMutableArray arrayWithObject: [NSValue valueWithRect: viewport]];
        check( [[r fitTextualDataToAvailableSpace] isEqual: @[@"…"]]);
        check( [gSource.lastObject isEqual: @"Coordinates"]);
        [r release];
    }
    [window release];
    printf( "PASS: production ROI budget, contour avoidance, manual restoration, actual font metrics, fixed bands, 1x/2x and occupied-pane indication\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
