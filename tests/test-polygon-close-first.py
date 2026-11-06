#!/usr/bin/env python3
"""Exercise production polygon click handling and native hit tolerance.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py), on a view whose window is at 1x or 2x and whose image
has square or tall pixels; without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

/// A closed polygon being drawn on the view.
static ROI *drawing( void)
{
    ROI *r = newROI( tCPolygon);
    showAlone( r);
    r.thickness = 1;
    [r setROIMode: ROI_drawing];
    return r;
}

static BOOL click( ROI *r, NSPoint p, float scale) { return [r mouseRoiDown: p : 7 : scale]; }

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{});
    for( int backing = 1; backing <= 2; backing++) for( int zoom = 1; zoom <= 5; zoom += 4) for( int ratio = 1; ratio <= 2; ratio++)
    {
        gBacking = backing;
        view.curDCM.pixelRatio = ratio;
        ROI *r = drawing();
        float scale = zoom * backing;
        check( click( r, NSMakePoint( 0, 0), scale));
        check( click( r, NSMakePoint( 100, 0), scale));
        check( click( r, NSMakePoint( 100, 100), scale));
        check( !click( r, NSMakePoint( 4.0 / zoom, 4.0 / (zoom * ratio)), scale));
        check( r.ROImode == ROI_selected && r.points.count == 3 && r.zPositions.count == 3);
    }
    gBacking = 1;
    view.curDCM.pixelRatio = 1;
    for( int scenario = 0; scenario < 5; scenario++)
    {
        ROI *r = drawing();
        click( r, NSMakePoint( 0, 0), 1);
        click( r, NSMakePoint( 100, 0), 1);
        if( scenario != 0) click( r, NSMakePoint( 100, 100), 1);
        if( scenario == 1) r.type = tOPolygon;
        if( scenario == 2) [r setROIMode: ROI_selectedModify];
        NSPoint target = scenario == 3 ? NSMakePoint( 6, 6) : NSMakePoint( 0, 0);
        if( scenario == 4) target = NSMakePoint( 100, 100);
        NSUInteger before = r.points.count;
        click( r, target, 1);
        if( scenario == 4) check( r.ROImode == ROI_selected && r.points.count == before);
        else check( r.points.count == before + 1);
    }
    [window release];
    printf( "PASS: first-vertex completion, no duplicate points/slices, 1x/2x, zoom/anisotropy, minimum vertices, open/edit/outside hits, last-vertex completion\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
