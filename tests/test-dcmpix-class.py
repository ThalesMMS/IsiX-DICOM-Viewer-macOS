#!/usr/bin/env python3
"""DCMPix itself behaves as the Objective-C class did, value for value.

The parts of DCMPix that are neither the display image, the geometry, the ROI
measures, the annotations nor the formats that are not DICOM - its life cycle
and state - are characterized by a probe linked with the class as this
checkout builds it (tests/roi_harness.py), and the records are compared with
tests/fixtures/dcmpix-class-records.json, which the same probe wrote against
the Objective-C DCMPix.m before the class moved to Swift:

* the initializers: -init, -myinitEmpty, -initWithData::::::::: (float, ARGB,
  RGBA, a volume's own buffer), the lower-case aliases, -initWithPath::::::,
  -initWithContentsOfFile: and +dcmPixWithImageObj:, a missing file;
* -copyWithZone:, every field it copies, and the buffer it shares;
* the accessors and setters with their own rules: the pixel spacing, the
  origin, the slice, the window, the buffer and who owns it, -setPixelX:Y:value:,
  the fusion and stack, the shutter, the transfer function, the subtraction's
  offset;
* the series' minimum and maximum, the full window, -isLoaded;
* the image arithmetic and the subtraction of a mask (DSA), its sliders;
* the SUV: the dose correction, -checkSUV, -appliedFactorPET2SUV, -copySUVfrom:;
* -revert and -revert:; loading from a file through -CheckLoad (an image that is
  not DICOM, a file that cannot be read, a volume's buffer, the protected
  mode, -CheckLoadFromThread:), the count of decodes, the file revision;
* -description, the class methods, and key-value coding by every property and
  by every former instance variable name;
* every selector the Objective-C header declared for the class
  (tests/fixtures/dcmpix-class-selectors.txt), which plugins send by name: the
  class and its instances still respond to each one.

Floating-point values are hexadecimal and buffers are hashes of their bytes.

    python3 tests/test-dcmpix-class.py            # compare with the records
    python3 tests/test-dcmpix-class.py --record   # rewrite the records (from the Objective-C class only)

HOROS_TEST_CONFIGURATION=Release runs the Release build.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import roi_harness  # noqa: E402

RECORDS = ROOT / 'tests/fixtures/dcmpix-class-records.json'
SELECTORS = ROOT / 'tests/fixtures/dcmpix-class-selectors.txt'
SKIPPED = 2
# The app's Swift the class reaches while loading a file: the file revision and
# the sentences that explain a missing picture.
APP_SWIFT = ('PreviewWindowing', 'FileRevision', 'MissingPixelsReason')
configuration = roi_harness.configuration()

PROBE = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "DCMPix.h"

static NSMutableArray *gRecords = nil;
static NSString *gFolder = nil;

static void record( NSString *name, id value) { [gRecords addObject: @{@"name": name, @"value": value ?: [NSNull null]}]; }
static NSString *hd( double v) { return [NSString stringWithFormat: @"%a", v]; }
static id orNull( id v) { return v ? [v description] : [NSNull null]; }

static NSString *hashOf( const void *bytes, long count)
{
    if( bytes == NULL) return @"none";
    unsigned long long h = 1469598103934665603ULL;
    const unsigned char *b = bytes;
    for( long i = 0; i < count; i++) { h ^= b[ i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat: @"%016llx", h];
}

// A former instance variable, wherever the class keeps it now: under its own
// name, or under horos_ and its name.
static void *ivarAddress( id object, const char *name)
{
    Ivar ivar = class_getInstanceVariable( [object class], name);
    if( ivar == NULL)
    {
        char prefixed[ 256];
        snprintf( prefixed, sizeof prefixed, "horos_%s", name);
        ivar = class_getInstanceVariable( [object class], prefixed);
    }
    if( ivar == NULL) { fprintf( stderr, "no ivar %s\n", name); exit( 3); }
    return (char*) (__bridge void*) object + ivar_getOffset( ivar);
}
#define IV( object, type, name) (*(type*) ivarAddress( object, #name))

static NSArray *orientationOf( DCMPix *p)
{
    double o[ 9];
    [p orientationDouble: o];
    NSMutableArray *a = [NSMutableArray array];
    for( int i = 0; i < 9; i++) [a addObject: hd( o[ i])];
    return a;
}

// What an object holds, read without loading it (no accessor that calls -CheckLoad).
static NSDictionary *raw( DCMPix *p)
{
    long w = IV( p, long, width), h = IV( p, long, height);
    float *f = IV( p, float*, fImage);
    BOOL rgb = IV( p, BOOL, isRGB);
    return @{
        @"size": @[@(w), @(h)], @"rgb": @(rgb), @"pixels": f ? hashOf( f, w * h * 4) : @"none",
        @"spacing": @[hd( IV( p, double, pixelSpacingX)), hd( IV( p, double, pixelSpacingY)), hd( IV( p, double, pixelRatio))],
        @"origin": @[hd( IV( p, double, originX)), hd( IV( p, double, originY)), hd( IV( p, double, originZ)), @(IV( p, BOOL, isOriginDefined))],
        @"slice": @[hd( IV( p, double, sliceLocation)), hd( IV( p, double, sliceThickness)), hd( IV( p, double, sliceInterval)),
                    hd( IV( p, double, spacingBetweenSlices))],
        @"window": @[hd( IV( p, float, ww)), hd( IV( p, float, wl)), hd( IV( p, float, savedWW)), hd( IV( p, float, savedWL)),
                     hd( IV( p, float, fullww)), hd( IV( p, float, fullwl))],
        @"rescale": @[hd( IV( p, float, slope)), hd( IV( p, float, offset))],
        @"pixelFormat": @[@(IV( p, BOOL, fIsSigned)), @(IV( p, short, bitsAllocated)), @(IV( p, short, bitsStored)),
                          @(IV( p, long, fPlanarConf)), @(IV( p, BOOL, inverseVal))],
        @"numbers": @[@(IV( p, long, imID)), @(IV( p, long, imTot)), @(IV( p, long, frameNo)), @(IV( p, long, serieNo)),
                      @(IV( p, int, numberOfFrames)), @(IV( p, BOOL, isBonjour)), @(IV( p, BOOL, generated))],
        @"external": @(IV( p, float*, fExternalOwnedImage) != NULL),
        @"externalIsImage": @(IV( p, float*, fExternalOwnedImage) != NULL && IV( p, float*, fExternalOwnedImage) == f),
        @"stack": @[@(IV( p, short, stack)), @(IV( p, short, stackMode)), @(IV( p, short, stackDirection)), @(IV( p, NSInteger, pixPos))],
        @"flags": @[@(IV( p, BOOL, needToCompute8bitRepresentation)), @(IV( p, BOOL, updateToBeApplied)),
                    @(IV( p, BOOL, notAbleToLoadImage)), @(IV( p, BOOL, VOILUTApplied)), @(IV( p, BOOL, SUVConverted)),
                    @(IV( p, BOOL, hasSUV)), @(IV( p, BOOL, displaySUVValue)), @(IV( p, BOOL, shutterEnabled))],
        @"subtraction": @[hd( IV( p, float, subtractedfPercent)), hd( IV( p, float, subtractedfZ)), hd( IV( p, float, subtractedfZero)),
                          hd( IV( p, float, subtractedfGamma)), NSStringFromPoint( IV( p, NSPoint, subPixOffset)),
                          NSStringFromPoint( IV( p, NSPoint, subMinMax)), @(IV( p, GammaFunction, subGammaFunction) != NULL)],
        @"suv": @[hd( IV( p, float, decayFactor)), hd( IV( p, float, factorPET2SUV)), hd( IV( p, float, radionuclideTotalDose)),
                  hd( IV( p, float, radionuclideTotalDoseCorrected)), hd( IV( p, float, halflife)), hd( IV( p, float, patientsWeight)),
                  hd( IV( p, float, philipsFactor))],
        @"series": @[hd( IV( p, float, maxValueOfSeries)), hd( IV( p, float, minValueOfSeries))],
        @"times": @[hd( IV( p, float, fImageTime)), hd( IV( p, float, maskTime)), @(IV( p, long, maskID)), hd( IV( p, float, cineRate))],
        @"shutter": @[NSStringFromRect( IV( p, NSRect, shutterRect)), @(IV( p, NSPoint*, shutterPolygonal) != NULL)],
        @"transfer": @[@(IV( p, float*, transferFunctionPtr) != NULL), @([IV( p, NSData*, transferFunction) length])],
        @"text": @[orNull( IV( p, NSString*, modalityString)), orNull( IV( p, NSString*, rescaleType)), orNull( IV( p, NSString*, units)),
                   orNull( IV( p, NSString*, decayCorrection)), orNull( IV( p, NSString*, SOPClassUID)),
                   orNull( IV( p, NSString*, frameofReferenceUID)), orNull( IV( p, NSString*, imageType)),
                   orNull( IV( p, NSString*, repetitiontime)), orNull( IV( p, NSString*, echotime)), orNull( IV( p, NSString*, flipAngle)),
                   orNull( IV( p, NSString*, laterality)), orNull( IV( p, NSString*, viewPosition)), orNull( IV( p, NSString*, patientPosition)),
                   orNull( IV( p, NSString*, acquisitionDate)), orNull( IV( p, NSString*, generatedName)), orNull( IV( p, NSString*, yearOld)),
                   orNull( IV( p, NSString*, yearOldAcquisition)), orNull( IV( p, NSString*, missingPixelsReason))],
        @"dates": @[orNull( IV( p, NSDate*, acquisitionTime)), orNull( IV( p, NSDate*, radiopharmaceuticalStartTime))],
        @"angles": @[orNull( IV( p, NSNumber*, positionerPrimaryAngle)), orNull( IV( p, NSNumber*, positionerSecondaryAngle))],
        @"objects": @[@(IV( p, id, checking) != nil), @([IV( p, NSArray*, usRegions) count]), @(IV( p, NSArray*, pixArray) != nil),
                      @([p.annotationsDictionary count]), @(IV( p, id, waveform) != nil)],
        @"orientation": orientationOf( p),
    };
}

static float *greyData( long w, long h, float seed)
{
    float *data = malloc( w * h * sizeof( float));
    for( long i = 0; i < w * h; i++)
        data[ i] = seed + (float) ((i * 37 + (i / w) * 11) % 251) * 3.25f - 300.f;
    return data;
}

static DCMPix *grey( long w, long h, float seed)
{
    float *data = greyData( w, h, seed);
    DCMPix *p = [[[DCMPix alloc] initWithData: data :32 :w :h :0.8f :0.6f :1.5f :-2.25f :7.5f] autorelease];
    free( data);
    return p;
}

static void initializers( void)
{
    DCMPix *plain = [[[DCMPix alloc] init] autorelease];
    record( @"init", raw( plain));
    DCMPix *empty = [[[DCMPix alloc] myinitEmpty] autorelease];
    record( @"myinitEmpty", raw( empty));

    float *data = greyData( 13, 9, 4);
    record( @"initWithData-32", raw( [[[DCMPix alloc] initWithData: data :32 :13 :9 :0.8f :0.6f :1 :2 :3] autorelease]));
    record( @"initwithdata-32", raw( [[[DCMPix alloc] initwithdata: data :32 :13 :9 :0.8f :0.6f :1 :2 :3] autorelease]));
    record( @"initWithData-spacing", raw( [[[DCMPix alloc] initWithData: data :32 :13 :9 :0 :2000 :1 :2 :3] autorelease]));
    record( @"initWithData-ratio", raw( [[[DCMPix alloc] initWithData: data :32 :13 :9 :0.5f :0 :1 :2 :3] autorelease]));
    DCMPix *volume = [[[DCMPix alloc] initWithData: data :32 :13 :9 :1 :1 :0 :0 :0 :YES] autorelease];
    record( @"initWithData-volume", raw( volume));
    record( @"initwithdata-volume", raw( [[[DCMPix alloc] initwithdata: data :32 :13 :9 :1 :1 :0 :0 :0 :YES] autorelease]));
    unsigned char *bytes = malloc( 13 * 9 * 4);
    for( int i = 0; i < 13 * 9 * 4; i++) bytes[ i] = (unsigned char) (i * 7 + 3);
    record( @"initWithData-argb", raw( [[[DCMPix alloc] initWithData: (float*) bytes :7 :13 :9 :1 :1 :0 :0 :0] autorelease]));
    record( @"initWithData-rgba", raw( [[[DCMPix alloc] initWithData: (float*) bytes :8 :13 :9 :1 :1 :0 :0 :0] autorelease]));
    record( @"initWithData-null", raw( [[[DCMPix alloc] initWithData: NULL :32 :13 :9 :1 :1 :0 :0 :0] autorelease]));
    record( @"initWithData-other", raw( [[[DCMPix alloc] initWithData: data :16 :13 :9 :1 :1 :0 :0 :0] autorelease]));
    free( bytes);
    free( data);

    record( @"initWithPath-missing", @([[[DCMPix alloc] initWithPath: [gFolder stringByAppendingPathComponent: @"missing.dcm"] :0 :1 :nil :0 :0] autorelease] == nil));
    record( @"initWithContentsOfFile-missing", @([[[DCMPix alloc] initWithContentsOfFile: @"/nonexistent/missing.dcm"] autorelease] == nil));
    DCMPix *unnamed = [[[DCMPix alloc] initWithPath: nil :4 :9 :nil :2 :3 isBonjour: NO imageObj: nil] autorelease];
    record( @"initWithPath-nil", raw( unnamed));
    record( @"myinit", raw( [[[DCMPix alloc] myinit: nil :5 :6 :nil :1 :2] autorelease]));
    record( @"myinit-bonjour", raw( [[[DCMPix alloc] myinit: nil :5 :6 :nil :1 :2 isBonjour: YES imageObj: nil] autorelease]));
    record( @"dcmPixWithImageObj-nil", raw( [DCMPix dcmPixWithImageObj: nil]));
    record( @"initWithImageObj-nil", raw( [[[DCMPix alloc] initWithImageObj: nil] autorelease]));
}

static DCMPix *configured( void)
{
    DCMPix *p = grey( 17, 11, 9);
    p.srcFile = @"/probe/configured.dcm";
    [p setID: 4];
    p.frameNo = 3;
    [p setTot: 12];
    double o[ 6] = { 0, 1, 0, 0, 0, -1};
    [p setOrientationDouble: o];
    double origin[ 3] = { -10.5, 20.25, 33};
    [p setOriginDouble: origin];
    p.sliceThickness = 2.5;
    p.sliceInterval = 1.25;
    p.sliceLocation = 44;
    p.savedWL = 40; p.savedWW = 400;
    p.slope = 2; p.offset = -1024;
    p.frameofReferenceUID = @"1.2.3.4";
    p.rescaleType = @"HU";
    p.units = @"BQML";
    p.decayCorrection = @"START";
    p.patientsWeight = 72.5f;
    p.halflife = 6586.2f;
    p.radionuclideTotalDose = 3.7e8f;
    p.acquisitionTime = [NSDate dateWithTimeIntervalSinceReferenceDate: 800000000];
    p.radiopharmaceuticalStartTime = [NSDate dateWithTimeIntervalSinceReferenceDate: 799996400];
    p.acquisitionDate = @"20260101";
    p.repetitiontime = @"500"; p.echotime = @"15";
    p.shutterRect = NSMakeRect( 1, 2, 10, 8);
    p.shutterEnabled = YES;
    p.SUVConverted = YES;
    p.factorPET2SUV = 0.25f;
    p.displaySUVValue = YES;
    p.imageType = @"ORIGINAL\\PRIMARY";
    p.SOPClassUID = @"1.2.840.10008.5.1.4.1.1.2";
    p.generatedName = @"generated";
    p.yearOld = @"40 y"; p.yearOldAcquisition = @"39 y";
    [p setValue: @"PT" forKey: @"modalityString"];
    [p positionerPrimaryAngle: @12.5];
    [p positionerSecondaryAngle: @-3];
    [p maskID: 7]; [p maskTime: 1.5f]; [p fImageTime: 2.5f];
    return p;
}

static void copying( void)
{
    DCMPix *p = configured();
    DCMPix *copy = [[p copy] autorelease];
    record( @"copy-class", NSStringFromClass( [copy class]));
    record( @"copy", raw( copy));
    record( @"copy-shares-pixels", @(IV( copy, float*, fImage) == IV( p, float*, fImage)));
    record( @"copy-source", @[orNull( copy.srcFile), @([copy ID]), @(copy.frameNo)]);
    // The copy shares the buffer and does not own it; it is given its own before both go.
    float *own = malloc( 17 * 11 * sizeof( float));
    memcpy( own, IV( p, float*, fImage), 17 * 11 * sizeof( float));
    IV( copy, float*, fImage) = own;
}

static void setters( void)
{
    DCMPix *p = grey( 9, 7, 1);
    NSMutableArray *spacing = [NSMutableArray array];
    for( NSNumber *v in @[@0.5, @0, @(NAN), @2000, @-1, @1e-6, @3.25])
    {
        p.pixelSpacingX = v.doubleValue;
        [spacing addObject: @[hd( p.pixelSpacingX), hd( p.pixelSpacingY), hd( p.pixelRatio)]];
        p.pixelSpacingY = v.doubleValue * 2;
        [spacing addObject: @[hd( p.pixelSpacingX), hd( p.pixelSpacingY), hd( p.pixelRatio)]];
    }
    record( @"pixel-spacing", spacing);
    p.pixelRatio = 1.75;
    record( @"pixel-ratio", hd( p.pixelRatio));

    float of[ 3] = { 1.5f, -2.5f, 3.25f};
    [p setOrigin: of];
    float og[ 3]; [p origin: og];
    double od[ 3]; [p originDouble: od];
    record( @"origin-float", @[hd( og[ 0]), hd( og[ 1]), hd( og[ 2]), hd( od[ 0]), hd( p.originX), hd( p.originY), hd( p.originZ)]);
    double dd[ 3] = { 0.1, 0.2, 0.3};
    [p setOriginDouble: dd];
    [p originDouble: od];
    record( @"origin-double", @[hd( od[ 0]), hd( od[ 1]), hd( od[ 2]), @(p.isOriginDefined)]);

    double o[ 6] = { 1, 0, 0, 0, 0.6, 0.8};
    [p setOrientationDouble: o];
    p.pixelSpacingX = 0.7; p.pixelSpacingY = 0.9;
    [p computeSliceLocation];
    record( @"slice-location", @[hd( p.sliceLocation), hd( p.sliceThickness), hd( p.sliceInterval), hd( p.spacingBetweenSlices)]);
    p.sliceLocation = -5; p.sliceThickness = 3; p.sliceInterval = 0.5;
    record( @"slice-set", @[hd( p.sliceLocation), hd( p.sliceThickness), hd( p.sliceInterval)]);

    p.savedWL = 11; p.savedWW = 22;
    record( @"window", @[hd( p.ww), hd( p.wl), hd( p.savedWL), hd( p.savedWW), hd( p.fullww), hd( p.fullwl), hd( [p cineRate])]);
    [p setPixelX: 2 Y: 3 value: 1234.5f];
    record( @"set-pixel", @[hd( p.fImage[ 3 * 9 + 2]), hashOf( p.fImage, 9 * 7 * 4)]);
    [p computePixMinPixMax];
    record( @"full-window", @[hd( p.fullww), hd( p.fullwl)]);

    [p setRGB: YES];
    record( @"rgb", @[@(p.isRGB)]);
    [p setRGB: NO];

    [p setID: 8]; p.Tot = 30; p.frameNo = 2;
    record( @"numbers", @[@([p ID]), @(p.Tot), @(p.frameNo), @(p.serieNo)]);
    p.pwidth = 9; p.pheight = 7;

    p.needToCompute8bitRepresentation = NO;
    [p setFusion: 2 :5 :1];
    record( @"fusion", @[@(p.stack), @(p.stackMode), @(p.stackDirection), @([p updateToApply]), @(p.needToCompute8bitRepresentation)]);
    [p setFusion: -1 :-1 :-1];
    record( @"fusion-keep", @[@(p.stack), @(p.stackMode), @(p.stackDirection)]);
    [p setFusion: 0 :4 :0];
    record( @"fusion-off", @[@(p.stack), @(IV( p, short, stack)), @(p.stackMode)]);
    p.pixPos = 3; p.countstackMean = 2.5f;
    record( @"pix-pos", @[@(p.pixPos), hd( p.countstackMean)]);

    IV( p, BOOL, updateToBeApplied) = NO;
    p.shutterEnabled = YES;
    record( @"shutter-enabled", @[@(p.shutterEnabled), @([p updateToApply])]);
    IV( p, NSPoint*, shutterPolygonal) = malloc( 3 * sizeof( NSPoint));
    p.shutterRect = NSMakeRect( 2, 3, 4, 5);
    record( @"shutter-rect", @[NSStringFromRect( p.shutterRect), @(p.shutterPolygonal != NULL)]);

    IV( p, BOOL, updateToBeApplied) = NO;
    float table[ 4] = { 1, 2, 3, 4};
    NSData *tf = [NSData dataWithBytes: table length: sizeof table];
    p.transferFunction = tf;
    record( @"transfer", @[@(p.transferFunctionPtr == (float*) tf.bytes), @([p updateToApply]), @(p.transferFunction == tf)]);
    IV( p, BOOL, updateToBeApplied) = NO;
    p.transferFunction = tf;
    record( @"transfer-same", @([p updateToApply]));
    p.transferFunction = nil;
    record( @"transfer-none", @[@(p.transferFunctionPtr == NULL), @([p updateToApply])]);

    IV( p, BOOL, updateToBeApplied) = NO;
    p.subPixOffset = NSMakePoint( 1, -2);
    record( @"sub-offset", @[NSStringFromPoint( p.subPixOffset), @([p updateToApply])]);
    IV( p, BOOL, updateToBeApplied) = NO;
    [p setUpdateToApply];
    record( @"update", @([p updateToApply]));

    [p positionerPrimaryAngle: @1]; [p positionerSecondaryAngle: @2];
    [p maskID: 3]; [p maskTime: 4]; [p fImageTime: 5];
    record( @"angles", @[[p positionerPrimaryAngle], [p positionerSecondaryAngle], @([p maskID]), hd( [p maskTime]), hd( [p fImageTime])]);

    p.isLUT12Bit = YES;
    record( @"lut12", @(p.isLUT12Bit));
    p.isLUT12Bit = NO;
    p.minValueOfSeries = 0; p.maxValueOfSeries = 0;
    [p setSourceFile: @"/probe/source.dcm"];
    record( @"source-file", @[orNull( [p sourceFile]), orNull( p.srcFile)]);
    p.srcFile = nil;
    record( @"usregions", @[@([p hasUSRegions]), @([p.usRegions count])]);
    record( @"setters", raw( p));
}

static void buffers( void)
{
    // The buffer of a volume: not freed by the object, and handed back when it changes.
    float *volume = greyData( 6, 5, 2);
    DCMPix *v = [[[DCMPix alloc] initWithData: volume :32 :6 :5 :1 :1 :0 :0 :0 :YES] autorelease];
    float *other = greyData( 6, 5, 3);
    v.fImage = other;
    record( @"external-set", @[@(IV( v, float*, fExternalOwnedImage) == other), @(IV( v, float*, fImage) == other)]);
    [v freefImageWhenDone: YES];
    record( @"free-when-done", @[@(IV( v, float*, fExternalOwnedImage) == NULL)]);
    [v freefImageWhenDone: NO];
    record( @"keep-when-done", @[@(IV( v, float*, fExternalOwnedImage) == other)]);
    [v revert];
    record( @"revert-external", @[@(IV( v, float*, fImage) == NULL), @(v.isLoaded), @(v.needToCompute8bitRepresentation)]);
    free( other);
    free( volume);

    DCMPix *p = configured();
    record( @"isLoaded", @(p.isLoaded));
    [p revert: NO];
    record( @"revert-no-annotations", raw( p));
    DCMPix *q = configured();
    [q revert];
    record( @"revert", raw( q));
    [q revert];
    record( @"revert-again", @(IV( q, float*, fImage) == NULL));
}

static void series( void)
{
    NSMutableArray *list = [NSMutableArray array];
    for( int i = 0; i < 3; i++)
    {
        DCMPix *p = grey( 8, 8, i * 500);
        [list addObject: p];
    }
    for( int i = 0; i < 3; i++) [list[ i] setArrayPix: list :i];
    DCMPix *middle = list[ 1];
    record( @"series-max", hd( middle.maxValueOfSeries));
    record( @"series-min", hd( middle.minValueOfSeries));
    record( @"series-values", @[hd( IV( list[ 0], float, maxValueOfSeries)), hd( IV( list[ 2], float, minValueOfSeries)),
                                @(middle.pixPos), @(middle.pixArray.count)]);
    for( DCMPix *p in list) IV( p, NSArray*, pixArray) = nil;
}

static void arithmetic( void)
{
    DCMPix *a = grey( 10, 8, 5), *b = grey( 10, 8, -40), *small = grey( 9, 8, 0);
    [a imageArithmeticMultiplication: b];
    record( @"multiply", hashOf( a.fImage, 10 * 8 * 4));
    [a imageArithmeticMultiplication: small];
    record( @"multiply-size", hashOf( a.fImage, 10 * 8 * 4));
    a.subPixOffset = NSMakePoint( 2, 1);
    [a imageArithmeticSubtraction: b];
    record( @"subtract", hashOf( a.fImage, 10 * 8 * 4));
    [a imageArithmeticSubtraction: b absolute: YES];
    record( @"subtract-absolute", hashOf( a.fImage, 10 * 8 * 4));
    [a imageArithmeticSubtraction: small absolute: YES];
    record( @"subtract-size", hashOf( a.fImage, 10 * 8 * 4));
    float *product = [a multiplyImages: a.fImage :b.fImage];
    float *difference = [a arithmeticSubtractImages: a.fImage :b.fImage];
    float *absolute = [a arithmeticSubtractImages: a.fImage :b.fImage absolute: YES];
    record( @"arithmetic-buffers", @[hashOf( product, 320), hashOf( difference, 320), hashOf( absolute, 320)]);
    free( product); free( difference); free( absolute);

    DCMPix *s = grey( 10, 8, 100), *mask = grey( 10, 8, 40);
    NSPoint range = [s subMinMax: s.fImage :mask.fImage];
    record( @"sub-min-max", NSStringFromPoint( range));
    [s setSubSlidersPercent: 0.75f gamma: 1.5f zero: 0.6f];
    record( @"sub-sliders", raw( s)[ @"subtraction"]);
    [s setSubSlidersPercent: 0.5f];
    record( @"sub-sliders-percent", raw( s)[ @"subtraction"]);
    IV( s, BOOL, updateToBeApplied) = NO;
    [s setSubtractedfImage: mask.fImage :range];
    record( @"subtracted-image", @[@(s.subtractedfImage == mask.fImage), @([s updateToApply])]);
    float *input = malloc( 320);
    memcpy( input, s.fImage, 320);
    float *subtracted = [s subtractImages: input :mask.fImage];
    record( @"subtract-images", @[hashOf( subtracted, 320), @(subtracted == input)]);
    if( subtracted != input) free( subtracted);
    else free( input);
    float *own = [s subtractImages: s.fImage :mask.fImage];
    record( @"subtract-own", @[hashOf( own, 320), @(own == s.fImage)]);
    if( own != s.fImage) free( own);
    s.subtractedfImage = NULL;
}

static void suv( void)
{
    for( NSString *correction in @[@"START", @"ADMIN", @"NONE", @"OTHER"])
    {
        DCMPix *p = configured();
        p.decayCorrection = correction;
        [p computeTotalDoseCorrected];
        NSArray *corrected = @[hd( p.radionuclideTotalDoseCorrected), hd( p.decayFactor)];
        [p checkSUV];
        record( [@"suv-" stringByAppendingString: correction],
                @[corrected, @(p.hasSUV), hd( p.radionuclideTotalDoseCorrected), hd( p.decayFactor), hd( [p appliedFactorPET2SUV])]);
    }
    DCMPix *p = configured();
    p.SUVConverted = NO;
    record( @"suv-not-converted", hd( [p appliedFactorPET2SUV]));
    p.units = @"CNTS";
    [p checkSUV];
    record( @"suv-counts", @(p.hasSUV));
    DCMPix *to = grey( 4, 4, 0);
    [to copySUVfrom: configured()];
    record( @"suv-copy", raw( to));
}

static NSString *writeFile( NSString *name, NSData *data)
{
    NSString *path = [gFolder stringByAppendingPathComponent: name];
    [data writeToFile: path atomically: NO];
    return path;
}

static NSData *png( int w, int h)
{
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: w pixelsHigh: h bitsPerSample: 8
        samplesPerPixel: 3 hasAlpha: NO isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: w * 3 bitsPerPixel: 24] autorelease];
    unsigned char *b = rep.bitmapData;
    for( int i = 0; i < w * h * 3; i++) b[ i] = (unsigned char) ((i * 13) % 256);
    return [rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}];
}

static void loading( void)
{
    [DCMPix resetDecodedFrameCount];
    NSString *picture = writeFile( @"picture.png", png( 12, 10));
    DCMPix *p = [[[DCMPix alloc] initWithPath: picture :0 :1 :nil :0 :0] autorelease];
    record( @"load-before", @[@(p.isLoaded), @([DCMPix decodedFrameCount])]);
    [p CheckLoad];
    record( @"load-picture", raw( p));
    record( @"load-picture-count", @[@([DCMPix decodedFrameCount]), @(p.isLoaded), @([p loadedFileMatchesDisk]),
                                     @([p loadedFileRevision] != nil), @([[p parsedFileCacheKey] length] > 0)]);
    [p CheckLoad];
    record( @"load-again-count", @([DCMPix decodedFrameCount]));
    writeFile( @"picture.png", png( 14, 10));
    record( @"load-changed", @([p loadedFileMatchesDisk]));
    [p revert];
    record( @"load-reverted", @[@(p.isLoaded), @([p loadedFileRevision] != nil), @([p loadedFileMatchesDisk])]);
    record( @"load-reload", @[@(p.pwidth), @(p.pheight), hashOf( p.fImage, p.pwidth * p.pheight * 4), @([DCMPix decodedFrameCount])]);

    NSString *garbage = writeFile( @"garbage.bin", [@"this is not an image" dataUsingEncoding: NSUTF8StringEncoding]);
    DCMPix *g = [[[DCMPix alloc] initWithContentsOfFile: garbage] autorelease];
    [g CheckLoad];
    record( @"load-garbage", raw( g));

    float *volume = calloc( 5 * 4, sizeof( float));
    for( int i = 0; i < 20; i++) volume[ i] = 99;
    DCMPix *v = [[[DCMPix alloc] initWithPath: garbage :0 :1 :volume :0 :0] autorelease];
    IV( v, int, savedWidthInDB) = 5;
    IV( v, int, savedHeightInDB) = 4;
    [v CheckLoad];
    record( @"load-volume", raw( v));
    record( @"load-volume-buffer", @[@(IV( v, float*, fImage) == volume), hashOf( volume, 80)]);
    DCMPix *u = [[[DCMPix alloc] initWithPath: garbage :0 :1 :volume :0 :0] autorelease];
    [u CheckLoad];
    record( @"load-volume-unknown", raw( u));
    free( volume);

    [DCMPix setRunOsiriXInProtectedMode: YES];
    DCMPix *protected = [[[DCMPix alloc] initWithPath: picture :0 :1 :nil :0 :0] autorelease];
    [protected CheckLoad];
    record( @"load-protected", @[@([DCMPix isRunOsiriXInProtectedModeActivated]), @(IV( protected, float*, fImage) == NULL),
                                 @(IV( protected, BOOL, needToCompute8bitRepresentation))]);
    [DCMPix setRunOsiriXInProtectedMode: NO];
    record( @"protected-off", @([DCMPix isRunOsiriXInProtectedModeActivated]));

    NSThread *idle = [[[NSThread alloc] initWithTarget: [NSObject class] selector: @selector(class) object: nil] autorelease];
    DCMPix *t = [[[DCMPix alloc] initWithPath: picture :0 :1 :nil :0 :0] autorelease];
    [t CheckLoadFromThread: idle];
    record( @"load-from-idle-thread", @(IV( t, float*, fImage) == NULL));
    [t CheckLoadFromThread: [NSThread currentThread]];
    record( @"load-from-this-thread", @[@(IV( t, float*, fImage) == NULL), @(t.isLoaded)]);
    [DCMPix resetDecodedFrameCount];
    record( @"count-reset", @([DCMPix decodedFrameCount]));
    // -releaseParsedFile, which the Objective-C class named -clearCachedDCMFrameworkFiles.
    [p performSelector: [p respondsToSelector: NSSelectorFromString( @"releaseParsedFile")] ?
        NSSelectorFromString( @"releaseParsedFile") : NSSelectorFromString( @"clearCachedDCMFrameworkFiles")];
    [DCMPix purgeCachedDictionaries];
    record( @"papyrus", @([p loadDICOMPapyrus]));
}

static void keyValueCoding( void)
{
    DCMPix *p = configured();
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *keys = @[@"pwidth", @"pheight", @"isRGB", @"ww", @"wl", @"fullww", @"fullwl", @"slope", @"offset", @"savedWW", @"savedWL",
        @"pixelRatio", @"pixelSpacingX", @"pixelSpacingY", @"originX", @"originY", @"originZ", @"isOriginDefined", @"sliceLocation",
        @"sliceThickness", @"sliceInterval", @"spacingBetweenSlices", @"frameNo", @"ID", @"Tot", @"serieNo", @"stack", @"stackMode",
        @"pixPos", @"stackDirection", @"countstackMean", @"generated", @"generatedName", @"srcFile", @"sourceFile", @"modalityString",
        @"imageType", @"referencedSOPInstanceUID", @"yearOld", @"yearOldAcquisition", @"SOPClassUID", @"frameofReferenceUID",
        @"repetitiontime", @"echotime", @"flipAngle", @"laterality", @"viewPosition", @"patientPosition", @"philipsFactor",
        @"patientsWeight", @"halflife", @"radionuclideTotalDose", @"radionuclideTotalDoseCorrected", @"acquisitionTime",
        @"acquisitionDate", @"rescaleType", @"missingPixelsReason", @"radiopharmaceuticalStartTime", @"SUVConverted",
        @"needToCompute8bitRepresentation", @"hasSUV", @"decayFactor", @"units", @"decayCorrection", @"displaySUVValue",
        @"isLUT12Bit", @"minValueOfSeries", @"maxValueOfSeries", @"factorPET2SUV", @"notAbleToLoadImage", @"VOILUTApplied",
        @"shutterEnabled", @"shutterRect", @"subPixOffset", @"transferFunction", @"usRegions", @"cineRate",
        // Former instance variables without an accessor of their own.
        @"URIRepresentationAbsoluteString", @"isBonjour", @"fileTypeHasPrefixDICOM", @"numberOfFrames", @"fIsSigned",
        @"bitsAllocated", @"bitsStored", @"height", @"width", @"fPlanarConf", @"estimatedRadiographicMagnificationFactor",
        @"pixelSpacingFromUltrasoundRegions", @"inverseVal", @"subtractedfPercent", @"subtractedfZ", @"subtractedfZero",
        @"subtractedfGamma", @"subMinMax", @"maskID", @"maskTime", @"fImageTime", @"positionerPrimaryAngle",
        @"positionerSecondaryAngle", @"shutterCircular", @"shutterCircular_radius", @"shutterPolygonalSize", @"imID", @"imTot",
        @"convolution", @"updateToBeApplied", @"kernelsize", @"normalization", @"thickSlabVRActivated", @"fixed8bitsWLWW",
        @"VOILUT_first", @"VOILUT_number", @"VOILUT_depth", @"blackIndex", @"savedHeightInDB", @"savedWidthInDB",
        @"clutEntryR", @"clutDepthR", @"fSetClut", @"fSetClut16", @"cachedFileKey", @"loadedFileRevision", @"_srcFile",
        @"annotationsDictionary", @"annotationsDBFields", @"waveform", @"imageObjectID", @"pixArray"];
    for( NSString *key in keys)
    {
        id value;
        @try { value = [p valueForKey: key]; value = value ? [value description] : @"nil"; }
        @catch( NSException *e) { value = [@"exception " stringByAppendingString: e.name]; }
        values[ key] = value;
    }
    record( @"kvc-get", values);
    NSMutableDictionary *set = [NSMutableDictionary dictionary];
    for( NSArray *pair in @[@[@"width", @21], @[@"height", @19], @[@"fIsSigned", @YES], @[@"bitsStored", @12], @[@"numberOfFrames", @4],
                            @[@"inverseVal", @YES], @[@"modalityString", @"MR"], @[@"generatedName", @"g"], @[@"savedWW", @7],
                            @[@"pixPos", @2], @[@"imID", @6], @[@"subtractedfPercent", @0.25]])
    {
        id value;
        @try { [p setValue: pair[ 1] forKey: pair[ 0]]; value = [[p valueForKey: pair[ 0]] description]; }
        @catch( NSException *e) { value = [@"exception " stringByAppendingString: e.name]; }
        set[ pair[ 0]] = value ?: @"nil";
    }
    record( @"kvc-set", set);
    // The buffer is still the one of the size before: what lies past it is not the image's.
    NSMutableDictionary *state = [[raw( p) mutableCopy] autorelease];
    [state removeObjectForKey: @"pixels"];
    record( @"kvc-set-state", state);
}

static void classMethods( void)
{
    record( @"max-processors", @([DCMPix maxProcessors] == MIN( 12, (int) [[NSProcessInfo processInfo] processorCount])));
    [DCMPix resetUserDefaults];
    [DCMPix checkUserDefaults: NO];
    [DCMPix checkUserDefaults: YES];
    DCMPix *p = configured();
    NSString *d = [p description];
    NSRegularExpression *address = [NSRegularExpression regularExpressionWithPattern: @"<[0-9a-f]+>" options: 0 error: nil];
    record( @"description", [address stringByReplacingMatchesInString: d options: 0 range: NSMakeRange( 0, d.length) withTemplate: @"<address>"]);
}

// The selectors that neither the class nor its instances answer, from a list of
// "-selector" and "+selector" lines.
static NSArray *missingSelectors( NSString *path)
{
    NSMutableArray *missing = [NSMutableArray array];
    for( NSString *line in [[NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: nil] componentsSeparatedByString: @"\n"])
    {
        if( line.length < 2) continue;
        SEL selector = NSSelectorFromString( [line substringFromIndex: 1]);
        BOOL answers = [line hasPrefix: @"+"] ? [DCMPix respondsToSelector: selector] : [DCMPix instancesRespondToSelector: selector];
        if( answers == NO) [missing addObject: line];
    }
    return missing;
}

int main( int argc, const char **argv)
{
    @autoreleasepool
    {
        if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
        [NSApplication sharedApplication];
        gRecords = [NSMutableArray new];
        gFolder = [[NSString stringWithUTF8String: argv[ 1]] retain];
        [[NSUserDefaults standardUserDefaults] setVolatileDomain: @{@"UseShutter": @NO, @"DisplayDICOMOverlays": @YES} forName: NSArgumentDomain];
        initializers();
        copying();
        setters();
        buffers();
        series();
        arithmetic();
        suv();
        loading();
        keyValueCoding();
        classMethods();
        if( argc > 2) record( @"missing-selectors", missingSelectors( [NSString stringWithUTF8String: argv[ 2]]));
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


def run(harness, folder):
    try:
        done = subprocess.run([str(harness), str(folder), str(SELECTORS)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise RuntimeError('the probe did not finish in 60 s')
    if done.returncode:
        raise RuntimeError(f'the probe ended with {done.returncode}:\n{done.stderr[-3000:]}')
    records = {}
    for line in done.stdout.splitlines():
        entry = json.loads(line)
        records[entry['name']] = entry['value']
    return records


def main():
    write = '--record' in sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix='horos-dcmpix-class-') as tmp:
        tmp = Path(tmp)
        try:
            harness = roi_harness.build(roi_harness.WORKTREE, tmp / 'harness', PROBE, config=configuration, app_swift=APP_SWIFT)
        except LookupError as error:
            print('skipped: %s' % error, file=sys.stderr)
            sys.exit(SKIPPED)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            print(f'FAIL: the harness did not build: {str(error)[-4000:]}')
            sys.exit(1)
        files = tmp / 'files'
        files.mkdir()
        try:
            records = run(harness, files)
        except RuntimeError as error:
            print(f'FAIL: {error}')
            sys.exit(1)
    missing = records.pop('missing-selectors', None)
    if missing is None:
        print('FAIL: the probe did not check the selectors')
        sys.exit(1)
    if write:
        if not (ROOT / roi_harness.PIX_SOURCE).is_file():
            print('FAIL: the records are written from the Objective-C class only')
            sys.exit(1)
        if missing:
            print(f'FAIL: the selector list names what the Objective-C class does not answer: {missing}')
            sys.exit(1)
        RECORDS.write_text(json.dumps(records, indent=1, sort_keys=True) + '\n')
        print(f'wrote {len(records)} records to {RECORDS.relative_to(ROOT)}')
        return
    expected = json.loads(RECORDS.read_text())
    failures = [f'differs from the Objective-C class: {problem}' for problem in roi_harness.diff(expected, records)]
    failures += [f'no longer answers {selector}, which the Objective-C header declared' for selector in missing]
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        sys.exit(1)
    print(f'PASS: {len(records)} records (initializers, copy, setters, buffers, series, arithmetic, subtraction, SUV, '
          f'loading, key-value coding, class methods) identical to the Objective-C class, and all '
          f'{len(SELECTORS.read_text().split())} declared selectors answered, in {configuration}')


if __name__ == '__main__':
    main()
