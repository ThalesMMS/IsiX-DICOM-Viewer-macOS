#!/usr/bin/env python3
"""Check actual ROI spline/length code and text preparation independent of zoom.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py): a polygon is drawn and labelled at 1, 100 and 500
percent, and its label's length, the length its data export reports and its
smoothed outline compared. Without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

@interface ROI (LengthZoom)
- (NSMutableArray*) splinePoints:(float) scale correspondingSegmentArray:(NSMutableArray**) array;
@end

/// The length the label shows, drawn at `zoom`.
static NSString *displayedLengthAtZoom( ROI *r, float zoom)
{
    gScale = zoom;
    picture( @"length", NO);
    return r.type == tOPolygon || r.type == tCPolygon ? r.textualBoxLine5 : nil;
}

static float exportedLength( ROI *r) { return [[[r dataString] objectForKey: @"Length"] floatValue]; }

static NSMutableArray *polyline( double *xy, int count) { return myPoints( xy, count); }

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{@"splineForROI": @NO, @"ROITEXTIFSELECTED": @NO});
    ROI *r = newROI( tOPolygon);
    showAlone( r);
    r.pixelSpacingX = 0.5; r.pixelSpacingY = 2;
    double three[] = { 0, 0, 3, 4, 6, 4};
    r.points = polyline( three, 3);
    float expected = (hypot( 1.5, 8) + 1.5) / 10;
    NSString *label = [NSString stringWithFormat: @"Length: %@", [ROI formattedLength: expected]];
    for( NSNumber *z in @[@0.01, @1, @5]) check( [displayedLengthAtZoom( r, z.floatValue) isEqual: label]);
    check( fabs( exportedLength( r) - expected) < 1e-6);
    r.isSpline = YES;
    double four[] = { 0, 0, 20, 35, 45, -10, 60, 15};
    r.points = polyline( four, 4);
    for( NSNumber *z in @[@0.01, @1, @5])
    {
        NSArray *sampled = [r splinePoints: z.floatValue];
        check( NSEqualPoints( [(MyPoint*) sampled.firstObject point], [(MyPoint*) r.points.firstObject point]));
        check( NSEqualPoints( [(MyPoint*) sampled.lastObject point], [(MyPoint*) r.points.lastObject point]));
    }
    check( [[r splinePoints: 0.01] count] != [[r splinePoints: 5] count]);
    for( int spacing = 0; spacing < 2; spacing++)
    {
        float sx = spacing ? 0.5 : 1, sy = spacing ? 2 : 1;
        r.pixelSpacingX = sx; r.pixelSpacingY = sy;
        // Drawing takes the spacing it is given: the view's image's, here the ROI's.
        NSString *reference = displayedLengthAtZoom( r, 5);
        check( [reference isEqual: [NSString stringWithFormat: @"Length: %@", [ROI formattedLength: exportedLength( r)]]]);
        for( NSNumber *z in @[@0.01, @1, @5]) check( [displayedLengthAtZoom( r, z.floatValue) isEqual: reference]);
    }
    for( int i = 0; i < 100; i++)
    {
        NSMutableArray *segments = nil; NSArray *sampled = [r splinePoints: 5 correspondingSegmentArray: &segments];
        check( sampled.count == segments.count && sampled.count > 4);
    }
    r.type = tCPolygon;
    check( [[NSString stringWithFormat: @"Length: %@", [ROI formattedLength: exportedLength( r)]] isEqual: displayedLengthAtZoom( r, 5)]);
    r.isSpline = NO; r.pixelSpacingX = .5; r.pixelSpacingY = 2;
    r.points = polyline( three, 3);
    check( fabs( exportedLength( r) - (hypot( 1.5, 8) + 1.5 + hypot( 3, 8)) / 10) < 1e-6);
    r.points = [NSMutableArray array]; check( exportedLength( r) == 0);
    [r.points addObject: [MyPoint point: NSMakePoint( 2, 3)]]; check( exportedLength( r) == 0);
    [window release];
    printf( "PASS: 1/100/500 percent zoom, curved splines and analytic anisotropic polyline\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
