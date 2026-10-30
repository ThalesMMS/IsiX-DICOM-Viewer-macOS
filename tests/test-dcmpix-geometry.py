#!/usr/bin/env python3
"""DCMPix's geometry and coordinates, bit for bit.

What this compares, between this checkout and the last revision of DCMPix.m that
did it in Objective-C, running the same probe against both:

* the orientation: -orientation:, -orientationDouble:, -setOrientation:,
  -setOrientationDouble: (unit, unnormalised, without a normal),
  -identicalOrientationTo: and -is3DPlane;
* the coordinates: pixel to patient (-convertPixX:pixY:toDICOMCoords: and its
  double version, with and without the pixel centre), patient to slice
  (-convertDICOMCoords:toSliceCoords: and its double version),
  -getSliceCenter3DCoords:, +nearestSliceInPixelList:withDICOMCoords:sliceCoords:,
  +originDeltaBetween:And:, +originCorrectedAccordingToOrientation:,
  -rectCoordinates and +rotatePoint:aroundPoint:angle:;
* the rendering: -orientationCorrected:rotation:xFlipped:yFlipped:,
  -usefulRectWithRotation:..., -renderWithRotation:... (rotations, scales,
  flips, background, shutter), -renderInRectSize:... with and without the smart
  crop, -renderNSImageInRectSize:..., -mergeWithDCMPix:offset: and
  -drawImage:inImage:offset:background:transparency:.

Every value is recorded as hexadecimal floating point and every buffer by a hash
of its bytes. ArbitraryRotate, which the orientation correction rotates with, is
DCMView's in the application; the probe gives both revisions the same one, the
IsiXImaging rotation DCMView calls.

    python3 tests/test-dcmpix-geometry.py [REFERENCE_REVISION]

Once DCMPix itself is Swift, no revision of DCMPix.m links with this checkout's
Swift: the reference is then what the probe answered against the last
Objective-C class, kept for each configuration in
tests/fixtures/dcmpix-geometry-records.json (HOROS_RECORD_GOLDEN=1 on a checkout
of that class writes them).

HOROS_TEST_CONFIGURATION=Release compares the Release builds.
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import roi_harness  # noqa: E402
from history_reference import before_text_removed, show  # noqa: E402

PIX = 'Horos/Sources/DCMPix.m'
# The records of the last Objective-C class, in tests/fixtures.
GOLDEN = 'dcmpix-geometry'
# What DCMPix.m defines while it still renders and converts coordinates itself.
OBJC_MARKER = '- (DCMPix*) renderWithRotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF backgroundOffset: (float) bgO'
# The Swift extension of DCMPix that took this part out of DCMPix.m.
MOVED = ('DCMPix+Geometry',)
SKIPPED = 2
configuration = roi_harness.configuration()

# The rotation ArbitraryRotate does in the application (DCMView), for both revisions.
ROTATION = r'''
import IsiXImaging

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
#import <Accelerate/Accelerate.h>
#import "DCMPix.h"

// Declared by no header of a revision that keeps them in DCMPix.m: without this,
// their float arguments would be passed as doubles.
@interface DCMPix (GeometryProbe)
- (void) orientationCorrected:(float*) correctedOrientation rotation:(float) rotation xFlipped: (BOOL) xFlipped yFlipped: (BOOL) yFlipped;
- (void) drawImage: (vImage_Buffer*) src inImage: (vImage_Buffer*) dst offset:(NSPoint) oo background:(float) b transparency: (BOOL) t;
- (void) drawImage: (vImage_Buffer*) src inImage: (vImage_Buffer*) dst offset:(NSPoint) oo background:(float) b;
@end

extern void probeArbitraryRotate( double px, double py, double pz, double theta, double rx, double ry, double rz, double *out);

XYZ ArbitraryRotate( XYZ p, double theta, XYZ r)
{
    double o[ 3];
    probeArbitraryRotate( p.x, p.y, p.z, theta, r.x, r.y, r.z, o);
    XYZ q = { o[ 0], o[ 1], o[ 2]};
    return q;
}

static NSMutableArray *gRecords = nil;

static void record( NSString *name, id value) { [gRecords addObject: @{@"name": name, @"value": value ?: [NSNull null]}]; }
static NSString *hd( double v) { return [NSString stringWithFormat: @"%a", v]; }
static NSArray *fl( const float *f, int n) { NSMutableArray *a = [NSMutableArray array]; for( int i = 0; i < n; i++) [a addObject: hd( f[ i])]; return a; }
static NSArray *dl( const double *d, int n) { NSMutableArray *a = [NSMutableArray array]; for( int i = 0; i < n; i++) [a addObject: hd( d[ i])]; return a; }
static NSArray *pt( NSPoint p) { return @[hd( p.x), hd( p.y)]; }
static NSArray *rc( NSRect r) { return @[hd( r.origin.x), hd( r.origin.y), hd( r.size.width), hd( r.size.height)]; }

static NSString *hashOf( const void *bytes, long count)
{
    if( bytes == NULL) return @"none";
    unsigned long long h = 1469598103934665603ULL;
    const unsigned char *b = bytes;
    for( long i = 0; i < count; i++) { h ^= b[ i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat: @"%016llx", h];
}

static DCMPix *makePix( long w, long h, float sx, float sy, double ox, double oy, double oz, const double *cosines, float seed)
{
    float *data = malloc( w * h * sizeof( float));
    for( long i = 0; i < w * h; i++) data[ i] = seed + (float) ((i * 37 + (i / w) * 11) % 251) * 1.5f - 100.f;
    DCMPix *p = [[[DCMPix alloc] initWithData: data :32 :w :h :sx :sy :0 :0 :0] autorelease];
    free( data);
    double o[ 3] = { ox, oy, oz};
    [p setOriginDouble: o];
    if( cosines) [p setOrientationDouble: (double*) cosines];
    p.minValueOfSeries = -1024;
    p.srcFile = @"probe.dcm";    // -copyWithZone: copies both
    [p setValue: @"CT" forKey: @"modalityString"];
    return p;
}

static NSDictionary *pixState( DCMPix *p)
{
    if( p == nil) return (id) [NSNull null];
    double o[ 9], origin[ 3];
    [p orientationDouble: o];
    [p originDouble: origin];
    return @{@"size": @[@([p pwidth]), @([p pheight])], @"pixels": hashOf( [p fImage], [p pwidth] * [p pheight] * 4),
             @"orientation": dl( o, 9), @"origin": dl( origin, 3), @"spacing": @[hd( [p pixelSpacingX]), hd( [p pixelSpacingY])],
             @"ratio": hd( [p pixelRatio]), @"rgb": @([p isRGB])};
}

static const double kAxial[ 6] = { 1, 0, 0, 0, 1, 0};
static const double kCoronal[ 6] = { 1, 0, 0, 0, 0, -1};
static const double kSagittal[ 6] = { 0, 1, 0, 0, 0, -1};
static const double kOblique[ 6] = { 0.8660254, 0.5, 0.1, -0.4924038, 0.8528685, 0.17364818};
static const double kUnnormalised[ 6] = { 2, 0, 0, 0, 3, 0.5};

static NSArray *pixes( void)
{
    return @[makePix( 64, 48, 0.703125, 0.6640625, -120.25, 33.125, 17.5, kAxial, 0),
             makePix( 40, 30, 1, 1, 10, -20.5, 300.75, kCoronal, 7),
             makePix( 33, 21, 0.5, 0.8, -7.3, 0.1, -55.55, kSagittal, -3),
             makePix( 37, 23, 0.7, 0.9, 101.1, -77.7, 12.34, kOblique, 11),
             makePix( 25, 35, 1.25, 0.6, 0, 0, 0, kUnnormalised, 5),
             makePix( 20, 16, 0.9, 0.9, 3.3, 4.4, 5.5, NULL, 2)];
}

static void orientations( NSArray *list)
{
    int index = 0;
    for( DCMPix *p in list)
    {
        float f[ 9]; double d[ 9];
        [p orientation: f];
        [p orientationDouble: d];
        record( [NSString stringWithFormat: @"orientation-%d", index], @{@"float": fl( f, 9), @"double": dl( d, 9), @"3D": @([p is3DPlane])});
        index++;
    }
    DCMPix *p = makePix( 8, 8, 1, 1, 0, 0, 0, NULL, 0);
    float cosines[ 9] = { 0.6f, 0.8f, 0, -0.8f, 0.6f, 0.25f, 9, 9, 9};
    [p setOrientation: cosines];
    double d[ 9]; [p orientationDouble: d];
    record( @"set-orientation-float", dl( d, 9));
    NSMutableArray *same = [NSMutableArray array];
    DCMPix *near = makePix( 8, 8, 1, 1, 0, 0, 0, kOblique, 0);
    double nudged[ 6] = { 0.8660254 + 0.0004, 0.5, 0.1, -0.4924038, 0.8528685, 0.17364818};
    DCMPix *nudgedPix = makePix( 8, 8, 1, 1, 0, 0, 0, nudged, 0);
    double far[ 6] = { 0.8660254 + 0.01, 0.5, 0.1, -0.4924038, 0.8528685, 0.17364818};
    DCMPix *farPix = makePix( 8, 8, 1, 1, 0, 0, 0, far, 0);
    for( DCMPix *a in list) for( DCMPix *b in @[near, nudgedPix, farPix, list[ 0]]) [same addObject: @([a identicalOrientationTo: b])];
    record( @"identical-orientation", same);
}

static void coordinates( NSArray *list)
{
    float points[][ 2] = { {0, 0}, {10.5, 20.25}, {-3.7, 511.9}, {255.5, 0.125}, {1e4, -1e-3}, {31, 23}};
    double patient[][ 3] = { {0, 0, 0}, {1.5, -2.25, 17.5}, {-120.25, 33.125, 17.5}, {101.1, -77.7, 12.34}, {1e3, -1e3, 0.333}};
    int index = 0;
    for( DCMPix *p in list)
    {
        NSMutableArray *out = [NSMutableArray array];
        for( int i = 0; i < 6; i++)
        {
            float x = points[ i][ 0], y = points[ i][ 1];
            float a[ 3], b[ 3], c[ 3]; double da[ 3], db[ 3], dc[ 3];
            [p convertPixX: x pixY: y toDICOMCoords: a];
            [p convertPixX: x pixY: y toDICOMCoords: b pixelCenter: YES];
            [p convertPixX: x pixY: y toDICOMCoords: c pixelCenter: NO];
            [p convertPixDoubleX: x * 1.000001 pixY: y toDICOMCoords: da];
            [p convertPixDoubleX: x pixY: y * 0.999 toDICOMCoords: db pixelCenter: YES];
            [p convertPixDoubleX: x pixY: y toDICOMCoords: dc pixelCenter: NO];
            [out addObject: @[fl( a, 3), fl( b, 3), fl( c, 3), dl( da, 3), dl( db, 3), dl( dc, 3)]];
        }
        for( int i = 0; i < 5; i++)
        {
            float f[ 3] = { patient[ i][ 0], patient[ i][ 1], patient[ i][ 2]};
            float a[ 3], b[ 3], c[ 3]; double da[ 3], db[ 3], dc[ 3];
            [p convertDICOMCoords: f toSliceCoords: a];
            [p convertDICOMCoords: f toSliceCoords: b pixelCenter: YES];
            [p convertDICOMCoords: f toSliceCoords: c pixelCenter: NO];
            [p convertDICOMCoordsDouble: patient[ i] toSliceCoords: da];
            [p convertDICOMCoordsDouble: patient[ i] toSliceCoords: db pixelCenter: YES];
            [p convertDICOMCoordsDouble: patient[ i] toSliceCoords: dc pixelCenter: NO];
            [out addObject: @[fl( a, 3), fl( b, 3), fl( c, 3), dl( da, 3), dl( db, 3), dl( dc, 3)]];
        }
        float center[ 3];
        [p getSliceCenter3DCoords: center];
        [p getSliceCenter3DCoords: NULL];
        [out addObject: fl( center, 3)];
        [out addObject: pt( [DCMPix originCorrectedAccordingToOrientation: p])];
        [out addObject: rc( [p rectCoordinates])];
        NSMutableArray *deltas = [NSMutableArray array];
        for( DCMPix *q in list) [deltas addObject: pt( [DCMPix originDeltaBetween: p And: q])];
        [out addObject: deltas];
        record( [NSString stringWithFormat: @"coordinates-%d", index], out);
        index++;
    }
    DCMPix *flat = makePix( 10, 10, 0, 0, 1, 2, 3, kAxial, 0);
    record( @"no-spacing", @[rc( [flat rectCoordinates]), pt( [DCMPix originDeltaBetween: flat And: list[ 0]]), pt( [DCMPix originDeltaBetween: list[ 0] And: flat])]);

    NSMutableArray *stack = [NSMutableArray array];
    for( int i = 0; i < 5; i++) [stack addObject: makePix( 16, 16, 0.8, 0.8, -6, -6, 2.5 * i - 1, kAxial, i)];
    [stack addObject: makePix( 16, 16, 0.8, 0.8, 0, 0, 3.7, kOblique, 9)];
    float targets[][ 3] = { {1, 2, 3.6}, {0, 0, -4}, {5, 5, 8.76}, {0, 0, 6.25}, {1, 1, 1.25}, {-2, 7, 3.7}};
    NSMutableArray *nearest = [NSMutableArray array];
    for( int i = 0; i < 6; i++)
    {
        float sc[ 3] = { 7, 7, 7};
        int n = [DCMPix nearestSliceInPixelList: stack withDICOMCoords: targets[ i] sliceCoords: sc];
        [nearest addObject: @[@(n), fl( sc, 3)]];
    }
    float sc[ 3] = { 7, 7, 7};
    [nearest addObject: @[@([DCMPix nearestSliceInPixelList: @[] withDICOMCoords: targets[ 0] sliceCoords: sc]), fl( sc, 3)]];
    record( @"nearest-slice", nearest);

    NSMutableArray *rotated = [NSMutableArray array];
    NSPoint centers[] = { {0, 0}, {12.5, -3.25}, {256, 256}};
    NSPoint ps[] = { {0, 0}, {1, 0}, {10.75, -20.5}, {-300.125, 77.3}};
    float angles[] = { 0, 0.5f, -1.0471976f, 3.14159265f, 7.5f, 1.5707964f};
    for( int c = 0; c < 3; c++) for( int p = 0; p < 4; p++) for( int a = 0; a < 6; a++)
        [rotated addObject: pt( [DCMPix rotatePoint: ps[ p] aroundPoint: centers[ c] angle: angles[ a]])];
    record( @"rotate-point", rotated);
}

static const float kRotations[] = { 0, 90, 45, -30, 180, 270, 12.5};
static const float kScales[] = { 1, 0.75, 1.6};

static void rendering( NSArray *list)
{
    DCMPix *oblique = list[ 3], *axial = list[ 0];
    for( DCMPix *p in @[axial, oblique])
    {
        NSMutableArray *corrected = [NSMutableArray array], *useful = [NSMutableArray array];
        for( int r = 0; r < 7; r++) for( int f = 0; f < 4; f++)
        {
            float o[ 9];
            [p orientationCorrected: o rotation: kRotations[ r] + 3.3f * f xFlipped: f & 1 yFlipped: f & 2];
            [corrected addObject: fl( o, 9)];
            for( int s = 0; s < 3; s++)
                [useful addObject: rc( [p usefulRectWithRotation: kRotations[ r] scale: kScales[ s] xFlipped: f & 1 yFlipped: f & 2])];
        }
        record( [NSString stringWithFormat: @"orientation-corrected-%ld", [p pwidth]], corrected);
        record( [NSString stringWithFormat: @"useful-rect-%ld", [p pwidth]], useful);
    }

    NSMutableArray *renders = [NSMutableArray array];
    for( int r = 0; r < 7; r++) for( int s = 0; s < 3; s++) for( int f = 0; f < 4; f++)
        [renders addObject: pixState( [oblique renderWithRotation: kRotations[ r] scale: kScales[ s] xFlipped: f & 1 yFlipped: f & 2])];
    record( @"render", renders);
    record( @"render-background", @[pixState( [oblique renderWithRotation: 30 scale: 1.2 xFlipped: NO yFlipped: YES backgroundOffset: 0]),
                                    pixState( [oblique renderWithRotation: 90 scale: 1 xFlipped: YES yFlipped: NO backgroundOffset: 55.5])]);

    DCMPix *shuttered = makePix( 37, 23, 0.7, 0.9, 101.1, -77.7, 12.34, kOblique, 11);
    shuttered.shutterEnabled = YES;
    shuttered.shutterRect = NSMakeRect( 3.4, -2.2, 20.6, 30.7);
    NSDictionary *shutterRender = pixState( [shuttered renderWithRotation: 45 scale: 1.1 xFlipped: YES yFlipped: NO]);
    record( @"render-shutter", @[shutterRender, rc( shuttered.shutterRect)]);

    float rgbData[ 4 * 4];
    memset( rgbData, 0, sizeof rgbData);
    DCMPix *rgb = [[[DCMPix alloc] initWithData: rgbData :8 :4 :4 :1 :1 :0 :0 :0] autorelease];
    rgb.srcFile = @"probe.dcm";
    [rgb setValue: @"CT" forKey: @"modalityString"];
    record( @"render-rgb", @[@([rgb renderWithRotation: 10 scale: 1 xFlipped: NO yFlipped: NO] == nil),
                             @([rgb renderInRectSize: NSMakeSize( 8, 8) atPosition: NSZeroPoint rotation: 0 scale: 1 xFlipped: NO yFlipped: NO] == nil),
                             @([rgb renderNSImageInRectSize: NSMakeSize( 8, 8) atPosition: NSZeroPoint rotation: 0 scale: 1 xFlipped: NO yFlipped: NO] == nil),
                             @([axial mergeWithDCMPix: rgb offset: NSZeroPoint] == nil), @([rgb mergeWithDCMPix: axial offset: NSZeroPoint] == nil),
                             @([axial mergeWithDCMPix: nil offset: NSZeroPoint] == nil)]);

    NSMutableArray *inRect = [NSMutableArray array];
    NSSize sizes[] = { {64, 48}, {20, 10}};
    NSPoint positions[] = { {0, 0}, {5.5, -3.2}};
    for( int z = 0; z < 2; z++) for( int q = 0; q < 2; q++) for( int r = 0; r < 2; r++) for( int f = 0; f < 2; f++) for( int c = 0; c < 2; c++)
        [inRect addObject: pixState( [oblique renderInRectSize: sizes[ z] atPosition: positions[ q] rotation: r * 30 scale: 1 + 0.3 * r
                                                     xFlipped: f yFlipped: NO smartCrop: c])];
    [inRect addObject: pixState( [oblique renderInRectSize: NSMakeSize( 50, 40) atPosition: NSMakePoint( 2, 3) rotation: 15 scale: 0.9 xFlipped: NO yFlipped: YES])];
    record( @"render-in-rect", inRect);

    NSImage *image = [oblique renderNSImageInRectSize: NSMakeSize( 50, 40) atPosition: NSMakePoint( 2, 3) rotation: 15 scale: 0.9 xFlipped: NO yFlipped: YES];
    NSBitmapImageRep *bitmap = (NSBitmapImageRep*) [[image representations] firstObject];
    record( @"render-image", @[@([image size].width), @([image size].height), NSStringFromClass( [bitmap class]) ?: @"",
                               [bitmap isKindOfClass: [NSBitmapImageRep class]] ? hashOf( [bitmap bitmapData], [bitmap bytesPerRow] * [bitmap pixelsHigh]) : @""]);

    DCMPix *base = makePix( 40, 30, 0.8, 0.8, -10, 5, 2, kAxial, 0);
    DCMPix *other = makePix( 25, 35, 0.8, 0.8, -3, 8, 2, kAxial, 40);
    DCMPix *otherWindow = makePix( 25, 35, 0.8, 0.8, -3, 8, 2, kAxial, 40);
    [base changeWLWW: 40 :400];
    [other changeWLWW: 40 :400];
    [otherWindow changeWLWW: 100 :1000];
    NSMutableArray *merged = [NSMutableArray array];
    NSPoint offsets[] = { {0, 0}, {7.6, -4.2}, {-30, 50}, {3, 3}};
    for( int i = 0; i < 4; i++)
    {
        [merged addObject: pixState( [base mergeWithDCMPix: other offset: offsets[ i]])];
        [merged addObject: pixState( [base mergeWithDCMPix: otherWindow offset: offsets[ i]])];
    }
    record( @"merge", merged);

    NSMutableArray *drawn = [NSMutableArray array];
    float srcData[ 8 * 6], dstData[ 20 * 15];
    for( int i = 0; i < 48; i++) srcData[ i] = (i % 3 == 0) ? 2000.5f + i : -50.25f + i;
    NSPoint origins[] = { {-3, -2}, {5, 4}, {15, 12}, {30, 30}, {-20, 3}, {2.9, 1.7}};
    for( int o = 0; o < 6; o++) for( int t = 0; t < 2; t++)
    {
        for( int i = 0; i < 300; i++) dstData[ i] = 0.5f * i - 7;
        vImage_Buffer src = { srcData, 6, 8, 8 * 4}, dst = { dstData, 15, 20, 20 * 4};
        [base drawImage: &src inImage: &dst offset: origins[ o] background: 1000.25f transparency: t];
        [drawn addObject: hashOf( dstData, sizeof dstData)];
    }
    for( int i = 0; i < 300; i++) dstData[ i] = 1;
    vImage_Buffer src = { srcData, 6, 8, 8 * 4}, dst = { dstData, 15, 20, 20 * 4};
    [base drawImage: &src inImage: &dst offset: NSMakePoint( 4, 4) background: -3];
    [drawn addObject: hashOf( dstData, sizeof dstData)];
    record( @"draw-image", drawn);
}

int main( int argc, const char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        gRecords = [[NSMutableArray alloc] init];
        NSArray *list = pixes();
        orientations( list);
        coordinates( list);
        rendering( list);
        for( NSDictionary *r in gRecords)
        {
            NSData *json = [NSJSONSerialization dataWithJSONObject: r options: NSJSONWritingSortedKeys error: nil];
            printf( "%s\n", [[[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
        }
        fflush( stdout);
    }
    return 0;
}
'''


def run(harness):
    try:
        done = subprocess.run([str(harness)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise RuntimeError('the probe did not finish in 60 s')
    if done.returncode:
        raise RuntimeError(f'the probe ended with {done.returncode}:\n{done.stderr[-3000:]}')
    records = {}
    for line in done.stdout.splitlines():
        record = json.loads(line)
        records[record['name']] = record['value']
    return records


def build(revision, folder):
    rotation = folder.parent / 'rotation.swift'
    rotation.write_text(ROTATION)
    if revision == roi_harness.WORKTREE:
        return roi_harness.build(revision, folder, PROBE, config=configuration, extra_swift=(str(rotation),))
    # The revision's DCMPix.m already calls the Swift that left it before this
    # part did; it gets this checkout's, without the extension that took this.
    keep = [name for name in roi_harness.swift_dcmpix_files() if name not in MOVED]
    return roi_harness.build(revision, folder, PROBE, config=configuration, extra_swift=(str(rotation),), dcmpix_swift=keep)


def check_expectations(records, failures):
    """What the records must show whatever the revision: each part did its work."""
    renders = records.get('render', [])
    if len({str(r) for r in renders}) < len(renders) // 2:
        failures.append('the renders are mostly the same: the rotation, scale or flips had no effect')
    if records.get('identical-orientation', [None])[:3] == [True, True, True]:
        failures.append('an orientation 0.01 away is taken as identical')
    if not records.get('merge') or records['merge'][0] is None:
        failures.append('the merge made nothing')


def main():
    swift_class = not roi_harness.objc_class()
    current_text = '' if swift_class else (ROOT / PIX).read_bytes().decode('latin1')
    delegates = OBJC_MARKER not in current_text
    if swift_class:
        # No revision of DCMPix.m links with the Swift class: the reference is
        # what this test recorded against the last Objective-C class.
        reference = None
    elif len(sys.argv) > 1:
        reference = sys.argv[1]
    elif not delegates:
        reference = 'HEAD'
    elif OBJC_MARKER in show('HEAD', PIX).decode('latin1'):
        reference = 'HEAD'
    else:
        reference = before_text_removed(PIX, OBJC_MARKER)
    if reference is None and not swift_class:
        print('skipped: no revision of DCMPix.m in this history renders in Objective-C', file=sys.stderr)
        sys.exit(SKIPPED)

    failures = []
    outputs = {}
    with tempfile.TemporaryDirectory(prefix='horos-dcmpix-geometry-') as tmp:
        tmp = Path(tmp)
        for label, revision in ((('reference', reference),) if reference else ()) + (('current', roi_harness.WORKTREE),):
            (tmp / label).mkdir()
            try:
                harness = build(revision, tmp / label / 'harness')
            except LookupError as error:
                print('skipped: %s' % error, file=sys.stderr)
                sys.exit(SKIPPED)
            except (subprocess.CalledProcessError, RuntimeError) as error:
                print(f'FAIL: the {label} harness ({revision}) did not build: {str(error)[-4000:]}')
                sys.exit(1)
            try:
                outputs[label] = run(harness)
            except RuntimeError as error:
                print(f'FAIL: {label}: {error}')
                sys.exit(1)
        if os.environ.get('HOROS_GEOMETRY_RECORDS'):
            Path(os.environ['HOROS_GEOMETRY_RECORDS']).write_text(json.dumps(outputs, indent=1, sort_keys=True))

    current = outputs['current']
    against = reference[:12] if reference else 'the records of the last Objective-C class'
    try:
        previous = outputs['reference'] if reference else roi_harness.golden(GOLDEN, configuration)
    except LookupError as error:
        print(f'FAIL: {error}')
        sys.exit(1)
    check_expectations(current, failures)
    for problem in roi_harness.diff(previous, current):
        failures.append('differs from the reference: ' + problem)
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    if roi_harness.recording_golden():
        roi_harness.golden(GOLDEN, configuration, current)
    print(f'PASS: {len(current)} records (orientation, coordinates, nearest slice, origins, rotations, renders, merges, '
          f'blits) identical to {against} in {configuration}')


if __name__ == '__main__':
    main()
