#!/usr/bin/env python3
"""Check that the ROI scanline filler reports the same coordinates for RGB pixels.

`ras_FillPolygon` walks a polygon and, when asked, writes one (x, y) pair per
covered pixel. It has two inner loops, one per pixel format, and `getROIValue`
picks between them from the series. A coordinate is a property of the polygon,
so the two loops have to agree; `createLayerROIFromROI:` sizes a bitmap from the
Y range and the calcium scoring overlap test compares Y between ROIs, so a
constant Y is a wrong bitmap and a wrong overlap rather than a visible error.

This links the object file the application itself is built from, so it measures
the shipped filler and not a copy of it. Since the filler left DCMPix.m for the
IsiXROI module (ROIPolygonFill.sample, which -getROIValue::: calls), the module
is built from this checkout and run with the same polygon and the same checks.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import app_object_probe  # noqa: E402

obj = app_object_probe.built_object('DCMPix')
if obj is None:
    print('needs a built DCMPix.o: build Debug or Release once', file=sys.stderr)
    raise SystemExit(2)

# The polygon is a rectangle, so every covered pixel's row is known in advance
# and the test does not have to trust either loop to produce the expectation.
LEFT, RIGHT, TOP, BOTTOM, WIDTH, HEIGHT = 2, 6, 3, 6, 10, 10
PROBE = r'''
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>
typedef struct { long x, y; } NSPointInt;
extern "C" void ras_FillPolygon( NSPointInt *p, long no, float *pix, long w, long h, long s,
    float min, float max, BOOL outside, float newVal, BOOL addition, BOOL RGB, BOOL compute,
    float *imax, float *imin, long *count, float *itotal, float *idev, float imean,
    long orientation, long stackNo, BOOL restore, float *values, float *locations);
static const long kLeft = %(left)d, kRight = %(right)d, kTop = %(top)d, kBottom = %(bottom)d;
static const long kWidth = %(width)d, kHeight = %(height)d;
static void fill( BOOL rgb, float **locations, long *count)
{
    // Four bytes per pixel either way: the RGB loop reads this buffer as bytes.
    float *pix = (float*) calloc( kWidth * kHeight, sizeof( float));
    NSPointInt pts[ 4] = {{kLeft, kTop}, {kRight, kTop}, {kRight, kBottom}, {kLeft, kBottom}};
    float *values = (float*) calloc( kWidth * kHeight, sizeof( float));
    *locations = (float*) calloc( kWidth * kHeight * 2, sizeof( float));
    *count = 0;
    ras_FillPolygon( pts, 4, pix, kWidth, kHeight, 1, 0, 0, NO, 0, NO, rgb, YES, nil, nil,
                     count, nil, nil, 0, 2, 0, NO, values, *locations);
    free( values);
    free( pix);
}
int main(){ @autoreleasepool {
    float *grey = nil, *rgb = nil;
    long greyCount = 0, rgbCount = 0;
    fill( NO, &grey, &greyCount);
    fill( YES, &rgb, &rgbCount);
    if( greyCount == 0 || greyCount != rgbCount) {
        fprintf( stderr, "FAIL: %%ld greyscale points and %%ld RGB points\n", greyCount, rgbCount);
        return 1;
    }
    int failures = 0;
    long index = 0;
    for( long y = kTop; y <= kBottom; y++) {
        for( long x = kLeft; x <= kRight; x++, index++) {
            if( index >= greyCount) break;
            const float *pair[ 2] = {grey + 2 * index, rgb + 2 * index};
            const char *name[ 2] = {"greyscale", "RGB"};
            for( int which = 0; which < 2; which++) {
                if( pair[ which][ 0] != (float) x || pair[ which][ 1] != (float) y) {
                    if( failures < 8)
                        fprintf( stderr, "FAIL: %%s point %%ld is (%%g, %%g), expected (%%ld, %%ld)\n",
                                 name[ which], index, pair[ which][ 0], pair[ which][ 1], x, y);
                    failures++;
                }
            }
        }
    }
    const long expected = (kRight - kLeft + 1) * (kBottom - kTop + 1);
    if( greyCount != expected) {
        fprintf( stderr, "FAIL: %%ld points cover a %%ld pixel rectangle\n", greyCount, expected);
        return 1;
    }
    free( grey);
    free( rgb);
    if( failures) {
        fprintf( stderr, "FAIL: %%d of %%ld coordinates wrong\n", failures, 2 * greyCount);
        return 1;
    }
    printf( "PASS: %%ld scanline coordinates identical and correct in both pixel formats\n", greyCount);
    return 0;
}}
''' % dict(left=LEFT, right=RIGHT, top=TOP, bottom=BOTTOM, width=WIDTH, height=HEIGHT)

SWIFT_DRIVER = '''
import Foundation
import IsiXROI

let left = %(left)d, right = %(right)d, top = %(top)d, bottom = %(bottom)d, width = %(width)d, height = %(height)d
var result: [String: [Float]] = [:]
for rgb in [false, true] {
    // Four bytes per pixel either way: the RGB loop reads this buffer as bytes.
    let pixels = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
    pixels.initialize(repeating: 0, count: width * height)
    let values = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
    let locations = UnsafeMutablePointer<Float>.allocate(capacity: width * height * 2)
    let polygon = [ROIPixelPoint(x: left, y: top), ROIPixelPoint(x: right, y: top),
                   ROIPixelPoint(x: right, y: bottom), ROIPixelPoint(x: left, y: bottom)]
    let count = ROIPolygonFill.sample(polygon, image: pixels, width: width, height: height, isRGB: rgb,
                                      values: values, locations: locations, capacity: width * height)
    result[rgb ? "rgb" : "grey"] = Array(UnsafeBufferPointer(start: locations, count: count * 2))
}
print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
''' % dict(left=LEFT, right=RIGHT, top=TOP, bottom=BOTTOM, width=WIDTH, height=HEIGHT)

listing = subprocess.run(['nm', '-g', '--defined-only', str(obj)], capture_output=True, text=True).stdout
if '_ras_FillPolygon' not in listing:
    from isix_modules import module_flags
    with tempfile.TemporaryDirectory(prefix='horos-roi-scanline-') as name:
        directory = Path(name)
        (directory / 'driver.swift').write_text(SWIFT_DRIVER)
        subprocess.run(['xcrun', 'swiftc', str(directory / 'driver.swift'),
                        *module_flags('IsiXROI', directory / 'modules'), '-o', str(directory / 'driver')],
                       check=True, capture_output=True)
        sampled = json.loads(subprocess.run([str(directory / 'driver')], capture_output=True, text=True, check=True).stdout)
    grey, rgb = sampled['grey'], sampled['rgb']
    expected = [float(c) for y in range(TOP, BOTTOM + 1) for x in range(LEFT, RIGHT + 1) for c in (x, y)]
    failures = []
    if not grey or len(grey) != len(rgb):
        failures.append('%d greyscale points and %d RGB points' % (len(grey) // 2, len(rgb) // 2))
    for name, points in (('greyscale', grey), ('RGB', rgb)):
        if points != expected:
            failures.append('%s coordinates are %r, expected %r' % (name, points[:16], expected[:16]))
    for failure in failures:
        print('FAIL: ' + failure, file=sys.stderr)
    if failures:
        raise SystemExit(1)
    print('PASS: %d scanline coordinates identical and correct in both pixel formats' % (len(grey) // 2))
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='horos-roi-scanline-') as name:
    directory = Path(name)
    (directory / 'probe.mm').write_text(PROBE)
    run = app_object_probe.link_and_run(directory, [directory / 'probe.mm'], [obj], flags=['-fobjc-arc'])
    sys.stdout.write(run.stdout)
    sys.stderr.write(run.stderr)
    raise SystemExit(run.returncode)
