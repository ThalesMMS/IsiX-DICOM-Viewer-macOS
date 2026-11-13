#!/usr/bin/env python3
"""A rendered image hides what the screen hides: the shutter's circle too.

The display shutter of an image is a rectangle, a circle, a polygon, or
several of them. The 8-bit picture the screen draws is black outside each. The
image -renderWithRotation:... makes, which a 16-bit export of the view stores,
kept everything inside the rectangle: with a circular shutter the export showed
what the screen hides, and all of it when the object states no rectangle (the
rectangle is then the whole image).

The probe is linked with the DCMPix of this checkout's build. For an image
with a circular shutter, alone and inside a rectangle, shown as stored and
shown inverted, it compares pixel by pixel what the 8-bit picture blackens
with what the rendered image fills: the same pixels, filled with what shows
black in the image's polarity. A rectangle alone hides what it always hid. The
polygon, which only the reading of a file gives an image, is compared in the
module (ShutterMaskTests) and in the application.

The rendering also rounds the rectangle and keeps it in the image. It stored
that through the property, whose setter is the user's new rectangle and
discards the polygon: one 16-bit export, and the screen no longer hid what the
polygon hides. The rendering stores the rectangle as the 8-bit picture does.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import private_tmpdir  # noqa: E402,F401  - its own TMPDIR for the tools it runs
import roi_harness  # noqa: E402

SKIPPED = 2

# The rounded rectangle goes to the storage, never through the setter that discards the polygon.
import re  # noqa: E402
GEOMETRY = (ROOT / 'Horos/Sources/DCMPix+Geometry.swift').read_text(encoding='utf-8')
assert 'horos_shutterRect = ImageRendering.shutterRect(horos_shutterRect' in GEOMETRY, 'the rendering rounds the stored rectangle'
assert not re.search(r'^\s*(?:self\.)?shutterRect\s*=[^=]', GEOMETRY, re.M), 'the rendering sets the rectangle through the property'

SWIFT = r'''
import IsiXImaging

// The rotation DCMPix's orientation correction turns with (DCMView's in the application).
@_cdecl("probeArbitraryRotate")
public func probeArbitraryRotate(_ px: Double, _ py: Double, _ pz: Double, _ theta: Double,
                                 _ rx: Double, _ ry: Double, _ rz: Double, _ out: UnsafeMutablePointer<Double>) {
    let q = PlaneGeometry.arbitraryRotate(SIMD3(px, py, pz), theta: theta, axis: SIMD3(rx, ry, rz))
    out[0] = q.x
    out[1] = q.y
    out[2] = q.z
}
'''

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import "DCMPix.h"

extern void probeArbitraryRotate( double px, double py, double pz, double theta, double rx, double ry, double rz, double *out);

XYZ ArbitraryRotate( XYZ p, double theta, XYZ r)
{
    double o[ 3];
    probeArbitraryRotate( p.x, p.y, p.z, theta, r.x, r.y, r.z, o);
    XYZ q = { o[ 0], o[ 1], o[ 2]};
    return q;
}

enum { kWidth = 64, kHeight = 48, kMinimum = 500, kMaximum = 3500 };

// Stored values 500 to 3500, none of which the window 2048/4096 draws black or white.
static DCMPix *makePix( BOOL inverted, NSRect rect, NSPoint centre, long radius)
{
    float *data = malloc( kWidth * kHeight * sizeof( float));
    for( long i = 0; i < kWidth * kHeight; i++) data[ i] = kMinimum + (float) (i % 7) * 500.f;
    DCMPix *p = [[[DCMPix alloc] initWithData: data :32 :kWidth :kHeight :1 :1 :0 :0 :0] autorelease];
    free( data);
    p.minValueOfSeries = kMinimum;
    p.maxValueOfSeries = kMaximum;
    p.srcFile = @"probe.dcm";
    [p setValue: @"DX" forKey: @"modalityString"];
    p.displayInverted = inverted;
    p.shutterRect = rect;
    [p setValue: [NSValue valueWithPoint: centre] forKey: @"shutterCircular"];
    [p setValue: @(radius) forKey: @"shutterCircular_radius"];
    p.shutterEnabled = YES;
    return p;
}

// Which pixels the 8-bit picture blackens, and which the rendered image fills beyond the values of the image.
static NSDictionary *compare( BOOL inverted, NSRect rect, NSPoint centre, long radius)
{
    DCMPix *screen = makePix( inverted, rect, centre, radius);
    [screen changeWLWW: 2048 : 4096];
    unsigned char *picture = (unsigned char*) [screen baseAddr];
    DCMPix *rendered = [makePix( inverted, rect, centre, radius) renderWithRotation: 0 scale: 1 xFlipped: NO yFlipped: NO backgroundOffset: 0];
    if( picture == NULL || rendered == nil || [rendered pwidth] != kWidth || [rendered pheight] != kHeight) return @{@"rendered": @NO};
    float *values = [rendered fImage];
    long black = 0, filled = 0, onlyScreen = 0, onlyRender = 0, wrongFill = 0;
    for( long i = 0; i < kWidth * kHeight; i++)
    {
        BOOL hiddenOnScreen = picture[ i] == 0;
        BOOL hiddenInRender = inverted ? values[ i] > kMaximum + 512 : values[ i] < kMinimum - 512;
        black += hiddenOnScreen;
        filled += hiddenInRender;
        onlyScreen += hiddenOnScreen && !hiddenInRender;
        onlyRender += hiddenInRender && !hiddenOnScreen;
        // Resampled, even at the same size: the fill comes back within a unit.
        wrongFill += hiddenInRender && fabsf( values[ i] - (inverted ? kMaximum + 1024 : kMinimum - 1024)) > 1.f;
    }
    return @{@"rendered": @YES, @"screen": @(black), @"render": @(filled), @"only the screen hides": @(onlyScreen),
             @"only the render hides": @(onlyRender), @"filled with another value": @(wrongFill), @"pixels": @(kWidth * kHeight)};
}

int main( int argc, const char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        NSMutableDictionary *records = [NSMutableDictionary dictionary];
        NSRect whole = NSMakeRect( 0, 0, kWidth, kHeight), inner = NSMakeRect( 8, 6, 48, 36);
        for( int inverted = 0; inverted < 2; inverted++)
        {
            NSString *polarity = inverted ? @"inverted" : @"as stored";
            // The object states a circle only: the rectangle is the whole image.
            records[[polarity stringByAppendingString: @", circle"]] = compare( inverted, whole, NSMakePoint( 32, 24), 15);
            records[[polarity stringByAppendingString: @", circle in a rectangle"]] = compare( inverted, inner, NSMakePoint( 30, 22), 20);
            records[[polarity stringByAppendingString: @", rectangle"]] = compare( inverted, inner, NSZeroPoint, 0);
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject: records options: NSJSONWritingSortedKeys error: nil];
        printf( "%s\n", [[[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
    }
    return 0;
}
'''

PIXELS = 64 * 48


def main():
    configuration = roi_harness.configuration()
    with tempfile.TemporaryDirectory(prefix='horos-shutter-shapes-') as folder:
        folder = Path(folder)
        extra = folder / 'probe.swift'
        extra.write_text(SWIFT)
        try:
            harness = roi_harness.build(roi_harness.WORKTREE, folder / 'harness', PROBE, config=configuration, extra_swift=(str(extra),))
        except LookupError as error:
            print('skipped: %s' % error, file=sys.stderr)
            sys.exit(SKIPPED)
        done = subprocess.run([str(harness)], capture_output=True, text=True, timeout=120)
        if done.returncode:
            print('FAIL: the probe ended with %d:\n%s' % (done.returncode, done.stderr[-3000:]))
            sys.exit(1)
        records = json.loads(done.stdout.splitlines()[-1])

    failures = []
    for name, record in sorted(records.items()):
        shown = json.dumps(record, sort_keys=True)
        if not record.get('rendered'):
            failures.append('%s: nothing was rendered: %s' % (name, shown))
            continue
        if not 0 < record['screen'] < PIXELS:
            failures.append('%s: the screen hides a part of the picture, not none nor all of it: %s' % (name, shown))
        if record['only the screen hides'] or record['only the render hides']:
            failures.append('%s: the rendered image hides the pixels the screen hides: %s' % (name, shown))
        if record['filled with another value']:
            failures.append('%s: what is hidden holds what shows black, 1024 beyond the series: %s' % (name, shown))
    # A circle hides more than the rectangle around it: the cases are not all the rectangle's.
    for polarity in ('as stored', 'inverted'):
        if not records[polarity + ', circle in a rectangle']['screen'] > records[polarity + ', rectangle']['screen']:
            failures.append('%s: the circle inside the rectangle hides more than the rectangle alone' % polarity)
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    print('PASS: with a circular shutter, alone or inside a rectangle, shown as stored or inverted, a rendered image fills '
          'exactly the pixels the 8-bit picture blackens, with what shows black; a rectangle alone hides what it did')


if __name__ == '__main__':
    main()
