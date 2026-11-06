#!/usr/bin/env python3
"""DCMPix windows, subtracts, convolves and computes SUV as it always did.

The operations DCMPix applies to an image it has already loaded - the window
(-changeWLWW::, the full window, the 8-bit representation: linear, through a
transfer function, colour, inverted), the image arithmetic and the DSA mask
subtraction, the convolution filter and the SUV checks and dose correction -
moved from DCMPix.m to the IsiXImaging module, with DCMPix delegating to it.

This compiles DCMPix.m with the command the app's build used, links it into a
probe with tests/app_object_probe.py and runs every operation on synthetic
images, printing the buffers they produce (bytes in hexadecimal, floats to the
bit) and the values they set. It checks the plainer results against values
worked out by hand and, when the operations have moved, compiles the DCMPix.m
of the revision before the move the same way and requires every output to be
identical.

Once DCMPix itself is Swift, no revision of DCMPix.m links with this checkout's
Swift: the reference is then what the probe answered against the last
Objective-C class, kept for each configuration in
tests/fixtures/dcmpix-buffer-operations-records.json (HOROS_RECORD_GOLDEN=1 on a checkout
of that class writes them).

Usage: test-dcmpix-buffer-operations.py [REFERENCE_REVISION]
"""
from pathlib import Path
import json
import math
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
sys.path.insert(0, str(ROOT / 'tools'))
import app_object_probe  # noqa: E402
import object_probe  # noqa: E402
from history_reference import before_removal, before_text_removed, show  # noqa: E402

PIX = 'Horos/Sources/DCMPix.m'
HELPERS = 'Horos/Sources/altivecFunctions.c'
# Text of the Objective-C operations, gone once they delegate to the module.
OBJC_MARKER = 'vsubtractNoAltivecAbs(input, subfImage, result, i);'

PROBE = r'''
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import "DCMPix.h"
#include <cstdio>
#include <cmath>
// PIX_IVARS

@interface DCMPix (BufferOperationsProbe)
- (void) setSubPixOffset:(NSPoint) offset;
- (void) setTransferFunction:(NSData*) tf;
@end

@interface ProbePix : DCMPix
@end
@implementation ProbePix
- (void) CheckLoad {}
- (void) applyShutter {}
- (void) shape:(long) w :(long) h rgb:(BOOL) rgb
{
    PIX_IVAR( self, long, width) = w; PIX_IVAR( self, long, height) = h; PIX_IVAR( self, BOOL, isRGB) = rgb;
    PIX_IVAR( self, float, slope) = 1; PIX_IVAR( self, float, offset) = 0;
    PIX_IVAR( self, float*, fImage) = (float*) calloc( w * h, sizeof( float));
    PIX_IVAR( self, char*, baseAddr) = (char*) calloc( w * h, 4);
}
- (float*) floats { return PIX_IVAR( self, float*, fImage); }
- (char*) bytes { return PIX_IVAR( self, char*, baseAddr); }
- (void) setRGB:(BOOL) v { PIX_IVAR( self, BOOL, isRGB) = v; }
- (void) setInverse:(BOOL) v { PIX_IVAR( self, BOOL, inverseVal) = v; }
- (void) setFixed:(BOOL) v { PIX_IVAR( self, BOOL, fixed8bitsWLWW) = v; }
- (void) setSlopeValue:(float) v { PIX_IVAR( self, float, slope) = v; }
- (void) setWindow:(float) l :(float) w { PIX_IVAR( self, float, wl) = l; PIX_IVAR( self, float, ww) = w; }
- (void) setFull:(float) l :(float) w { PIX_IVAR( self, float, fullwl) = l; PIX_IVAR( self, float, fullww) = w; }
- (void) setSUVUnits:(NSString*) u decay:(NSString*) d philips:(float) p factor:(float) f halflife:(float) h dose:(float) dose
               start:(NSDate*) start acquisition:(NSDate*) acquisition
{
    self.units = u; self.decayCorrection = d; PIX_IVAR( self, float, philipsFactor) = p; PIX_IVAR( self, float, decayFactor) = f;
    PIX_IVAR( self, float, halflife) = h;
    PIX_IVAR( self, float, radionuclideTotalDose) = dose;
    [PIX_IVAR( self, NSDate*, radiopharmaceuticalStartTime) release]; PIX_IVAR( self, NSDate*, radiopharmaceuticalStartTime) = [start retain];
    [PIX_IVAR( self, NSDate*, acquisitionTime) release]; PIX_IVAR( self, NSDate*, acquisitionTime) = [acquisition retain];
}
- (void) setConverted:(BOOL) c factor:(float) f { PIX_IVAR( self, BOOL, SUVConverted) = c; PIX_IVAR( self, float, factorPET2SUV) = f; }
- (NSPoint) offsetValue { return PIX_IVAR( self, NSPoint, subPixOffset); }
- (NSPoint) minMaxValue { return PIX_IVAR( self, NSPoint, subMinMax); }
- (NSString*) subtractionState
{
    return [NSString stringWithFormat: @"%a %a %a %a", (double) PIX_IVAR( self, float, subtractedfPercent),
            (double) PIX_IVAR( self, float, subtractedfZ), (double) PIX_IVAR( self, float, subtractedfZero),
            (double) PIX_IVAR( self, float, subtractedfGamma)];
}
@end

static NSString *hexBytes( const void *p, long n)
{
    NSMutableString *s = [NSMutableString stringWithCapacity: n * 2];
    for( long i = 0; i < n; i++) [s appendFormat: @"%02x", ((const unsigned char*) p)[i]];
    return s;
}

static NSArray *hexFloats( const float *p, long n)
{
    NSMutableArray *a = [NSMutableArray array];
    for( long i = 0; i < n; i++) [a addObject: [NSString stringWithFormat: @"%a", (double) p[i]]];
    return a;
}

static NSString *hf( double v) { return [NSString stringWithFormat: @"%a", v]; }

static void record( NSString *name, NSDictionary *values)
{
    NSMutableDictionary *d = [[values mutableCopy] autorelease];
    d[@"name"] = name;
    NSData *line = [NSJSONSerialization dataWithJSONObject: d options: NSJSONWritingSortedKeys error: nil];
    printf( "%s\n", [[[[NSString alloc] initWithData: line encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
    fflush( stdout);
}

static ProbePix *grey( long w, long h, float scale, float base)
{
    ProbePix *p = [[ProbePix alloc] init];
    [p shape: w : h rgb: NO];
    float *f = [p floats];
    for( long i = 0; i < w * h; i++)
        f[i] = base + scale * (float) ((i * 37 + (i / w) * 11) % 997) + 0.25f * (float) (i % 3);
    return p;
}

static ProbePix *colour( long w, long h)
{
    ProbePix *p = [[ProbePix alloc] init];
    [p shape: w : h rgb: YES];
    unsigned char *b = (unsigned char*) [p floats];
    for( long i = 0; i < w * h * 4; i++) b[i] = (unsigned char) ((i * 29 + i / 7) % 256);
    return p;
}

static NSDictionary *greyState( ProbePix *p, BOOL bytes)
{
    long n = [p pwidth] * [p pheight];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"window"] = @[hf( p.wl), hf( p.ww), hf( p.fullwl), hf( p.fullww)];
    if( bytes) d[@"bytes"] = hexBytes( [p bytes], n * (p.isRGB ? 4 : 1));
    return d;
}

static void windowing()
{
    struct { const char *name; float wl, ww; } requests[] = {
        {"linear", 4000, 9000}, {"auto", 0, 0}, {"nan-level", NAN, 300}, {"inf-width", 10, INFINITY},
        {"zero-width", 50, 0}, {"rounded", 100.6f, 300.3f}, {"half", 150, 300}, {"narrow", 10, 0.00001f},
        {"negative", -500, 120}};
    for( unsigned i = 0; i < sizeof( requests) / sizeof( requests[0]); i++)
    {
        ProbePix *p = grey( 37, 23, 20, -3000);
        [p computePixMinPixMax];
        [p changeWLWW: requests[i].wl : requests[i].ww];
        [p compute8bitRepresentation];
        record( [NSString stringWithFormat: @"window-%s", requests[i].name], greyState( p, YES));
    }

    ProbePix *small = grey( 16, 9, 0.1f, 2);              // a full width under 256: no rounding
    [small computePixMinPixMax];
    [small changeWLWW: 3.3f : 1.7f];
    [small compute8bitRepresentation];
    record( @"window-small-range", greyState( small, YES));

    ProbePix *flat = grey( 8, 8, 0, 42);
    for( int i = 0; i < 64; i++) [flat floats][i] = 42;
    [flat changeWLWW: 0 : 0];
    record( @"window-flat", greyState( flat, NO));

    ProbePix *steep = grey( 8, 8, 1, 0);
    [steep setSlopeValue: 3];
    [steep setFull: 0 : 100];
    [steep changeWLWW: 5 : 0.0001f];
    record( @"window-slope-floor", greyState( steep, NO));

    ProbePix *inverted = grey( 37, 23, 20, -3000);
    [inverted setInverse: YES];
    [inverted changeWLWW: 1000 : 8000];
    [inverted compute8bitRepresentation];
    NSMutableDictionary *d = [[greyState( inverted, YES) mutableCopy] autorelease];
    d[@"levels"] = @[hf( [inverted storedWindowLevelForCalibratedLevel: 120.5f]),
                     hf( [inverted calibratedWindowLevelForStoredLevel: -33]), @(inverted.displayInverted)];
    record( @"window-inverted", d);

    ProbePix *fixed = grey( 21, 13, 1, 0);
    [fixed setFixed: YES];
    [fixed setWindow: 500 : 20];
    [fixed compute8bitRepresentation];
    record( @"window-fixed-8-bits", greyState( fixed, YES));

    // A transfer function: 4096 entries, a curve.
    NSMutableData *table = [NSMutableData dataWithLength: 4096 * sizeof( float)];
    float *t = (float*) table.mutableBytes;
    for( int i = 0; i < 4096; i++) t[i] = powf( i / 4095.0f, 0.6f);
    for( int rows = 1; rows <= 37; rows += 12)
    {
        ProbePix *p = grey( 29, rows, 15, -2000);
        [p setTransferFunction: table];
        [p changeWLWW: 2000 : 7000];
        [p compute8bitRepresentation];
        record( [NSString stringWithFormat: @"window-table-%d-rows", rows], greyState( p, YES));
    }

    ProbePix *rgb = colour( 19, 11);
    [rgb setWindow: 100 : 150];
    [rgb compute8bitRepresentation];
    record( @"colour-linear", greyState( rgb, YES));

    ProbePix *rgbZero = colour( 19, 11);
    [rgbZero setWindow: 128 : 0];
    [rgbZero compute8bitRepresentation];
    record( @"colour-zero-width", greyState( rgbZero, YES));

    ProbePix *rgbTable = colour( 19, 11);
    [rgbTable setTransferFunction: table];
    [rgbTable setWindow: 140 : 200];
    [rgbTable compute8bitRepresentation];
    record( @"colour-table", greyState( rgbTable, YES));

    ProbePix *rgbAuto = colour( 4, 4);
    [rgbAuto computePixMinPixMax];
    record( @"colour-full-window", greyState( rgbAuto, NO));
}

static void convolution()
{
    float sharpen[25] = {0, -1, 0, -1, 5, -1, 0, -1, 0};
    float blur[25];
    for( int i = 0; i < 25; i++) blur[i] = 1 + (i % 3);

    ProbePix *p = grey( 33, 21, 7, -100);
    [p setConvolutionKernel: sharpen : 3 : 1];
    [p changeWLWW: 2000 : 6000];
    [p compute8bitRepresentation];
    record( @"convolution-display", greyState( p, YES));
    [p applyConvolutionOnSourceImage];
    record( @"convolution-source", @{@"floats": hexFloats( [p floats], 33 * 21)});

    ProbePix *q = grey( 33, 21, 7, -100);
    [q setConvolutionKernel: blur : 5 : 0];
    [q applyConvolutionOnSourceImage];
    record( @"convolution-unnormalized", @{@"floats": hexFloats( [q floats], 33 * 21)});

    ProbePix *r = grey( 33, 21, 7, -100);
    [r setConvolutionKernel: blur : 5 : 39];
    [r applyConvolutionOnSourceImage];
    record( @"convolution-5x5", @{@"floats": hexFloats( [r floats], 33 * 21)});

    ProbePix *c = colour( 17, 12);
    [c setConvolutionKernel: sharpen : 3 : 1];
    [c setWindow: 128 : 256];
    [c compute8bitRepresentation];
    record( @"convolution-colour-display", greyState( c, YES));
    [c applyConvolutionOnSourceImage];
    record( @"convolution-colour-source", @{@"bytes": hexBytes( [c floats], 17 * 12 * 4)});
}

static void arithmetic()
{
    NSPoint offsets[] = {{0, 0}, {3, -2}, {-4, 5}, {40, 0}, {0.6f, -0.4f}};
    for( unsigned i = 0; i < sizeof( offsets) / sizeof( offsets[0]); i++)
    {
        for( int op = 0; op < 3; op++)
        {
            ProbePix *a = grey( 23, 17, 3, -50);
            ProbePix *b = grey( 23, 17, -2, 400);
            [a setSubPixOffset: offsets[i]];
            if( op == 0) [a imageArithmeticMultiplication: b];
            else [a imageArithmeticSubtraction: b absolute: op == 2];
            record( [NSString stringWithFormat: @"arithmetic-%s-%u", op == 0 ? "multiply" : op == 1 ? "subtract" : "absolute", i],
                    @{@"floats": hexFloats( [a floats], 23 * 17)});
        }
    }
    ProbePix *a = grey( 23, 17, 3, -50);
    ProbePix *other = grey( 22, 17, 3, -50);
    [a imageArithmeticSubtraction: other];
    [a imageArithmeticMultiplication: other];
    record( @"arithmetic-other-size", @{@"floats": hexFloats( [a floats], 23 * 17)});
}

static void subtraction()
{
    NSPoint offsets[] = {{0, 0}, {2, 1}, {-3, -2}};
    float windows[][2] = {{128, 256}, {600, 1}, {1, 700}, {64, 100}};
    for( unsigned i = 0; i < 3; i++)
        for( unsigned w = 0; w < 4; w++)
        {
            ProbePix *frame = grey( 31, 19, 4, 100);
            ProbePix *mask = grey( 31, 19, 3, 80);
            NSPoint range = [frame subMinMax: [frame floats] : [mask floats]];
            [frame setSubtractedfImage: [mask floats] : range];
            [frame setSubPixOffset: offsets[i]];
            if( w == 3) [frame setSubSlidersPercent: 0.5f];
            [frame setWindow: windows[w][0] : windows[w][1]];
            [frame compute8bitRepresentation];
            NSMutableDictionary *d = [[greyState( frame, YES) mutableCopy] autorelease];
            d[@"range"] = @[hf( range.x), hf( range.y)];
            d[@"sliders"] = [frame subtractionState];
            record( [NSString stringWithFormat: @"subtraction-%u-%u", i, w], d);
        }

    ProbePix *p = grey( 8, 8, 1, 0);
    [p setSubSlidersPercent: 0.25f gamma: 1.5f zero: 0.9f];
    record( @"subtraction-sliders", @{@"sliders": [p subtractionState]});

    // The gamma and zero of many windows, and the zero of many shares: the
    // arithmetic, rounding included, has to be the same.
    NSMutableArray *sweep = [NSMutableArray array];
    for( int i = 0; i < 400; i++)
    {
        ProbePix *s = grey( 2, 2, 1, 0);
        ProbePix *m = grey( 2, 2, 0.5f, 0);
        [s setSubtractedfImage: [m floats] : NSMakePoint( -1, 3)];
        [s setWindow: 1.7f + i * 1.31f : 2.9f + i * 0.73f];
        [s compute8bitRepresentation];
        [s setSubSlidersPercent: i / 397.0f gamma: 1 zero: 0.01f + i * 0.0049f];
        [sweep addObject: [NSString stringWithFormat: @"%@ %@", [s subtractionState], hexBytes( [s bytes], 4)]];
    }
    record( @"subtraction-sweep", @{@"states": sweep});
}

static void suv()
{
    NSDate *start = [NSDate dateWithTimeIntervalSinceReferenceDate: 800000000];
    NSDate *later = [start dateByAddingTimeInterval: 3600.5];
    NSDate *earlier = [start dateByAddingTimeInterval: -60];
    struct { const char *name; NSString *units, *decay; float philips, factor, halflife, dose; NSDate *acquisition; BOOL rgb; } cases[] = {
        {"start", @"BQML", @"START", 0, 1.2f, 6586.2f, 370000000, later, NO},
        {"start-no-factor", @"BQML", @"START", 0, 0, 6586.2f, 370000000, later, NO},
        {"start-no-halflife", @"BQML", @"START", 0, 1.2f, 0, 370000000, later, NO},
        {"start-no-time", @"BQML", @"START", 0, 1.2f, 6586.2f, 370000000, nil, NO},
        {"start-before-injection", @"BQML", @"START", 0, 1.2f, 6586.2f, 370000000, earlier, NO},
        {"admin", @"BQML", @"ADMIN", 0, 0, 0, 370000000, nil, NO},
        {"none", @"BQML", @"NONE", 0, 0, 6586.2f, 250000000, later, NO},
        {"counts-philips", @"CNTS", @"START", 0.5f, 1.1f, 6586.2f, 370000000, later, NO},
        {"counts-no-philips", @"CNTS", @"START", 0, 1.1f, 6586.2f, 370000000, later, NO},
        {"other-units", @"GML", @"START", 0, 1.2f, 6586.2f, 370000000, later, NO},
        {"no-decay", @"BQML", nil, 0, 1.2f, 6586.2f, 370000000, later, NO},
        {"other-decay", @"BQML", @"DECY", 0, 1.2f, 6586.2f, 370000000, later, NO},
        {"no-dose", @"BQML", @"START", 0, 1.2f, 6586.2f, 0, later, NO},
        {"colour", @"BQML", @"START", 0, 1.2f, 6586.2f, 370000000, later, YES},
        {"no-units", nil, @"START", 0, 1.2f, 6586.2f, 370000000, later, NO}};
    for( unsigned i = 0; i < sizeof( cases) / sizeof( cases[0]); i++)
    {
        ProbePix *p = grey( 4, 4, 1, 0);
        [p setRGB: cases[i].rgb];
        [p setSUVUnits: cases[i].units decay: cases[i].decay philips: cases[i].philips factor: cases[i].factor
              halflife: cases[i].halflife dose: cases[i].dose start: start acquisition: cases[i].acquisition];
        p.radionuclideTotalDoseCorrected = 12345;
        [p checkSUV];
        NSDictionary *checked = @{@"hasSUV": @(p.hasSUV), @"decayFactor": hf( p.decayFactor),
                                  @"corrected": hf( p.radionuclideTotalDoseCorrected)};
        p.radionuclideTotalDoseCorrected = 12345;
        [p computeTotalDoseCorrected];
        record( [NSString stringWithFormat: @"suv-%s", cases[i].name],
                @{@"check": checked, @"corrected": hf( p.radionuclideTotalDoseCorrected), @"decayFactor": hf( p.decayFactor)});
    }

    ProbePix *converted = grey( 4, 4, 1, 0);
    [converted setConverted: NO factor: 3.5f];
    float before = [converted appliedFactorPET2SUV];
    [converted setConverted: YES factor: 3.5f];
    ProbePix *copy = grey( 4, 4, 1, 0);
    [converted setSUVUnits: @"BQML" decay: @"START" philips: 0 factor: 1.3f halflife: 6586.2f dose: 370000000
                     start: start acquisition: later];
    converted.patientsWeight = 74.5f;
    [copy copySUVfrom: converted];
    record( @"suv-factor-and-copy", @{@"applied": @[hf( before), hf( [converted appliedFactorPET2SUV])],
                                      @"copy": @[@(copy.hasSUV), hf( copy.radionuclideTotalDoseCorrected), hf( copy.decayFactor),
                                                 hf( [copy appliedFactorPET2SUV]), hf( copy.patientsWeight), copy.units ?: @""]});
}

int main() { @autoreleasepool {
    windowing();
    convolution();
    arithmetic();
    subtraction();
    suv();
    return 0;
} }
'''


def compile_pix(source_text, folder):
    """DCMPix.m compiled with the build's own command, outside the checkout."""
    command = object_probe.compile_command(PIX, 'Debug')
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / 'DCMPix.m'
    # A DCMPix.m from before the Swift extensions, against the headers of today.
    source.write_bytes(app_object_probe.dcmpix_source_for_current_headers(source_text))
    obj = folder / 'DCMPix.o'
    built = subprocess.run(command + ['-c', str(source), '-o', str(obj)], capture_output=True, text=True)
    if built.returncode:
        raise RuntimeError('DCMPix.m does not compile:\n' + built.stderr[-3000:])
    return obj


def helpers(folder):
    """The vector helpers the Objective-C image arithmetic called: gone from the
    tree with the last caller, they are read from the last revision that has them."""
    revision = 'HEAD' if (ROOT / HELPERS).exists() else before_removal(HELPERS)
    if revision is None:
        raise RuntimeError('no revision of this history has ' + HELPERS)
    for path in (HELPERS, HELPERS[:-2] + '.h'):
        (folder / Path(path).name).write_bytes((ROOT / path).read_bytes() if revision == 'HEAD' else show(revision, path))
    obj = folder / 'altivecFunctions.o'
    subprocess.run(['xcrun', 'clang', '-c', '-O0', '-arch', 'arm64', str(folder / 'altivecFunctions.c'), '-o', str(obj)],
                   check=True, capture_output=True)
    return obj


def run_probe(obj, folder):
    import roi_harness
    (folder / 'probe.mm').write_text(PROBE.replace('// PIX_IVARS\n', roi_harness.PIX_IVARS))
    run = app_object_probe.link_and_run(folder, [folder / 'probe.mm', helpers(folder)], [obj],
                                        probe_classes=('ProbePix',), timeout=300)
    if run.returncode:
        raise RuntimeError('the probe failed (exit %d) after %s:\n%s' % (
            run.returncode, [json.loads(l)['name'] for l in run.stdout.splitlines() if l.startswith('{')][-1:], run.stderr[-3000:]))
    return {r['name']: r for r in (json.loads(line) for line in run.stdout.splitlines() if line.startswith('{'))}


def fl(text):
    return float.fromhex(text)


def f32(value):
    return struct.unpack('f', struct.pack('f', value))[0]


failures = []


def expect(condition, message):
    if not condition:
        failures.append(message)


def check_expectations(records):
    window = lambda name: [fl(v) for v in records[name]['window']]  # noqa: E731
    expect(window('window-linear')[:2] == [4000, 9000], 'a window was not applied as asked: %r' % window('window-linear'))
    auto = window('window-auto')
    expect(auto[:2] == auto[2:], 'a request of (0, 0) did not take the full window: %r' % auto)
    expect(window('window-nan-level')[:2] == auto[:2] and window('window-inf-width')[:2] == auto[:2]
           and window('window-zero-width')[:2] == auto[:2], 'a window that is not a number is not the full window')
    expect(window('window-rounded')[:2] == [100, 300], 'a wide range does not round the window: %r' % window('window-rounded'))
    expect(window('window-half')[:2] == [150, 300], 'a window starting at zero moved: %r' % window('window-half'))
    expect(window('window-narrow')[:2] == [10, 2], 'a window under one is not two on a wide range: %r' % window('window-narrow'))
    expect(window('window-small-range')[:2] == [f32(3.3), f32(1.7)], 'a narrow range was rounded: %r' % window('window-small-range'))
    expect(window('window-flat') == [52, 20, 52, 20], 'a flat image does not get a width of 20: %r' % window('window-flat'))
    expect(window('window-slope-floor')[:2] == [5, f32(0.001 * 3)], 'the smallest width does not follow the slope: %r'
           % window('window-slope-floor'))
    expect([fl(v) for v in records['window-inverted']['levels'][:2]] == [-120.5, 33.0]
           and records['window-inverted']['levels'][2], 'the stored level of an inverted image is not the opposite')
    linear = bytes.fromhex(records['window-linear']['bytes'])
    expect(any(0 < b < 255 for b in linear), 'the linear window is not a ramp')
    inverted = bytes.fromhex(records['window-inverted']['bytes'])
    expect(len(inverted) == 37 * 23, 'the inverted image has %d bytes' % len(inverted))
    full = [fl(v) for v in records['colour-full-window']['window']]
    expect(full[2:] == [127.5, 255], 'a colour image\'s full window is %r' % full)

    corrected = lambda name: fl(records['suv-' + name]['corrected'])  # noqa: E731
    expected = 370000000 * math.exp(-f32(3600.5) * f32(math.log(2)) / f32(6586.2))
    expect(abs(corrected('start') - expected) / expected < 1e-6, 'the decay of the dose is %r, not %r' % (corrected('start'), expected))
    expect(corrected('start-before-injection') == 0 and corrected('start-no-halflife') == 0,
           'a dose that cannot be corrected is not refused')
    expect(corrected('admin') == 370000000 and fl(records['suv-admin']['decayFactor']) == 1,
           'an ADMIN dose is not the injected dose')
    has = lambda name: records['suv-' + name]['check']['hasSUV']  # noqa: E731
    expect(has('start') and has('admin') and has('none') and has('counts-philips'), 'an SUV series is not one')
    expect(not any(has(name) for name in ('start-no-factor', 'start-no-halflife', 'start-no-time', 'counts-no-philips',
                                         'other-units', 'no-decay', 'other-decay', 'no-dose', 'colour', 'no-units')),
           'a series without what SUV needs has SUV')
    copied = records['suv-factor-and-copy']
    expect([fl(v) for v in copied['applied']] == [1.0, 3.5], 'the applied factor is %r' % copied['applied'])
    expect(copied['copy'][0] and copied['copy'][5] == 'BQML', 'the copy did not carry the SUV: %r' % copied['copy'])

    product = [fl(v) for v in records['arithmetic-multiply-0']['floats']]
    expect(product[1] == f32(f32(-50 + 3 * 37 + 0.25) * f32(400 - 2 * 37 + 0.25)), 'the product is %r' % product[1])
    shifted = [fl(v) for v in records['arithmetic-subtract-3']['floats']]
    expect(all(v == 0 for v in shifted), 'a shift past the image left a difference')
    expect([fl(v) for v in records['subtraction-sliders']['sliders'].split()]
           == [0.25, f32(0.9), f32(f32(0.9) - 0.8 + 0.25 * 0.8), 1.5],
           'the sliders are %r' % records['subtraction-sliders']['sliders'])
    clamped = [fl(v) for v in records['subtraction-0-1']['window']]
    expect(clamped[:2] == [512, 2], 'a subtraction window is not clamped to 2..512: %r' % clamped)


import roi_harness  # noqa: E402
# The records of the last Objective-C class, in tests/fixtures.
GOLDEN = 'dcmpix-buffer-operations'
GOLDEN_CONFIGURATION = 'Debug'  # the probe compiles and links what the Debug build logged
with tempfile.TemporaryDirectory(prefix='horos-buffer-operations-') as directory:
    work = Path(directory)
    swift_class = not roi_harness.objc_class()
    current = b'' if swift_class else (ROOT / PIX).read_bytes()
    current_text = current.decode('latin1')
    delegates = OBJC_MARKER not in current_text
    if swift_class:
        # No revision of DCMPix.m links with the Swift class: the reference is
        # what this test recorded against the last Objective-C class.
        reference = None
    elif len(sys.argv) > 1:
        reference = sys.argv[1]
    elif not delegates:
        reference = None
    elif OBJC_MARKER in show('HEAD', PIX).decode('latin1'):
        reference = 'HEAD'  # the move is not committed yet
    else:
        reference = before_text_removed(PIX, OBJC_MARKER)

    if swift_class:
        obj = app_object_probe.built_object('DCMPix')
        if obj is None:
            print('needs a built DCMPix.o: build Debug or Release once', file=sys.stderr)
            sys.exit(2)
        (work / 'current').mkdir()
        records = run_probe(obj, work / 'current')
    else:
        records = run_probe(compile_pix(current, work / 'current'), work / 'current')
    check_expectations(records)

    if reference or swift_class:
        if swift_class:
            reference = 'the records of the last Objective-C class'
            try:
                previous = roi_harness.golden(GOLDEN, GOLDEN_CONFIGURATION)
            except LookupError as error:
                print(f'FAIL: {error}')
                sys.exit(1)
        else:
            previous = run_probe(compile_pix(show(reference, PIX), work / 'reference'), work / 'reference')
        for name in sorted(set(records) | set(previous)):
            if records.get(name) != previous.get(name):
                new, old = records.get(name) or {}, previous.get(name) or {}
                keys = sorted(k for k in set(new) | set(old) if new.get(k) != old.get(k))
                failures.append('%s differs from %s in %s: %s against %s' % (
                    name, reference[:12], keys, str({k: new.get(k) for k in keys})[:400], str({k: old.get(k) for k in keys})[:400]))
    elif delegates:
        print('note: the history does not reach the Objective-C operations; only the expectations were checked')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
if roi_harness.recording_golden():
    roi_harness.golden(GOLDEN, GOLDEN_CONFIGURATION, records)
print('ok: %d operations%s' % (len(records), ', identical to the Objective-C operations of %s' % reference[:12]
                                if reference else ' by the Objective-C operations, as expected'))
