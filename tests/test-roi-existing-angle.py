#!/usr/bin/env python3
"""Existing tAngle already measures in physical coordinates; do not add a second tool.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py); without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402
from sources import class_text  # noqa: E402

method = class_text('ROI')
method = method[method.index('@objc(Angle:::)'):]
method = method[:method.index('\n    }\n')]
if 'spacingX: _pixelSpacingX, spacingY: _pixelSpacingY' not in method:
    print('FAIL: existing Angle: no longer uses physical spacing', file=sys.stderr)
    sys.exit(1)

PROBE = r'''
int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ROI *r = [[[ROI alloc] initWithType: tAngle : 1 : NSZeroPoint] autorelease];
    r.pixelSpacingX = 1;
    r.pixelSpacingY = 0.5;
    float physical = [r Angle: NSMakePoint( 4, 0) : NSMakePoint( 0, 0) : NSMakePoint( 4, 4)];
    float expected = atan( 0.5) * 180 / M_PI;
    if( fabs( physical - expected) > 1e-4)
    {
        fprintf( stderr, "FAIL: existing Angle: %f wanted %f\n", physical, expected);
        return 1;
    }
    r.pixelSpacingX = r.pixelSpacingY = 1;
    if( fabs( [r Angle: NSMakePoint( 4, 0) : NSMakePoint( 0, 0) : NSMakePoint( 4, 4)] - 45) > 1e-4)
    {
        fprintf( stderr, "FAIL: isotropic Angle:\n");
        return 1;
    }
    puts( "PASS: existing tAngle tool already reports the physical angle");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
