#!/usr/bin/env python3
"""Check that a ROI's text label is painted at the ROI's opacity.

Case R254 covers a colour or opacity change that has no effect. The geometry
of a ROI is drawn with its colour at `opacity` at every site, but the label
that names it and carries its measurement is drawn by `-[ROI glStr::::]`,
which took its colour from the ROI and its alpha from a literal. A ROI at half
opacity therefore faded except for its text, which is the reported symptom.

The label is a premultiplied picture on the view's text layer, as it
was a premultiplied texture composited with (ONE, ONE_MINUS_SRC_ALPHA), so the
colour has to carry the opacity as well as the alpha channel: an alpha alone
leaves the source at full strength and only lightens what is behind it, which
comes out brighter than the opaque label rather than fainter.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py); the probe records the colours `glStr` hands the text
layer, and requires the shadow and the text to be the premultiplied form of
the ROI's colour at its opacity. Compare `tests/test-roi-draw-color.py`, which
covers the geometry and the blend itself. The label box is off
(ROILabelBackground); over the box the text is opaque, which
`tests/test-roi-label-contrast.py` covers. Without a build the test is skipped.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

PROBE = r'''
static NSColor *gText, *gShadow;
static int gCalls;

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    ProbeWindow *window = setUp( @{@"ROILabelBackground": @NO, @"LabelFONTNAME": @"Helvetica", @"LabelFONTSIZE": @12});
    // What the text layer is given.
    method_setImplementation( class_getInstanceMethod( [HorosAnnotationOverlay class], @selector( addText:x:y:textColor:shadowColor:blendOnAlpha:)),
                              imp_implementationWithBlock( ^( id self, id text, CGFloat x, CGFloat y, NSColor *textColor, NSColor *shadowColor, BOOL blend) {
        [gText release]; [gShadow release];
        gText = [textColor retain]; gShadow = [shadowColor retain];
        gCalls++;
    }));
    HorosAnnotationOverlay *overlay = [HorosAnnotationOverlay overlayForView: view];
    [overlay beginFrameWidth: kFrame height: kFrame];
    [[HorosROICanvas current] setModelview: CGAffineTransformIdentity viewport: NSMakeRect( 0, 0, kFrame, kFrame)];
    ROI *p = newROI( tMesure);
    showAlone( p);
    const unsigned short cases[][3] = {{65535, 0, 0}, {0, 65535, 0}, {0, 0, 65535}, {65535, 65535, 0}, {32768, 32768, 32768}};
    const float opacities[] = {1.0f, 0.5f, 0.25f, 0.0f};
    int failures = 0;
    for( unsigned c = 0; c < sizeof( cases) / sizeof( cases[ 0]); c++)
        for( unsigned o = 0; o < sizeof( opacities) / sizeof( opacities[ 0]); o++)
        {
            RGBColor rgb = { cases[ c][ 0], cases[ c][ 1], cases[ c][ 2]};
            [p setColor: rgb globally: NO];
            [p setOpacity: opacities[ o] globally: NO];
            gCalls = 0;
            [p glStr: @"Area: 1.440 cm2" : 10 : 20 : 0];
            if( gCalls != 1)
            {
                fprintf( stderr, "FAIL: %d pictures, expected one with its shadow and text colours\n", gCalls);
                return 1;
            }
            // The label is composited premultiplied, so the colour carries the opacity
            // as well as the alpha. Premultiplied black is black.
            const float a = opacities[ o];
            const CGFloat wanted[ 2][ 4] = {
                {0, 0, 0, a},
                {a * cases[ c][ 0] / 65535.f, a * cases[ c][ 1] / 65535.f, a * cases[ c][ 2] / 65535.f, a}};
            NSColor *got[ 2] = { gShadow, gText};
            const char *pass[ 2] = {"shadow", "text"};
            for( int which = 0; which < 2; which++)
            {
                CGFloat channels[ 4] = { got[ which].redComponent, got[ which].greenComponent, got[ which].blueComponent, got[ which].alphaComponent};
                for( int channel = 0; channel < 4; channel++)
                    if( fabs( channels[ channel] - wanted[ which][ channel]) > 1e-6)
                    {
                        fprintf( stderr, "FAIL %s pass, colour %u opacity %.2f: channel %d is %.5f, expected %.5f\n",
                                 pass[ which], c, opacities[ o], channel, channels[ channel], wanted[ which][ channel]);
                        failures++;
                    }
            }
        }
    if( failures) { fprintf( stderr, "FAIL: %d wrong channels\n", failures); return 1; }
    [window release];
    printf( "PASS: ROI label shadow and text carry the ROI opacity across five colours and four opacities\n");
    return 0;
}}
'''

result = roi_harness.run_probe(PROBE)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
