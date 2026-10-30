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
slices. Clamping at both ends of the series is part of the comparison, because a
slab that runs off the end is where an index rule is likely to differ.

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
    PIX_IVAR( self, short, stack) = thickness; PIX_IVAR( self, short, stackDirection) = direction; PIX_IVAR( self, short, stackMode) = mode; PIX_IVAR( self, NSInteger, pixPos) = position;
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

// The reference: the same slices this volume holds, reduced here.
static void reference( NSArray *slices, int position, int thickness, int direction,
                       int mode, float *out)
{
    DCMPix *first = [slices objectAtIndex: position];
    const long count = kSide * kSide;
    memcpy( out, [first fImage], count * sizeof( float));
    long used = 1;
    for( int i = 1; i < thickness; i++)
    {
        int index = direction ? position - i : position + i;
        if( index < 0 || index >= (int) slices.count) continue;
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
    long compared = 0, clamped = 0;
    const char *names[] = {"", "mean", "maximum", "minimum"};

    for( int mode = 1; mode <= 3; mode++)
        for( int thickness = 1; thickness <= 5; thickness++)
            for( int direction = 0; direction <= 1; direction++)
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
                    // A slab that runs off the end is the interesting half.
                    int far = direction ? position - (thickness - 1) : position + (thickness - 1);
                    if( far < 0 || far >= kSlices) clamped++;
                    compared++;
                    free( got);
                }

    check( compared == 3 * 5 * 2 * kSlices, "every combination must have been compared");
    check( clamped > 0, "the comparison must include slabs that run off the end of the series");

    if( failures) { fprintf( stderr, "FAIL: %d check%s\n", failures, failures == 1 ? "" : "s"); return 1; }
    printf( "%ld slabs matched the reference, %ld of them clamped at an end", compared, clamped);
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
