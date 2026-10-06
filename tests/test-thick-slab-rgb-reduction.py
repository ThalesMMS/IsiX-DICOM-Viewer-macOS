#!/usr/bin/env python3
"""The thick slab of an RGB series reduces every slice, and every pixel.

`-[DCMPix computeThickSlabRGB]` reduces a MIP or MinIP slab of a colour series
byte by byte, through `vmax8ARM`/`vmin8ARM` (altivecFunctions.c) on arm64. Two
defects made its result wrong:

  * the arm64 branch compared every slice with the *current* one
    (`vmax8ARM(fNext, fImage, fResult)`) instead of with what had been reduced
    so far, so each slice overwrote the last: the slab was the current slice
    against the last slice only, and an extremum in a middle slice was lost.
    When the first neighbour had no pixels the result was not written at all;
  * the helpers reduce `size/4` vectors of four pixels, so when the width times
    the height is not a multiple of four the last one to three pixels of the
    freshly allocated result were never written.

The fix folds each slice into the running result (`reduced` starts at the
current slice and becomes `fResult` once a slice has been compared), copies the
current slice when no other slice has pixels, and gives the helpers a scalar
tail for the pixels the vectors do not cover. The vector loop is unchanged.

Two halves, both built from the sources under test:

  1. the helpers alone: altivecFunctions.c compiled with AddressSanitizer,
     each helper called for 1 to 67 pixels on buffers of exactly that size, the
     result pre-filled with 0x00 and then 0xFF (a poisoned buffer: a byte the
     helper does not write keeps the fill, which differs from any reduction in
     one of the two runs), also in place as the accumulation calls it;
  2. the method itself: DCMPix.m compiled with the command xcodebuild logged
     for the app and linked with the sanitised helpers into a probe that builds
     nine RGB slices of 13 x 7 pixels (91, not a multiple of four), whose channel
     values put each channel's maximum and minimum in different, often middle,
     slices. For MIP and MinIP, thickness 1 to 6, both directions and every
     position (slabs that run off an end included), and again with one slice
     that has no pixels, the result must equal a scalar reference byte for byte.
     The probe runs twice under AddressSanitizer with the allocator filling new
     memory with 0x00 and with 0xFF, so an unwritten pixel cannot pass both.

The second half needs a build log holding DCMPix.m's compile command (build
Debug once, or pass --build-root of a checkout that has one); without it the
first half still runs and the test reports itself skipped (exit 2).

    python3 tests/test-thick-slab-rgb-reduction.py              # the working tree
    python3 tests/test-thick-slab-rgb-reduction.py <revision>   # negative control
    python3 tests/test-thick-slab-rgb-reduction.py --build-root ../other-checkout

The mean of an RGB slab (mode 1) still copies the current slice, as the code
documents; that is outside this test.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import object_probe  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('revision', nargs='?', help='read the sources from this revision (the negative control)')
parser.add_argument('--configuration', default='Debug', choices=('Debug', 'Release'))
parser.add_argument('--build-root', type=Path, default=ROOT,
                    help='checkout whose xcodebuild log holds the compile command for DCMPix.m')
arguments = parser.parse_args()

HELPERS = 'Horos/Sources/altivecFunctions.c'
PIX = 'Horos/Sources/DCMPix.m'
OPTIMIZATION = '-O0' if arguments.configuration == 'Debug' else '-O2'
TARGET = ['-arch', 'arm64', '-mmacosx-version-min=26.0']


def source_bytes(relative):
    if arguments.revision:
        return subprocess.run(['git', '-C', str(ROOT), 'show', arguments.revision + ':' + relative],
                              check=True, capture_output=True).stdout
    return (ROOT / relative).read_bytes()


HELPER_PROBE = r'''
#include "altivecFunctions.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*Reduce)( vUInt8 *a, vUInt8 *b, vUInt8 *r, long size);

int main( void)
{
    const Reduce reduce[2] = { vmax8ARM, vmin8ARM};
    const char *names[2] = { "vmax8ARM", "vmin8ARM"};
    long checked = 0, failures = 0;

    for( int mode = 0; mode < 2; mode++)
        for( long pixels = 1; pixels <= 67; pixels++)
            for( int variant = 0; variant < 3; variant++)    // fill 0x00, fill 0xFF, in place
            {
                const size_t bytes = pixels * 4;             // exactly the size: no slack for ASan to miss
                unsigned char *a = malloc( bytes), *b = malloc( bytes), *expected = malloc( bytes);
                for( size_t i = 0; i < bytes; i++)
                {
                    a[ i] = (unsigned char)( 1 + (i * 37 + 11) % 253);
                    b[ i] = (unsigned char)( 1 + (i * 101 + 200) % 253);
                    expected[ i] = mode == 0 ? (a[ i] > b[ i] ? a[ i] : b[ i]) : (a[ i] < b[ i] ? a[ i] : b[ i]);
                }
                unsigned char *r = a;
                if( variant < 2)
                {
                    r = malloc( bytes);
                    memset( r, variant == 0 ? 0x00 : 0xFF, bytes);
                }
                reduce[ mode]( (vUInt8*) a, (vUInt8*) b, (vUInt8*) r, pixels);

                long differing = 0, first = -1;
                for( size_t i = 0; i < bytes; i++)
                    if( r[ i] != expected[ i]) { if( first < 0) first = (long) i; differing++; }
                if( differing)
                {
                    fprintf( stderr, "FAIL: %s over %ld pixels (%s): %ld of %zu bytes wrong, first at byte %ld\n",
                             names[ mode], pixels, variant == 2 ? "in place" : variant ? "result filled 0xFF" : "result filled 0x00",
                             differing, bytes, first);
                    failures++;
                }
                checked++;
                if( r != a) free( r);
                free( a); free( b); free( expected);
            }

    if( failures) { fprintf( stderr, "FAIL: %ld of %ld helper calls wrong\n", failures, checked); return 1; }
    printf( "%ld helper calls (1 to 67 pixels, poisoned and in place) matched the scalar reduction\n", checked);
    return 0;
}
'''

PIX_PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

static const int kWidth = 13, kHeight = 7;     // 91 pixels: not a multiple of the four a vector holds
static const int kSlices = 9;
static const long kBytes = kWidth * kHeight * 4;

// Not declared in DCMPix.h; it is the RGB slab this test exists to measure.
@interface DCMPix (HorosRGBSlabProbe)
- (float*) computeThickSlabRGB;
@end

@interface ProbePix : DCMPix
- (void) prepareSlice:(int) index;
- (void) dropPixels;
- (void) setSlab:(int) thickness direction:(int) direction mode:(int) mode position:(int) position array:(NSArray*) array;
@end
@implementation ProbePix
- (void) CheckLoad {}
- (void) prepareSlice:(int) index
{
    width = kWidth; height = kHeight; isRGB = YES; thickSlabVRActivated = NO;
    fImage = (float*) malloc( kBytes);
    unsigned char *bytes = (unsigned char*) fImage;
    // Each channel of each pixel peaks and bottoms out at its own slice, most
    // often a middle one, so neither the current nor the last slice of a slab
    // holds its extremum. Values stay within 1..254: a byte left at the
    // allocator's fill (0x00 or 0xFF) can never pass for a result.
    for( long p = 0; p < kWidth * kHeight; p++)
        for( int c = 0; c < 4; c++)
            bytes[ p * 4 + c] = (unsigned char)( 20 + (p * 7 + c * 13) % 23 + 11 * ((index * index * 5 + p + c * 3) % 19));
}
- (void) dropPixels { fImage = NULL; }
- (void) setSlab:(int) thickness direction:(int) direction mode:(int) mode position:(int) position array:(NSArray*) array
{
    stack = thickness; stackDirection = direction; stackMode = mode; pixPos = position;
    [pixArray release];
    pixArray = [array retain];
    ww = 256; wl = 127;
}
@end

static int failures = 0;
static void fail( const char *what) { fprintf( stderr, "FAIL: %s\n", what); failures++; }

// The reference: the slab's slices, the current one first, reduced byte by byte.
// A slice without pixels is skipped; the slab stops at either end of the series.
static void reference( NSArray *slices, int position, int thickness, int direction, int mode,
                       unsigned char *out, int *lastUsed)
{
    memcpy( out, [[slices objectAtIndex: position] fImage], kBytes);
    *lastUsed = position;
    for( int i = 1; i < thickness; i++)
    {
        int index = direction ? position - i : position + i;
        if( index < 0 || index >= (int) slices.count) break;
        const unsigned char *next = (const unsigned char*) [[slices objectAtIndex: index] fImage];
        if( next == NULL) continue;
        for( long b = 0; b < kBytes; b++)
            out[ b] = mode == 2 ? MAX( out[ b], next[ b]) : MIN( out[ b], next[ b]);
        *lastUsed = index;
    }
}

int main(){ @autoreleasepool {
    NSMutableArray *slices = [NSMutableArray array];
    for( int i = 0; i < kSlices; i++)
    {
        ProbePix *pix = [[ProbePix alloc] init];
        [pix prepareSlice: i];
        [slices addObject: pix];
    }

    unsigned char *expected = (unsigned char*) malloc( kBytes);
    unsigned char *naive = (unsigned char*) malloc( kBytes);
    long compared = 0, clamped = 0, middle = 0, tails = 0;

    for( int pass = 0; pass < 2; pass++)
    {
        // The second pass takes the pixels away from one slice, which is the
        // first neighbour of slices 3 and 5.
        if( pass == 1) [[slices objectAtIndex: 4] dropPixels];

        for( int mode = 2; mode <= 3; mode++)
            for( int thickness = 1; thickness <= 6; thickness++)
                for( int direction = 0; direction <= 1; direction++)
                    for( int position = 0; position < kSlices; position++)
                    {
                        ProbePix *pix = [slices objectAtIndex: position];
                        if( [pix fImage] == NULL) continue;
                        [pix setSlab: thickness direction: direction mode: mode position: position array: slices];

                        unsigned char *got = (unsigned char*) [pix computeThickSlabRGB];
                        if( got == NULL) { fail( "computeThickSlabRGB returned nothing"); continue; }

                        int last;
                        reference( slices, position, thickness, direction, mode, expected, &last);

                        // What the arm64 branch used to give: the current slice against the last one.
                        memcpy( naive, [pix fImage], kBytes);
                        const unsigned char *lastBytes = (const unsigned char*) [[slices objectAtIndex: last] fImage];
                        for( long b = 0; b < kBytes; b++)
                            naive[ b] = mode == 2 ? MAX( naive[ b], lastBytes[ b]) : MIN( naive[ b], lastBytes[ b]);
                        if( memcmp( naive, expected, kBytes)) middle++;

                        long differing = 0, tail = 0, first = -1;
                        for( long b = 0; b < kBytes; b++)
                            if( got[ b] != expected[ b])
                            {
                                if( first < 0) first = b;
                                differing++;
                                if( b >= (kWidth * kHeight / 4) * 16) tail++;
                            }
                        if( differing)
                        {
                            char message[ 300];
                            snprintf( message, sizeof message,
                                      "%s slab of %d at slice %d, direction %d%s: %ld of %ld bytes differ "
                                      "(%ld in the last pixels a vector does not cover), first at byte %ld",
                                      mode == 2 ? "maximum" : "minimum", thickness, position, direction,
                                      pass ? ", slice 4 without pixels" : "", differing, kBytes, tail, first);
                            fail( message);
                            if( tail) tails++;
                        }
                        int far = direction ? position - (thickness - 1) : position + (thickness - 1);
                        if( far < 0 || far >= kSlices) clamped++;
                        compared++;
                        free( got);
                    }
    }

    // The data must be able to tell the two defects apart from a correct slab.
    if( middle == 0) fail( "no slab had its extremum in a middle slice; the data proves nothing");
    if( clamped == 0) fail( "no slab ran off an end of the series");

    if( failures) { fprintf( stderr, "FAIL: %d check%s (%ld with wrong trailing pixels)\n",
                             failures, failures == 1 ? "" : "s", tails); return 1; }
    printf( "%ld RGB slabs matched the reference byte for byte (%ld with an extremum in a middle slice, "
            "%ld clamped at an end)", compared, middle, clamped);
    return 0;
}}
'''

FRAMEWORKS = ['Foundation', 'AppKit', 'AVFoundation', 'CoreData', 'CoreMedia', 'CoreVideo', 'Accelerate']
SANITIZER = ['-fsanitize=address', '-fno-omit-frame-pointer']


def objective_c_stubs(obj):
    listing = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
    names = sorted({m.group(1) for m in re.finditer(r'_OBJC_CLASS_\$_(\w+)', listing)})
    sources = ROOT / 'Horos/Sources'
    declared = [n for n in names
                if n != 'ROI' and any((sources / (n + suffix)).is_file() for suffix in ('.h', '.m', '.mm'))]
    return ('@interface ROI : NSObject @end\n@implementation ROI @end\n'
            + ''.join('@interface %s : NSObject @end\n@implementation %s @end\n' % (n, n) for n in declared))


def run_sanitised(executable, fill, timeout=120):
    environment = dict(os.environ)
    environment['ASAN_OPTIONS'] = 'malloc_fill_byte=%d:max_malloc_fill_size=1048576:abort_on_error=0' % fill
    return subprocess.run([str(executable)], capture_output=True, text=True, timeout=timeout, env=environment)


failed = False
skipped = None
with tempfile.TemporaryDirectory(prefix='horos-rgb-slab-') as name:
    work = Path(name)
    sources = work / 'src'
    sources.mkdir()
    (sources / 'altivecFunctions.c').write_bytes(source_bytes(HELPERS))
    (sources / 'altivecFunctions.h').write_bytes(source_bytes('Horos/Sources/altivecFunctions.h'))

    # 1. The helpers alone, sanitised.
    helpers = work / 'altivecFunctions.o'
    subprocess.run(['xcrun', 'clang', OPTIMIZATION, '-g', *TARGET, *SANITIZER, '-c',
                    str(sources / 'altivecFunctions.c'), '-o', str(helpers)], check=True)
    (work / 'helpers.c').write_text(HELPER_PROBE)
    subprocess.run(['xcrun', 'clang', OPTIMIZATION, '-g', *TARGET, *SANITIZER, '-I', str(sources),
                    str(work / 'helpers.c'), str(helpers), '-framework', 'Accelerate',
                    '-o', str(work / 'helpers')], check=True)
    run = run_sanitised(work / 'helpers', 0)
    if run.returncode:
        sys.stderr.write(run.stderr)
        print('FAIL: the RGB slab helpers leave pixels unreduced or read out of bounds')
        failed = True
    else:
        print('PASS: %s' % run.stdout.strip())

    # 2. -computeThickSlabRGB, compiled as the app compiles it.
    try:
        command = object_probe.compile_command(PIX, arguments.configuration, root=arguments.build_root)
    except LookupError as error:
        command = None
        skipped = 'needs a build log with the compile command for DCMPix.m: %s' % error
    if command:
        # A copy outside the checkout, so its quoted includes resolve through the
        # logged header maps like every other header the command reads.
        (sources / 'DCMPix.m').write_bytes(source_bytes(PIX))
        pix = work / 'DCMPix.o'
        compiled = subprocess.run(command + ['-c', str(sources / 'DCMPix.m'), '-o', str(pix)],
                                  capture_output=True, text=True)
        if compiled.returncode:
            sys.stderr.write(compiled.stderr[-3000:])
            print('FAIL: DCMPix.m does not compile with the logged command')
            raise SystemExit(1)
        (work / 'probe.mm').write_text(PIX_PROBE)
        (work / 'stubs.mm').write_text('#import <Foundation/Foundation.h>\n' + objective_c_stubs(pix))
        placeholders = set()
        runs = []
        for _ in range(200):
            assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
            (work / 'placeholders.s').write_text('.data\n' + assembly)
            link = ['xcrun', 'clang++', '-std=c++11', OPTIMIZATION, '-g', *TARGET, *SANITIZER,
                    '-Wno-deprecated-declarations', '-I' + str(arguments.build_root / 'Horos/Sources'),
                    str(work / 'probe.mm'), str(work / 'stubs.mm'), str(work / 'placeholders.s'),
                    str(pix), str(helpers), '-Wl,-undefined,dynamic_lookup', '-o', str(work / 'probe')]
            for framework in FRAMEWORKS:
                link += ['-framework', framework]
            subprocess.run(link, check=True, capture_output=True)
            try:
                runs = [run_sanitised(work / 'probe', fill) for fill in (0x00, 0xFF)]
            except subprocess.TimeoutExpired:
                print('FAIL: computeThickSlabRGB did not finish in 120 s', file=sys.stderr)
                raise SystemExit(1)
            missing = [m.group(1) for r in runs
                       for m in [re.search(r"symbol not found in flat namespace '([^']+)'", r.stderr)] if m]
            if not missing:
                break
            if missing[0] in placeholders:
                print('cannot satisfy %s' % missing[0], file=sys.stderr)
                raise SystemExit(1)
            placeholders.add(missing[0])
        else:
            print('too many unresolved symbols in %s' % pix, file=sys.stderr)
            raise SystemExit(1)

        for fill, run in zip((0x00, 0xFF), runs):
            if run.returncode:
                sys.stderr.write(run.stderr[-6000:])
                print('FAIL: computeThickSlabRGB (%s, new memory filled with 0x%02X) does not match the reference'
                      % (arguments.configuration, fill))
                failed = True
            else:
                print('PASS: %s, %s, new memory filled with 0x%02X' % (run.stdout.strip(), arguments.configuration, fill))

if failed:
    raise SystemExit(1)
if skipped:
    print(skipped, file=sys.stderr)
    raise SystemExit(2)
