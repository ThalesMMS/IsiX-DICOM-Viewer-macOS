#!/usr/bin/env python3
"""A ROI measures, reports and archives what it did before its arithmetic and
its file format left ROI.m and DCMPix.m.

The geometry of a ROI's points (lengths, angles, areas, perimeters,
centroids), the statistics of the pixels inside it (mean, deviation, minimum,
maximum, sum, skewness, kurtosis, median) and the archive that .roi files, the
pasteboard and ROI SRs carry are pinned here for every kind of ROI: length,
arrow, oval, rectangle, angle, dynamic angle, open and closed polygons,
pencil, brush, layer, text, point, axis, TAGT and the patient-space length.

Two harnesses are built the same way, from the application's own objects (see
tests/roi_harness.py): an Objective-C ROI.m and DCMPix.m compiled with the
command the Debug build logged for the app's Objective-C, a Swift ROI linked as
the build's own objects, with MyPoint and the Swift they call. One is the
revision before the extraction, read from git; the other is this checkout. Both
run the same probe, and every number they print must be the same, bit for bit
(floats are printed in hexadecimal). Archives written by each are compared
byte for byte and read back by the other; when ../DICOM_Example holds ROI
archives of earlier Horos versions (SRs, .roi files), both must read them to
the same ROIs.

On a tree that has not been changed yet the reference is the tree itself, and
the probe's own expectations - areas, lengths and statistics worked out by hand
on the synthetic shapes - still have to hold. `<git revision>` as an argument
compares with that revision instead.

Needs a Debug build of this checkout whose compile commands are logged;
without it the test is skipped. HOROS_TEST_CONFIGURATION=Release uses the
Release build's commands and objects.

`--harnesses DIR [revision]` only builds the two harnesses into DIR/reference
and DIR/current, for a timing campaign with tools/ab_protocol.py: `harness
bench N` prints, as JSON, N timings in milliseconds of the ROI statistics of a
synthetic series (eight 512 x 512 slices, five ROIs each), without and with
skewness and kurtosis.
"""
from pathlib import Path
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import roi_harness  # noqa: E402

SKIPPED = roi_harness.SKIPPED
root = roi_harness.ROOT
ROI_SOURCE = roi_harness.ROI_SOURCE
# The text whose arrival in ROI.m marks the extraction: the revision before it is the reference.
EXTRACTION_MARK = '#import "IsiXROI-Swift.h"'

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

# `--harnesses DIR` only builds the two harnesses into DIR, for a timing campaign:
# `harness bench N` prints the ROI statistics times of a synthetic series.
arguments = sys.argv[1:]
keep = None
if arguments[:1] == ['--harnesses']:
    keep, arguments = Path(arguments[1]), arguments[2:]
if arguments:
    reference = arguments[0]
else:
    reference = history_reference.before_text_added(ROI_SOURCE, EXTRACTION_MARK) or 'HEAD'

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import "ROI.h"
#import "DCMPix.h"
#import "MyPoint.h"
// PIX_IVARS

// Methods ROI.m defines without declaring them in ROI.h.
@interface ROI (Characterization)
- (float) EllipseArea;
- (float) plainArea;
- (float) Area;
- (float) Magnitude:(NSPoint) a :(NSPoint) b;
- (int) DistancePointLine:(NSPoint) p :(NSPoint) a :(NSPoint) b :(float*) distance;
- (double) angleBetween2Lines:(NSPoint) a1 :(NSPoint) a2 :(NSPoint) b1 :(NSPoint) b2;
- (float) MesureLength:(float*) pixels pointA:(NSPoint) a pointB:(NSPoint) b;
+ (float) lengthBetween:(NSPoint) a and:(NSPoint) b;
+ (NSPoint) segmentDistToPoint:(NSPoint) a :(NSPoint) b :(NSPoint) p;
+ (NSPoint) positionAtDistance:(float) distance inPolygon:(NSArray*) points;
@end

static int kSide = 64;    // the bench measures on larger images

@interface ProbePix : DCMPix
@end
@implementation ProbePix
- (void) CheckLoad {}
- (void) applyShutter {}
- (BOOL) thickSlabVRActivated { return NO; }
- (float*) computefImageForMeasurement { return PIX_IVAR( self, float*, fImage); }
- (BOOL) hasUSRegions { return NO; }
+ (ProbePix*) pixWithSpacing:(double) spacing
{
    ProbePix *pix = [[[ProbePix alloc] init] autorelease];
    PIX_IVAR( pix, long, width) = PIX_IVAR( pix, long, height) = kSide; PIX_IVAR( pix, BOOL, isRGB) = NO;
    float *fImage = PIX_IVAR( pix, float*, fImage) = (float*) calloc( kSide * kSide, sizeof( float));
    PIX_IVAR( pix, NSArray*, pixArray) = [[NSArray arrayWithObject: [NSNull null]] retain];
    PIX_IVAR( pix, double, pixelSpacingX) = spacing; PIX_IVAR( pix, double, pixelSpacingY) = spacing * 1.25;
    PIX_IVAR( pix, double, pixelRatio) = 1.25;
    PIX_IVAR( pix, double, sliceThickness) = 2.5; PIX_IVAR( pix, double, sliceInterval) = 2.0;
    PIX_IVAR( pix, double, originX) = -30.5; PIX_IVAR( pix, double, originY) = 12.25; PIX_IVAR( pix, double, originZ) = 7;
    double orientation[ 9] = { 1, 0, 0, 0, 1, 0, 0, 0, 1};
    for( int i = 0; i < 9; i++) PIX_ORIENTATION( pix)[ i] = orientation[ i];
    PIX_IVAR( pix, NSString*, frameofReferenceUID) = [@"1.2.826.0.1.3680043.2.1125.1" retain];
    PIX_IVAR( pix, NSString*, rescaleType) = [@"HU" retain];
    // Not flat, with negative values and a few far ones: every statistic moves.
    for( int y = 0; y < kSide; y++)
        for( int x = 0; x < kSide; x++)
            fImage[ y * kSide + x] = (float)( x * 3.25 - y * 7.5) + ((x / 8 + y / 8) % 2 ? 1200.75f : -17.125f) + (x == 33 && y == 30 ? 3.0e4f : 0);
    return pix;
}
@end

static NSString *F( double v) { return [NSString stringWithFormat: @"%a", v]; }
static NSString *P( NSPoint p) { return [NSString stringWithFormat: @"%a,%a", p.x, p.y]; }

static NSArray *pointsOf( NSArray *points)
{
    NSMutableArray *a = [NSMutableArray array];
    for( MyPoint *p in points) [a addObject: P( p.point)];
    return a;
}

static NSMutableArray *myPoints( double *xy, int count)
{
    NSMutableArray *a = [NSMutableArray array];
    for( int i = 0; i < count; i++) [a addObject: [MyPoint point: NSMakePoint( xy[ 2*i], xy[ 2*i+1])]];
    return a;
}

/// Every value a ROI's archive holds, read back through the ROI.
static NSDictionary *stateOf( ROI *roi)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = NSStringFromClass( [roi class]);
    d[@"type"] = @(roi.type);
    d[@"name"] = roi.name ?: @"<nil>";
    d[@"comments"] = roi.comments ?: @"<nil>";
    d[@"points"] = pointsOf( [roi valueForKey: @"points"]);
    d[@"rect"] = NSStringFromRect( roi.rect);
    d[@"thickness"] = F( roi.thickness);
    d[@"opacity"] = F( roi.opacity);
    RGBColor c = roi.rgbcolor;
    d[@"color"] = [NSString stringWithFormat: @"%d,%d,%d", c.red, c.green, c.blue];
    d[@"spacing"] = [NSString stringWithFormat: @"%@,%@", F( roi.pixelSpacingX), F( roi.pixelSpacingY)];
    d[@"origin"] = P( roi.imageOrigin);
    NSMutableArray *z = [NSMutableArray array];
    for( NSNumber *n in roi.zPositions) [z addObject: n.stringValue];
    d[@"zPositions"] = z;
    for( NSString *key in @[@"fill", @"needQuartz", @"offsetTextBox_x", @"offsetTextBox_y", @"groupID", @"calciumThreshold",
                            @"displayCalciumScoring", @"isLayerOpacityConstant", @"canColorizeLayer", @"displayTextualData",
                            @"canResizeLayer", @"selectable", @"locked", @"isAliased", @"_isSpline", @"_hasIsSpline",
                            @"textNameOnly", @"hidden"])
        d[key] = [[roi valueForKey: key] description];
    d[@"textualBoxLines"] = @[roi.textualBoxLine1 ?: @"<nil>", roi.textualBoxLine2 ?: @"<nil>", roi.textualBoxLine3 ?: @"<nil>",
                              roi.textualBoxLine4 ?: @"<nil>", roi.textualBoxLine5 ?: @"<nil>"];
    if( roi.type == tPlain)
    {
        d[@"texture"] = [NSString stringWithFormat: @"%d x %d at %d,%d to %d,%d", roi.textureWidth, roi.textureHeight,
                         roi.textureUpLeftCornerX, roi.textureUpLeftCornerY, roi.textureDownRightCornerX, roi.textureDownRightCornerY];
        NSData *bytes = [NSData dataWithBytes: roi.textureBuffer length: roi.textureWidth * roi.textureHeight];
        d[@"textureBytes"] = [bytes base64EncodedStringWithOptions: 0];
    }
    NSColor *layerColor = [roi valueForKey: @"layerColor"];
    d[@"layerColor"] = layerColor ? [NSString stringWithFormat: @"%@ %@", layerColor.colorSpaceName, layerColor] : @"<nil>";
    NSData *layer = [roi valueForKey: @"layerImageJPEG"];
    d[@"layerImage"] = layer ? [layer base64EncodedStringWithOptions: 0] : @"<nil>";
    if( [roi isKindOfClass: [HorosVolumeLengthROI class]])
        d[@"volumeLength"] = [(HorosVolumeLengthROI*) roi volumeLength].description;
    return d;
}

/// The numbers of -dataString, as the ROI manager and exports read them.
static NSDictionary *exported( ROI *roi)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSDictionary *data = [roi dataString];
    for( NSString *key in data)
    {
        id value = data[ key];
        d[ key] = [value isKindOfClass: [NSNumber class]] ? F( [value doubleValue]) : [value description];
    }
    return d;
}

static ROI *makeROI( ToolMode type, double *xy, int count, double spacing)
{
    ROI *roi = [[[ROI alloc] initWithType: type : spacing : spacing * 1.25 : NSMakePoint( -30.5, 12.25)] autorelease];
    roi.name = [NSString stringWithFormat: @"Kind %d é", type];
    roi.comments = @"synthetic";
    if( count) [roi setPoints: myPoints( xy, count)];
    return roi;
}

static NSMutableDictionary *cases;
static NSMutableArray *expectations;
static void expect( BOOL ok, NSString *what) { if( !ok) [expectations addObject: what]; }

/// What a ROI of any kind measures and reports.
static NSMutableDictionary *measure( ROI *roi, ProbePix *pix)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    roi.pix = pix;
    NSArray *pts = [roi valueForKey: @"points"];
    d[@"points"] = pointsOf( roi.points);
    d[@"splinePoints"] = pointsOf( [roi splinePoints]);
    d[@"Area"] = F( [roi Area]);
    d[@"EllipseArea"] = F( [roi EllipseArea]);
    d[@"plainArea"] = F( [roi plainArea]);
    d[@"roiArea"] = F( [roi roiArea]);
    d[@"centroid"] = P( [roi centroid]);
    if( pts.count >= 2)
    {
        NSPoint a = [pts[0] point], b = [pts[1] point];
        float pixels = -1;
        d[@"MesureLength"] = F( [roi MesureLength: &pixels pointA: a pointB: b]);
        d[@"MesureLengthPixels"] = F( pixels);
        d[@"Length"] = F( [roi Length: a : b]);
        d[@"LengthInPixel"] = F( [roi LengthFrom: a to: b inPixel: YES]);
        d[@"Magnitude"] = F( [roi Magnitude: a : b]);
        d[@"Projection"] = P( [roi ProjectionPointLine: NSMakePoint( 20.25, 31.5) : a : b]);
        float distance = -1;
        int on = [roi DistancePointLine: NSMakePoint( (a.x + b.x) / 2 + 1.5, (a.y + b.y) / 2 - 2.25) : a : b : &distance];
        d[@"DistancePointLine"] = [NSString stringWithFormat: @"%d %@", on, F( distance)];
        on = [roi DistancePointLine: NSMakePoint( b.x + 40, b.y + 40) : a : b : &distance];
        d[@"DistancePointLineOutside"] = [NSString stringWithFormat: @"%d %@", on, F( distance)];
    }
    if( pts.count >= 3)
        d[@"Angle"] = F( [roi Angle: [pts[0] point] : [pts[1] point] : [pts[2] point]]);
    if( pts.count >= 4)
        d[@"angleBetween2Lines"] = F( [roi angleBetween2Lines: [pts[0] point] : [pts[1] point] : [pts[2] point] : [pts[3] point]]);
    d[@"dataString"] = exported( roi);
    // The statistics the label, the ROI manager and the exports show, from the shipped DCMPix.
    float mean = -1, total = -1, dev = -1, min = -1, max = -1, skewness = -1, kurtosis = -1;
    roi.median = -12345;
    [pix computeROI: roi :&mean :&total :&dev :&min :&max :&skewness :&kurtosis];
    d[@"statistics"] = @[F( mean), F( total), F( dev), F( min), F( max), F( skewness), F( kurtosis), F( roi.median)];
    float mean2 = -1, total2 = -1, dev2 = -1, min2 = -1, max2 = -1;
    [pix computeROI: roi :&mean2 :&total2 :&dev2 :&min2 :&max2];
    d[@"statisticsShort"] = @[F( mean2), F( total2), F( dev2), F( min2), F( max2)];
    [pix computeROI: roi :&mean2 :NULL :NULL :NULL :NULL];
    d[@"statisticsMeanOnly"] = F( mean2);
    @try
    {
        long count = 0;
        float *values = [roi dataValuesAsFloatPointer: &count];
        double sum = 0; for( long i = 0; i < count; i++) sum += values[ i];
        free( values);
        d[@"samples"] = [NSString stringWithFormat: @"%ld %@", count, F( sum)];
    }
    @catch( NSException *e) { d[@"samples"] = [NSString stringWithFormat: @"<exception %@>", e.name]; }
    // The archive, as .roi files, the pasteboard and SRs carry it.
    NSData *archive = [roi data];
    d[@"archive"] = [archive base64EncodedStringWithOptions: 0];
    ROI *back = [NSUnarchiver unarchiveObjectWithData: archive];
    d[@"state"] = stateOf( roi);
    d[@"readBack"] = back ? stateOf( back) : @"<refused>";
    return d;
}

static void addCase( NSString *label, ROI *roi, ProbePix *pix)
{
    cases[ label] = measure( roi, pix);
}

static void writeArchives( NSString *folder)
{
    for( NSString *label in cases)
    {
        NSString *b64 = cases[ label][@"archive"];
        if( b64 == nil) continue;
        [[[[NSData alloc] initWithBase64EncodedString: b64 options: 0] autorelease] writeToFile: [folder stringByAppendingPathComponent: label] atomically: YES];
    }
}

static id decodeAll( id object)
{
    if( [object isKindOfClass: [ROI class]]) return stateOf( object);
    if( [object isKindOfClass: [NSArray class]])
    {
        NSMutableArray *a = [NSMutableArray array];
        for( id o in object) [a addObject: decodeAll( o) ?: @"<nil>"];
        return a;
    }
    return object ? NSStringFromClass( [object class]) : @"<nil>";
}

/// Every archive in `folder`, as this revision reads it.
static NSDictionary *readArchives( NSString *folder)
{
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    for( NSString *name in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath: folder error: nil] sortedArrayUsingSelector: @selector(compare:)])
    {
        NSData *data = [NSData dataWithContentsOfFile: [folder stringByAppendingPathComponent: name]];
        id object = nil;
        @try { object = [NSUnarchiver unarchiveObjectWithData: data]; }
        @catch( NSException *e) { object = [NSString stringWithFormat: @"<exception %@>", e.name]; }
        read[ name] = [object isKindOfClass: [NSString class]] ? object : decodeAll( object);
    }
    return read;
}

/// The ROI statistics of a synthetic series, timed: eight 512 x 512 slices,
/// each with an oval, a rectangle, a closed polygon, a pencil and a brush, as
/// the label and the ROI manager ask for them. One time per repetition, in
/// milliseconds, without and with skewness and kurtosis.
static NSDictionary *bench( int repetitions)
{
    kSide = 512;
    double polygon[] = { 68, 74, 406, 100, 441, 387, 244, 450, 98, 324};
    double pencil[] = { 160, 160, 196, 146, 240, 168, 270, 220, 252, 272, 200, 290, 156, 254, 138, 204};
    NSMutableArray *pixes = [NSMutableArray array], *rois = [NSMutableArray array];
    for( int slice = 0; slice < 8; slice++)
    {
        ProbePix *pix = [ProbePix pixWithSpacing: 0.5];
        float *pixels = pix.fImage; for( long i = 0; i < (long) kSide * kSide; i++) pixels[ i] += slice * 13.5f;
        NSMutableArray *slab = [NSMutableArray array];
        ROI *oval = makeROI( tOval, NULL, 0, 0.5); oval.rect = NSMakeRect( 256, 250, 150, 110); [slab addObject: oval];
        ROI *rectangle = makeROI( tROI, NULL, 0, 0.5); rectangle.rect = NSMakeRect( 40, 60, 300, 200); [slab addObject: rectangle];
        [slab addObject: makeROI( tCPolygon, polygon, 5, 0.5)];
        [slab addObject: makeROI( tPencil, pencil, 8, 0.5)];
        int w = 300, h = 260;
        unsigned char *mask = calloc( w * h, 1);
        for( int y = 0; y < h; y++) for( int x = 0; x < w; x++)
            mask[ y * w + x] = (x - 150) * (x - 150) + (y - 130) * (y - 130) <= 120 * 120 ? 255 : 0;
        [slab addObject: [[[ROI alloc] initWithTexture: mask textWidth: w textHeight: h textName: @"Brush" positionX: 100 positionY: 120
                                              spacingX: 0.5 spacingY: 0.625 imageOrigin: NSZeroPoint] autorelease]];
        free( mask);
        for( ROI *roi in slab) roi.pix = pix;
        [pixes addObject: pix];
        [rois addObject: slab];
    }
    NSMutableDictionary *times = [NSMutableDictionary dictionary];
    for( NSNumber *moments in @[@NO, @YES])
    {
        [[NSUserDefaults standardUserDefaults] setBool: moments.boolValue forKey: @"ROIComputeSkewnessAndKurtosis"];
        NSMutableArray *series = [NSMutableArray array];
        float mean, total, dev, min, max, skewness, kurtosis;
        for( int repetition = 0; repetition < repetitions; repetition++)
        {
            NSTimeInterval start = [NSProcessInfo processInfo].systemUptime;
            for( NSUInteger slice = 0; slice < pixes.count; slice++)
                for( ROI *roi in rois[ slice])
                    [pixes[ slice] computeROI: roi :&mean :&total :&dev :&min :&max :&skewness :&kurtosis];
            [series addObject: @(([NSProcessInfo processInfo].systemUptime - start) * 1000)];
        }
        times[ moments.boolValue ? @"series_moments_ms" : @"series_ms"] = series;
    }
    return times;
}

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    [[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"ROIComputeSkewnessAndKurtosis"];
    [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"ROIColorRotation"];
    if( argc > 2 && strcmp( argv[ 1], "bench") == 0)
    {
        NSData *json = [NSJSONSerialization dataWithJSONObject: bench( atoi( argv[ 2])) options: NSJSONWritingSortedKeys error: nil];
        fwrite( json.bytes, 1, json.length, stdout);
        return 0;
    }
    if( argc > 2 && strcmp( argv[ 1], "read") == 0)
    {
        NSData *json = [NSJSONSerialization dataWithJSONObject: readArchives( @(argv[ 2])) options: NSJSONWritingSortedKeys error: nil];
        fwrite( json.bytes, 1, json.length, stdout);
        return 0;
    }
    cases = [NSMutableDictionary dictionary];
    expectations = [NSMutableArray array];
    ProbePix *pix = [ProbePix pixWithSpacing: 0.5];
    ProbePix *uncalibrated = [ProbePix pixWithSpacing: 0];

    double line[] = { 10.25, 12.5, 40.75, 31.125};
    double triangle[] = { 10, 10, 40, 10, 10, 50};                 // legs 30 and 40: area 600 pixels
    double polygon[] = { 8.5, 9.25, 50.75, 12.5, 55.125, 48.375, 30.5, 56.25, 12.25, 40.5};
    double pencil[] = { 20, 20, 24.5, 18.25, 30, 21, 33.75, 27.5, 31.5, 34, 25, 36.25, 19.5, 31.75, 17.25, 25.5};
    double angle[] = { 40.5, 12.25, 20.25, 30.5, 50.75, 45.125};
    double dynAngle[] = { 10, 10, 50, 22.5, 12.5, 40, 46.25, 8.75};
    double axis[] = { 15, 15, 45.5, 17.25, 47.75, 44.5, 13.25, 43};
    double tagt[] = { 10, 20, 50, 20, 10, 40, 50, 40, 30, 20, 30, 40};

    for( NSNumber *spacing in @[@0.5, @0])
    {
        ProbePix *p = spacing.doubleValue ? pix : uncalibrated;
        NSString *suffix = spacing.doubleValue ? @"" : @" uncalibrated";
        addCase( [@"length" stringByAppendingString: suffix], makeROI( tMesure, line, 2, spacing.doubleValue), p);
        addCase( [@"arrow" stringByAppendingString: suffix], makeROI( tArrow, line, 2, spacing.doubleValue), p);
        addCase( [@"triangle" stringByAppendingString: suffix], makeROI( tCPolygon, triangle, 3, spacing.doubleValue), p);
        addCase( [@"closed polygon" stringByAppendingString: suffix], makeROI( tCPolygon, polygon, 5, spacing.doubleValue), p);
        addCase( [@"open polygon" stringByAppendingString: suffix], makeROI( tOPolygon, polygon, 5, spacing.doubleValue), p);
        addCase( [@"pencil" stringByAppendingString: suffix], makeROI( tPencil, pencil, 8, spacing.doubleValue), p);
        addCase( [@"angle" stringByAppendingString: suffix], makeROI( tAngle, angle, 3, spacing.doubleValue), p);
        addCase( [@"dynamic angle" stringByAppendingString: suffix], makeROI( tDynAngle, dynAngle, 4, spacing.doubleValue), p);
        addCase( [@"axis" stringByAppendingString: suffix], makeROI( tAxis, axis, 4, spacing.doubleValue), p);
        addCase( [@"tagt" stringByAppendingString: suffix], makeROI( tTAGT, tagt, 6, spacing.doubleValue), p);

        ROI *oval = makeROI( tOval, NULL, 0, spacing.doubleValue);
        oval.rect = NSMakeRect( 30.5, 28.25, 12.75, 9.5);
        addCase( [@"oval" stringByAppendingString: suffix], oval, p);
        ROI *rectangle = makeROI( tROI, NULL, 0, spacing.doubleValue);
        rectangle.rect = NSMakeRect( 12.5, 14.25, 20.75, 30.5);
        addCase( [@"rectangle" stringByAppendingString: suffix], rectangle, p);
        ROI *point = makeROI( t2DPoint, NULL, 0, spacing.doubleValue);
        point.rect = NSMakeRect( 21.25, 33.5, 0, 0);
        addCase( [@"point" stringByAppendingString: suffix], point, p);
        ROI *text = makeROI( tText, NULL, 0, spacing.doubleValue);
        text.rect = NSMakeRect( 18, 22.5, 30, 12);
        addCase( [@"text" stringByAppendingString: suffix], text, p);

        // A brush: a disc and a separate square, 21 x 17 at 9,11.
        int w = 21, h = 17;
        unsigned char *mask = calloc( w * h, 1);
        for( int y = 0; y < h; y++) for( int x = 0; x < w; x++)
            mask[ y * w + x] = ((x - 7) * (x - 7) + (y - 8) * (y - 8) <= 36) || (x >= 15 && y >= 3 && y <= 9) ? 255 : 0;
        ROI *brush = [[[ROI alloc] initWithTexture: mask textWidth: w textHeight: h textName: @"Brush é" positionX: 9 positionY: 11
                                          spacingX: spacing.floatValue spacingY: spacing.floatValue * 1.25 imageOrigin: NSMakePoint( -30.5, 12.25)] autorelease];
        free( mask);
        brush.textNameOnly = YES;
        brush.calciumThreshold = 130;
        addCase( [@"brush" stringByAppendingString: suffix], brush, p);
    }

    // A layer, with its image and a colour.
    ROI *layer = [[[ROI alloc] initWithType: tLayerROI : 0.5 : 0.625 : NSZeroPoint] autorelease];
    double corners[] = { 5, 5, 25, 5, 25, 15, 5, 15};
    [layer setPoints: myPoints( corners, 4)];
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: 4 pixelsHigh: 2 bitsPerSample: 8 samplesPerPixel: 4
                                                                       hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 0] autorelease];
    memset( rep.bitmapData, 0x7f, rep.bytesPerRow * 2);
    NSImage *image = [[[NSImage alloc] initWithSize: NSMakeSize( 4, 2)] autorelease];
    [image addRepresentation: rep];
    layer.layerImage = image;
    layer.canColorizeLayer = YES;
    [layer setValue: [NSColor colorWithCalibratedRed: 0.25 green: 0.5 blue: 0.75 alpha: 1] forKey: @"layerColor"];
    layer.textualBoxLine2 = @"second line";
    addCase( @"layer", layer, pix);

    // The patient-space length.
    HorosVolumeLengthROI *volume = [[[HorosVolumeLengthROI alloc] initWithType: tMesure : 0.5 : 0.625 : NSZeroPoint] autorelease];
    volume.volumeLength = @{@"version": @1, @"id": @"V1", @"series": @"1.2.3", @"frameOfReference": @"1.2.826.0.1.3680043.2.1125.1",
                            @"a": @[@0.25, @-3.5, @0], @"b": @[@3.75, @4, @12.5], @"temporalIndex": @0};
    addCase( @"patient-space length", volume, pix);
    NSMutableDictionary *v = cases[ @"patient-space length"];
    v[@"distanceMM"] = F( volume.distanceMM);
    v[@"validGeometry"] = @([HorosVolumeLengthROI validGeometry: pix]);
    v[@"patientPoint"] = [[HorosVolumeLengthROI patientPoint: NSMakePoint( 12.25, -3.5) pix: pix] description];
    double depth = 0;
    NSPoint projected = [HorosVolumeLengthROI projectPoint: @[@1.5, @-2.25, @9.75] pix: pix depth: &depth];
    v[@"projectPoint"] = [NSString stringWithFormat: @"%@ %@", P( projected), F( depth)];
    v[@"validPayload"] = @[@([HorosVolumeLengthROI validPayload: volume.volumeLength]),
                           @([HorosVolumeLengthROI validPayload: @{@"version": @2}]),
                           @([HorosVolumeLengthROI validPayload: @{@"version": @1, @"id": @"V", @"series": @"S", @"frameOfReference": @"F",
                                                                 @"a": @[@1, @2, @3], @"b": @[@1, @2, @3]}])];

    // The class geometry the ROI tools and the interpolation call.
    NSArray *outline = myPoints( polygon, 5);
    NSMutableDictionary *helpers = [NSMutableDictionary dictionary];
    helpers[@"lengthBetween"] = F( [ROI lengthBetween: NSMakePoint( 1.25, 2.5) and: NSMakePoint( 30.75, 41.125)]);
    helpers[@"pointBetween"] = P( [ROI pointBetweenPoint: NSMakePoint( 1.25, 2.5) and: NSMakePoint( 30.75, 41.125) ratio: 0.3]);
    helpers[@"segmentDistToPoint"] = P( [ROI segmentDistToPoint: NSMakePoint( 1.25, 2.5) : NSMakePoint( 30.75, 41.125) : NSMakePoint( 20, 3)]);
    NSMutableArray *positions = [NSMutableArray array];
    for( NSNumber *distance in @[@0, @10.5, @77.25, @150, @400])
        [positions addObject: P( [ROI positionAtDistance: distance.floatValue inPolygon: outline])];
    helpers[@"positionAtDistance"] = positions;
    helpers[@"resamplePoints"] = pointsOf( [ROI resamplePoints: outline number: 23]);
    helpers[@"resamplePointsReversed"] = pointsOf( [ROI resamplePoints: [[outline reverseObjectEnumerator] allObjects] number: 16]);
    cases[@"class geometry"] = helpers;

    // Worked out by hand on the synthetic shapes.
    expect( [cases[@"triangle uncalibrated"][@"Area"] isEqual: F( 600)], @"a 30-40 right triangle has an area of 600 pixels");
    expect( [cases[@"triangle"][@"roiArea"] isEqual: F( (float)(600 * 0.5 * 0.625 / 100.))], @"its calibrated area is 600 x 0.5 x 0.625 / 100 cm2");
    expect( [cases[@"triangle uncalibrated"][@"dataString"][@"Length"] isEqual: F( 120)], @"its perimeter is 30 + 40 + 50 pixels");
    expect( [cases[@"rectangle"][@"dataString"][@"AreaCM2"] isEqual: F( (float)(20.75 * 0.5 * 30.5 * 0.625 / 100.))], @"a rectangle's area");
    expect( [cases[@"oval uncalibrated"][@"dataString"][@"AreaPIX2"] isEqual: F( (float)(M_PI * 12.75 * 9.5))], @"an oval's area is pi a b");
    expect( [cases[@"angle uncalibrated"][@"Angle"] isEqual: F( (float)(acos( ((40.5-20.25)*(50.75-20.25) + (12.25-30.5)*(45.125-30.5)) /
            (hypot( 40.5-20.25, 12.25-30.5) * hypot( 50.75-20.25, 45.125-30.5))) * 180 / M_PI))] ||
            fabs( strtod( [cases[@"angle uncalibrated"][@"Angle"] UTF8String], NULL) - 81.3755) < 0.001, @"an angle's degrees");
    expect( [cases[@"length uncalibrated"][@"Length"] isEqual: F( (float) hypot( 30.5, 18.625))], @"a length in pixels");
    expect( [cases[@"patient-space length"][@"distanceMM"] isEqual: F( sqrt( 3.5*3.5 + 7.5*7.5 + 12.5*12.5))], @"a patient-space length");
    long painted = 0;
    for( int y = 0; y < 17; y++) for( int x = 0; x < 21; x++) painted += ((x - 7) * (x - 7) + (y - 8) * (y - 8) <= 36) || (x >= 15 && y >= 3 && y <= 9);
    expect( [cases[@"brush uncalibrated"][@"plainArea"] isEqual: F( painted)], @"a brush's area is its painted pixels");
    NSArray *s = cases[@"rectangle"][@"statistics"];
    expect( [s[0] isEqual: s[0]] && ![s[0] isEqual: F( -1)] && ![s[2] isEqual: F( -1)] && ![s[7] isEqual: F( -12345)], @"statistics were taken");
    for( NSString *label in cases)
    {
        id back = cases[ label][@"readBack"];
        if( back == nil) continue;
        NSMutableDictionary *a = [[cases[ label][@"state"] mutableCopy] autorelease], *b = [[back mutableCopy] autorelease];
        // A patient-space length is read back as an alias of every image it crosses.
        if( [a[@"class"] isEqual: @"HorosVolumeLengthROI"]) expect( [b[@"isAliased"] isEqual: @"1"], @"a patient-space length reads back aliased");
        [a removeObjectForKey: @"isAliased"]; [b removeObjectForKey: @"isAliased"];
        expect( [a isEqual: b], [NSString stringWithFormat: @"%@ reads back from its own archive as it was", label]);
    }

    if( argc > 2 && strcmp( argv[ 1], "write") == 0) writeArchives( @(argv[ 2]));
    NSData *json = [NSJSONSerialization dataWithJSONObject: @{@"cases": cases, @"expectations": expectations} options: NSJSONWritingSortedKeys error: nil];
    fwrite( json.bytes, 1, json.length, stdout);
    return 0;
}}
'''

def build(revision, folder):
    """The probe linked with the ROI and DCMPix.m of `revision` (WORKTREE for this checkout)."""
    statistics = 'Horos/Sources/ROIStatistics.swift'
    extra_swift, pix_flags = [], []
    # A revision whose DCMPix.m asks the app's HorosROIStatistics for the median,
    # built where this checkout's build no longer has it.
    if revision != roi_harness.WORKTREE and statistics in roi_harness.git_files(revision, statistics) \
            and not (root / statistics).is_file():
        folder.mkdir(parents=True)
        extra_swift = [roi_harness.object_probe.revision_source(statistics, revision, folder / 'swift' / 'ROIStatistics.swift')]
        (folder / 'median.h').write_text('#import <Foundation/Foundation.h>\n'
                                         '@interface HorosROIStatistics : NSObject\n'
                                         '+ (double)medianOfValues:(const float *)values count:(NSInteger)count;\n@end\n')
        pix_flags = ['-include', str(folder / 'median.h')]
        folder = folder / 'harness'
    return roi_harness.build(revision, folder, PROBE.replace('// PIX_IVARS\n', roi_harness.PIX_IVARS), config=configuration,
                             pix_flags=pix_flags, extra_swift=extra_swift)


def example_archives(directory):
    """ROI archives of earlier Horos versions in ../DICOM_Example: raw .roi
    typedstreams and the (0042,0011) values of SRs holding one."""
    common = subprocess.run(['git', '-C', str(root), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                            capture_output=True, text=True).stdout.strip()
    candidates = [root.parent / 'DICOM_Example']
    if common:
        candidates.append(Path(common).parent.parent / 'DICOM_Example')
    selected = os.environ.get('HOROS_TEST_ROI_EXAMPLES')
    examples = Path(selected) if selected else next((c for c in candidates if c.is_dir()), None)
    if examples is None:
        return 0
    found = subprocess.run(['grep', '-r', '-l', '-a', '--null', '--', 'streamtyped', str(examples)], capture_output=True)
    count = 0
    for path in filter(None, found.stdout.split(b'\0')):
        data = Path(os.fsdecode(path)).read_bytes()
        if data.startswith(b'\x04\x0bstreamtyped'):
            value = data
        else:
            at = data.find(b'\x42\x00\x11\x00OB\x00\x00')
            if at < 0:
                continue
            length = struct.unpack('<I', data[at + 8:at + 12])[0]
            value = data[at + 12:at + 12 + length]
            if not value.startswith(b'\x04\x0bstreamtyped'):
                continue
        (directory / ('example-%04d' % count)).write_bytes(value)
        count += 1
    return count


diff = roi_harness.diff


if keep:
    for label, revision in (('reference', reference), ('current', roi_harness.WORKTREE)):
        print(build(revision, keep / label))
    sys.exit(0)

failures = []
with tempfile.TemporaryDirectory(prefix='horos-roi-characterization-') as tmp:
    tmp = Path(tmp)
    harnesses = {}
    for label, revision in (('reference', reference), ('current', roi_harness.WORKTREE)):
        try:
            harnesses[label] = build(revision, tmp / label)
        except LookupError as error:
            print('skipped: %s' % error, file=sys.stderr)
            sys.exit(SKIPPED)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            detail = error.stderr.decode(errors='replace')[-4000:] if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
            print(f'FAIL: the {label} harness ({revision}) did not build: {detail}')
            sys.exit(1)

    outputs = {}
    for label, harness in harnesses.items():
        archives = tmp / f'{label}-archives'
        archives.mkdir()
        result = subprocess.run([str(harness), 'write', str(archives)], capture_output=True, text=True, timeout=600)
        if result.returncode:
            print(f'FAIL: the {label} probe ended with {result.returncode}: {result.stderr[-3000:]}')
            sys.exit(1)
        outputs[label] = json.loads(result.stdout)
        for failure in outputs[label]['expectations']:
            failures.append(f'{label}: {failure}')

    reference_cases, current_cases = outputs['reference']['cases'], outputs['current']['cases']
    for problem in diff(reference_cases, current_cases):
        failures.append('differs from the reference: ' + problem)

    # Archives written by each revision, read by the other; earlier versions' archives read by both.
    example_folder = tmp / 'examples'
    example_folder.mkdir()
    examples = example_archives(example_folder)
    reads = {}
    for reader in harnesses:
        for written in ('reference-archives', 'current-archives', 'examples'):
            result = subprocess.run([str(harnesses[reader]), 'read', str(tmp / written)], capture_output=True, text=True, timeout=600)
            if result.returncode:
                failures.append(f'{reader} could not read {written}: {result.stderr[-2000:]}')
                continue
            reads[(reader, written)] = json.loads(result.stdout)
    for written in ('reference-archives', 'current-archives', 'examples'):
        a, b = reads.get(('reference', written)), reads.get(('current', written))
        if a is not None and b is not None:
            for problem in diff(a, b):
                failures.append(f'{written} read differently by the two revisions: {problem}')
    # Each reads the other's archives exactly as their writer reads them back.
    if ('current', 'reference-archives') in reads:
        for name, state in reads[('current', 'reference-archives')].items():
            if state != reference_cases[name]['readBack']:
                failures.append(f'{name}: the reference archive does not read back in this checkout as in the reference')
    if ('reference', 'current-archives') in reads:
        for name, state in reads[('reference', 'current-archives')].items():
            if state != current_cases[name]['readBack']:
                failures.append(f'{name}: this checkout\'s archive does not read back in the reference as here')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'PASS: {len(current_cases)} ROI cases (every kind, calibrated and not) measure, report statistics and archive '
      f'exactly as {reference} does; archives cross-read both ways; '
      + (f'{examples} archives of earlier versions read alike' if examples else 'no archives of earlier versions in ../DICOM_Example'))
