"""Runs the image attribute reading of one revision of DCMPix.m on synthetic data sets.

`tests/test-dcmpix-attribute-reading.py` uses this to compare the reading the
app does now with the Objective-C reading it replaced, field by field and bit
by bit. The parts of DCMPix.m that read the attributes are cut out of the
source of a revision and compiled into a small program, with stand-ins for the
parsed DICOM object (a dictionary), its date type and the database write. The
Objective-C revision is compiled on its own; a revision whose reading lives in
the IsiXImaging module is linked with the module built from this checkout.
Once DCMPix itself is Swift, its reading (DCMPix+ImageAttributes.swift, with
the parameters, the orientation, the slice location and the dose correction
it uses) is compiled as it stands instead, in a class that holds the state it
reads under the names DCMPix.swift stores it by, over the same stand-ins
(compile_swift_class); the date stand-in is then an NSDate, as the
framework's date is. A revision of DCMPix.m is compiled against its own
DCMPix.h, which declares the instance variables it uses.

The program prints one JSON object per step, with every attribute the reading
sets (floating-point values as hexadecimal, so that equal means identical), the
sizes written back to the database, the exceptions raised and logged, and the
log lines without their time stamps.
"""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

# The Objective-C reading, before it moved to the module.
OBJC_MARKER = '- (void) dcmFrameworkLoad0x0018: (DCMObject*) dcmObject'
# The reading that delegates to the module.
MODULE_MARKER = '#pragma mark *image attributes'


def between(text, start, end, include_end=False):
    begin = text.index(start)
    stop = text.index(end, begin + len(start))
    return text[begin:stop + (len(end) if include_end else 0)]


# The parser's answer to the module's attribute source, for the stand-in
# DCMObject: what DCMObject of IsiXDICOMDataset does (sequenceItems(withName:)) for
# the real one, which the stand-in replaces.
STAND_IN_ATTRIBUTE_SOURCE = r"""@interface DCMObject (IsiXDICOMAttributeSource) <IsiXDICOMAttributeSource>
@end

@implementation DCMObject (IsiXDICOMAttributeSource)

- (id) isixSequenceItemsWithName:(NSString*) name
{
    DCMAttribute *attribute = [self attributeWithName: name];

    if( attribute == nil)
        return nil;

    if( [attribute isKindOfClass: [DCMSequenceAttribute class]] == NO)
        return attribute;

    return [(DCMSequenceAttribute*) attribute sequence];
}

@end
"""


def stand_in_source(attributes):
    """DCMPix's view of the parsed object (DCMPix+ImageAttributes.swift) for the
    stand-in DCMObject, whose adoption of the protocol only the run time knows."""
    source = between(attributes, 'extension DCMObject {', '\n}\n', include_end=True)
    return source.replace('DICOMAttributeSource { self }', 'DICOMAttributeSource { self as! DICOMAttributeSource }')


def is_objc(source):
    return OBJC_MARKER in source


# Where the orientation and the pixel conversions are in DCMPix+Geometry.swift, the
# program has the setter that extension has, in Objective-C: the cosines handed to
# the module. The reading of a module revision converts no pixel.
CONVERT_MARKER = '-(void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter'
SWIFT_ORIENTATION = '''-(void) setOrientationDouble:(double*) c
{
    [IsiXImagePlaneGeometry setOrientation: orientation fromCosines: c];
}
'''


def pieces(source):
    """The parts of DCMPix.m the program compiles, from either kind of revision."""
    in_swift = CONVERT_MARKER not in source
    common = {
        'CONVERT': '' if in_swift else between(source, CONVERT_MARKER, '-(void) convertPixDoubleX:'),
        # Up to the RT STRUCT methods, or to where they were before they moved to Swift.
        'DOSE': between(source, '- (void) computeTotalDoseCorrected',
                        '#ifndef OSIRIX_LIGHT\n- (void)createROIsFromRTSTRUCT' if '#ifndef OSIRIX_LIGHT\n- (void)createROIsFromRTSTRUCT' in source
                        else '// The ROIs of an RT STRUCT are made in DCMPix+RTStruct.swift.'),
        'INITPARAMETERS': between(source, '- (void) initParameters', '- (id) initwithdata'),
        'INITEMPTY': between(source, '-(id) myinitEmpty', '-(void) setArrayPix'),
        'ORIENTATION': SWIFT_ORIENTATION if in_swift else between(source, '-(void) setOrientationDouble:(double*) c',
                                                                    '-(void) setOrientation:(float*) c'),
        'SLICELOCATION': between(source, '- (void) computeSliceLocation', '- (double) sliceThickness'),
    }
    if is_objc(source):
        common['READING'] = (between(source, 'static id horosNumberValue', '- (void) dcmFrameworkLoad0x0018:')
                             + between(source, '- (void) dcmFrameworkLoad0x0018:',
                                       '#ifndef OSIRIX_LIGHT\n#ifndef DECOMPRESS_APP\n// The table the object carries'))
        common['IDENTIFY'] = between(source, '    self.SOPClassUID = horosStringValue(', '    short maxFrame = 1;')
        common['READ'] = between(source, '        pixelSpacingX = 0;\n        pixelSpacingY = 0;\n',
                                 '        [self computeSliceLocation];\n', include_end=True)
        common['CATEGORY'] = ''
        common['SETTLE'] = between(source, '        if( pixelSpacingY != 0)\n        {\n            if( fabs(pixelSpacingX) / fabs(pixelSpacingY) > 10000',
                                   '            pixelRatio = pixelSpacingY / pixelSpacingX;\n        }\n', include_end=True)
    else:
        common['READING'] = between(source, MODULE_MARKER, '#pragma mark *end of image attributes')
        start = source.index('@interface DCMObject (IsiXDICOMAttributeSource)')
        implementation = source.index('@implementation DCMObject (IsiXDICOMAttributeSource)', start)
        common['CATEGORY'] = source[start:source.index('\n@end\n', implementation) + len('\n@end\n')]
        common['IDENTIFY'] = '    [self readImageIdentificationFrom: dcmObject];\n'
        common['READ'] = '        [self readImageAttributesFrom: dcmObject];\n'
        start = source.rindex('\n', 0, source.index('[IsiXImagePlaneGeometry settlePixelSpacingX:')) + 1
        common['SETTLE'] = source[start:source.index(';', start) + 1] + '\n'
    return common


PROGRAM = r'''
#import <Cocoa/Cocoa.h>
#import "DCMPix.h"
#import "DCMUSRegion.h"
#include <math.h>
MODULE_IMPORT

#define OsirixDicomImageSizeUnknown INT_MAX

static NSMutableArray *harnessStoredSizes, *harnessLoggedExceptions;

// --- the parsed object, its attributes and its date type, from JSON ---------
@interface DCMAttribute : NSObject { @public NSArray *values; }
- (id) value;
- (NSArray*) values;
@end
@implementation DCMAttribute
- (id) value { return values.count ? values[0] : nil; }
- (NSArray*) values { return values; }
@end

@interface DCMSequenceAttribute : DCMAttribute { @public NSArray *items; }
- (NSArray*) sequence;
@end
@implementation DCMSequenceAttribute
- (NSArray*) sequence { return [NSMutableArray arrayWithArray: items]; }
- (id) value { return items.count ? items[0] : nil; }
- (NSArray*) values { return items; }
@end

@interface DCMObject : NSObject { @public NSMutableDictionary *attributes; }
- (id) attributeValueWithName:(NSString*) name;
- (NSArray*) attributeArrayWithName:(NSString*) name;
- (id) attributeValueForKey:(NSString*) key;
- (NSArray*) attributeArrayForKey:(NSString*) key;
- (DCMAttribute*) attributeWithName:(NSString*) name;
@end
@implementation DCMObject
- (DCMAttribute*) attributeWithName:(NSString*) name { return attributes[name]; }
- (id) attributeValueWithName:(NSString*) name { return [attributes[name] value]; }
- (NSArray*) attributeArrayWithName:(NSString*) name { return [attributes[name] values]; }
- (id) attributeValueForKey:(NSString*) key { return [attributes[key] value]; }
- (NSArray*) attributeArrayForKey:(NSString*) key { return [attributes[key] values]; }
- (NSString*) description { return @"<DCMObject>"; }
@end

@interface DCMCalendarDate : NSObject { @public NSString *date, *time, *dateTime; }
+ (id) dicomDateTime:(NSString*) string;
- (NSString*) dateString;
- (NSString*) timeString;
@end
@implementation DCMCalendarDate
+ (id) dicomDateTime:(NSString*) string { DCMCalendarDate *d = [[DCMCalendarDate new] autorelease]; d->dateTime = [string copy]; return d; }
- (NSString*) dateString { return date; }
- (NSString*) timeString { return time; }
- (NSTimeInterval) seconds
{
    NSString *digits = [dateTime stringByPaddingToLength: 14 withString: @"0" startingAtIndex: 0];
    NSDateComponents *c = [NSDateComponents new];
    c.year = [[digits substringWithRange: NSMakeRange(0, 4)] intValue];
    c.month = [[digits substringWithRange: NSMakeRange(4, 2)] intValue];
    c.day = [[digits substringWithRange: NSMakeRange(6, 2)] intValue];
    c.hour = [[digits substringWithRange: NSMakeRange(8, 2)] intValue];
    c.minute = [[digits substringWithRange: NSMakeRange(10, 2)] intValue];
    c.second = [[digits substringWithRange: NSMakeRange(12, 2)] intValue];
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier: NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT: 0];
    NSTimeInterval t = [[calendar dateFromComponents: c] timeIntervalSinceReferenceDate];
    [c release];
    NSRange dot = [dateTime rangeOfString: @"."];
    if (dot.location != NSNotFound) t += [[@"0" stringByAppendingString: [dateTime substringFromIndex: dot.location]] doubleValue];
    return t;
}
- (NSTimeInterval) timeIntervalSinceDate:(DCMCalendarDate*) other { return [self seconds] - [other seconds]; }
// What a date answers when Swift reads it as a Date: the dose correction in
// the module reads the injection and acquisition times that way.
- (NSTimeInterval) timeIntervalSinceReferenceDate { return [self seconds]; }
- (NSString*) description { return dateTime ?: [NSString stringWithFormat: @"%@/%@", date, time]; }
@end

static id parsedValue(id json);

static DCMObject *dataset(NSDictionary *json)
{
    DCMObject *object = [DCMObject new];
    object->attributes = [NSMutableDictionary new];
    for (NSString *name in json)
    {
        id value = json[name];
        if ([value isKindOfClass: [NSDictionary class]] && value[@"seq"])
        {
            DCMSequenceAttribute *sequence = [DCMSequenceAttribute new];
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *item in value[@"seq"]) [items addObject: [dataset(item) autorelease]];
            sequence->items = [items retain];
            object->attributes[name] = sequence;
        }
        else
        {
            DCMAttribute *attribute = [DCMAttribute new];
            NSMutableArray *values = [NSMutableArray array];
            for (id element in ([value isKindOfClass: [NSArray class]] ? value : @[value]))
                [values addObject: parsedValue(element)];
            attribute->values = [values retain];
            object->attributes[name] = attribute;
        }
    }
    return object;
}

static id parsedValue(id json)
{
    if ([json isKindOfClass: [NSDictionary class]])
    {
        if (json[@"bytes"])
        {
            NSMutableData *data = [NSMutableData data];
            NSString *hex = json[@"bytes"];
            for (NSUInteger i = 0; i + 1 < hex.length; i += 2)
            {
                unsigned int byte = 0;
                [[NSScanner scannerWithString: [hex substringWithRange: NSMakeRange(i, 2)]] scanHexInt: &byte];
                unsigned char b = byte;
                [data appendBytes: &b length: 1];
            }
            return data;
        }
        if (json[@"date"] || json[@"time"])
        {
            DCMCalendarDate *d = [[DCMCalendarDate new] autorelease];
            d->date = [json[@"date"] copy];
            d->time = [json[@"time"] copy];
            return d;
        }
        if (json[@"double"]) return [NSNumber numberWithDouble: [json[@"double"] doubleValue]];
    }
    return json;
}

// --- what DCMPix.m finds around the reading --------------------------------
static void DCMPixStoreSizeInDatabase(NSManagedObjectID *imageID, NSDictionary *size)
{
    if (size.count == 0) return;
    [harnessStoredSizes addObject: size];
}
static void N2LogExceptionWithStackTrace(NSException *e) { [harnessLoggedExceptions addObject: e.name]; }
#define N2LogStackTrace(...) NSLog(__VA_ARGS__)

BOOL gUseShutter = NO;
int gSUVAcquisitionTimeField = 0;
static const int maxNumberOfOverlays = 16;
static NSMutableDictionary *cachedDCMTKFileFormat = nil;
static NSMutableDictionary *cachedParsedDICOMFiles = nil;

CATEGORY

@implementation DCMPix
@synthesize frameNo, SOPClassUID, frameofReferenceUID, slope, offset, isRGB, pixelRatio, isOriginDefined;
@synthesize shutterEnabled, shutterRect, imageType, repetitiontime, echotime, flipAngle, laterality;
@synthesize viewPosition, patientPosition, srcFile = _srcFile, usRegions, philipsFactor, patientsWeight;
@synthesize halflife, radionuclideTotalDose, radionuclideTotalDoseCorrected, acquisitionTime, rescaleType;
@synthesize radiopharmaceuticalStartTime, decayFactor, units, decayCorrection, referencedSOPInstanceUID, checking;

+ (void) checkUserDefaults:(BOOL) update {}
// Where a revision writes the size back by the class method of DCMPix+Database.swift.
+ (void) storeSize:(NSDictionary*) size inDatabaseForImageID:(NSManagedObjectID*) imageID { DCMPixStoreSizeInDatabase(imageID, size); }
- (void) CheckLoad {}
- (long) pwidth { return width; }
- (long) pheight { return height; }

READING
CONVERT
DOSE
INITPARAMETERS
INITEMPTY
ORIENTATION
SLICELOCATION

- (void) harnessContext:(NSDictionary*) context
{
    frameNo = [context[@"frame"] longValue];
    numberOfFrames = [context[@"numberOfFrames"] intValue];
    savedHeightInDB = [context[@"savedHeight"] intValue];
    savedWidthInDB = [context[@"savedWidth"] intValue];
    static float externalBuffer[4];
    fExternalOwnedImage = [context[@"external"] boolValue] ? externalBuffer : NULL;
    gUseShutter = [context[@"useShutter"] boolValue];
    gSUVAcquisitionTimeField = [context[@"suvField"] intValue];
    self.srcFile = @"/fixtures/attribute-reading.dcm";
}

- (NSString*) harnessRead:(DCMObject*) dcmObject
{
IDENTIFY
    short maxFrame = 1;
    short imageNb = frameNo;
    (void) maxFrame; (void) imageNb;
    @try
    {
READ
    }
    @catch (NSException *e)
    {
        return e.name;
    }
    return nil;
}

- (void) harnessSettle
{
SETTLE
}

- (void) harnessSetOrientation:(double*) c { [self setOrientationDouble: c]; }
- (void) harnessComputeSliceLocation { [self computeSliceLocation]; }
- (void) harnessOrientation:(double*) o { for (int i = 0; i < 9; i++) o[i] = orientation[i]; }
- (void) harnessSetGeometry:(NSArray*) values
{
    for (int i = 0; i < 9; i++) orientation[i] = [values[i] doubleValue];
    originX = [values[9] doubleValue]; originY = [values[10] doubleValue]; originZ = [values[11] doubleValue];
    pixelSpacingX = [values[12] doubleValue]; pixelSpacingY = [values[13] doubleValue];
    width = [values[14] longValue]; height = [values[15] longValue];
    sliceLocation = -12345.0;
}
- (void) harnessSetSpacing:(NSArray*) values
{
    pixelSpacingX = [values[0] doubleValue]; pixelSpacingY = [values[1] doubleValue];
    pixelRatio = [values[2] doubleValue]; estimatedRadiographicMagnificationFactor = [values[3] doubleValue];
}

static NSString *hexd(double v) { return [NSString stringWithFormat: @"%a", v]; }
static NSString *hexf(float v) { return [NSString stringWithFormat: @"%a", (double) v]; }
static id orNull(id v) { return v ? [v description] : [NSNull null]; }

- (NSDictionary*) harnessDump
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSMutableArray *o = [NSMutableArray array];
    for (int i = 0; i < 9; i++) [o addObject: hexd(orientation[i])];
    d[@"orientation"] = o;
    d[@"origin"] = @[hexd(originX), hexd(originY), hexd(originZ)];
    d[@"isOriginDefined"] = @(isOriginDefined);
    d[@"spacing"] = @[hexd(pixelSpacingX), hexd(pixelSpacingY), hexd(pixelRatio), hexd(estimatedRadiographicMagnificationFactor)];
    d[@"spacingFromUltrasoundRegions"] = @(pixelSpacingFromUltrasoundRegions);
    d[@"slice"] = @[hexd(sliceThickness), hexd(spacingBetweenSlices), hexd(sliceLocation)];
    d[@"pixels"] = @[@(fIsSigned), @(bitsAllocated), @(bitsStored), @(width), @(height), @(fPlanarConf), @(isRGB)];
    d[@"rescale"] = @[hexf(slope), hexf(offset), orNull(rescaleType)];
    d[@"window"] = @[hexf(savedWL), hexf(savedWW)];
    d[@"text"] = @[orNull(imageType), orNull(SOPClassUID), orNull(referencedSOPInstanceUID), orNull(frameofReferenceUID),
                   orNull(repetitiontime), orNull(echotime), orNull(flipAngle), orNull(viewPosition), orNull(patientPosition),
                   orNull(laterality), orNull(units), orNull(decayCorrection)];
    d[@"angles"] = @[orNull(positionerPrimaryAngle), orNull(positionerSecondaryAngle),
                     positionerPrimaryAngle ? NSStringFromClass([positionerPrimaryAngle class]) : @"nil"];
    d[@"cineRate"] = hexf(cineRate);
    d[@"referenceCoordinates"] = @[hexf(referenceCoordinates[0]), hexf(referenceCoordinates[1]), hexf(referenceCoordinates[2]), hexf(referenceCoordinates[3])];
    d[@"shutter"] = @[@(shutterEnabled), NSStringFromRect(shutterRect), NSStringFromPoint(shutterCircular), @(shutterCircular_radius)];
    NSMutableArray *polygon = [NSMutableArray array];
    for (long i = 0; i < shutterPolygonalSize; i++) [polygon addObject: NSStringFromPoint(shutterPolygonal[i])];
    d[@"polygon"] = polygon;
    NSMutableArray *regions = [NSMutableArray array];
    for (DCMUSRegion *r in usRegions)
        [regions addObject: [[r dictionaryWithValuesForKeys: @[@"regionSpatialFormat", @"regionDataType", @"regionFlags",
            @"regionLocationMinX0", @"regionLocationMinY0", @"regionLocationMaxX1", @"regionLocationMaxY1",
            @"referencePixelX0", @"isReferencePixelX0Present", @"referencePixelY0", @"isReferencePixelY0Present",
            @"physicalUnitsXDirection", @"physicalUnitsYDirection", @"refPixelPhysicalValueX", @"refPixelPhysicalValueY",
            @"physicalDeltaX", @"physicalDeltaY", @"dopplerCorrectionAngle"]] description]];
    d[@"usRegions"] = usRegions ? regions : (id)[NSNull null];
    d[@"suv"] = @[hexf(patientsWeight), hexf(decayFactor), hexf(radionuclideTotalDose), hexf(radionuclideTotalDoseCorrected),
                  hexf(halflife), hexf(philipsFactor), orNull(radiopharmaceuticalStartTime), orNull(acquisitionTime)];
    NSMutableArray *overlays = [NSMutableArray array];
    for (int i = 0; i < 16; i++)
    {
        NSMutableString *bitmap = [NSMutableString string];
        if (oData[i] && oRows[i] > 0 && oColumns[i] > 0)
            for (long p = 0; p < (long) oRows[i] * oColumns[i]; p++) if (oData[i][p]) [bitmap appendFormat: @"%ld,", p];
        [overlays addObject: @[@(overlaysChannelON[i]), @(oRows[i]), @(oColumns[i]), @(oType[i]), @(oOrigin[i][0]), @(oOrigin[i][1]),
                               @(oBits[i]), @(oBitPosition[i]), oData[i] ? bitmap : @"none"]];
    }
    d[@"overlays"] = overlays;
    return d;
}
@end

int main(int argc, const char **argv) { @autoreleasepool {
    harnessStoredSizes = [NSMutableArray new];
    harnessLoggedExceptions = [NSMutableArray new];
    NSData *input = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: argv[1]]];
    NSDictionary *fixtures = [NSJSONSerialization JSONObjectWithData: input options: 0 error: nil];
    for (NSDictionary *fixture in fixtures[@"fixtures"])
    {
        DCMPix *pix = [[DCMPix alloc] init];
        [pix initParameters];
        [pix harnessContext: fixture[@"context"] ?: @{}];
        int step = 0;
        for (NSDictionary *json in fixture[@"datasets"])
        {
            [harnessStoredSizes removeAllObjects];
            [harnessLoggedExceptions removeAllObjects];
            fprintf(stderr, "=== %s %d\n", [fixture[@"name"] UTF8String], step);
            DCMObject *object = dataset(json);
            NSString *raised = [pix harnessRead: object];
            if (raised == nil && [fixture[@"settle"] boolValue]) [pix harnessSettle];
            NSMutableDictionary *dump = [[[pix harnessDump] mutableCopy] autorelease];
            dump[@"raised"] = raised ?: (id)[NSNull null];
            dump[@"storedSizes"] = [[harnessStoredSizes copy] autorelease];
            dump[@"loggedExceptions"] = [[harnessLoggedExceptions copy] autorelease];
            NSData *line = [NSJSONSerialization dataWithJSONObject: @{@"fixture": fixture[@"name"], @"step": @(step), @"state": dump}
                                                           options: NSJSONWritingSortedKeys error: nil];
            printf("%s\n", [[[[NSString alloc] initWithData: line encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
            [object release];
            step++;
        }
        [pix release];
    }

    // Fresh objects, as the two initialisers leave them.
    {
        DCMPix *pix = [[DCMPix alloc] init];
        [pix initParameters];
        printf("init %s\n", [[[pix harnessDump][@"orientation"] componentsJoinedByString: @","] UTF8String]);
        DCMPix *empty = [[DCMPix alloc] myinitEmpty];
        printf("empty %s\n", [[[empty harnessDump][@"orientation"] componentsJoinedByString: @","] UTF8String]);
    }

    // Plane arithmetic on deterministic pseudo-random geometries.
    srand48(1412);
    for (int n = 0; n < 2000; n++)
    {
        DCMPix *pix = [[DCMPix alloc] init];
        double c[6];
        for (int i = 0; i < 6; i++) c[i] = (drand48() - 0.5) * (n % 7 == 0 ? 0 : (n % 5 == 0 ? 1e-3 : 4));
        [pix harnessSetOrientation: c];
        NSArray *o = [pix harnessDump][@"orientation"];
        double normalized[9];
        [pix harnessOrientation: normalized];
        NSMutableArray *geometry = [NSMutableArray array];
        for (int i = 0; i < 9; i++) [geometry addObject: @(n % 11 == 0 ? 0 : normalized[i])];
        [geometry addObjectsFromArray: @[@((drand48() - 0.5) * 500), @((drand48() - 0.5) * 500), @((drand48() - 0.5) * 500),
                                         @(drand48() * 2 + 0.01), @(drand48() * 2 + 0.01), @(1 + lrand48() % 1024), @(1 + lrand48() % 1024)]];
        [pix harnessSetGeometry: geometry];
        [pix harnessComputeSliceLocation];
        NSArray *spacing = @[@((drand48() - 0.5) * (n % 3 ? 2 : 2e5)), @((drand48() - 0.5) * 2), @(drand48()), @(n % 4 ? 0 : drand48() + 0.5)];
        [pix harnessSetSpacing: spacing];
        [pix harnessSettle];
        NSDictionary *dump = [pix harnessDump];
        printf("geometry %d %s %s %s\n", n, [[o componentsJoinedByString: @","] UTF8String],
               [[dump[@"slice"] componentsJoinedByString: @","] UTF8String], [[dump[@"spacing"] componentsJoinedByString: @","] UTF8String]);
        [pix release];
    }
    return 0;
} }
'''


def former_region(work):
    """DCMUSRegion.h and .m of the last revision that has them, in work/former-region:
    the class the Objective-C DCMPix filled, now UltrasoundRegion of IsiXImaging."""
    folder = Path(work) / 'former-region'
    if (folder / 'DCMUSRegion.m').is_file():
        return folder
    import history_reference
    path = 'Horos/Sources/DCMUSRegion.m'
    revision = history_reference.before_removal(path)
    if revision is None and (ROOT / path).is_file():
        folder.mkdir(parents=True, exist_ok=True)
        for name in ('DCMUSRegion.h', 'DCMUSRegion.m'):
            (folder / name).write_bytes((ROOT / 'Horos/Sources' / name).read_bytes())
        return folder
    if revision is None:
        try:
            revision = 'HEAD'
            history_reference.show(revision, path)
        except subprocess.CalledProcessError:
            return None
    folder.mkdir(parents=True, exist_ok=True)
    for name in ('DCMUSRegion.h', 'DCMUSRegion.m'):
        (folder / name).write_bytes(history_reference.show(revision, 'Horos/Sources/' + name))
    return folder


def compile_revision(source, work, name, module_folder=None, header=None):
    """The program for one revision of DCMPix.m; None, with the compiler's reason, when it does not build."""
    work = Path(work)
    text = PROGRAM
    for key, value in pieces(source).items():
        text = text.replace('\n' + key + '\n', '\n' + value + '\n')
    module = not is_objc(source)
    text = text.replace('MODULE_IMPORT', '#import "IsiXImaging-Swift.h"' if module else '')
    program = work / (name + '.m')
    program.write_text(text, encoding='latin1')
    # The class's header of the revision, which declares the instance variables
    # its methods use; the header of a Swift class has none.
    include = []
    if header is not None:
        (work / (name + '-headers')).mkdir(exist_ok=True)
        (work / (name + '-headers') / 'DCMPix.h').write_bytes(header)
        include = ['-I', str(work / (name + '-headers'))]
    # Warnings are about the stand-ins, not about the code under test.
    region_folder = former_region(work)
    if region_folder is None:
        return None, 'no revision of this history has DCMUSRegion.m, which this Objective-C reference uses'
    flags = ['-fno-objc-arc', '-DOSIRIX_VIEWER', '-w', *include, '-I', str(region_folder), '-I', str(ROOT / 'Horos/Sources')]
    objects = [work / (name + '.o'), work / (name + '-region.o')]
    built = subprocess.run(['xcrun', 'clang', '-c', '-Os', *flags, *(['-I', str(module_folder)] if module else []),
                            str(program), '-o', str(objects[0])], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr
    built = subprocess.run(['xcrun', 'clang', '-c', '-Os', '-fno-objc-arc', '-I', str(region_folder),
                            str(region_folder / 'DCMUSRegion.m'), '-o', str(objects[1])], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr
    binary = work / name
    if module:
        link = ['xcrun', 'swiftc', *map(str, objects), str(Path(module_folder) / 'libIsiXImaging.a'),
                '-framework', 'Cocoa', '-o', str(binary)]
    else:
        link = ['xcrun', 'clang', *map(str, objects), '-framework', 'Cocoa', '-o', str(binary)]
    built = subprocess.run(link, capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr
    return binary, ''


def swift_class_pieces():
    """The parts of the Swift class the program compiles, as they stand: the
    reading of DCMPix+ImageAttributes.swift, the parameters a new object starts
    with and those of an empty one, the slice location, the orientation, the dose
    correction and the spacing settled after the reading (DCMPix.swift,
    DCMPix+Geometry.swift, DCMPix+SUV.swift, DCMPix+Loading.swift), and the
    attribute source category of the parser."""
    sources = ROOT / 'Horos/Sources'
    pix = (sources / 'DCMPix.swift').read_text(encoding='utf-8')
    attributes = (sources / 'DCMPix+ImageAttributes.swift').read_text(encoding='utf-8')
    geometry = (sources / 'DCMPix+Geometry.swift').read_text(encoding='utf-8')
    suv = (sources / 'DCMPix+SUV.swift').read_text(encoding='utf-8')
    loading = (sources / 'DCMPix+Loading.swift').read_text(encoding='utf-8')
    empty = between(pix, '        guard let fresh = sendInit() else { return nil }\n', '        return fresh\n').split('\n', 1)[1]
    settle = loading.index('ImagePlaneGeometryFunctions.settlePixelSpacing(')
    methods = (between(attributes, 'extension DCMPix {\n', '\nextension DCMObject {')[len('extension DCMPix {\n'):]
               .rsplit('\n}\n', 1)[0] + '\n'
               + between(pix, '    final func initParameters() {', '\n    }\n', include_end=True)
               + between(pix, '    func computeSliceLocation() {', '\n    }\n', include_end=True)
               + between(geometry, '    public dynamic func setOrientationDouble(', '\n    }\n', include_end=True)
               + between(suv, '    final func correctTotalDose() {', '\n    }\n', include_end=True)
               + '    func computeTotalDoseCorrected() { correctTotalDose() }\n'
               + '    func harnessEmpty(_ fresh: DCMPix) {\n' + empty + '    }\n'
               + '    func harnessSettle() {\n        ' + loading[settle:loading.index(')', loading.index('magnification:', settle)) + 1]
               + '\n    }\n')
    used = set(re.findall(r'\bhoros_\w+', methods + SWIFT_ATTRIBUTE_PROGRAM))
    storage = ''.join(line + '\n' for line in pix.splitlines()
                      if (m := re.match(r'\s*final (?:unowned\(unsafe\) )?(?:var|let) (horos_\w+)\b', line)) and m.group(1) in used)
    return {
        'ARRAYS': between(pix, 'struct DCMPixArrays {', '\n}\n', include_end=True),
        'SOURCE': stand_in_source(attributes),
        'STORAGE': storage,
        'METHODS': methods,
        'CATEGORY': STAND_IN_ATTRIBUTE_SOURCE,
    }


# What the Swift class's reading finds around it, and the harness of PROGRAM in
# Swift: the same steps, dumped the same way.
SWIFT_ATTRIBUTE_PROGRAM = r'''
import Cocoa
import CoreData
import IsiXImaging

// The DICOM date type of IsiXDICOMFile, played by the program's stand-in.
typealias DICOMCalendarDate = DCMCalendarDate

var harnessStoredSizes: [NSDictionary] = []
var harnessLoggedExceptions: [String] = []

func _N2LogExceptionImpl(_ exception: NSException, _ trace: Bool, _ where_: String) {
    harnessLoggedExceptions.append(exception.name.rawValue)
}

enum DCMPixSettings {
    nonisolated(unsafe) static var useShutter = false
    nonisolated(unsafe) static var suvAcquisitionTimeField: Int32 = 0
}

ARRAYS

SOURCE

final class DCMPix: NSObject {
STORAGE
    var srcFile: String!
    var rescaleType: String!
    var sopClassUID: String!
    var referencedSOPInstanceUID: String!
    var imageType: String!
    var frameofReferenceUID: String!

    class func checkUserDefaults(_ update: Bool) {}
    class func storeSize(_ size: NSDictionary, inDatabaseForImageID imageID: NSManagedObjectID?) {
        if size.count == 0 { return }
        harnessStoredSizes.append(size)
    }

METHODS

    func harnessContext(_ context: [String: Any]) {
        func number(_ key: String) -> NSNumber? { context[key] as? NSNumber }
        horos_frameNo = number("frame")?.intValue ?? 0
        horos_numberOfFrames = number("numberOfFrames")?.int32Value ?? 0
        horos_savedHeightInDB = number("savedHeight")?.int32Value ?? 0
        horos_savedWidthInDB = number("savedWidth")?.int32Value ?? 0
        horos_fExternalOwnedImage = (number("external")?.boolValue ?? false) ? harnessExternal : nil
        DCMPixSettings.useShutter = number("useShutter")?.boolValue ?? false
        DCMPixSettings.suvAcquisitionTimeField = number("suvField")?.int32Value ?? 0
        srcFile = "/fixtures/attribute-reading.dcm"
    }

    func harnessRead(_ dcmObject: DCMObject) -> String? {
        var raised: NSException?
        if let exception = harnessTry({
            self.readImageIdentification(from: dcmObject)
            raised = self.readImageAttributes(from: dcmObject)
        }) { return exception.name.rawValue }
        return raised?.name.rawValue
    }

    func harnessSetGeometry(_ values: [Double]) {
        for i in 0..<9 { horos_arrays.orientation[i] = values[i] }
        horos_originX = values[9]; horos_originY = values[10]; horos_originZ = values[11]
        horos_pixelSpacingX = values[12]; horos_pixelSpacingY = values[13]
        horos_width = Int(values[14]); horos_height = Int(values[15])
        horos_sliceLocation = -12345.0
    }

    func harnessSetSpacing(_ values: [Double]) {
        horos_pixelSpacingX = values[0]; horos_pixelSpacingY = values[1]
        horos_pixelRatio = values[2]; horos_estimatedRadiographicMagnificationFactor = values[3]
    }

    func harnessDump() -> [String: Any] {
        func hexd(_ v: Double) -> String { String(format: "%a", v) }
        func hexf(_ v: Float) -> String { String(format: "%a", Double(v)) }
        func orNull(_ v: Any?) -> Any { v.map { ($0 as AnyObject).description as String } ?? NSNull() }
        func n(_ v: Bool) -> NSNumber { NSNumber(value: v) }
        let a = horos_arrays
        var d: [String: Any] = [:]
        d["orientation"] = (0..<9).map { hexd(a.orientation[$0]) }
        d["origin"] = [hexd(horos_originX), hexd(horos_originY), hexd(horos_originZ)]
        d["isOriginDefined"] = n(horos_isOriginDefined)
        d["spacing"] = [hexd(horos_pixelSpacingX), hexd(horos_pixelSpacingY), hexd(horos_pixelRatio),
                        hexd(horos_estimatedRadiographicMagnificationFactor)]
        d["spacingFromUltrasoundRegions"] = n(horos_pixelSpacingFromUltrasoundRegions)
        d["slice"] = [hexd(horos_sliceThickness), hexd(horos_spacingBetweenSlices), hexd(horos_sliceLocation)]
        d["pixels"] = [n(horos_fIsSigned), NSNumber(value: horos_bitsAllocated), NSNumber(value: horos_bitsStored),
                       NSNumber(value: horos_width), NSNumber(value: horos_height), NSNumber(value: horos_fPlanarConf), n(horos_isRGB)]
        d["rescale"] = [hexf(horos_slope), hexf(horos_offset), orNull(rescaleType as NSString?)]
        d["window"] = [hexf(horos_savedWL), hexf(horos_savedWW)]
        d["text"] = [orNull(imageType as NSString?), orNull(sopClassUID as NSString?), orNull(referencedSOPInstanceUID as NSString?),
                     orNull(frameofReferenceUID as NSString?), orNull(horos_repetitiontime), orNull(horos_echotime),
                     orNull(horos_flipAngle), orNull(horos_viewPosition), orNull(horos_patientPosition), orNull(horos_laterality),
                     orNull(horos_units), orNull(horos_decayCorrection)]
        d["angles"] = [orNull(horos_positionerPrimaryAngle), orNull(horos_positionerSecondaryAngle),
                       horos_positionerPrimaryAngle.map { NSStringFromClass(type(of: $0)) } ?? "nil"]
        d["cineRate"] = hexf(horos_cineRate)
        d["referenceCoordinates"] = (0..<4).map { hexf(a.referenceCoordinates[$0]) }
        d["shutter"] = [n(horos_shutterEnabled), NSStringFromRect(horos_shutterRect), NSStringFromPoint(horos_shutterCircular),
                        NSNumber(value: horos_shutterCircular_radius)]
        d["polygon"] = (0..<horos_shutterPolygonalSize).map { NSStringFromPoint(horos_shutterPolygonal![$0]) }
        d["usRegions"] = horos_usRegions.map { regions in regions.map { harnessRegionDescription($0) } } ?? NSNull()
        d["suv"] = [hexf(horos_patientsWeight), hexf(horos_decayFactor), hexf(horos_radionuclideTotalDose),
                    hexf(horos_radionuclideTotalDoseCorrected), hexf(horos_halflife), hexf(horos_philipsFactor),
                    orNull(horos_radiopharmaceuticalStartTime), orNull(horos_acquisitionTime)]
        var overlays: [Any] = []
        for i in 0..<16 {
            var bitmap = ""
            if let data = a.overlayData[i], a.overlayRows[i] > 0, a.overlayColumns[i] > 0 {
                for p in 0..<(Int(a.overlayRows[i]) * Int(a.overlayColumns[i])) where data[p] != 0 { bitmap += "\(p)," }
            }
            overlays.append([n(a.overlayOn[i]), NSNumber(value: a.overlayRows[i]), NSNumber(value: a.overlayColumns[i]),
                             NSNumber(value: a.overlayType[i]), NSNumber(value: a.overlayOrigin[2 * i]),
                             NSNumber(value: a.overlayOrigin[2 * i + 1]), NSNumber(value: a.overlayBits[i]),
                             NSNumber(value: a.overlayBitPosition[i]), a.overlayData[i] != nil ? bitmap : "none"])
        }
        d["overlays"] = overlays
        return d
    }
}

nonisolated(unsafe) let harnessExternal = UnsafeMutablePointer<Float>.allocate(capacity: 4)

func emit(_ object: Any) {
    let line = try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    print(String(data: line, encoding: .utf8)!)
}

let input = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let root = try! JSONSerialization.jsonObject(with: input) as! [String: Any]
for fixture in root["fixtures"] as! [[String: Any]] {
    autoreleasepool {
        let pix = DCMPix()
        pix.initParameters()
        pix.harnessContext(fixture["context"] as? [String: Any] ?? [:])
        for (step, json) in (fixture["datasets"] as! [[String: Any]]).enumerated() {
            harnessStoredSizes.removeAll()
            harnessLoggedExceptions.removeAll()
            FileHandle.standardError.write("=== \(fixture["name"] as! String) \(step)\n".data(using: .utf8)!)
            let object = harnessDataset(json)!
            let raised = pix.harnessRead(object)
            if raised == nil && (fixture["settle"] as? NSNumber)?.boolValue == true { pix.harnessSettle() }
            var dump = pix.harnessDump()
            dump["raised"] = raised ?? NSNull()
            dump["storedSizes"] = harnessStoredSizes
            dump["loggedExceptions"] = harnessLoggedExceptions
            emit(["fixture": fixture["name"]!, "step": step, "state": dump])
        }
    }
}

// Fresh objects, as the two initialisers leave them.
do {
    let pix = DCMPix()
    pix.initParameters()
    print("init " + (pix.harnessDump()["orientation"] as! [String]).joined(separator: ","))
    let empty = DCMPix()
    empty.harnessEmpty(empty)
    print("empty " + (empty.harnessDump()["orientation"] as! [String]).joined(separator: ","))
}

// Plane arithmetic on deterministic pseudo-random geometries.
srand48(1412)
for n in 0..<2000 {
    let pix = DCMPix()
    var c = [Double](repeating: 0, count: 6)
    for i in 0..<6 { c[i] = (drand48() - 0.5) * (n % 7 == 0 ? 0 : (n % 5 == 0 ? 1e-3 : 4)) }
    pix.setOrientationDouble(&c)
    let o = pix.harnessDump()["orientation"] as! [String]
    var geometry = (0..<9).map { n % 11 == 0 ? 0 : pix.horos_arrays.orientation[$0] }
    let more = [(drand48() - 0.5) * 500, (drand48() - 0.5) * 500, (drand48() - 0.5) * 500, drand48() * 2 + 0.01, drand48() * 2 + 0.01]
    geometry += more
    geometry += [Double(1 + harnessLrand48() % 1024)]
    geometry += [Double(1 + harnessLrand48() % 1024)]
    pix.harnessSetGeometry(geometry)
    pix.computeSliceLocation()
    let spacing = [(drand48() - 0.5) * (n % 3 != 0 ? 2 : 2e5), (drand48() - 0.5) * 2, drand48(), n % 4 != 0 ? 0 : drand48() + 0.5]
    pix.harnessSetSpacing(spacing)
    pix.harnessSettle()
    let dump = pix.harnessDump()
    print("geometry \(n) \(o.joined(separator: ",")) \((dump["slice"] as! [String]).joined(separator: ",")) \((dump["spacing"] as! [String]).joined(separator: ","))")
}
'''

SWIFT_ATTRIBUTE_HEADER = r'''
#import <Cocoa/Cocoa.h>
@interface DCMAttribute : NSObject { @public NSArray *values; }
- (id) value;
- (NSArray*) values;
@end
@interface DCMSequenceAttribute : DCMAttribute { @public NSArray *items; }
- (NSArray*) sequence;
@end
@interface DCMObject : NSObject { @public NSMutableDictionary *attributes; }
- (id) attributeValueWithName:(NSString*) name;
- (NSArray*) attributeArrayWithName:(NSString*) name;
- (id) attributeValueForKey:(NSString*) key;
- (NSArray*) attributeArrayForKey:(NSString*) key;
- (DCMAttribute*) attributeWithName:(NSString*) name;
@end
// A date, as the DICOM framework's is one.
@interface DCMCalendarDate : NSDate { @public NSString *date, *time, *dateTime; }
+ (instancetype) dicomDateTime:(NSString*) string;
@end
DCMObject *harnessDataset(NSDictionary *json);
NSException *harnessTry(void (NS_NOESCAPE ^block)(void));
NSString *harnessRegionDescription(id region);
// lrand48, which Swift does not import.
long harnessLrand48(void);
'''


def compile_swift_class(work, name, module_folder):
    """The program for the Swift class of this checkout; None, with the compiler's reason, when it does not build."""
    import isix_modules
    work = Path(work)
    parts = swift_class_pieces()
    stand_ins = PROGRAM[PROGRAM.index('@interface DCMAttribute : NSObject'):PROGRAM.index('// --- what DCMPix.m finds around the reading')]
    # The header declares the stand-ins; the date is an NSDate, as the framework's is.
    for declared in ('DCMAttribute : NSObject', 'DCMSequenceAttribute : DCMAttribute', 'DCMObject : NSObject',
                     'DCMCalendarDate : NSObject'):
        start = stand_ins.index('@interface ' + declared)
        stand_ins = stand_ins[:start] + stand_ins[stand_ins.index('@end\n', start) + len('@end\n'):]
    stand_ins = stand_ins.replace('@implementation DCMCalendarDate\n',
                                  '@implementation DCMCalendarDate\n'
                                  '- (instancetype) initWithTimeIntervalSinceReferenceDate:(NSTimeInterval) t { return self; }\n')
    objc = ('#import "Harness.h"\n#import "IsiXImaging-Swift.h"\n' + stand_ins + parts['CATEGORY']
            + 'DCMObject *harnessDataset(NSDictionary *json) { return [dataset(json) autorelease]; }\n'
              'NSException *harnessTry(void (NS_NOESCAPE ^block)(void)) { @try { block(); } @catch (NSException *e) { return e; } return nil; }\n'
              'long harnessLrand48(void) { return lrand48(); }\n'
              'NSString *harnessRegionDescription(id r)\n{\n    return [[r dictionaryWithValuesForKeys: @[@"regionSpatialFormat", @"regionDataType", @"regionFlags",\n'
              '        @"regionLocationMinX0", @"regionLocationMinY0", @"regionLocationMaxX1", @"regionLocationMaxY1",\n'
              '        @"referencePixelX0", @"isReferencePixelX0Present", @"referencePixelY0", @"isReferencePixelY0Present",\n'
              '        @"physicalUnitsXDirection", @"physicalUnitsYDirection", @"refPixelPhysicalValueX", @"refPixelPhysicalValueY",\n'
              '        @"physicalDeltaX", @"physicalDeltaY", @"dopplerCorrectionAngle"]] description];\n}\n')
    (work / 'Harness.h').write_text(SWIFT_ATTRIBUTE_HEADER)
    (work / (name + '-standins.m')).write_text(objc, encoding='latin1')
    program = SWIFT_ATTRIBUTE_PROGRAM
    for key in ('ARRAYS', 'SOURCE', 'STORAGE', 'METHODS'):
        program = program.replace('\n' + key + '\n', '\n' + parts[key] + '\n')
    (work / (name + '.swift')).write_text(program)
    # The regions are the module's UltrasoundRegion.
    objects = [work / (name + '-standins.o')]
    for source, obj in ((work / (name + '-standins.m'), objects[0]),):
        built = subprocess.run(['xcrun', 'clang', '-c', '-Os', '-fno-objc-arc', '-w', '-I', str(work), '-I', str(ROOT / 'Horos/Sources'),
                                '-I', str(module_folder), str(source), '-o', str(obj)], capture_output=True, text=True)
        if built.returncode != 0:
            return None, built.stderr
    binary = work / name
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-Onone', *isix_modules.module_flags('IsiXImaging', module_folder),
                            '-Xcc', '-I', '-Xcc', str(ROOT / 'Horos/Sources'), '-import-objc-header', str(work / 'Harness.h'),
                            str(work / (name + '.swift')), *map(str, objects), '-framework', 'Cocoa', '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stdout + built.stderr
    return binary, ''


LOG_PREFIX = re.compile(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+(?:[+-]\d{4})? \S+\[\d+:\d+\] ')


def run(binary, fixtures, work):
    """The states, the geometry lines and the log lines of one program on the fixtures."""
    work = Path(work)
    path = work / 'fixtures.json'
    path.write_text(json.dumps({'fixtures': fixtures}))
    ran = subprocess.run([str(binary), str(path)], capture_output=True, text=True, timeout=600)
    if ran.returncode != 0:
        raise RuntimeError(f'{binary.name} exited {ran.returncode}: {ran.stderr[-2000:]}')
    states, other = [], []
    for line in ran.stdout.splitlines():
        if line.startswith('{'):
            states.append(json.loads(line))
        else:
            other.append(line)
    logs = [LOG_PREFIX.sub('', line) for line in ran.stderr.splitlines()]
    # An exception's reason names the instance's address, which differs run to run.
    logs = [re.sub(r'0x[0-9a-f]+', '0x…', line) for line in logs]
    return states, other, logs
