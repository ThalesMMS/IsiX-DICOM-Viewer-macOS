#!/usr/bin/env python3
"""The CPU thick slab, against an independent reference.

A215 asks that the same volume and thick slab in **VRT** match a CPU reference
across thicknesses and orientations. Nothing in the repository had a CPU
reference at all, so there was nothing for a VRT rendering to be compared
against.

This is that reference, and it is measured against the application's own
`-[DCMPix computeThickSlab]` rather than written beside it: the probe builds a
small volume, runs the shipped method under every mode, thickness and direction,
and compares it with a mean, maximum and minimum computed here from the same
slices. The slab is centred on the slice shown, with the slice more of an even
slab on the side the slab goes, and is pulled back inside the series at both
ends, where it keeps its slices; a slab of more slices than the series has is
the whole series. The ends are part of the comparison, because a slab that
would run off the end is where an index rule is likely to differ, and there the
slices that show the same slab must give the same floats, bit for bit: the
image stops while the slice shown goes on.

This is not the VRT comparison the criterion finishes with; it is the half that
has to be right before that comparison means anything.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import app_object_probe  # noqa: E402
import roi_harness  # noqa: E402

obj = app_object_probe.built_object('DCMPix')
if obj is None:
    print('needs a built DCMPix.o: build Debug or Release once', file=sys.stderr)
    raise SystemExit(2)

PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
// PIX_IVARS
#include <cstdio>
#include <cstdlib>
#include <cmath>

static const int kSide = 16;
static const int kSlices = 9;

// Not declared in DCMPix.h; it is the CPU slab this test exists to measure.
@interface DCMPix (HorosThickSlabProbe)
- (float*) computeThickSlab;
@end

@interface ProbePix : DCMPix
- (void) prepareSlice:(int) index;
- (void) setSlab:(int) thickness direction:(int) direction mode:(int) mode position:(int) position array:(NSArray*) array;
@end
@implementation ProbePix
- (void) CheckLoad {}
- (void) prepareSlice:(int) index
{
    PIX_IVAR( self, long, width) = PIX_IVAR( self, long, height) = kSide; PIX_IVAR( self, BOOL, isRGB) = NO; PIX_IVAR( self, BOOL, thickSlabVRActivated) = NO;
    float *fImage = PIX_IVAR( self, float*, fImage) = (float*) calloc( kSide * kSide, sizeof( float));
    // Every slice different, and not monotonic in the slice index, so a mean
    // cannot be mistaken for a maximum and a slab taken from the wrong side
    // shows up as a difference rather than as the same answer.
    for( int y = 0; y < kSide; y++)
        for( int x = 0; x < kSide; x++)
            fImage[ y * kSide + x] = (float)((x * 7 + y * 3) % 23) + (float)((index * index * 5) % 17) * 10.f;
}
- (void) setSlab:(int) thickness direction:(int) direction mode:(int) mode position:(int) position array:(NSArray*) array
{
    PIX_IVAR( self, short, stack) = thickness; PIX_IVAR( self, short, stackDirection) = direction; PIX_IVAR( self, short, stackMode) = mode; PIX_IVAR( self, short, pixPos) = position;
    [PIX_IVAR( self, NSArray*, pixArray) release];
    PIX_IVAR( self, NSArray*, pixArray) = [array retain];
    PIX_IVAR( self, float, ww) = 256; PIX_IVAR( self, float, wl) = 127;
}
@end

static int failures = 0;
static void check( bool ok, const char *what)
{
    if( !ok) { fprintf( stderr, "FAIL: %s\n", what); failures++; }
}

// The slices of a slab, written here apart from the application's rule:
// `thickness` of them, (thickness - 1) / 2 before `position` in the slab's
// direction and the rest after it, moved back inside the series at an end, and
// all the series when it has fewer.
static void slabRange( int position, int thickness, int direction, int count, int *first, int *last)
{
    int slices = thickness < count ? thickness : count;
    if( slices < 1) slices = 1;
    int before = (slices - 1) / 2, after = slices - 1 - before;
    int low = direction ? position - after : position - before;
    if( low < 0) low = 0;
    if( low > count - slices) low = count - slices;
    *first = low;
    *last = low + slices - 1;
}

// The reference: the same slices this volume holds, reduced here, from the
// near end of the slab to its far end.
static void reference( NSArray *slices, int position, int thickness, int direction,
                       int mode, float *out)
{
    int low, high;
    slabRange( position, thickness, direction, (int) slices.count, &low, &high);
    const int start = direction ? high : low, step = direction ? -1 : 1;
    const long count = kSide * kSide;
    memcpy( out, [(DCMPix*) [slices objectAtIndex: start] fImage], count * sizeof( float));
    long used = 1;
    for( int index = start + step; index >= low && index <= high; index += step)
    {
        float *next = [[slices objectAtIndex: index] fImage];
        for( long p = 0; p < count; p++)
        {
            if( mode == 2) out[ p] = MAX( out[ p], next[ p]);
            else if( mode == 3) out[ p] = MIN( out[ p], next[ p]);
            else out[ p] += next[ p];
        }
        used++;
    }
    if( mode == 1 && used > 1)
        for( long p = 0; p < count; p++) out[ p] /= (float) used;
}

int main(){ @autoreleasepool {
    NSMutableArray *slices = [NSMutableArray array];
    for( int i = 0; i < kSlices; i++)
    {
        ProbePix *pix = [[ProbePix alloc] init];
        [pix prepareSlice: i];
        [slices addObject: pix];
    }

    float *expected = (float*) malloc( kSide * kSide * sizeof( float));
    float *previous = (float*) malloc( kSide * kSide * sizeof( float));
    long compared = 0, pulledBack = 0, whole = 0, repeated = 0;
    const char *names[] = {"", "mean", "maximum", "minimum"};
    // Odd and even slabs, one of all the slices and one of more than there are.
    const int thicknesses[] = {1, 2, 3, 4, 5, 6, kSlices, kSlices + 3};
    const int thicknessCount = sizeof thicknesses / sizeof thicknesses[ 0];

    for( int mode = 1; mode <= 3; mode++)
        for( int t = 0; t < thicknessCount; t++)
            for( int direction = 0; direction <= 1; direction++)
            {
                const int thickness = thicknesses[ t];
                int previousLow = -1, previousHigh = -1;
                for( int position = 0; position < kSlices; position++)
                {
                    ProbePix *pix = [slices objectAtIndex: position];
                    [pix setSlab: thickness direction: direction mode: mode position: position array: slices];

                    float *got = [pix computeThickSlab];
                    if( got == nil) { check( false, "computeThickSlab returned nothing"); continue; }

                    reference( slices, position, thickness, direction, mode, expected);

                    long differing = 0;
                    float worst = 0;
                    for( long p = 0; p < kSide * kSide; p++)
                    {
                        float delta = fabsf( got[ p] - expected[ p]);
                        if( delta > 0.001f) { differing++; if( delta > worst) worst = delta; }
                    }
                    if( differing)
                    {
                        char message[ 260];
                        snprintf( message, sizeof message,
                                  "%s slab of %d at slice %d, direction %d: %ld of %d pixels differ, worst %g",
                                  names[ mode], thickness, position, direction, differing, kSide * kSide, worst);
                        check( false, message);
                    }
                    // A slab that would run off an end is the interesting half:
                    // it is pulled back, and the slice shown is not its middle.
                    int low, high;
                    slabRange( position, thickness, direction, kSlices, &low, &high);
                    const int before = (thickness - 1) / 2, after = thickness - 1 - before;
                    const int centredLow = direction ? position - after : position - before;
                    if( thickness > kSlices) whole++;
                    else if( centredLow != low) pulledBack++;
                    // The slices that show one slab show the same floats.
                    if( low == previousLow && high == previousHigh)
                    {
                        if( memcmp( got, previous, kSide * kSide * sizeof( float)) != 0)
                        {
                            char message[ 260];
                            snprintf( message, sizeof message,
                                      "%s slab of %d, direction %d: slices %d and %d show the slab %d to %d with different floats",
                                      names[ mode], thickness, direction, position - 1, position, low, high);
                            check( false, message);
                        }
                        repeated++;
                    }
                    memcpy( previous, got, kSide * kSide * sizeof( float));
                    previousLow = low; previousHigh = high;
                    compared++;
                    free( got);
                }
            }

    check( compared == 3 * thicknessCount * 2 * kSlices, "every combination must have been compared");
    check( pulledBack > 0, "the comparison must include slabs pulled back from an end of the series");
    check( whole == 3 * 2 * kSlices, "the comparison must include slabs of more slices than the series has");
    check( repeated > 0, "the comparison must include slices that show the same slab");

    if( failures) { fprintf( stderr, "FAIL: %d check%s\n", failures, failures == 1 ? "" : "s"); return 1; }
    printf( "%ld slabs matched the reference, %ld of them pulled back from an end, %ld the whole series, %ld the same floats as the slice before",
            compared, pulledBack, whole, repeated);
    return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-thick-slab-') as name:
    directory = Path(name)
    (directory / 'probe.mm').write_text(PROBE.replace('// PIX_IVARS\n', roi_harness.PIX_IVARS))
    # The shipped method dispatches worker threads and waits on condition
    # locks; a deadlock must fail rather than hang the suite.
    try:
        run = app_object_probe.link_and_run(directory, [directory / 'probe.mm'], [obj], always_stub=('ROI',))
    except subprocess.TimeoutExpired:
        print('FAIL: computeThickSlab did not finish in 120 s', file=sys.stderr)
        raise SystemExit(1)

if run.returncode:
    sys.stderr.write(run.stderr)
    print('FAIL: the CPU thick slab does not match the reference')
    raise SystemExit(1)

print('PASS: %s' % run.stdout.strip())
