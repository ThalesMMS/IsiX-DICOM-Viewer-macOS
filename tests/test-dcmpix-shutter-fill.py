#!/usr/bin/env python3
"""What a rendered image holds outside its shutter is what shows black.

-renderWithRotation:...backgroundOffset: and -renderInRectSize:... make the
image a 16-bit export of the view stores: the pixels outside the display
shutter, the corners a turn uncovers and what a view shows beside the image
are filled. The values of an image shown inverted (MONOCHROME1) are kept as
stored, and the largest shows black: filled with the series' minimum, as an
image shown as stored is, the outside of the shutter was written 0 and reopened
white.

The probe is linked with the DCMPix of this checkout's build. For an image
shown as stored and for the same one shown inverted it records the rendered
values at those places, what the 16-bit capture stores of them (the encoding
of IsiXImaging the view's capture uses), and the 8-bit picture the screen and
the 8-bit captures take, with its shutter. As stored, nothing changes: the
series' minimum less 1024 outside the shutter and beside the image, the
minimum plus the offset in a corner. Inverted, they are at the other end,
at or above every value of the series. The 8-bit picture is black outside the
shutter either way. -renderWithRotation:... without an offset makes the layers
a fusion is merged from, and the merge draws nothing of what lies 1024 below
the minimum: that one keeps its fill in both polarities.
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

// What the view's 16-bit capture stores of `count` rendered samples.
@_cdecl("probeStore16")
public func probeStore16(_ samples: UnsafeMutablePointer<Float>, _ count: Int, _ minimumOfSeries: Float,
                         _ stored: UnsafeMutablePointer<UInt16>) -> Int32 {
    let encoding = CaptureRaster.SixteenBitEncoding(minimumOfSeries: minimumOfSeries)
    CaptureRaster.convertFloatSamples(UnsafeMutableRawPointer(samples), width: count, height: 1, slope: 1,
                                      encoding: encoding, into: UnsafeMutableRawPointer(stored))
    return encoding.isSigned ? 1 : 0
}
'''

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import "DCMPix.h"

extern void probeArbitraryRotate( double px, double py, double pz, double theta, double rx, double ry, double rz, double *out);
extern int probeStore16( float *samples, long count, float minimumOfSeries, unsigned short *stored);

XYZ ArbitraryRotate( XYZ p, double theta, XYZ r)
{
    double o[ 3];
    probeArbitraryRotate( p.x, p.y, p.z, theta, r.x, r.y, r.z, o);
    XYZ q = { o[ 0], o[ 1], o[ 2]};
    return q;
}

// Large enough for the corner of a turned image to be clear of the resampling at its edges.
enum { kWidth = 64, kHeight = 48, kMinimum = 500, kMaximum = 3500 };

// A radiograph's stored values, 500 to 3500, with a shutter that keeps its middle.
static DCMPix *makePix( BOOL inverted, BOOL shutter)
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
    if( shutter)
    {
        p.shutterRect = NSMakeRect( 16, 12, 32, 24);
        p.shutterEnabled = YES;
    }
    return p;
}

static NSDictionary *sample( DCMPix *rendered, long x, long y)
{
    if( rendered == nil) return @{@"rendered": @NO};
    float value = [rendered fImage][ y * [rendered pwidth] + x];
    unsigned short stored = 0;
    probeStore16( &value, 1, [rendered minValueOfSeries], &stored);
    float largest = -1e30f;
    for( long i = 0; i < [rendered pwidth] * [rendered pheight]; i++) if( [rendered fImage][ i] > largest) largest = [rendered fImage][ i];
    return @{@"rendered": @YES, @"value": @(value), @"stored": @(stored), @"size": @[@([rendered pwidth]), @([rendered pheight])],
             @"inverted": @([rendered displayInverted]), @"largest": @(largest)};
}

int main( int argc, const char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        NSMutableDictionary *records = [NSMutableDictionary dictionary];
        for( int inverted = 0; inverted < 2; inverted++)
        {
            NSMutableDictionary *r = [NSMutableDictionary dictionary];
            DCMPix *shuttered = makePix( inverted, YES);
            // The pixels in memory, flipped: the 16-bit export "as stored".
            DCMPix *flipped = [shuttered renderWithRotation: 0 scale: 1 xFlipped: YES yFlipped: NO backgroundOffset: 0];
            r[@"outside the shutter, flipped"] = sample( flipped, 0, 0);
            r[@"inside the shutter, flipped"] = sample( flipped, 30, 20);
            // The view at full resolution: the 16-bit export of what is shown.
            DCMPix *view = [shuttered renderInRectSize: NSMakeSize( kWidth, kHeight) atPosition: NSZeroPoint rotation: 0 scale: 1
                                              xFlipped: NO yFlipped: NO smartCrop: NO];
            r[@"outside the shutter, view"] = sample( view, 0, 0);
            r[@"inside the shutter, view"] = sample( view, 30, 20);
            // Resampled, even at the same size: the value comes back within a hundredth.
            r[@"inside is the source"] = @(view != nil && fabsf( [view fImage][ 20 * [view pwidth] + 30] - [shuttered fImage][ 20 * kWidth + 30]) < 0.01f);
            // A turn uncovers the corners: with the export's offset and with the default one.
            DCMPix *plain = makePix( inverted, NO);
            r[@"corner, export"] = sample( [plain renderWithRotation: 30 scale: 1 xFlipped: NO yFlipped: NO backgroundOffset: 0], 0, 0);
            // What a fusion is merged from: its nothing is 1024 below the minimum, whatever the polarity.
            r[@"corner, fusion layer"] = sample( [plain renderWithRotation: 30 scale: 1 xFlipped: NO yFlipped: NO], 0, 0);
            r[@"outside the shutter, fusion layer"] = sample( [shuttered renderWithRotation: 0 scale: 1 xFlipped: YES yFlipped: NO], 0, 0);
            // A view larger than the image: what it shows beside it.
            DCMPix *wide = [plain renderInRectSize: NSMakeSize( kWidth + 20, kHeight + 20) atPosition: NSZeroPoint rotation: 0 scale: 1
                                          xFlipped: NO yFlipped: NO smartCrop: NO];
            r[@"beside the image, view"] = sample( wide, 0, 0);
            // An image in no series, which knows no extremes of one.
            DCMPix *lone = makePix( inverted, YES);
            lone.minValueOfSeries = 0;
            lone.maxValueOfSeries = 0;
            r[@"outside the shutter, no series"] = sample( [lone renderWithRotation: 0 scale: 1 xFlipped: YES yFlipped: NO backgroundOffset: 0], 0, 0);
            // The 8-bit picture of the screen, with its shutter.
            DCMPix *screen = makePix( inverted, YES);
            [screen changeWLWW: 2048 : 4096];
            unsigned char *picture = (unsigned char*) [screen baseAddr];
            r[@"picture"] = picture ? @{@"outside": @(picture[ 0]), @"inside low": @(picture[ 20 * kWidth + 30]), @"inside high": @(picture[ 20 * kWidth + 31])} : @{};
            records[inverted ? @"inverted" : @"as stored"] = r;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject: records options: NSJSONWritingSortedKeys error: nil];
        printf( "%s\n", [[[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
    }
    return 0;
}
'''

MINIMUM, MAXIMUM = 500, 3500


def main():
    configuration = roi_harness.configuration()
    with tempfile.TemporaryDirectory(prefix='horos-shutter-fill-') as folder:
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

    def expect(condition, what, record):
        if not condition:
            failures.append('%s: %s' % (what, json.dumps(record, sort_keys=True)))

    stored, inverted = records['as stored'], records['inverted']
    for polarity, record in (('as stored', stored), ('inverted', inverted)):
        for name in ('outside the shutter, flipped', 'outside the shutter, view', 'corner, export', 'corner, fusion layer',
                     'outside the shutter, fusion layer', 'beside the image, view', 'outside the shutter, no series'):
            expect(record[name].get('rendered'), '%s: nothing was rendered for "%s"' % (polarity, name), record[name])
        expect(record['inside is the source'], polarity + ': the shutter keeps the pixels inside as they are', record)
        expect(record['outside the shutter, view'].get('inverted') == (polarity == 'inverted'),
               polarity + ': the rendered image keeps the polarity of its source', record['outside the shutter, view'])
        # The screen and the 8-bit captures: black outside the shutter, the image in its polarity inside.
        picture = record['picture']
        expect(picture.get('outside') == 0, polarity + ': the 8-bit picture is black outside the shutter', picture)
        brighter = picture.get('inside high', 0) > picture.get('inside low', 0)
        expect(brighter == (polarity == 'as stored') and picture.get('inside high') != picture.get('inside low'),
               polarity + ': the 8-bit picture shows the larger value ' + ('brighter' if polarity == 'as stored' else 'darker'), picture)
    if failures:
        for failure in failures:
            print('FAIL:', failure)
        sys.exit(1)

    # Shown as stored, nothing changes: the minimum less 1024 outside the shutter (stored 0), the minimum plus the offset in a corner.
    for name, value, kept in (('outside the shutter, flipped', MINIMUM - 1024, 0), ('outside the shutter, view', MINIMUM - 1024, 0),
                              ('corner, export', MINIMUM, MINIMUM), ('beside the image, view', MINIMUM - 1024, 0),
                              ('outside the shutter, no series', -1024, 0),
                              ('corner, fusion layer', MINIMUM - 1024, 0), ('outside the shutter, fusion layer', MINIMUM - 1024, 0)):
        expect(stored[name]['value'] == value and stored[name]['stored'] == kept,
               'as stored: "%s" is %d, stored %d' % (name, value, kept), stored[name])
    # The layers of a fusion keep the nothing its merge knows, inverted or not.
    for name in ('corner, fusion layer', 'outside the shutter, fusion layer'):
        expect(inverted[name]['value'] == MINIMUM - 1024, 'inverted: "%s" is %d, as the merge of a fusion takes it' % (name, MINIMUM - 1024),
               inverted[name])
    # Shown inverted, the fill is at the other end: what shows black is above every pixel of the image.
    for name, value in (('outside the shutter, flipped', MAXIMUM + 1024), ('outside the shutter, view', MAXIMUM + 1024),
                        ('corner, export', MAXIMUM), ('beside the image, view', MAXIMUM + 1024),
                        ('outside the shutter, no series', MAXIMUM + 1024)):
        expect(inverted[name]['value'] == value and inverted[name]['stored'] == value,
               'inverted: "%s" is %d, stored as it is' % (name, value), inverted[name])
        expect(inverted[name]['stored'] >= MAXIMUM, 'inverted: "%s" is stored at least the largest pixel, which shows black' % name, inverted[name])
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    print('PASS: outside the shutter and in the corners a turn uncovers, a rendered image holds what shows black: the least for an '
          'image shown as stored (unchanged), the most for one shown inverted; the 8-bit picture is black outside the shutter in both')


if __name__ == '__main__':
    main()
