#!/usr/bin/env python3
"""DCMPix's display image, bit for bit.

What this compares, between this checkout and the last revision of DCMPix.m that
did it in Objective-C, running the same probe against both:

* the 8-bit image: -changeWLWW:: (a window, the full window, a fixed 8-bit
  window), -compute8bitRepresentation through the linear window, a transfer
  function, the subtraction, the inversion and the colour table, -baseAddr,
  -kill8bitsImage, -checkImageAvailble:: and -allocate8bitRepresentation, and
  the stored and calibrated levels;
* the source of the display: -computefImage, -computefImageForMeasurement,
  -computefImageForDisplay (with the MPR's plane), the thick slab (mean, maximum
  and minimum, both directions, grey and colour), -getPixelValueX:Y: through a
  slab, the convolution kernel and -applyConvolutionOnSourceImage;
* the shutter: rectangle, circle and polygon, grey and colour;
* -ConvertToBW: and -ConvertToRGB::: in every mode;
* the pictures: -image, -generateThumbnailImageWithWW:WL:, the icon's size and
  +resizeIfNecessary:dcmPix:;
* the preview windows: DICOM, automatic, frame range and stored range.

Every value is recorded as hexadecimal floating point and every buffer by a hash
of its bytes.

    python3 tests/test-dcmpix-display.py [REFERENCE_REVISION]

Once DCMPix itself is Swift, no revision of DCMPix.m links with this checkout's
Swift: the reference is then what the probe answered against the last
Objective-C class, kept for each configuration in
tests/fixtures/dcmpix-display-records.json (HOROS_RECORD_GOLDEN=1 on a checkout
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
GOLDEN = 'dcmpix-display'
# What DCMPix.m defines while it still makes the display image itself.
OBJC_MARKER = '- (void) compute8bitRepresentation\n'
# The Swift extensions of DCMPix that took this part out of DCMPix.m.
MOVED = ('DCMPix+Display', 'DCMPix+DisplaySource')
SKIPPED = 2
# The preview windows are the app's Swift classes.
APP_SWIFT = ('PreviewWindowing',)
configuration = roi_harness.configuration()

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>
#import "DCMPix.h"

// The byte reductions of a colour slab, for a revision whose DCMPix.m calls them
// (the file left the tree with the last of them).
#if __has_include("altivecFunctions.c")
#include "altivecFunctions.c"
#endif

// Declared by no header of a revision that keeps them in DCMPix.m.
@interface DCMPix (DisplayProbe)
- (void) compute8bitRepresentation;
- (void) kill8bitsImage;
- (void) checkImageAvailble:(float)newWW :(float)newWL;
- (void) allocate8bitRepresentation;
- (float*) computefImageForMeasurement;
- (float*) computefImageForDisplay;
- (float*) computeThickSlab;
- (float*) computeThickSlabRGB;
- (void) applyShutter;
- (void) setBlackIndex:(int) i;
- (float*) applyConvolutionOnImage:(float*) src RGB:(BOOL) color;
- (void) applyConvolutionOnSourceImage;
- (float) storedWindowLevelForCalibratedLevel:(float) level;
- (float) calibratedWindowLevelForStoredLevel:(float) level;
- (BOOL) isColorPreviewFrame;
- (id) dicomPreviewWindow;
- (id) automaticPreviewWindow;
- (id) frameRangePreviewWindow;
- (id) storedRangePreviewWindow;
- (void) setHorosMPRDisplayPixels:(NSData*) pixels;
@end

static NSMutableArray *gRecords = nil;

static void record( NSString *name, id value) { [gRecords addObject: @{@"name": name, @"value": value ?: [NSNull null]}]; }
static NSString *hd( double v) { return [NSString stringWithFormat: @"%a", v]; }

static NSString *hashOf( const void *bytes, long count)
{
    if( bytes == NULL) return @"none";
    unsigned long long h = 1469598103934665603ULL;
    const unsigned char *b = bytes;
    for( long i = 0; i < count; i++) { h ^= b[ i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat: @"%016llx", h];
}

// An instance variable written directly: the ones the class has no setter for.
// The Objective-C class has it under its name, the Swift one under horos_ and it.
static void setIvar( id object, const char *name, const void *value, size_t size)
{
    Ivar ivar = class_getInstanceVariable( [object class], name);
    if( ivar == NULL)
    {
        char prefixed[ 256];
        snprintf( prefixed, sizeof prefixed, "horos_%s", name);
        ivar = class_getInstanceVariable( [object class], prefixed);
    }
    if( ivar == NULL) { fprintf( stderr, "no ivar %s\n", name); exit( 3); }
    memcpy( (char*) (__bridge void*) object + ivar_getOffset( ivar), value, size);
}

static float *greyData( long w, long h, float seed)
{
    float *data = malloc( w * h * sizeof( float));
    for( long i = 0; i < w * h; i++)
    {
        long x = i % w, y = i / w;
        data[ i] = seed + (float) ((x * 37 + y * 11 + (x * y) % 13) % 251) * 7.25f - 600.f + (float) (x == y) * 900.f;
    }
    return data;
}

static DCMPix *grey( long w, long h, float seed)
{
    float *data = greyData( w, h, seed);
    DCMPix *p = [[[DCMPix alloc] initWithData: data :32 :w :h :0.8f :0.6f :0 :0 :0] autorelease];
    free( data);
    p.srcFile = @"probe.dcm";
    [p setValue: @"CT" forKey: @"modalityString"];
    return p;
}

static DCMPix *colour( long w, long h, int seed)
{
    unsigned char *data = malloc( w * h * 4);
    for( long i = 0; i < w * h * 4; i++) data[ i] = (unsigned char) ((i * 29 + seed * 17 + (i / (w * 4)) * 5) % 256);
    DCMPix *p = [[[DCMPix alloc] initWithData: (float*) data :7 :w :h :1 :1 :0 :0 :0] autorelease];
    free( data);
    p.srcFile = @"probe.dcm";
    [p setValue: @"US" forKey: @"modalityString"];
    return p;
}

static NSString *eightBit( DCMPix *p)
{
    char *b = [p baseAddr];
    return hashOf( b, [p pwidth] * [p pheight] * ([p isRGB] ? 4 : 1));
}

static NSArray *windowOf( DCMPix *p) { return @[hd( [p wl]), hd( [p ww]), hd( [p fullwl]), hd( [p fullww])]; }

static NSString *floats( DCMPix *p, float *f)
{
    NSString *h = hashOf( f, [p pwidth] * [p pheight] * 4);
    return h;
}

static void window8bit( void)
{
    NSMutableArray *out = [NSMutableArray array];
    DCMPix *p = grey( 37, 29, 0);
    float windows[][ 2] = { {40, 400}, {-300, 1500}, {0, 0}, {1000, 1}, {NAN, 200}, {100, 0}, {-2000.5f, 3.25f}};
    for( int i = 0; i < 7; i++)
    {
        [p changeWLWW: windows[ i][ 0] :windows[ i][ 1]];
        [out addObject: @[eightBit( p), windowOf( p)]];
    }
    [p setFixed8bitsWLWW: YES];
    [p changeWLWW: 40 :400];
    [out addObject: @[eightBit( p), windowOf( p)]];
    [p setFixed8bitsWLWW: NO];

    // A transfer function of 4096 entries.
    float table[ 4096];
    for( int i = 0; i < 4096; i++) table[ i] = (float) ((i * 7919) % 4096) / 4095.f;
    [p setTransferFunction: [NSData dataWithBytes: table length: sizeof table]];
    [p changeWLWW: 50 :700];
    [out addObject: @[eightBit( p), windowOf( p)]];
    [p setTransferFunction: nil];
    [p changeWLWW: 50 :700];
    [out addObject: @[eightBit( p), windowOf( p)]];

    p.displayInverted = YES;
    [p changeWLWW: 50 :700];
    [out addObject: @[eightBit( p), @(p.displayInverted), hd( [p storedWindowLevelForCalibratedLevel: 33.5f]),
                      hd( [p calibratedWindowLevelForStoredLevel: -12.25f])]];
    p.displayInverted = NO;
    [out addObject: @[@(p.displayInverted), hd( [p storedWindowLevelForCalibratedLevel: 33.5f])]];

    // The 8-bit image made, dropped and made again.
    DCMPix *q = grey( 20, 30, 5);
    [q changeWLWW: 30 :300];      // no 8-bit image yet: the window is kept for it
    [out addObject: @[windowOf( q), @([q baseAddr] != NULL)]];
    [out addObject: eightBit( q)];
    [q kill8bitsImage];
    [q checkImageAvailble: 500 :-20];
    [out addObject: @[windowOf( q), eightBit( q), @(q.needToCompute8bitRepresentation)]];
    [q allocate8bitRepresentation];
    [out addObject: @[windowOf( q), eightBit( q)]];
    record( @"window-8bit", out);

    // A subtraction.
    DCMPix *frame = grey( 24, 18, 10), *mask = grey( 24, 18, -40);
    [frame changeWLWW: 10 :200];
    [frame setSubtractedfImage: [mask fImage] :NSMakePoint( 0, 0)];
    [frame changeWLWW: 10 :200];
    record( @"window-subtraction", @[eightBit( frame), windowOf( frame)]);

    // Colour.
    NSMutableArray *rgb = [NSMutableArray array];
    DCMPix *c = colour( 23, 17, 3);
    float cw[][ 2] = { {127, 256}, {60, 90}, {200, 30}, {0, 0}};
    for( int i = 0; i < 4; i++)
    {
        [c changeWLWW: cw[ i][ 0] :cw[ i][ 1]];
        [rgb addObject: @[eightBit( c), windowOf( c)]];
    }
    [c setTransferFunction: [NSData dataWithBytes: table length: sizeof table]];
    [c changeWLWW: 100 :200];
    [rgb addObject: eightBit( c)];
    c.displayInverted = YES;
    [rgb addObject: @[eightBit( c), @(c.displayInverted)]];
    record( @"window-colour", rgb);
}

static NSArray *series( int count, BOOL rgb)
{
    NSMutableArray *list = [NSMutableArray array];
    for( int i = 0; i < count; i++) [list addObject: rgb ? colour( 19, 13, i * 3) : grey( 19, 13, i * 45.5f - 100)];
    for( int i = 0; i < count; i++) [list[ i] setArrayPix: list :i];
    return list;
}

static void thickSlab( void)
{
    NSMutableArray *out = [NSMutableArray array];
    NSArray *list = series( 7, NO);
    int points[][ 2] = { {0, 0}, {5, 7}, {18, 12}, {9, 3}};
    for( int mode = 1; mode <= 3; mode++) for( int direction = 0; direction < 2; direction++) for( int stack = 1; stack <= 4; stack += 3)
        for( int index = 1; index < 7; index += 4)
        {
            DCMPix *p = list[ index];
            [p setFusion: mode :stack :direction];
            float *f = [p computefImage];
            float *m = [p computefImageForMeasurement];
            NSMutableArray *values = [NSMutableArray array];
            for( int i = 0; i < 4; i++) [values addObject: hd( [p getPixelValueX: points[ i][ 0] Y: points[ i][ 1]])];
            [values addObject: hd( [p getPixelValueX: -1 Y: 3])];
            [p changeWLWW: 100 :900];
            [out addObject: @[floats( p, f), floats( p, m), hd( p.countstackMean), values, eightBit( p)]];
            if( f != [p fImage]) free( f);
            if( m != [p fImage]) free( m);
            [p setFusion: 0 :-1 :-1];
        }
    record( @"thick-slab", out);

    NSMutableArray *rgb = [NSMutableArray array];
    NSArray *colours = series( 5, YES);
    for( int mode = 1; mode <= 3; mode++) for( int direction = 0; direction < 2; direction++)
    {
        DCMPix *p = colours[ 2];
        [p setFusion: mode :3 :direction];
        float *f = [p computeThickSlabRGB];
        NSMutableArray *values = [NSMutableArray array];
        for( int i = 0; i < 4; i++) [values addObject: hd( [p getPixelValueX: points[ i][ 0] Y: points[ i][ 1]])];
        [p changeWLWW: 127 :256];
        [rgb addObject: @[floats( p, f), values, eightBit( p)]];
        free( f);
        [p setFusion: 0 :-1 :-1];
    }
    // The last slices: the slab stops at the end of the series.
    DCMPix *last = colours[ 4];
    [last setFusion: 2 :3 :0];
    float *f = [last computeThickSlabRGB];
    [rgb addObject: floats( last, f)];
    free( f);
    record( @"thick-slab-colour", rgb);

    // A series of one image has no slab.
    DCMPix *single = grey( 10, 10, 0);
    [single setArrayPix: @[single] :0];
    [single setFusion: 1 :3 :0];
    record( @"thick-slab-single", @[@([single computefImage] == [single fImage]), hd( [single getPixelValueX: 2 Y: 3])]);
}

static void convolution( void)
{
    NSMutableArray *out = [NSMutableArray array];
    DCMPix *p = grey( 31, 22, 7);
    float sharpen[ 9] = { 0, -1, 0, -1, 5, -1, 0, -1, 0};
    float blur[ 25];
    for( int i = 0; i < 25; i++) blur[ i] = 1 + i % 3;
    [p setConvolutionKernel: sharpen :3 :1];
    [out addObject: @[@([p kernelsize]), hd( [p normalization]), hashOf( [p kernel], 9 * 4)]];
    float *f = [p computefImage];
    [p changeWLWW: 0 :1000];
    [out addObject: @[floats( p, f), eightBit( p), @([p computefImageForMeasurement] == [p fImage])]];
    free( f);
    [p setConvolutionKernel: blur :5 :45];
    f = [p computefImageForDisplay];
    [p changeWLWW: 0 :1000];
    [out addObject: @[floats( p, f), eightBit( p), @([p kernelsize]), hd( [p normalization])]];
    free( f);
    DCMPix *c = colour( 15, 11, 2);
    [c setConvolutionKernel: sharpen :3 :1];
    [c changeWLWW: 127 :256];
    [out addObject: eightBit( c)];
    float *copy = malloc( 31 * 22 * 4);
    memcpy( copy, [p fImage], 31 * 22 * 4);
    float *filtered = [p applyConvolutionOnImage: copy RGB: NO];
    [out addObject: floats( p, filtered)];
    free( filtered);
    [out addObject: @([p applyConvolutionOnImage: nil RGB: NO] == nil)];
    [p applyConvolutionOnSourceImage];
    [out addObject: floats( p, [p fImage])];
    [p setConvolutionKernel: nil :3 :1];
    f = [p computefImage];
    [out addObject: @[@(f == [p fImage]), @([p kernelsize]), hd( [p normalization])]];
    record( @"convolution", out);
}

static void shutters( void)
{
    NSMutableArray *out = [NSMutableArray array];
    NSRect rects[] = { {{3.4, 2.6}, {20.2, 11.5}}, {{-5, -4}, {50, 40}}, {{10, 8}, {0.4, 0.6}}, {{25.5, 18.5}, {30, 30}}};
    for( int i = 0; i < 4; i++)
    {
        DCMPix *p = grey( 33, 27, i);
        [p setBlackIndex: 17 * i];
        p.shutterEnabled = YES;
        p.shutterRect = rects[ i];
        [p changeWLWW: 20 :600];
        [out addObject: @[eightBit( p), @[hd( p.shutterRect.origin.x), hd( p.shutterRect.origin.y), hd( p.shutterRect.size.width), hd( p.shutterRect.size.height)]]];
    }
    // The circle and the polygon of the grey image.
    long radii[] = { 9, 20, 1};
    NSPoint centres[] = { {16, 13}, {5.7, 20.2}, {40, 3}};
    for( int i = 0; i < 3; i++)
    {
        DCMPix *p = grey( 33, 27, 3);
        p.shutterEnabled = YES;
        p.shutterRect = NSMakeRect( 0, 0, 33, 27);
        setIvar( p, "shutterCircular", &centres[ i], sizeof( NSPoint));
        setIvar( p, "shutterCircular_radius", &radii[ i], sizeof( long));
        [p setBlackIndex: 5];
        [p changeWLWW: 20 :600];
        [out addObject: eightBit( p)];
    }
    DCMPix *p = grey( 33, 27, 3);
    p.shutterEnabled = YES;
    p.shutterRect = NSMakeRect( 1, 1, 30, 24);
    NSPoint *polygon = malloc( 5 * sizeof( NSPoint));
    NSPoint corners[] = { {2.5, 1}, {30, 4.25}, {25.5, 22}, {6, 25}, {1, 12.75}};
    memcpy( polygon, corners, sizeof corners);
    long count = 5;
    setIvar( p, "shutterPolygonal", &polygon, sizeof( NSPoint*));
    setIvar( p, "shutterPolygonalSize", &count, sizeof( long));
    [p changeWLWW: 20 :600];
    [out addObject: eightBit( p)];
    DCMPix *c = colour( 21, 15, 4);
    c.shutterEnabled = YES;
    c.shutterRect = NSMakeRect( 2.6, 3.4, 12, 9.5);
    [c changeWLWW: 127 :256];
    [out addObject: eightBit( c)];
    // Off: the image as it is.
    DCMPix *off = grey( 33, 27, 1);
    off.shutterRect = NSMakeRect( 3, 3, 4, 4);
    [off changeWLWW: 20 :600];
    [out addObject: eightBit( off)];
    record( @"shutter", out);
}

static void mprPlane( void)
{
    DCMPix *p = grey( 16, 12, 0);
    float *plane = greyData( 16, 12, 333);
    [p setHorosMPRDisplayPixels: [NSData dataWithBytes: plane length: 16 * 12 * 4]];
    float *f = [p computefImageForDisplay];
    [p changeWLWW: 300 :900];
    NSMutableArray *out = [NSMutableArray arrayWithObjects: floats( p, f), @(f != [p fImage]), eightBit( p), floats( p, [p computefImage]), nil];
    free( f);
    [p setHorosMPRDisplayPixels: [NSData dataWithBytes: plane length: 8]];
    f = [p computefImageForDisplay];
    [out addObject: @(f == [p fImage])];
    free( plane);
    record( @"mpr-plane", out);
}

static void conversions( void)
{
    NSMutableArray *out = [NSMutableArray array];
    for( int mode = 0; mode < 4; mode++)
    {
        DCMPix *c = colour( 17, 13, mode);
        [c changeWLWW: 127 :256];
        [c ConvertToBW: mode];
        [out addObject: @[floats( c, [c fImage]), @([c isRGB]), windowOf( c), eightBit( c)]];
    }
    for( int mode = 0; mode < 4; mode++)
    {
        DCMPix *g = grey( 17, 13, mode * 10);
        [g changeWLWW: 40 :400];
        [g ConvertToRGB: mode :40 :400];
        [out addObject: @[floats( g, [g fImage]), @([g isRGB]), windowOf( g), eightBit( g)]];
    }
    DCMPix *g = grey( 9, 7, 0);
    [g ConvertToBW: 3];
    [out addObject: floats( g, [g fImage])];
    DCMPix *c = colour( 9, 7, 1);
    [c ConvertToRGB: 0 :0 :100];
    [out addObject: floats( c, [c fImage])];
    record( @"convert", out);

    NSMutableArray *values = [NSMutableArray array];
    DCMPix *a = grey( 11, 9, 2), *b = colour( 11, 9, 5);
    int points[][ 2] = { {0, 0}, {10, 8}, {11, 0}, {0, 9}, {-1, -1}, {5, 4}};
    for( int i = 0; i < 6; i++)
        [values addObject: @[hd( [a getPixelValueX: points[ i][ 0] Y: points[ i][ 1]]), hd( [b getPixelValueX: points[ i][ 0] Y: points[ i][ 1]])]];
    record( @"pixel-value", values);
}

static NSArray *bitmapOf( NSImage *image)
{
    if( image == nil) return @[@"nil"];
    NSBitmapImageRep *rep = (NSBitmapImageRep*) [[image representations] firstObject];
    if( ![rep isKindOfClass: [NSBitmapImageRep class]]) return @[hd( image.size.width), hd( image.size.height), NSStringFromClass( [rep class]) ?: @""];
    return @[hd( image.size.width), hd( image.size.height), @([rep pixelsWide]), @([rep pixelsHigh]), @([rep samplesPerPixel]),
             @([rep bytesPerRow]), [rep colorSpaceName], hashOf( [rep bitmapData], [rep bytesPerRow] * [rep pixelsHigh])];
}

static void pictures( void)
{
    NSMutableArray *out = [NSMutableArray array];
    DCMPix *g = grey( 37, 29, 0), *c = colour( 23, 17, 3);
    [g changeWLWW: 40 :400];
    [c changeWLWW: 127 :256];
    [out addObject: bitmapOf( [g image])];
    [out addObject: bitmapOf( [c image])];
    g.displayInverted = YES;
    [out addObject: bitmapOf( [g image])];
    record( @"image", out);

    NSMutableArray *thumbnails = [NSMutableArray array];
    long sizes[][ 2] = { {37, 29}, {29, 37}, {300, 200}, {68, 68}, {1, 1}, {500, 7}, {7, 500}};
    for( int i = 0; i < 7; i++)
    {
        DCMPix *p = grey( sizes[ i][ 0], sizes[ i][ 1], i);
        [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: 400 WL: 40])];
        [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: 0 WL: 0])];
        [thumbnails addObject: windowOf( p)];
    }
    DCMPix *p = grey( 37, 29, 0);
    [p changeWLWW: -100 :50];
    [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: 0 WL: 0])];
    [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: 1 WL: 5])];
    [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: -10 WL: 5])];
    // A window wider than single precision holds exactly, and samples that are
    // not finite.
    [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: 1e9f WL: 3e7f])];
    DCMPix *odd = grey( 90, 70, 0);
    float *f = [odd fImage];
    for( long i = 0; i < 90 * 70; i += 97) f[ i] = i % 2 ? NAN : (i % 3 ? INFINITY : -INFINITY);
    f[ 0] = 3e30f;
    [thumbnails addObject: bitmapOf( [odd generateThumbnailImageWithWW: 400 WL: 40])];
    p.displayInverted = YES;
    [thumbnails addObject: bitmapOf( [p generateThumbnailImageWithWW: 400 WL: 40])];
    for( int i = 0; i < 3; i++)
    {
        DCMPix *rgb = colour( 90 + 40 * i, 70 - 20 * i, i);
        [thumbnails addObject: bitmapOf( [rgb generateThumbnailImageWithWW: 256 WL: 127])];
        [thumbnails addObject: bitmapOf( [rgb generateThumbnailImageWithWW: 100 WL: 60])];
    }
    record( @"thumbnail", thumbnails);

    NSMutableArray *resized = [NSMutableArray array];
    DCMPix *small = grey( 256, 200, 0), *large = grey( 700, 600, 0);
    NSSize imageSizes[] = { {512, 512}, {513, 513}, {2000, 1500}, {1500, 3000}, {600, 520}, {4000, 4000}};
    for( int i = 0; i < 6; i++)
        for( DCMPix *pix in @[small, large])
        {
            NSImage *image = [[[NSImage alloc] initWithSize: imageSizes[ i]] autorelease];
            NSImage *r = [DCMPix resizeIfNecessary: image dcmPix: pix];
            [resized addObject: @[@(r == image), hd( r.size.width), hd( r.size.height)]];
        }
    record( @"resize", resized);
}

static NSArray *windowRecord( id w)
{
    if( w == nil) return @[@"nil"];
    return @[hd( [[w valueForKey: @"level"] floatValue]), hd( [[w valueForKey: @"width"] floatValue]), [w valueForKey: @"sourceValue"]];
}

static void previews( void)
{
    NSMutableArray *out = [NSMutableArray array];
    DCMPix *g = grey( 40, 30, 0), *c = colour( 12, 10, 1);
    [out addObject: @[@([g isColorPreviewFrame]), @([c isColorPreviewFrame])]];
    float saved[][ 2] = { {40, 400}, {40, 0}, {NAN, 10}, {10, INFINITY}, {-35.5f, -12}};
    for( int i = 0; i < 5; i++)
    {
        g.savedWL = saved[ i][ 0];
        g.savedWW = saved[ i][ 1];
        [out addObject: windowRecord( [g dicomPreviewWindow])];
    }
    [out addObject: windowRecord( [g automaticPreviewWindow])];
    [out addObject: windowRecord( [c automaticPreviewWindow])];
    [out addObject: windowRecord( [g frameRangePreviewWindow])];
    [out addObject: windowRecord( [c frameRangePreviewWindow])];
    [out addObject: windowRecord( [c storedRangePreviewWindow])];
    short bits[][ 2] = { {12, 16}, {0, 16}, {31, 8}, {0, 0}, {16, 16}, {1, 8}};
    float slopes[][ 2] = { {1, -1024}, {0.5f, 3}, {-2, 100}, {1, 0}, {0.0001f, 0}, {3.3f, -7.7f}};
    for( int i = 0; i < 6; i++) for( int s = 0; s < 2; s++)
    {
        DCMPix *p = grey( 8, 8, 0);
        setIvar( p, "bitsStored", &bits[ i][ 0], sizeof( short));
        setIvar( p, "bitsAllocated", &bits[ i][ 1], sizeof( short));
        BOOL sign = s;
        setIvar( p, "fIsSigned", &sign, sizeof( BOOL));
        p.slope = slopes[ i][ 0];
        p.offset = slopes[ i][ 1];
        [out addObject: windowRecord( [p storedRangePreviewWindow])];
    }
    // Rescales whose product with the stored range is not exact: the fused
    // multiply-add and the separate one differ there.
    short inexactBits[] = { 16, 12, 16, 15};
    BOOL inexactSigned[] = { YES, NO, YES, NO};
    float inexact[][ 2] = { {0.1f, 0.7f}, {0.3f, -1024.3f}, {0.3f, -7.77f}, {0.1f, 0.7f}};
    for( int i = 0; i < 4; i++)
    {
        DCMPix *p = grey( 8, 8, 0);
        short allocated = 16;
        setIvar( p, "bitsStored", &inexactBits[ i], sizeof( short));
        setIvar( p, "bitsAllocated", &allocated, sizeof( short));
        setIvar( p, "fIsSigned", &inexactSigned[ i], sizeof( BOOL));
        p.slope = inexact[ i][ 0];
        p.offset = inexact[ i][ 1];
        [out addObject: windowRecord( [p storedRangePreviewWindow])];
    }
    DCMPix *flat = grey( 8, 8, 0);
    float *f = [flat fImage];
    for( int i = 0; i < 64; i++) f[ i] = 7;
    [out addObject: windowRecord( [flat frameRangePreviewWindow])];
    [out addObject: windowRecord( [flat automaticPreviewWindow])];
    record( @"preview-window", out);
}

int main( int argc, const char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        gRecords = [[NSMutableArray alloc] init];
        fprintf( stderr, "window8bit\n"); window8bit();
        fprintf( stderr, "thickSlab\n"); thickSlab();
        fprintf( stderr, "convolution\n"); convolution();
        fprintf( stderr, "shutters\n"); shutters();
        fprintf( stderr, "mprPlane\n"); mprPlane();
        fprintf( stderr, "conversions\n"); conversions();
        fprintf( stderr, "pictures\n"); pictures();
        fprintf( stderr, "previews\n"); previews();
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
    if revision == roi_harness.WORKTREE:
        return roi_harness.build(revision, folder, PROBE, config=configuration, app_swift=APP_SWIFT)
    # The revision's DCMPix.m already calls the Swift that left it before this
    # part did; it gets this checkout's, without the extensions that took this.
    keep = [name for name in roi_harness.swift_dcmpix_files() if name not in MOVED]
    return roi_harness.build(revision, folder, PROBE, config=configuration, dcmpix_swift=keep, app_swift=APP_SWIFT)


def check_expectations(records, failures):
    """What the records must show whatever the revision: each part did its work."""
    window = records.get('window-8bit', [])
    if len({str(w[0]) for w in window[:7]}) < 4:
        failures.append('the 8-bit images are mostly the same: the window had no effect')
    slab = records.get('thick-slab', [])
    if len({s[0] for s in slab}) < len(slab) // 3:
        failures.append('the thick slabs are mostly the same: the mode, stack or direction had no effect')
    # The rectangle over the whole image is the image without a shutter: the two are the same.
    shutter = [s[0] if isinstance(s, list) else s for s in records.get('shutter', [])]
    if len(set(shutter)) < len(shutter) - 1:
        failures.append('the shutters are mostly the same: the rectangle, circle or polygon had no effect')


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
        print('skipped: no revision of DCMPix.m in this history makes the display image in Objective-C', file=sys.stderr)
        sys.exit(SKIPPED)

    failures = []
    outputs = {}
    with tempfile.TemporaryDirectory(prefix='horos-dcmpix-display-') as tmp:
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
        if os.environ.get('HOROS_DISPLAY_RECORDS'):
            Path(os.environ['HOROS_DISPLAY_RECORDS']).write_text(json.dumps(outputs, indent=1, sort_keys=True))

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
    print(f'PASS: {len(current)} records (8-bit images, thick slabs, convolution, shutters, conversions, pictures, '
          f'preview windows) identical to {against} in {configuration}')


if __name__ == '__main__':
    main()
