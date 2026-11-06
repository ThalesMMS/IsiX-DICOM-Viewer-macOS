#!/usr/bin/env python3
"""A ROI measured after a draw must not read the display pixels.

`-[DCMPix getROIValue:::]` reads `self.baseAddr` for an RGB image. That buffer
is a *cache*: `-compute8bitRepresentation` rebuilds it from `fImage` whenever
`needToCompute8bitRepresentation` is set, and the `baseAddr` getter clears the
flag as it rebuilds.

`-[DCMView loadTextureIn:...]` runs the colour transfer for RGB images **in
place over that same buffer**:

    [self reapplyWindowLevel];              // sets the flag
    dest.data = self.curDCM.baseAddr;       // getter rebuilds and CLEARS it
    vImageTableLookUp_ARGB8888( &dest, &dest, …);   // writes display pixels

so the draw leaves CLUT'd pixels in the cache with the cache marked clean, and
the next ROI statistic is computed over them. A111 requires the opposite:
"ROIs/medidas mantêm valores originais".

Two halves, because neither alone would be honest:

* the object-level half links the application's own DCMPix.o and shows that the
  measurement follows whatever is written into `baseAddr`, and that setting the
  flag restores the original reading;
* the source half shows that the writer, `loadTextureIn:`, is gone:
  the view draws with Metal from copies, and nothing writes over the cache.
"""
from pathlib import Path
import re
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import app_object_probe  # noqa: E402
import roi_harness  # noqa: E402
from sources import class_text, class_text  # noqa: E402

obj = app_object_probe.built_object('DCMPix')
if obj is None:
    print('needs a built DCMPix.o: build Debug or Release once', file=sys.stderr)
    raise SystemExit(2)

failures = []

# ---------------------------------------------------------------- source half

# DCMView is Swift, with its C functions and array-parameter methods in DCMView+CAPI.m.
view = class_text('DCMView') + (root / 'Horos/Sources/DCMView+CAPI.m').read_bytes().decode('latin1')
bridge = (root / 'Horos/Sources/DCMView+PlanarSnapshot.swift').read_text(encoding='utf-8')  # the planar snapshot, Swift
pix = class_text('DCMPix')

# The writer is gone: the view draws its picture with Metal from copies
# of the host's bytes, and nothing transforms the measurement cache in place.
if 'loadTextureIn:' in view:
    failures.append('loadTextureIn: is back in DCMView; it wrote the colour transfer over baseAddr')
for name, text in (('DCMView', view), ('DCMView+PlanarSnapshot.swift', bridge)):
    if re.search(r'vImageTableLookUp_ARGB8888\(\s*&dest,\s*&dest,', text):
        failures.append('%s transforms a buffer in place again; check that it is not baseAddr' % name)
measure = root / 'Horos/Sources/DCMPix+ROIMeasure.swift'
measure = measure.read_text(encoding='utf-8') if measure.is_file() else ''
if 'computedfImage = (float*) self.baseAddr;' not in pix and \
        'computed = UnsafeMutableRawPointer(self.baseAddr)' not in measure:
    failures.append('getROIValue no longer reads baseAddr for RGB; re-measure A111')
if '- (char*)baseAddr' in pix:
    getter = pix[pix.find('- (char*)baseAddr'):]
    getter = getter[:getter.find('\n- (void)setLUT12baseAddr')]
    rebuilds = 'if( needToCompute8bitRepresentation)' in getter and '[self compute8bitRepresentation]' in getter
else:
    # The 8-bit picture is DCMPix+Display.swift's.
    display = (root / 'Horos/Sources/DCMPix+Display.swift').read_text(encoding='utf-8')
    getter = display[display.find('@objc(baseAddr) get {'):]
    getter = getter[:getter.find('@objc(setBaseAddr:) set')]
    rebuilds = 'if needToCompute8bitRepresentation { compute8bitRepresentation() }' in getter
if not rebuilds:
    failures.append('the baseAddr getter no longer rebuilds on demand; the premise of this test is gone')

# ---------------------------------------------------------- object-level half

PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
// PIX_IVARS
#include <cstdio>
#include <cstdlib>

enum { kBrush = 20 };   // ToolMode, DCMView.h

@interface ProbePix : DCMPix
- (void) prepareWidth:(long)w height:(long)h;
@end
@implementation ProbePix
- (void) CheckLoad {}
- (float*) computefImage { return PIX_IVAR( self, float*, fImage); }
- (void) applyShutter {}
- (void) prepareWidth:(long)w height:(long)h
{
    PIX_IVAR( self, long, width) = w; PIX_IVAR( self, long, height) = h; PIX_IVAR( self, BOOL, isRGB) = YES; PIX_IVAR( self, BOOL, thickSlabVRActivated) = NO;
    float *fImage = PIX_IVAR( self, float*, fImage) = (float*) calloc( w * h, sizeof( float));   // the ARGB source
    PIX_IVAR( self, char*, baseAddr) = (char*) calloc( w * h, 4);               // the display cache
    PIX_IVAR( self, NSArray*, pixArray) = [[NSArray arrayWithObject: [NSNull null]] retain];
}
@end

@interface ROI : NSObject
@property (assign) long type;
@property (assign) unsigned char *textureBuffer;
@property (assign) long textureWidth, textureHeight;
@property (assign) long textureUpLeftCornerX, textureUpLeftCornerY;
@end
@implementation ROI
- (NSMutableArray*) splinePoints { return nil; }
@end

static int failures = 0;
static void check( bool ok, const char *what)
{
    if( !ok) { fprintf( stderr, "FAIL: %s\n", what); failures++; }
}

static float measure( ProbePix *pix, ROI *roi)
{
    long count = 0;
    float *values = [pix getROIValue: &count : (id) roi : nil];
    float value = (count == 1 && values) ? values[ 0] : NAN;
    free( values);
    return value;
}

int main(){ @autoreleasepool {
    ProbePix *pix = [[ProbePix alloc] init];
    [pix prepareWidth: 8 height: 8];

    // One source pixel, ARGB, and a window level the RGB path can divide by.
    const unsigned char source[ 4] = {255, 40, 80, 120};
    memcpy( pix.fImage, source, sizeof source);
    [pix changeWLWW: 127 : 256];

    unsigned char texture = 1;
    ROI *roi = [[ROI alloc] init];
    roi.type = kBrush;
    roi.textureBuffer = &texture;
    roi.textureWidth = 1; roi.textureHeight = 1;
    roi.textureUpLeftCornerX = 0; roi.textureUpLeftCornerY = 0;

    // The legitimate reading: the cache rebuilt from fImage.
    const float original = measure( pix, roi);
    check( isfinite( original) && original > 0, "a one pixel RGB brush must measure something");

    // What a draw with a colour transfer leaves behind: display pixels written
    // straight into the cache, with the cache still marked clean.
    unsigned char *cache = (unsigned char*) pix.baseAddr;   // clean after the read above
    check( pix.needToCompute8bitRepresentation == NO,
           "reading baseAddr must leave the cache marked clean; the defect depends on it");
    const unsigned char display[ 4] = {255, 200, 210, 220};
    memcpy( cache, display, sizeof display);

    const float afterDraw = measure( pix, roi);
    const float displayMean = (display[ 1] + display[ 2] + display[ 3]) / 3.f;
    char message[ 200];
    snprintf( message, sizeof message,
              "the measurement followed the display pixels: %g, the mean of what was written (%g)",
              afterDraw, displayMean);
    check( afterDraw == displayMean, message);
    snprintf( message, sizeof message,
              "display pixels must differ from the original reading, or this proves nothing: %g vs %g",
              afterDraw, original);
    check( afterDraw != original, message);

    // The remedy: marking the cache stale makes the next measurement come from
    // the source again. This is what loadTextureIn: has to do before returning.
    pix.needToCompute8bitRepresentation = YES;
    const float afterInvalidation = measure( pix, roi);
    snprintf( message, sizeof message,
              "invalidating the cache must restore the original reading: %g, expected %g",
              afterInvalidation, original);
    check( afterInvalidation == original, message);

    if( failures) { fprintf( stderr, "FAIL: %d check%s\n", failures, failures == 1 ? "" : "s"); return 1; }
    puts( "ok");
    return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-measurement-source-') as name:
    directory = Path(name)
    (directory / 'probe.mm').write_text(PROBE.replace('// PIX_IVARS\n', roi_harness.PIX_IVARS))
    run = app_object_probe.link_and_run(directory, [directory / 'probe.mm'], [obj], probe_classes=('ROI',))
    if run.returncode:
        sys.stderr.write(run.stderr)
        failures.append('the measurement does not read the display cache the way this test assumes')

if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)

print('PASS: the measurement follows baseAddr and its cache flag, and no view writes the display transform over it')
