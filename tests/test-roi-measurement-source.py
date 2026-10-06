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
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
objects = [root / 'build/Build/Intermediates.noindex/Horos.build' / configuration /
           'Horos.build/Objects-normal/arm64/DCMPix.o'
           for configuration in ('Debug', 'Release')]
obj = next((o for o in objects if o.is_file()), None)
if obj is None:
    print('needs a built DCMPix.o in %s' % ' or '.join(str(o) for o in objects), file=sys.stderr)
    raise SystemExit(2)

failures = []

# ---------------------------------------------------------------- source half

view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')
bridge = (root / 'Horos/Sources/PlanarHostBridge.m').read_bytes().decode('latin1')
pix = (root / 'Horos/Sources/DCMPix.m').read_bytes().decode('latin1')

# The writer is gone: the view draws its picture with Metal from copies
# of the host's bytes, and nothing transforms the measurement cache in place.
if 'loadTextureIn:' in view:
    failures.append('loadTextureIn: is back in DCMView.m; it wrote the colour transfer over baseAddr')
for name, text in (('DCMView.m', view), ('PlanarHostBridge.m', bridge)):
    if re.search(r'vImageTableLookUp_ARGB8888\(\s*&dest,\s*&dest,', text):
        failures.append('%s transforms a buffer in place again; check that it is not baseAddr' % name)
if 'computedfImage = (float*) self.baseAddr;' not in pix:
    failures.append('getROIValue no longer reads baseAddr for RGB; re-measure A111')
getter = pix[pix.find('- (char*)baseAddr'):]
getter = getter[:getter.find('\n- (void)setLUT12baseAddr')]
if 'if( needToCompute8bitRepresentation)' not in getter or '[self compute8bitRepresentation]' not in getter:
    failures.append('the baseAddr getter no longer rebuilds on demand; the premise of this test is gone')

# ---------------------------------------------------------- object-level half

PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
#include <cstdio>
#include <cstdlib>

enum { kBrush = 20 };   // ToolMode, DCMView.h

@interface ProbePix : DCMPix
- (void) prepareWidth:(long)w height:(long)h;
@end
@implementation ProbePix
- (void) CheckLoad {}
- (float*) computefImage { return fImage; }
- (void) applyShutter {}
- (void) prepareWidth:(long)w height:(long)h
{
    width = w; height = h; isRGB = YES; thickSlabVRActivated = NO;
    fImage = (float*) calloc( w * h, sizeof( float));   // the ARGB source
    baseAddr = (char*) calloc( w * h, 4);               // the display cache
    pixArray = [[NSArray arrayWithObject: [NSNull null]] retain];
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

FRAMEWORKS = ['Foundation', 'AppKit', 'AVFoundation', 'CoreData', 'CoreMedia', 'CoreVideo']


def objectiveCStubs():
    listing = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
    names = sorted({m.group(1) for m in re.finditer(r'_OBJC_CLASS_\$_(\w+)', listing)})
    sources = root / 'Horos/Sources'
    declared = [n for n in names
                if n != 'ROI' and ((sources / (n + '.h')).is_file() or (sources / (n + '.m')).is_file()
                                   or (sources / (n + '.mm')).is_file())]
    return ''.join('@interface %s : NSObject @end\n@implementation %s @end\n' % (n, n) for n in declared)


def link(directory, placeholders):
    assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
    (directory / 'placeholders.s').write_text('.data\n' + assembly)
    command = ['xcrun', 'clang++', '-std=c++11', '-Wno-deprecated-declarations',
               '-I' + str(root / 'Horos/Sources'),
               str(directory / 'probe.mm'), str(directory / 'stubs.mm'),
               str(directory / 'placeholders.s'), str(obj),
               '-Wl,-undefined,dynamic_lookup', '-o', str(directory / 'probe')]
    for framework in FRAMEWORKS:
        command += ['-framework', framework]
    subprocess.run(command, check=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix='horos-measurement-source-') as name:
    directory = Path(name)
    (directory / 'probe.mm').write_text(PROBE)
    (directory / 'stubs.mm').write_text('#import <Foundation/Foundation.h>\n' + objectiveCStubs())
    placeholders = set()
    for _ in range(200):
        link(directory, placeholders)
        run = subprocess.run([str(directory / 'probe')], capture_output=True, text=True)
        missing = re.search(r"symbol not found in flat namespace '([^']+)'", run.stderr)
        if not missing:
            break
        if missing.group(1) in placeholders:
            print('cannot satisfy %s' % missing.group(1), file=sys.stderr)
            raise SystemExit(1)
        placeholders.add(missing.group(1))
    else:
        print('too many unresolved symbols in %s' % obj, file=sys.stderr)
        raise SystemExit(1)
    if run.returncode:
        sys.stderr.write(run.stderr)
        failures.append('the measurement does not read the display cache the way this test assumes')

if failures:
    print('FAIL:')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)

print('PASS: the measurement follows baseAddr and its cache flag, and no view writes the display transform over it')
