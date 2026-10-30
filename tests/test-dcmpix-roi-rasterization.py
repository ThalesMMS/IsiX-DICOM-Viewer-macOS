#!/usr/bin/env python3
"""DCMPix rasterizes, samples, masks and fills ROIs as it did in Objective-C.

The ROI half of DCMPix - the polygon clipping and scanline fill, the pixels
and locations inside a ROI (-getROIValue:::), a line's profile
(-getLineROIValue::), the point test (-isInROI::), the polygon and RT
STRUCT masks, the fills (-fillROI: in every variant, on a slice and across a
volume in the three orientations, with thresholds, addition, outside, a clip
rectangle and the restore cache), the calcium cofactor and the statistics -
runs here on synthetic float and RGB images with every kind of ROI: oval,
rectangle, open and closed polygons (concave, self-intersecting, crossing the
image border, horizontal edges, degenerate), pencil, point, line and brush.

Two harnesses are built with tests/roi_harness.py from the application's own
objects: the revision before the ROI half left DCMPix.m, read from git, and
this checkout. Both run the same probe and every value they print must be the
same, bit for bit (floats in hexadecimal, buffers as hashes of their bytes).
A few results depend on how the compiler converted an out-of-range float to a
byte, which the Objective-C left undefined (Debug saturated negatives to
zero, Release kept the low byte of the integer): those are printed apart and
checked against the Release rule, which this checkout follows in every
configuration. The probe's own expectations - areas, fills and masks worked
out by hand on the synthetic shapes - have to hold in both.

Where the Objective-C was wrong, the corrected behaviour is checked by the
probe's expectations, not against the reference: the restore of a polygon on
an RGB volume gives each pixel inside it its own original bytes (the
Objective-C read the next floats of the original as a pixel's bytes); the
five-argument fill is the fill of the image itself (the Objective-C asked for
stack -1, which is refused, and filled nothing); a point is in a brush when
the texel that contains it is painted (the Objective-C took the texel from
the fractional position, half a row off at y + 0.5).

`<git revision>` compares with that revision instead. `--harnesses DIR
[revision]` only builds the two harnesses into DIR/reference and DIR/current,
for a timing campaign with tools/ab_protocol.py: `harness bench N` prints, as
JSON, N timings in milliseconds of ROI measures, masks and fills on 512 x 512
images. Needs a Debug build of this checkout whose compile commands are logged;
Once DCMPix itself is Swift, no revision of DCMPix.m links with this checkout's
Swift: the reference is then what the probe answered against the last
Objective-C class, kept for each configuration in
tests/fixtures/dcmpix-roi-rasterization-records.json (HOROS_RECORD_GOLDEN=1 on a checkout
of that class writes them).

without it the test is skipped. HOROS_TEST_CONFIGURATION=Release uses the
Release build's commands and objects.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import roi_harness  # noqa: E402

SKIPPED = roi_harness.SKIPPED
PIX_SOURCE = roi_harness.PIX_SOURCE
# The text whose removal from DCMPix.m marks the move: the revision before it is the reference.
MOVE_MARK = 'void ras_FillPolygon('

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang, swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)
configuration = roi_harness.configuration()
try:
    roi_harness.objc_command(configuration)
    roi_harness.objects_dir(configuration)
except LookupError as error:
    print('skipped: %s' % error, file=sys.stderr)
    sys.exit(SKIPPED)

arguments = sys.argv[1:]
keep = None
if arguments[:1] == ['--harnesses']:
    keep, arguments = Path(arguments[1]), arguments[2:]
# The records of the last Objective-C class, in tests/fixtures.
GOLDEN = 'dcmpix-roi-rasterization'
if not roi_harness.objc_class():
    # No revision of DCMPix.m links with the Swift class: the reference is
    # what this test recorded against the last Objective-C class.
    reference = None
elif arguments:
    reference = arguments[0]
elif MOVE_MARK in history_reference.show('HEAD', PIX_SOURCE).decode('latin1'):
    reference = 'HEAD'  # the Objective-C of HEAD: this checkout's own, or the move is not committed yet
else:
    reference = history_reference.before_text_removed(PIX_SOURCE, MOVE_MARK) or 'HEAD'

PROBE = r'''
// What DCMPix answers for a ROI, never declared in DCMPix.h.
@interface DCMPix (RasterizationProbe)
+ (unsigned char *)getMapFromRTSTRUCTROI:(ROI *)roi width:(int)imageWidth height:(int)imageHeight size:(NSSize *)size origin:(NSPoint *)origin;
- (void) probeSetSize:(long) w :(long) h fImage:(float*) f rgb:(BOOL) rgb slices:(NSArray*) slices;
- (void) probeBorrow;
@end

@implementation DCMPix (RasterizationProbe)
- (void) probeSetSize:(long) w :(long) h fImage:(float*) f rgb:(BOOL) rgb slices:(NSArray*) slices
{
    PIX_IVAR( self, long, width) = w; PIX_IVAR( self, long, height) = h;
    PIX_IVAR( self, float*, fImage) = f; PIX_IVAR( self, BOOL, isRGB) = rgb;
    [PIX_IVAR( self, NSArray*, pixArray) release]; PIX_IVAR( self, NSArray*, pixArray) = [slices retain];
}
- (void) probeBorrow { PIX_IVAR( self, float*, fExternalOwnedImage) = PIX_IVAR( self, float*, fImage); }
@end

// The app's logging of a stack trace, which the harness would otherwise leave a zero: the message alone.
void N2LogStackTrace( NSString *format, ...)
{
    va_list arguments;
    va_start( arguments, format);
    NSLogv( format, arguments);
    va_end( arguments);
}
// Its one-message form, which the Swift of DCMPix calls since Swift cannot pass a variable argument list.
void N2LogStackTraceMessage( NSString *message)
{
    NSLog( @"%@", message);
}

static int gSide = 64;

/// A float image or an ARGB one, its pixels the display buffer as well.
@interface RasterPix : ProbePix
@end
@implementation RasterPix
- (char*) baseAddr { return (char*) PIX_IVAR( self, float*, fImage); }
@end

static float pattern( long x, long y, long z) { return (float)( x * 3.25 - y * 7.5 + z * 11.0) + ((x / 6 + y / 5 + z) % 2 ? 1200.75f : -17.125f); }

static RasterPix *image( BOOL rgb)
{
    RasterPix *pix = [[[RasterPix alloc] init] autorelease];
    float *f = (float*) calloc( gSide * gSide, sizeof( float));
    for( long y = 0; y < gSide; y++)
        for( long x = 0; x < gSide; x++)
        {
            if( rgb)
            {
                unsigned char *p = (unsigned char*) &f[ y * gSide + x];
                p[ 0] = 255; p[ 1] = (x * 7 + y * 3) % 256; p[ 2] = (x * 2 + y * 11 + 40) % 256; p[ 3] = (250 - x - y * 2) % 256;
            }
            else f[ y * gSide + x] = pattern( x, y, 0);
        }
    [pix probeSetSize: gSide : gSide fImage: f rgb: rgb slices: @[[NSNull null]]];
    return pix;
}

// A volume: kVW x kVH pixels, kVS slices, one contiguous buffer, the first slice's DCMPix holding it.
static const long kVW = 24, kVH = 20, kVS = 16;
static float *gOriginalVolume = NULL;
static BOOL gOriginalRGB = NO;

static RasterPix *volume( BOOL rgb)
{
    float *f = (float*) calloc( kVW * kVH * kVS, sizeof( float));
    for( long z = 0; z < kVS; z++)
        for( long y = 0; y < kVH; y++)
            for( long x = 0; x < kVW; x++)
            {
                long i = z * kVW * kVH + y * kVW + x;
                if( rgb)
                {
                    unsigned char *p = (unsigned char*) &f[ i];
                    p[ 0] = 255; p[ 1] = (x * 9 + z * 5) % 256; p[ 2] = (y * 13 + z) % 256; p[ 3] = (x + y + z * 7) % 256;
                }
                else f[ i] = pattern( x, y, z);
            }
    free( gOriginalVolume);
    gOriginalVolume = (float*) malloc( kVW * kVH * kVS * sizeof( float));
    memcpy( gOriginalVolume, f, kVW * kVH * kVS * sizeof( float));
    gOriginalRGB = rgb;
    NSMutableArray *slices = [NSMutableArray array];
    RasterPix *first = nil;
    for( long z = 0; z < kVS; z++)
    {
        RasterPix *pix = [[[RasterPix alloc] init] autorelease];
        [slices addObject: pix];
        if( z == 0) first = pix;
    }
    for( long z = 0; z < kVS; z++)
    {
        [[slices objectAtIndex: z] probeSetSize: kVW : kVH fImage: z == 0 ? f : f + z * kVW * kVH rgb: rgb slices: slices];
        if( z) [[slices objectAtIndex: z] probeBorrow];
    }
    return first;
}

// -prepareRestore makes a DCMPix of every slice's file: here, a copy of the slice as the volume was made.
static id restoreSlice( id self, SEL _cmd, NSString *path, long pos, long tot, float *ptr, long frame, long serie, BOOL bonjour, id imageObj)
{
    [self release];
    RasterPix *pix = [[RasterPix alloc] init];
    float *f = (float*) malloc( kVW * kVH * sizeof( float));
    memcpy( f, gOriginalVolume + pos * kVW * kVH, kVW * kVH * sizeof( float));
    [pix probeSetSize: kVW : kVH fImage: f rgb: gOriginalRGB slices: nil];
    return pix;
}

static NSString *H( const void *b, size_t n) { return b ? [NSString stringWithFormat: @"%016llx", hashBytes( (const unsigned char*) b, n)] : @"nil"; }

static ROI *makeROI( ToolMode type, double *xy, int count)
{
    ROI *roi = [[[ROI alloc] initWithType: type : 0.5 : 0.625 : NSMakePoint( -30.5, 12.25)] autorelease];
    if( count) [roi setPoints: myPoints( xy, count)];
    return roi;
}

static ROI *makeRect( ToolMode type, NSRect r)
{
    ROI *roi = makeROI( type, NULL, 0);
    roi.rect = r;
    return roi;
}

static unsigned char brushTexel( int w, int h, int x, int y, int shape)
{
    return shape == 0 ? (((x - w/2) * (x - w/2) + (y - h/2) * (y - h/2) <= (w/3) * (h/3)) || (x >= w - 4 && y >= 2 && y <= 6) ? 255 : 0)
                      : ((x + y) % 3 == 0 ? 7 : 0);
}

static ROI *makeBrush( int w, int h, int x0, int y0, int shape)
{
    unsigned char *mask = calloc( w * h + 1, 1);
    for( int y = 0; y < h; y++) for( int x = 0; x < w; x++)
        mask[ y * w + x] = brushTexel( w, h, x, y, shape);
    ROI *roi = [[[ROI alloc] initWithTexture: mask textWidth: w textHeight: h textName: @"Brush" positionX: x0 positionY: y0
                                     spacingX: 0.5 spacingY: 0.625 imageOrigin: NSMakePoint( -30.5, 12.25)] autorelease];
    free( mask);
    return roi;
}

static NSMutableDictionary *cases, *uncompared, *corrected;
static NSMutableArray *expectations;
static void expect( BOOL ok, NSString *what) { if( !ok) [expectations addObject: what]; }

static NSDictionary *valuesOf( DCMPix *pix, ROI *roi)
{
    long count = -1;
    float *locations = (float*) 1;
    float *values = [pix getROIValue: &count :roi :&locations];
    NSDictionary *d = @{@"count": @(count), @"values": H( values, values ? count * sizeof( float) : 0),
                        @"locations": H( locations, locations ? count * 2 * sizeof( float) : 0),
                        @"first": values && count > 0 ? F( values[ 0]) : @"-", @"last": values && count > 0 ? F( values[ count - 1]) : @"-",
                        @"firstLocation": locations && count > 0 ? [NSString stringWithFormat: @"%@,%@", F( locations[ 0]), F( locations[ 1])] : @"-",
                        @"locationsNil": @(locations == NULL), @"valuesNil": @(values == NULL)};
    free( values);
    free( locations);
    long other = -1;
    float *again = [pix getROIValue: &other :roi :nil];
    expect( other == count, [NSString stringWithFormat: @"%@: the count without locations is %ld, with %ld", roi.name, other, count]);
    free( again);
    return d;
}

static NSDictionary *statisticsOf( DCMPix *pix, ROI *roi)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for( NSNumber *moments in @[@NO, @YES])
    {
        [[NSUserDefaults standardUserDefaults] setBool: moments.boolValue forKey: @"ROIComputeSkewnessAndKurtosis"];
        float mean = -1, total = -1, dev = -1, min = -1, max = -1, skewness = -1, kurtosis = -1;
        [pix computeROI: roi :&mean :&total :&dev :&min :&max :&skewness :&kurtosis];
        d[ moments.boolValue ? @"moments" : @"plain"] = @[F( mean), F( total), F( dev), F( min), F( max), F( skewness), F( kurtosis), F( roi.median)];
        float mean2 = -1, total2 = -1, dev2 = -1, min2 = -1, max2 = -1;
        [pix computeROI: roi :&mean2 :&total2 :&dev2 :&min2 :&max2];
        expect( mean2 == mean && total2 == total && min2 == min && max2 == max,
                [NSString stringWithFormat: @"%@: the six-argument statistics differ", roi.name]);
    }
    return d;
}

static NSString *insideGrid( DCMPix *pix, ROI *roi)
{
    NSMutableString *s = [NSMutableString string];
    for( double y = -1.5; y < gSide + 1.5; y += 1.75)
        for( double x = -1.5; x < gSide + 1.5; x += 1.75)
            [s appendString: [pix isInROI: roi :NSMakePoint( x, y)] ? @"1" : @"0"];
    return s;
}

// A point is in a brush when the texel that contains it is painted, texel
// (x, y) covering x..<x + 1 and y..<y + 1 of the image, at its corners and
// edges as well as at its centre; a point just past the texture is not.
static NSDictionary *brushPoints( DCMPix *pix, ROI *roi, int w, int h, int x0, int y0, int shape)
{
    const double offsets[] = { 0, 0.001, 0.25, 0.5, 0.75, 0.999};
    long tested = 0, wrong = 0;
    NSMutableString *s = [NSMutableString string];
    for( int y = -1; y <= h; y++)
        for( int x = -1; x <= w; x++)
        {
            BOOL painted = x >= 0 && y >= 0 && x < w && y < h && brushTexel( w, h, x, y, shape);
            for( int i = 0; i < 6; i++)
                for( int j = 0; j < 6; j++)
                {
                    BOOL in = [pix isInROI: roi :NSMakePoint( x0 + x + offsets[ i], y0 + y + offsets[ j])];
                    [s appendString: in ? @"1" : @"0"];
                    tested++;
                    if( in != painted) wrong++;
                }
        }
    expect( wrong == 0, [NSString stringWithFormat: @"%@: %ld of %ld points answer another texel than the one that contains them", roi.name, wrong, tested]);
    return @{@"points": H( s.UTF8String, s.length), @"tested": @(tested), @"wrong": @(wrong)};
}

static NSDictionary *mapOf( DCMPix *pix, ROI *roi)
{
    NSSize size = NSMakeSize( -1, -1);
    NSPoint origin = NSMakePoint( -1, -1);
    unsigned char *map = [pix getMapFromPolygonROI: roi size: &size origin: &origin];
    NSSize size2 = NSMakeSize( -1, -1);
    NSPoint origin2 = NSMakePoint( -1, -1);
    unsigned char *map2 = [DCMPix getMapFromPolygonROI: roi size: &size2 origin: &origin2];
    long bytes = map ? (long) size.width * (long) size.height : 0;
    long lit = 0;
    for( long i = 0; i < bytes; i++) if( map[ i]) lit++;
    expect( (map == NULL) == (map2 == NULL) && NSEqualSizes( size, size2) && NSEqualPoints( origin, origin2) &&
            (map == NULL || memcmp( map, map2, bytes) == 0), [NSString stringWithFormat: @"%@: the class and instance masks differ", roi.name]);
    NSDictionary *d = @{@"map": map ? H( map, bytes) : @"nil", @"lit": @(lit), @"size": NSStringFromSize( size), @"origin": NSStringFromPoint( origin)};
    free( map);
    free( map2);
    return d;
}

static NSDictionary *contourOf( ROI *roi, int w, int h)
{
    NSSize size = NSMakeSize( -1, -1);
    NSPoint origin = NSMakePoint( -1, -1);
    unsigned char *map = [DCMPix getMapFromRTSTRUCTROI: roi width: w height: h size: &size origin: &origin];
    long bytes = map ? (long) size.width * (long) size.height : 0, lit = 0;
    for( long i = 0; i < bytes; i++) if( map[ i]) lit++;
    NSDictionary *d = @{@"map": map ? H( map, bytes) : @"nil", @"lit": @(lit), @"size": NSStringFromSize( size), @"origin": NSStringFromPoint( origin)};
    free( map);
    return d;
}

static NSDictionary *lineOf( DCMPix *pix, ROI *roi)
{
    long count = -1;
    float *values = [pix getLineROIValue: &count :roi];
    NSDictionary *d = @{@"count": @(count), @"values": H( values, values ? count * sizeof( float) : 0),
                        @"first": values && count ? F( values[ 0]) : @"-", @"last": values && count ? F( values[ count - 1]) : @"-"};
    free( values);
    return d;
}

static NSString *changed( const float *before, const float *after, long count)
{
    long n = 0;
    for( long i = 0; i < count; i++) if( memcmp( before + i, after + i, sizeof( float))) n++;
    return [NSString stringWithFormat: @"%ld", n];
}

typedef void (^Fill)( DCMPix *pix);

/// A fill on a fresh image: the hash of the whole buffer after it and how many pixels changed.
static NSDictionary *fillImage( BOOL rgb, Fill fill)
{
    DCMPix *pix = image( rgb);
    long n = gSide * gSide;
    float *before = malloc( n * sizeof( float));
    memcpy( before, pix.fImage, n * sizeof( float));
    fill( pix);
    NSDictionary *d = @{@"image": H( pix.fImage, n * sizeof( float)), @"changed": changed( before, pix.fImage, n)};
    free( before);
    return d;
}

static NSDictionary *fillVolume( BOOL rgb, BOOL withRestore, Fill fill)
{
    DCMPix *pix = volume( rgb);
    long n = kVW * kVH * kVS;
    float *data = pix.fImage;
    float *before = malloc( n * sizeof( float));
    memcpy( before, data, n * sizeof( float));
    if( withRestore)
    {
        for( long i = 0; i < n; i++) data[ i] = rgb ? data[ i] : -999.5f;
        if( rgb) for( long i = 0; i < n; i++) ((unsigned char*) &data[ i])[ 1] = 3;
        memcpy( before, data, n * sizeof( float));
        BOOL prepared = [pix prepareRestore];
        expect( prepared, @"the restore cache was not prepared");
    }
    fill( pix);
    if( withRestore) [pix freeRestore];
    NSDictionary *d = @{@"volume": H( data, n * sizeof( float)), @"changed": changed( before, data, n)};
    free( before);
    return d;
}

static void addCase( NSString *name, NSDictionary *value) { cases[ name] = value; }

// The restore of a polygon on an RGB volume gives every pixel inside it its
// three colour bytes back, and leaves the others as they were: the pixels
// inside are those the same restore changes on a float volume.
static NSDictionary *restoreRGB( ROI *roi, long o, long stack)
{
    long n = kVW * kVH * kVS;
    DCMPix *grey = volume( NO);
    float *values = grey.fImage;
    for( long i = 0; i < n; i++) values[ i] = -999.5f;
    expect( [grey prepareRestore], @"the restore cache was not prepared");
    [grey fillROI: roi : 0 : -FLT_MAX : FLT_MAX : NO : o : stack : YES];
    [grey freeRestore];
    BOOL *inside = calloc( n, sizeof( BOOL));
    long insideCount = 0;
    for( long i = 0; i < n; i++) if( values[ i] != -999.5f) { inside[ i] = YES; insideCount++; }

    DCMPix *pix = volume( YES);
    unsigned char *bytes = (unsigned char*) pix.fImage;
    for( long i = 0; i < n; i++) bytes[ i * 4 + 1] = 3;
    unsigned char *before = malloc( n * 4);
    memcpy( before, bytes, n * 4);
    expect( [pix prepareRestore], @"the restore cache was not prepared");
    [pix fillROI: roi : 0 : -FLT_MAX : FLT_MAX : NO : o : stack : YES];
    [pix freeRestore];
    // An axial fill paints the image it is sent to with the pixels of slice `stack`.
    const unsigned char *original = (const unsigned char*) gOriginalVolume + (o == 2 ? stack * kVW * kVH * 4 : 0);
    long wrong = 0;
    for( long i = 0; i < n; i++)
    {
        const unsigned char *expected = inside[ i] ? original : before;
        if( bytes[ i * 4] != before[ i * 4] || memcmp( bytes + i * 4 + 1, expected + i * 4 + 1, 3)) wrong++;
    }
    expect( insideCount > 0 && wrong == 0, [NSString stringWithFormat:
            @"orientation %ld: the RGB restore of a polygon gave %ld of %ld pixels other bytes than the original's", o, wrong, n]);
    NSDictionary *d = @{@"volume": H( bytes, n * 4), @"inside": @(insideCount), @"wrong": @(wrong)};
    free( inside);
    free( before);
    return d;
}

static NSDictionary *bench( int repetitions);

int main( int argc, char *argv[])
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [[NSUserDefaults standardUserDefaults] setVolatileDomain: @{} forName: NSArgumentDomain];
        [ROI loadDefaultSettings];
        Method init = class_getInstanceMethod( [DCMPix class], @selector(initWithPath::::::isBonjour:imageObj:));
        method_setImplementation( init, (IMP) restoreSlice);

        if( argc > 2 && strcmp( argv[ 1], "bench") == 0)
        {
            NSData *json = [NSJSONSerialization dataWithJSONObject: bench( atoi( argv[ 2])) options: 0 error: nil];
            printf( "%s\n", [[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] UTF8String]);
            return 0;
        }

        cases = [NSMutableDictionary dictionary];
        uncompared = [NSMutableDictionary dictionary];
        corrected = [NSMutableDictionary dictionary];
        expectations = [NSMutableArray array];

        double concave[] = { 10, 10, 50, 12, 52, 48, 30, 30, 12, 50};
        double crossing[] = { -8, 20, 30, -6, 75, 25, 40, 80, 5, 70};
        double bowtie[] = { 8, 8, 40, 40, 40, 8, 8, 40};
        double horizontal[] = { 5, 5, 40, 5, 40, 20, 25, 20, 25, 35, 5, 35};
        double outsideAll[] = { -30, -30, -10, -30, -10, -10, -30, -10};
        double thin[] = { 20, 20, 21, 50, 22, 20};
        double two[] = { 10, 10, 40, 30};
        double onePoint[] = { 17.75, 23.5};
        double oneOutside[] = { 70, 5};
        double fractional[] = { 10.4, 12.6, 30.5, 9.25, 41.75, 33.5, 22.1, 44.9, 8.6, 30.2};
        double pencil[] = { 16, 16, 19.5, 14.5, 24, 16.75, 27, 22, 25.25, 27.2, 20, 29, 15.6, 25.4, 13.8, 20.4};
        double open[] = { 6, 40, 20, 52, 34, 41, 48, 58};
        double line[] = { 5.5, 6.25, 40.75, 50.5};
        double lineCrossing[] = { -10, 30, 70, 35};
        double lineSteep[] = { 33, 2, 31, 61};

        NSMutableDictionary *rois = [NSMutableDictionary dictionary];
        rois[@"oval"] = makeRect( tOval, NSMakeRect( 30.5, 28.25, 12.75, 9.5));
        rois[@"oval-edge"] = makeRect( tOval, NSMakeRect( 60, 5, 10, 8));
        rois[@"rectangle"] = makeRect( tROI, NSMakeRect( 12.5, 14.25, 20.75, 30.5));
        rois[@"rectangle-outside"] = makeRect( tROI, NSMakeRect( -5, 50, 20, 30));
        rois[@"polygon-concave"] = makeROI( tCPolygon, concave, 5);
        rois[@"polygon-crossing"] = makeROI( tCPolygon, crossing, 5);
        rois[@"polygon-bowtie"] = makeROI( tCPolygon, bowtie, 4);
        rois[@"polygon-horizontal"] = makeROI( tCPolygon, horizontal, 6);
        rois[@"polygon-outside"] = makeROI( tCPolygon, outsideAll, 4);
        rois[@"polygon-thin"] = makeROI( tCPolygon, thin, 3);
        rois[@"polygon-two"] = makeROI( tCPolygon, two, 2);
        rois[@"polygon-fractional"] = makeROI( tCPolygon, fractional, 5);
        rois[@"open-polygon"] = makeROI( tOPolygon, open, 4);
        rois[@"pencil"] = makeROI( tPencil, pencil, 8);
        rois[@"point"] = makeROI( t2DPoint, onePoint, 1);
        rois[@"point-outside"] = makeROI( tCPolygon, oneOutside, 1);
        rois[@"empty-polygon"] = makeROI( tCPolygon, NULL, 0);
        rois[@"brush"] = makeBrush( 21, 17, 9, 11, 0);
        rois[@"brush-edge"] = makeBrush( 30, 26, -6, 50, 1);
        rois[@"line"] = makeROI( tMesure, line, 2);
        rois[@"line-crossing"] = makeROI( tMesure, lineCrossing, 2);
        rois[@"line-steep"] = makeROI( tMesure, lineSteep, 2);
        for( NSString *name in rois) [rois[ name] setName: name];

        for( NSString *rgbName in @[@"float", @"rgb"])
        {
            BOOL rgb = [rgbName isEqualToString: @"rgb"];
            DCMPix *pix = image( rgb);
            for( NSString *name in [rois.allKeys sortedArrayUsingSelector: @selector(compare:)])
            {
                ROI *roi = rois[ name];
                NSString *key = [NSString stringWithFormat: @"%@/%@", rgbName, name];
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                if( roi.type == tMesure)
                    d[@"line"] = lineOf( pix, roi);
                else if( ![name isEqualToString: @"empty-polygon"])
                {
                    d[@"values"] = valuesOf( pix, roi);
                    if( !rgb) d[@"statistics"] = statisticsOf( pix, roi);
                    if( roi.type == tPlain)
                    {
                        // The Objective-C took the texel from the fractional position
                        // (half a row off at y + 0.5): the records are not the reference.
                        corrected[[NSString stringWithFormat: @"%@/inside", key]] = insideGrid( pix, roi);
                        BOOL edge = [name isEqualToString: @"brush-edge"];
                        corrected[[NSString stringWithFormat: @"%@/points", key]] =
                            edge ? brushPoints( pix, roi, 30, 26, -6, 50, 1) : brushPoints( pix, roi, 21, 17, 9, 11, 0);
                    }
                    else
                        d[@"inside"] = insideGrid( pix, roi);
                }
                else
                    d[@"values"] = valuesOf( pix, roi);
                d[@"calcium"] = @[@([pix calciumCofactorForROI: roi threshold: 130]), @([pix calciumCofactorForROI: roi threshold: 1500])];
                if( !rgb && roi.type != tMesure && ![name isEqualToString: @"empty-polygon"])
                {
                    d[@"map"] = mapOf( pix, roi);
                    d[@"contour"] = contourOf( roi, gSide, gSide);
                    d[@"contour-small"] = contourOf( roi, 16, 12);
                }
                addCase( key, d);
            }
        }

        // Fills on a slice: inside and outside, thresholds, addition, a clip, the shorter variants.
        NSArray *fillNames = @[@"rectangle", @"oval-edge", @"polygon-concave", @"polygon-crossing", @"polygon-bowtie", @"polygon-horizontal",
                               @"polygon-outside", @"polygon-two", @"pencil", @"open-polygon", @"point", @"brush", @"brush-edge"];
        for( NSString *name in fillNames)
        {
            ROI *roi = rois[ name];
            for( NSString *rgbName in @[@"float", @"rgb"])
            {
                BOOL rgb = [rgbName isEqualToString: @"rgb"];
                float set = rgb ? 77 : -333.25f, low = rgb ? 40 : -50, high = rgb ? 200 : 1300;
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                // The five-argument form asks for stack -1 of an axial plane, which the scissor bounds refuse.
                d[@"inside"] = fillImage( rgb, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : NO : 2 : 0]; });
                // The five-argument fill is the fill of the image itself. The
                // Objective-C asked for stack -1, which is refused: it filled nothing.
                NSDictionary *five = fillImage( rgb, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : NO]; });
                corrected[[NSString stringWithFormat: @"fill/%@/%@/five", rgbName, name]] = five;
                expect( [five isEqual: d[@"inside"]], [NSString stringWithFormat: @"%@/%@: the five-argument fill differs from the fill of the image", rgbName, name]);
                d[@"outside"] = fillImage( rgb, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : YES : 2 : 0]; });
                d[@"thresholds"] = fillImage( rgb, ^(DCMPix *p) { [p fillROI: roi : set : low : high : NO : 2 : 0]; });
                d[@"outside-thresholds"] = fillImage( rgb, ^(DCMPix *p) { [p fillROI: roi : set : low : high : YES : 2 : 0]; });
                d[@"addition"] = fillImage( rgb, ^(DCMPix *p) {
                    [p fillROI: roi newVal: rgb ? 30 : 12.5f minValue: low maxValue: high outside: NO orientationStack: 2 stackNo: 0 restore: NO addition: YES]; });
                d[@"outside-addition"] = fillImage( rgb, ^(DCMPix *p) {
                    [p fillROI: roi newVal: rgb ? 30 : 12.5f minValue: low maxValue: high outside: YES orientationStack: 2 stackNo: 0 restore: NO addition: YES]; });
                d[@"spline"] = fillImage( rgb, ^(DCMPix *p) {
                    [p fillROI: roi newVal: set minValue: -FLT_MAX maxValue: FLT_MAX outside: NO orientationStack: 2 stackNo: 0 restore: NO addition: NO spline: YES]; });
                d[@"clip"] = fillImage( rgb, ^(DCMPix *p) {
                    [p fillROI: roi newVal: set minValue: -FLT_MAX maxValue: FLT_MAX outside: NO orientationStack: 2 stackNo: 0 restore: NO addition: NO
                         spline: NO clipMin: NSMakePoint( 15, 12) clipMax: NSMakePoint( 45, 40)]; });
                d[@"outside-clip"] = fillImage( rgb, ^(DCMPix *p) {
                    [p fillROI: roi newVal: set minValue: -FLT_MAX maxValue: FLT_MAX outside: YES orientationStack: 2 stackNo: 0 restore: NO addition: NO
                         spline: NO clipMin: NSMakePoint( 15, 12) clipMax: NSMakePoint( 45, 40)]; });
                d[@"restore-without-cache"] = fillImage( rgb, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : NO : 2 : 0 : YES]; });
                addCase( [NSString stringWithFormat: @"fill/%@/%@", rgbName, name], d);
                if( rgb)
                {
                    // Bytes past 255 and below zero: the conversion the Objective-C left to the compiler.
                    uncompared[[NSString stringWithFormat: @"fill/rgb/%@/negative", name]] = @{
                        @"set": fillImage( YES, ^(DCMPix *p) { [p fillROI: roi : -45.5f : -FLT_MAX : FLT_MAX : NO : 2 : 0]; }),
                        @"addition": fillImage( YES, ^(DCMPix *p) {
                            [p fillROI: roi newVal: -260 minValue: -FLT_MAX maxValue: FLT_MAX outside: YES orientationStack: 2 stackNo: 0 restore: NO addition: YES]; })};
                    cases[[NSString stringWithFormat: @"fill/rgb/%@/over", name]] = @{
                        @"addition": fillImage( YES, ^(DCMPix *p) {
                            [p fillROI: roi newVal: 300.75f minValue: -FLT_MAX maxValue: FLT_MAX outside: NO orientationStack: 2 stackNo: 0 restore: NO addition: YES]; })};
                }
            }
        }
        cases[@"fill/no-roi"] = @{@"outside": fillImage( NO, ^(DCMPix *p) { [p fillROI: nil : 5 : -FLT_MAX : FLT_MAX : YES : 2 : 0]; }),
                                  @"inside": fillImage( NO, ^(DCMPix *p) { [p fillROI: nil : 5 : -FLT_MAX : FLT_MAX : NO : 2 : 0]; }),
                                  @"rgb-outside": fillImage( YES, ^(DCMPix *p) { [p fillROI: nil : 5 : -FLT_MAX : FLT_MAX : YES : 2 : 0]; })};

        // Fills across a volume: the three orientations, the restore cache, refused stacks.
        double sagittal[] = { 2, 3, 15, 1, 18, 12, 9, 14, 3, 10};
        double coronal[] = { 3, 2, 20, 4, 22, 13, 12, 15, -4, 9};
        double axial[] = { 2, 2, 21, 4, 19, 18, 6, 15};
        NSDictionary *planes = @{@"0": makeROI( tCPolygon, sagittal, 5), @"1": makeROI( tCPolygon, coronal, 5), @"2": makeROI( tCPolygon, axial, 4)};
        for( NSString *orientation in @[@"0", @"1", @"2"])
        {
            ROI *roi = planes[ orientation];
            long o = orientation.integerValue, stack = o == 0 ? 5 : o == 1 ? 7 : 3;
            for( NSString *rgbName in @[@"float", @"rgb"])
            {
                BOOL rgb = [rgbName isEqualToString: @"rgb"];
                float set = rgb ? 90 : 4321.5f;
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"inside"] = fillVolume( rgb, NO, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : NO : o : stack]; });
                d[@"outside"] = fillVolume( rgb, NO, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : YES : o : stack]; });
                d[@"addition"] = fillVolume( rgb, NO, ^(DCMPix *p) {
                    [p fillROI: roi newVal: rgb ? 9 : 2.25f minValue: -FLT_MAX maxValue: FLT_MAX outside: NO orientationStack: o stackNo: stack restore: NO addition: YES]; });
                d[@"clip"] = fillVolume( rgb, NO, ^(DCMPix *p) {
                    [p fillROI: roi newVal: set minValue: -FLT_MAX maxValue: FLT_MAX outside: YES orientationStack: o stackNo: stack restore: NO addition: NO
                         spline: NO clipMin: NSMakePoint( 3, 2) clipMax: NSMakePoint( 14, 11)]; });
                d[@"refused"] = fillVolume( rgb, NO, ^(DCMPix *p) { [p fillROI: roi : set : -FLT_MAX : FLT_MAX : NO : o : 999]; });
                if( !rgb)
                    d[@"restore"] = fillVolume( NO, YES, ^(DCMPix *p) { [p fillROI: roi : 0 : -FLT_MAX : FLT_MAX : NO : o : stack : YES]; });
                else
                    // The Objective-C read the next floats of the original as a
                    // pixel's bytes: the records of that class are not the reference.
                    corrected[[NSString stringWithFormat: @"volume/rgb/%@/restore", orientation]] = restoreRGB( roi, o, stack);
                addCase( [NSString stringWithFormat: @"volume/%@/%@", rgbName, orientation], d);
            }
        }
        for( NSNumber *slice in @[@0, @3])
        {
            ROI *roi = planes[@"2"];
            long z = slice.longValue;
            NSDictionary *five = fillVolume( NO, NO, ^(DCMPix *p) {
                [[[p valueForKey: @"pixArray"] objectAtIndex: z] fillROI: roi : 4321.5f : -FLT_MAX : FLT_MAX : NO]; });
            NSDictionary *seven = fillVolume( NO, NO, ^(DCMPix *p) {
                [[[p valueForKey: @"pixArray"] objectAtIndex: z] fillROI: roi : 4321.5f : -FLT_MAX : FLT_MAX : NO : 2 : z]; });
            corrected[[NSString stringWithFormat: @"volume/five/%ld", z]] = five;
            expect( [five isEqual: seven] && [five[@"changed"] integerValue] > 0,
                    [NSString stringWithFormat: @"slice %ld: the five-argument fill is not the fill of that slice", z]);
        }
        ROI *volumeBrush = makeBrush( 9, 7, 4, 5, 0);
        cases[@"volume/brush"] = @{
            @"restore": fillVolume( NO, YES, ^(DCMPix *p) { [p fillROI: volumeBrush : 0 : -FLT_MAX : FLT_MAX : NO : 2 : 4 : YES]; }),
            @"restore-rgb": fillVolume( YES, YES, ^(DCMPix *p) { [p fillROI: volumeBrush : 0 : -FLT_MAX : FLT_MAX : NO : 2 : 4 : YES]; }),
            @"sagittal": fillVolume( NO, NO, ^(DCMPix *p) { [p fillROI: volumeBrush : 1 : -FLT_MAX : FLT_MAX : NO : 0 : 4]; })};
        DCMPix *empty = volume( NO);
        [empty probeSetSize: kVW : kVH fImage: empty.fImage rgb: NO slices: @[]];
        expect( [empty prepareRestore] == NO, @"a DCMPix without slices prepared a restore cache");

        // Hand-worked expectations.
        expect( [cases[@"float/rectangle"][@"values"][@"count"] longValue] > 0, @"the rectangle has no pixels");
        expect( [cases[@"float/polygon-outside"][@"values"][@"count"] longValue] == 0, @"a polygon outside the image has pixels");
        expect( [cases[@"float/point"][@"values"][@"count"] longValue] == 1, @"a point is not one pixel");
        expect( [cases[@"float/point-outside"][@"values"][@"first"] isEqual: F( 0)], @"a point outside the image is not zero");
        expect( [cases[@"float/brush"][@"calcium"][ 0] intValue] >= 1, @"a brush has no calcium cofactor");
        expect( [cases[@"float/oval"][@"calcium"][ 0] intValue] == 0, @"an oval has a calcium cofactor");
        expect( [[cases[@"float/oval"][@"inside"] substringWithRange: NSMakeRange( 0, 1)] isEqual: @"0"], @"a corner is inside the oval");
        expect( [cases[@"fill/no-roi"][@"inside"][@"changed"] isEqual: @"0"], @"an inside fill without a ROI changed pixels");
        expect( [cases[@"fill/no-roi"][@"outside"][@"changed"] integerValue] == gSide * gSide, @"an outside fill without a ROI left pixels");
        expect( [cases[@"fill/float/polygon-outside"][@"inside"][@"changed"] isEqual: @"0"], @"a fill of a polygon outside the image changed pixels");
        expect( [corrected[@"fill/float/rectangle/five"][@"changed"] integerValue] == [cases[@"float/rectangle"][@"values"][@"count"] integerValue],
                @"the rectangle's five-argument fill and its pixels differ in number");
        expect( [cases[@"fill/float/rectangle"][@"inside"][@"changed"] integerValue] == [cases[@"float/rectangle"][@"values"][@"count"] integerValue],
                @"the rectangle's fill and its pixels differ in number");
        expect( ![cases[@"float/rectangle"][@"statistics"][@"moments"][ 5] isEqual: F( 0)], @"the skewness was not computed");
        expect( [cases[@"volume/float/2"][@"refused"][@"changed"] isEqual: @"0"], @"a refused stack was filled");
        expect( [cases[@"volume/float/0"][@"restore"][@"changed"] integerValue] > 0, @"the sagittal restore restored nothing");
        expect( [cases[@"volume/brush"][@"restore"][@"changed"] integerValue] > 0, @"the brush restore restored nothing");

        NSData *json = [NSJSONSerialization dataWithJSONObject: @{@"cases": cases, @"uncompared": uncompared, @"corrected": corrected,
                                                                   @"expectations": expectations}
                                                       options: NSJSONWritingSortedKeys error: nil];
        printf( "%s\n", [[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] UTF8String]);
    }
    return 0;
}

/// ROI work on 512 x 512 images, timed: per repetition, the measures (pixels and statistics of an oval, a
/// rectangle, a polygon, a pencil and a brush on eight slices), the masks (polygon and RT STRUCT maps) and
/// the fills (inside and outside, a polygon and a brush, on a fresh image each time), in milliseconds.
static NSDictionary *bench( int repetitions)
{
    gSide = 512;
    double polygon[] = { 68, 74, 406, 100, 441, 387, 244, 450, 98, 324};
    double pencil[] = { 160, 160, 196, 146, 240, 168, 270, 220, 252, 272, 200, 290, 156, 254, 138, 204};
    NSArray *rois = @[makeRect( tOval, NSMakeRect( 256, 250, 150, 110)), makeRect( tROI, NSMakeRect( 40, 60, 300, 200)),
                      makeROI( tCPolygon, polygon, 5), makeROI( tPencil, pencil, 8), makeBrush( 300, 260, 100, 120, 0)];
    NSMutableArray *pixes = [NSMutableArray array];
    for( int slice = 0; slice < 8; slice++) [pixes addObject: image( NO)];
    DCMPix *target = image( NO);
    float *original = malloc( 512 * 512 * sizeof( float));
    memcpy( original, target.fImage, 512 * 512 * sizeof( float));
    NSMutableArray *measure = [NSMutableArray array], *masks = [NSMutableArray array], *fills = [NSMutableArray array];
    for( int repetition = 0; repetition < repetitions; repetition++)
    {
        NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
        for( DCMPix *pix in pixes)
            for( ROI *roi in rois)
            {
                float mean, total, dev, min, max;
                [pix computeROI: roi :&mean :&total :&dev :&min :&max];
                long count;
                float *locations = NULL;
                free( [pix getROIValue: &count :roi :&locations]);
                free( locations);
            }
        [measure addObject: @(([NSProcessInfo processInfo].systemUptime - start) * 1000)];

        start = [NSProcessInfo processInfo].systemUptime;
        for( int i = 0; i < 8; i++)
            for( ROI *roi in @[rois[ 2], rois[ 3]])
            {
                NSSize size; NSPoint origin;
                free( [DCMPix getMapFromPolygonROI: roi size: &size origin: &origin]);
                free( [DCMPix getMapFromRTSTRUCTROI: roi width: 512 height: 512 size: &size origin: &origin]);
            }
        [masks addObject: @(([NSProcessInfo processInfo].systemUptime - start) * 1000)];

        start = [NSProcessInfo processInfo].systemUptime;
        for( int i = 0; i < 4; i++)
            for( ROI *roi in @[rois[ 0], rois[ 2], rois[ 4]])
                for( NSNumber *outside in @[@NO, @YES])
                {
                    memcpy( target.fImage, original, 512 * 512 * sizeof( float));
                    [target fillROI: roi : -1000 : -FLT_MAX : FLT_MAX : outside.boolValue : 2 : 0];
                }
        [fills addObject: @(([NSProcessInfo processInfo].systemUptime - start) * 1000)];
    }
    free( original);
    return @{@"roi_measure_ms": measure, @"roi_mask_ms": masks, @"roi_fill_ms": fills};
}
'''


def build(revision, folder):
    """The probe linked with the ROI and DCMPix of `revision` (WORKTREE for this checkout)."""
    return roi_harness.build(revision, folder, roi_harness.PRELUDE + PROBE, config=configuration,
                             app_swift=('VRScissorBounds',))


LABELS = ((('reference', reference),) if reference else ()) + (('current', roi_harness.WORKTREE),)
if keep:
    for label, revision in LABELS:
        print(build(revision, keep / label))
    sys.exit(0)

failures = []
outputs = {}
with tempfile.TemporaryDirectory(prefix='horos-roi-rasterization-') as tmp:
    tmp = Path(tmp)
    for label, revision in LABELS:
        try:
            harness = build(revision, tmp / label)
        except LookupError as error:
            print('skipped: %s' % error, file=sys.stderr)
            sys.exit(SKIPPED)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            print(f'FAIL: the {label} harness ({revision}) did not build: {str(error)[-4000:]}')
            sys.exit(1)
        result = subprocess.run([str(harness)], capture_output=True, text=True, timeout=600)
        if result.returncode:
            print(f'FAIL: the {label} probe ended with {result.returncode}: {result.stderr[-3000:]}')
            sys.exit(1)
        outputs[label] = json.loads(result.stdout)
        for failure in outputs[label]['expectations']:
            failures.append(f'{label}: {failure}')

if not reference:
    try:
        outputs['reference'] = roi_harness.golden(GOLDEN, configuration)
    except LookupError as error:
        print(f'FAIL: {error}')
        sys.exit(1)
# What the Objective-C got wrong ("case" or "case/field" in the probe's
# corrected entries) is checked by the probe's expectations instead.
for key in outputs['current']['corrected']:
    case, _, field = key.rpartition('/')
    outputs['reference']['cases'].pop(key, None)
    if isinstance(outputs['reference']['cases'].get(case), dict):
        outputs['reference']['cases'][case].pop(field, None)
for problem in roi_harness.diff(outputs['reference']['cases'], outputs['current']['cases']):
    failures.append('differs from the reference: ' + problem)
# This checkout converts an out-of-range float to a byte as the Release build of the
# Objective-C did; a Release reference must agree on those too.
if configuration == 'Release':
    # What the Objective-C got wrong is checked by the probe's expectations instead.
    kept = {key: value for key, value in outputs['reference']['uncompared'].items() if key not in outputs['current']['corrected']}
    for problem in roi_harness.diff(kept, outputs['current']['uncompared']):
        failures.append('differs from the Release reference: ' + problem)

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
if roi_harness.recording_golden():
    roi_harness.golden(GOLDEN, configuration, {key: outputs['current'][key] for key in ('cases', 'uncompared')})
print(f'PASS: {len(outputs["current"]["cases"])} ROI cases (values, locations, point tests, statistics, masks, '
      f'line profiles, fills on slices and volumes) identical to {reference[:12] if reference else 'the records of the last Objective-C class'} in {configuration}'
      + (', out-of-range bytes included' if configuration == 'Release' else ''))
