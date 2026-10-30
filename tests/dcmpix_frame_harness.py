"""Runs the frame loading of one revision of DCMPix.m on synthetic decoded frames.

`tests/test-dcmpix-frame-loading.py` uses this to compare the frame loading the
app does now with the Objective-C loading it replaced, pixel by pixel and bit
by bit. The part of `-[DCMPix loadDICOMWithDCMTK]` that turns a decoded frame
into the image's buffer - photometric interpretation, sign extension, 8 to 16
bits, RGB to ARGB, the modality LUT to float, 32-bit integers, overlays burnt
in, short and empty frames, an object without Pixel Data - is cut out of the
source of a revision and compiled into a small program, with stand-ins for the
parsed object (a dictionary whose Pixel Data hands back the frame's bytes as
the decoder would), the video decoder, the VOI LUT step and the
missing-pixels sentences. Every revision is linked with the IsiXImaging module
built from this checkout, which the attribute reading of both kinds of
revision uses. Once DCMPix itself is Swift, its frame loading
(DCMPix+FrameLoading.swift) is compiled as it stands instead, in a class that
holds the state it reads under the names DCMPix.swift stores it by, over the
same stand-ins (compile_swift_class); a revision of DCMPix.m is then compiled
against its own DCMPix.h, which declares the instance variables it uses.

The program prints one JSON object per fixture: the buffer (floating-point
values as hexadecimal, colour as bytes), the flags the loading sets, the short
frames it reported, the VOI LUT step's input, the exception it raised and the
log lines without their time stamps.
"""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

# The Objective-C frame loading, before it moved to the module.
OBJC_MARKER = '#pragma mark *loading a frame'
# The frame loading that delegates to the module.
MODULE_MARKER = '#pragma mark *frame loading'


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


def pieces(source):
    """The parts of DCMPix.m the program compiles, from either kind of revision."""
    common = {
        'SHORTFRAME': between(source, '- (void) reportShortFrame:(long) carried of:(long) needed', '#ifndef DECOMPRESS_APP\n// Draws the image file'),
        'CATEGORY': source[source.index('@interface DCMObject (IsiXDICOMAttributeSource)'):
                           source.index('\n@end\n', source.index('@implementation DCMObject (IsiXDICOMAttributeSource)')) + len('\n@end\n')],
        'NUMBERVALUE': between(source, 'static id horosNumberValue(', '\n}\n', include_end=True),
    }
    if is_objc(source):
        common['LOAD'] = between(source, '#pragma mark READ PIXEL DATA\n', '        [IsiXImagePlaneGeometry settlePixelSpacingX:')
        common['FRAMEMETHODS'] = ''
    else:
        common['LOAD'] = between(source, '#pragma mark READ PIXEL DATA\n', '        [IsiXImagePlaneGeometry settlePixelSpacingX:')
        common['FRAMEMETHODS'] = between(source, MODULE_MARKER, '#pragma mark *end of frame loading')
    return common


PROGRAM = r'''
#import <Cocoa/Cocoa.h>
#import "DCMPix.h"
#include <math.h>
#import "IsiXImaging-Swift.h"

static NSMutableArray *harnessVOICalls;

// --- the parsed object, its Pixel Data and the decoders, from JSON --------
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
@end

@interface DCMTransferSyntax : NSObject { @public NSString *uid; }
@property(readonly) NSString *transferSyntax;
@end
@implementation DCMTransferSyntax
- (NSString*) transferSyntax { return uid; }
@end

@interface DCMPixelDataAttribute : DCMAttribute { @public NSArray *frames; DCMTransferSyntax *syntax; }
- (NSData*) decodeFrameAtIndex:(int) index;
@property(readonly) DCMTransferSyntax *transferSyntax;
@end
@implementation DCMPixelDataAttribute
- (NSData*) decodeFrameAtIndex:(int) index { return index >= 0 && index < (int) frames.count && [frames[index] length] ? frames[index] : nil; }
- (DCMTransferSyntax*) transferSyntax { return syntax; }
- (id) value { return frames.firstObject ?: [NSData data]; }
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
@end

static NSData *bytes(NSString *hex)
{
    NSMutableData *data = [NSMutableData dataWithLength: hex.length / 2];
    unsigned char *b = data.mutableBytes;
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2)
    {
        unsigned int byte = 0;
        [[NSScanner scannerWithString: [hex substringWithRange: NSMakeRange(i, 2)]] scanHexInt: &byte];
        b[i / 2] = byte;
    }
    return data;
}

static DCMObject *dataset(NSDictionary *json)
{
    DCMObject *object = [DCMObject new];
    object->attributes = [NSMutableDictionary new];
    for (NSString *name in json)
    {
        id value = json[name];
        if ([name isEqualToString: @"PixelData"])
        {
            DCMPixelDataAttribute *pixels = [DCMPixelDataAttribute new];
            NSMutableArray *frames = [NSMutableArray array];
            for (NSString *hex in value[@"frames"])
            {
                NSData *frame = bytes(hex);
                if ([value[@"misaligned"] boolValue] && frame.length)
                {
                    // A frame that starts one byte into a larger buffer, as a
                    // decoder may hand over a range of the element's bytes.
                    NSMutableData *larger = [NSMutableData dataWithLength: frame.length + 1];
                    memcpy((char*) larger.mutableBytes + 1, frame.bytes, frame.length);
                    [larger retain];
                    frame = [NSData dataWithBytesNoCopy: (char*) larger.mutableBytes + 1 length: frame.length freeWhenDone: NO];
                }
                [frames addObject: frame];
            }
            pixels->frames = [frames retain];
            pixels->syntax = [DCMTransferSyntax new];
            pixels->syntax->uid = [value[@"syntax"] ?: @"1.2.840.10008.1.2.1" copy];
            pixels->values = [@[frames.firstObject ?: [NSData data]] retain];
            object->attributes[name] = pixels;
            continue;
        }
        DCMAttribute *attribute = [DCMAttribute new];
        attribute->values = [([value isKindOfClass: [NSArray class]] ? value : @[value]) retain];
        object->attributes[name] = attribute;
    }
    return object;
}

@interface HorosH264StreamDecoder : NSObject
+ (BOOL) isVideoTransferSyntax:(NSString*) syntax;
@end
@implementation HorosH264StreamDecoder
+ (BOOL) isVideoTransferSyntax:(NSString*) syntax { return [syntax hasPrefix: @"1.2.840.10008.1.2.4.10"]; }
@end

@interface HorosMissingPixelsReason : NSObject
@end
@implementation HorosMissingPixelsReason
+ (NSString*) reasonForEmptyFrame:(int) frame { return [NSString stringWithFormat: @"empty frame %d", frame]; }
+ (NSString*) reasonForAbsentPixelData { return @"no pixel data"; }
+ (NSString*) reasonForShortFrame:(long) carried of:(long) needed { return [NSString stringWithFormat: @"short %ld of %ld", carried, needed]; }
@end

static void N2LogExceptionWithStackTrace(NSException *e) { NSLog(@"logged %@", e.name); }
#define N2LogStackTrace(...) NSLog(__VA_ARGS__)

BOOL gUseShutter = NO;
BOOL gDisplayDICOMOverlays = YES;
BOOL gUseVOILUT = NO;
int gSUVAcquisitionTimeField = 0;
static const int maxNumberOfOverlays = 16;

CATEGORY

@implementation DCMPix
@synthesize frameNo, SOPClassUID, frameofReferenceUID, slope, offset, isRGB, pixelRatio, isOriginDefined;
@synthesize shutterEnabled, shutterRect, imageType, repetitiontime, echotime, flipAngle, laterality;
@synthesize viewPosition, patientPosition, srcFile = _srcFile, usRegions, philipsFactor, patientsWeight;
@synthesize halflife, radionuclideTotalDose, radionuclideTotalDoseCorrected, acquisitionTime, rescaleType;
@synthesize radiopharmaceuticalStartTime, decayFactor, units, decayCorrection, referencedSOPInstanceUID, checking;
@synthesize missingPixelsReason;

- (void) CheckLoad {}
- (long) pwidth { return width; }
- (long) pheight { return height; }
- (void) computeSliceLocation
{
    sliceLocation = [IsiXImagePlaneGeometry sliceLocationWithOrientation: orientation originX: originX originY: originY originZ: originZ
                                                                spacingX: pixelSpacingX spacingY: pixelSpacingY width: width height: height current: sliceLocation];
}

// The VOI LUT step stays in the app: here it records what it was handed and
// marks it, so that a difference in when it runs or on what shows.
- (void) applyVOILUTFrom:(DCMObject*) dcmObject to:(unsigned short*) samples
{
    unsigned long sum = 0;
    for (long i = 0; i < width * height; i++) sum = sum * 31 + samples[i];
    [harnessVOICalls addObject: @(sum)];
    for (long i = 0; i < width * height; i++) samples[i] ^= 0x5;
}

- (NSData*) videoFrame:(int) index ofStreamInAttribute:(DCMPixelDataAttribute*) pixelAttr reason:(NSString**) reason
{
    if (pixelAttr->frames.count > 1 && index < (int) pixelAttr->frames.count) return pixelAttr->frames[index];
    if (reason) *reason = @"the video stream cannot be decoded";
    return nil;
}

NUMBERVALUE
SHORTFRAME
FRAMEMETHODS

- (void) harnessState:(NSDictionary*) state
{
    width = [state[@"width"] longValue];
    height = [state[@"height"] longValue];
    bitsAllocated = [state[@"bitsAllocated"] shortValue];
    bitsStored = [state[@"bitsStored"] shortValue];
    fIsSigned = [state[@"isSigned"] boolValue];
    fPlanarConf = [state[@"planar"] longValue];
    slope = state[@"slope"] ? [state[@"slope"] floatValue] : 1;
    offset = [state[@"offset"] floatValue];
    savedWL = [state[@"savedWL"] floatValue];
    savedWW = [state[@"savedWW"] floatValue];
    frameNo = [state[@"frame"] longValue];
    numberOfFrames = [state[@"numberOfFrames"] intValue];
    originZ = [state[@"originZ"] doubleValue];
    orientation[0] = 1; orientation[4] = 1; orientation[8] = 1;
    pixelSpacingX = pixelSpacingY = 1;
    static float external[64 * 64 + 100];
    if ([state[@"external"] boolValue])
    {
        for (int i = 0; i < 64 * 64 + 100; i++) external[i] = -7.5f;
        fExternalOwnedImage = external;
    }
    for (NSDictionary *overlay in state[@"overlays"])
    {
        int i = [overlay[@"index"] intValue];
        overlaysChannelON[i] = YES;
        oRows[i] = [overlay[@"rows"] intValue];
        oColumns[i] = [overlay[@"columns"] intValue];
        oOrigin[i][0] = [overlay[@"x"] intValue];
        oOrigin[i][1] = [overlay[@"y"] intValue];
        oData[i] = calloc(oRows[i] * oColumns[i], 1);
        for (NSNumber *p in overlay[@"set"]) oData[i][p.intValue] = 0xFF;
    }
    self.srcFile = @"/fixtures/frame-loading.dcm";
}

- (NSString*) harnessLoad:(DCMObject*) dcmObject
{
    short maxFrame = 1;
    short imageNb = frameNo;
    (void) maxFrame; (void) imageNb;
    BOOL returnValue = YES;
    @try
    {
LOAD
    }
    @catch (NSException *e)
    {
        return e.name;
    }
    (void) returnValue;
    return nil;
}

static NSString *hexf(float v) { return [NSString stringWithFormat: @"%a", (double) v]; }

- (NSDictionary*) harnessDump
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"flags"] = @[@(isRGB), @(inverseVal), @(bitsAllocated), @(bitsStored), @(fIsSigned), @(fPlanarConf), hexf(wl), hexf(ww)];
    d[@"external"] = @(fImage != nil && fImage == fExternalOwnedImage);
    d[@"originZ"] = [NSString stringWithFormat: @"%a", originZ];
    d[@"reason"] = missingPixelsReason ?: (id)[NSNull null];
    if (fImage == nil) d[@"buffer"] = [NSNull null];
    else if (isRGB)
    {
        NSMutableString *hex = [NSMutableString string];
        unsigned char *b = (unsigned char*) fImage;
        for (long i = 0; i < width * height * 4; i++) [hex appendFormat: @"%02x", b[i]];
        d[@"buffer"] = hex;
    }
    else
    {
        NSMutableArray *values = [NSMutableArray array];
        for (long i = 0; i < width * height; i++) [values addObject: hexf(fImage[i])];
        d[@"buffer"] = values;
    }
    return d;
}
@end

int main(int argc, const char **argv) { @autoreleasepool {
    harnessVOICalls = [NSMutableArray new];
    NSData *input = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: argv[1]]];
    NSArray *fixtures = [NSJSONSerialization JSONObjectWithData: input options: 0 error: nil];
    for (NSDictionary *fixture in fixtures)
    {
        [harnessVOICalls removeAllObjects];
        NSDictionary *globals = fixture[@"globals"] ?: @{};
        gUseVOILUT = [globals[@"voiLUT"] boolValue];
        gDisplayDICOMOverlays = globals[@"overlays"] ? [globals[@"overlays"] boolValue] : YES;
        gUseShutter = NO;
        [[NSUserDefaults standardUserDefaults] registerDefaults: @{@"OpacityTableNM": @([globals[@"opacityTableNM"] boolValue]),
                                                                   @"32bitDICOMAreAlwaysIntegers": @([globals[@"alwaysIntegers"] boolValue])}];
        fprintf(stderr, "=== %s\n", [fixture[@"name"] UTF8String]);
        DCMPix *pix = [[DCMPix alloc] init];
        [pix harnessState: fixture[@"state"]];
        DCMObject *object = dataset(fixture[@"dataset"]);
        NSString *raised = [pix harnessLoad: object];
        NSMutableDictionary *dump = [[[pix harnessDump] mutableCopy] autorelease];
        dump[@"raised"] = raised ?: (id)[NSNull null];
        dump[@"voi"] = [[harnessVOICalls copy] autorelease];
        NSData *line = [NSJSONSerialization dataWithJSONObject: @{@"fixture": fixture[@"name"], @"state": dump}
                                                       options: NSJSONWritingSortedKeys error: nil];
        printf("%s\n", [[[[NSString alloc] initWithData: line encoding: NSUTF8StringEncoding] autorelease] UTF8String]);
    }
    return 0;
} }
'''


def compile_revision(source, work, name, module_folder, header=None):
    """The program for one revision of DCMPix.m; None, with the compiler's reason, when it does not build."""
    work = Path(work)
    text = PROGRAM
    for key, value in pieces(source).items():
        text = text.replace('\n' + key + '\n', '\n' + value + '\n')
    program = work / (name + '.m')
    program.write_text(text, encoding='latin1')
    # The class's header of the revision, which declares the instance variables
    # its methods use; the header of a Swift class has none.
    include = []
    if header is not None:
        (work / (name + '-headers')).mkdir(exist_ok=True)
        (work / (name + '-headers') / 'DCMPix.h').write_bytes(header)
        include = ['-I', str(work / (name + '-headers'))]
    obj = work / (name + '.o')
    built = subprocess.run(['xcrun', 'clang', '-c', '-Os', '-fno-objc-arc', '-w', *include, '-I', str(ROOT / 'Horos/Sources'),
                            '-I', str(module_folder), str(program), '-o', str(obj)], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr
    binary = work / name
    built = subprocess.run(['xcrun', 'swiftc', str(obj), str(Path(module_folder) / 'libIsiXImaging.a'),
                            '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(binary)], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr
    return binary, ''


def swift_class_pieces():
    """The parts of the Swift class the program compiles, as they stand: the
    frame loading of DCMPix+FrameLoading.swift, the branch of the DICOM
    loading (DCMPix+Loading.swift) that runs it, the slice location and the
    fixed arrays of DCMPix.swift, the parsed object as the module reads it and
    the parser's answer to the attribute source (STAND_IN_ATTRIBUTE_SOURCE)."""
    sources = ROOT / 'Horos/Sources'
    pix = (sources / 'DCMPix.swift').read_text(encoding='utf-8')
    frames = (sources / 'DCMPix+FrameLoading.swift').read_text(encoding='utf-8')
    loading = (sources / 'DCMPix+Loading.swift').read_text(encoding='utf-8')
    attributes = (sources / 'DCMPix+ImageAttributes.swift').read_text(encoding='utf-8')
    at = loading.index('if dcmObject.attributeValue(withName: "PixelData") != nil {')
    end = loading.index('}', loading.index('self.loadAbsentPixelData()', at)) + 1
    return {
        'ARRAYS': between(pix, 'struct DCMPixArrays {', '\n}\n', include_end=True),
        'SLICELOCATION': between(pix, '    func computeSliceLocation() {', '\n    }\n', include_end=True),
        'FRAMEMETHODS': between(frames, '    final func frameLoad() -> FrameLoad {', '    // MARK: - The VOI LUT'),
        'LOAD': loading[at:end],
        'SOURCE': stand_in_source(attributes),
        'CATEGORY': STAND_IN_ATTRIBUTE_SOURCE,
    }


# The Swift class's state the frame loading reads and writes, under the names
# DCMPix.swift stores it by; what the app around it does, as in PROGRAM.
SWIFT_PROGRAM = r'''
import Cocoa
import IsiXImaging

var harnessVOICalls: [UInt] = []

func HorosDCMPixLogStackTrace(_ message: String) { NSLog("%@", message) }
func N2LogStackTraceMessage(_ message: String) { NSLog("%@", message) }

enum DCMPixSettings {
    nonisolated(unsafe) static var displayDICOMOverlays = true
    nonisolated(unsafe) static var useVOILUT = false
}

enum H264StreamDecoder {
    static func isVideo(transferSyntax syntax: String?) -> Bool { syntax?.hasPrefix("1.2.840.10008.1.2.4.10") ?? false }
}

enum MissingPixelsReason {
    static func reasonForEmptyFrame(_ frame: Int) -> String { String(format: "empty frame %d", Int32(frame)) }
    static func reasonForAbsentPixelData() -> String { "no pixel data" }
    static func reasonForShortFrame(_ carried: Int, of needed: Int) -> String { "short \(carried) of \(needed)" }
}

ARRAYS

SOURCE

final class DCMPix: NSObject {
    final var horos_width = 0
    final var horos_height = 0
    final var horos_bitsAllocated: Int16 = 0
    final var horos_bitsStored: Int16 = 0
    final var horos_fIsSigned = false
    final var horos_slope: Float = 0
    final var horos_offset: Float = 0
    final var horos_fPlanarConf = 0
    final var horos_inverseVal = false
    final var horos_isRGB = false
    final var horos_fImage: UnsafeMutablePointer<Float>!
    final var horos_fExternalOwnedImage: UnsafeMutablePointer<Float>?
    final var horos_savedWL: Float = 0
    final var horos_savedWW: Float = 0
    final var horos_wl: Float = 0
    final var horos_ww: Float = 0
    final var horos_frameNo = 0
    final var horos_numberOfFrames: Int32 = 0
    final var horos_originX: Double = 0
    final var horos_originY: Double = 0
    final var horos_originZ: Double = 0
    final var horos_pixelSpacingX: Double = 0
    final var horos_pixelSpacingY: Double = 0
    final var horos_sliceLocation: Double = 0
    final let horos_arrays = DCMPixArrays()
    var srcFile: String!
    var missingPixelsReason: String!

SLICELOCATION

    // The VOI LUT step stays in the app: here it records what it was handed and
    // marks it, so that a difference in when it runs or on what shows.
    final func applyVOILUT(from dcmObject: DCMObject, to samples: UnsafeMutablePointer<UInt16>?) {
        guard let samples else { return }
        var sum: UInt = 0
        for i in 0..<(horos_width * horos_height) { sum = sum &* 31 &+ UInt(samples[i]) }
        harnessVOICalls.append(sum)
        for i in 0..<(horos_width * horos_height) { samples[i] ^= 0x5 }
    }

    final func videoFrame(_ index: Int, ofStreamIn pixelAttr: DCMPixelDataAttribute?, reason: inout String?) -> Data? {
        let frames = pixelAttr?.harnessFrames() ?? []
        if frames.count > 1 && index < frames.count { return frames[index] as? Data }
        reason = "the video stream cannot be decoded"
        return nil
    }

FRAMEMETHODS

    func harnessState(_ state: [String: Any]) {
        func number(_ key: String) -> NSNumber? { state[key] as? NSNumber }
        horos_width = number("width")?.intValue ?? 0
        horos_height = number("height")?.intValue ?? 0
        horos_bitsAllocated = number("bitsAllocated")?.int16Value ?? 0
        horos_bitsStored = number("bitsStored")?.int16Value ?? 0
        horos_fIsSigned = number("isSigned")?.boolValue ?? false
        horos_fPlanarConf = number("planar")?.intValue ?? 0
        horos_slope = number("slope")?.floatValue ?? 1
        horos_offset = number("offset")?.floatValue ?? 0
        horos_savedWL = number("savedWL")?.floatValue ?? 0
        horos_savedWW = number("savedWW")?.floatValue ?? 0
        horos_frameNo = number("frame")?.intValue ?? 0
        horos_numberOfFrames = number("numberOfFrames")?.int32Value ?? 0
        horos_originZ = number("originZ")?.doubleValue ?? 0
        horos_arrays.orientation[0] = 1; horos_arrays.orientation[4] = 1; horos_arrays.orientation[8] = 1
        horos_pixelSpacingX = 1; horos_pixelSpacingY = 1
        if number("external")?.boolValue ?? false {
            for i in 0..<(64 * 64 + 100) { harnessExternal[i] = -7.5 }
            horos_fExternalOwnedImage = harnessExternal
        }
        for overlay in state["overlays"] as? [[String: Any]] ?? [] {
            let i = (overlay["index"] as! NSNumber).intValue
            let arrays = horos_arrays
            arrays.overlayOn[i] = true
            arrays.overlayRows[i] = (overlay["rows"] as! NSNumber).int32Value
            arrays.overlayColumns[i] = (overlay["columns"] as! NSNumber).int32Value
            arrays.overlayOrigin[2 * i] = (overlay["x"] as! NSNumber).int32Value
            arrays.overlayOrigin[2 * i + 1] = (overlay["y"] as! NSNumber).int32Value
            let data = calloc(Int(arrays.overlayRows[i] * arrays.overlayColumns[i]), 1)!.assumingMemoryBound(to: UInt8.self)
            for p in overlay["set"] as? [NSNumber] ?? [] { data[p.intValue] = 0xFF }
            arrays.overlayData[i] = data
        }
        srcFile = "/fixtures/frame-loading.dcm"
    }

    func harnessLoad(_ dcmObject: DCMObject) -> String? {
        var raised: NSException?
        if let exception = harnessTry({
LOAD
        }) { return exception.name.rawValue }
        return raised?.name.rawValue
    }

    func harnessDump() -> [String: Any] {
        func hexf(_ v: Float) -> String { String(format: "%a", Double(v)) }
        var d: [String: Any] = [:]
        d["flags"] = [NSNumber(value: horos_isRGB), NSNumber(value: horos_inverseVal), NSNumber(value: horos_bitsAllocated),
                      NSNumber(value: horos_bitsStored), NSNumber(value: horos_fIsSigned), NSNumber(value: horos_fPlanarConf),
                      hexf(horos_wl), hexf(horos_ww)]
        d["external"] = NSNumber(value: horos_fImage != nil && horos_fImage == horos_fExternalOwnedImage)
        d["originZ"] = String(format: "%a", horos_originZ)
        d["reason"] = missingPixelsReason ?? NSNull()
        if let image = horos_fImage {
            if horos_isRGB {
                let bytes = UnsafeRawPointer(image).assumingMemoryBound(to: UInt8.self)
                d["buffer"] = (0..<(horos_width * horos_height * 4)).map { String(format: "%02x", bytes[$0]) }.joined()
            } else {
                d["buffer"] = (0..<(horos_width * horos_height)).map { hexf(image[$0]) }
            }
        } else {
            d["buffer"] = NSNull()
        }
        return d
    }
}

nonisolated(unsafe) let harnessExternal = UnsafeMutablePointer<Float>.allocate(capacity: 64 * 64 + 100)

let input = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let fixtures = try! JSONSerialization.jsonObject(with: input) as! [[String: Any]]
for fixture in fixtures {
    autoreleasepool {
        harnessVOICalls.removeAll()
        let globals = fixture["globals"] as? [String: Any] ?? [:]
        DCMPixSettings.useVOILUT = (globals["voiLUT"] as? NSNumber)?.boolValue ?? false
        DCMPixSettings.displayDICOMOverlays = (globals["overlays"] as? NSNumber)?.boolValue ?? true
        UserDefaults.standard.register(defaults: ["OpacityTableNM": (globals["opacityTableNM"] as? NSNumber)?.boolValue ?? false,
                                                  "32bitDICOMAreAlwaysIntegers": (globals["alwaysIntegers"] as? NSNumber)?.boolValue ?? false])
        FileHandle.standardError.write("=== \(fixture["name"] as! String)\n".data(using: .utf8)!)
        let pix = DCMPix()
        pix.harnessState(fixture["state"] as? [String: Any] ?? [:])
        let object = harnessDataset(fixture["dataset"] as! [String: Any])!
        let raised = pix.harnessLoad(object)
        var dump = pix.harnessDump()
        dump["raised"] = raised ?? NSNull()
        dump["voi"] = harnessVOICalls.map { NSNumber(value: $0) }
        let line = try! JSONSerialization.data(withJSONObject: ["fixture": fixture["name"]!, "state": dump], options: .sortedKeys)
        print(String(data: line, encoding: .utf8)!)
    }
}
'''

# The parsed object's stand-ins of PROGRAM, for the Swift program: declared in
# its bridging header, implemented in Objective-C with the category.
SWIFT_HEADER = r'''
#import <Cocoa/Cocoa.h>
@interface DCMAttribute : NSObject { @public NSArray *values; }
- (id) value;
- (NSArray*) values;
@end
@interface DCMSequenceAttribute : DCMAttribute { @public NSArray *items; }
- (NSArray*) sequence;
@end
@interface DCMTransferSyntax : NSObject { @public NSString *uid; }
@property(readonly) NSString *transferSyntax;
@end
@interface DCMPixelDataAttribute : DCMAttribute { @public NSArray *frames; DCMTransferSyntax *syntax; }
// As DCMPixelDataAttribute.h declares it.
- (NSMutableData*) decodeFrameAtIndex:(int) index;
@property(readonly) DCMTransferSyntax *transferSyntax;
- (NSArray*) harnessFrames;
@end
@interface DCMObject : NSObject { @public NSMutableDictionary *attributes; }
- (id) attributeValueWithName:(NSString*) name;
- (NSArray*) attributeArrayWithName:(NSString*) name;
- (id) attributeValueForKey:(NSString*) key;
- (NSArray*) attributeArrayForKey:(NSString*) key;
- (DCMAttribute*) attributeWithName:(NSString*) name;
@end
DCMObject *harnessDataset(NSDictionary *json);
NSException *harnessTry(void (NS_NOESCAPE ^block)(void));
'''


def compile_swift_class(work, name, module_folder):
    """The program for the Swift class of this checkout; None, with the compiler's reason, when it does not build."""
    import isix_modules
    work = Path(work)
    parts = swift_class_pieces()
    stand_ins = PROGRAM[PROGRAM.index('@interface DCMAttribute : NSObject'):PROGRAM.index('@interface HorosH264StreamDecoder')]
    stand_ins = stand_ins.replace('- (NSData*) decodeFrameAtIndex:(int) index {', '- (NSMutableData*) decodeFrameAtIndex:(int) index {')
    stand_ins = stand_ins.replace('- (DCMTransferSyntax*) transferSyntax { return syntax; }',
                                  '- (DCMTransferSyntax*) transferSyntax { return syntax; }\n- (NSArray*) harnessFrames { return frames; }')
    objc = ('#import "Harness.h"\n#import "IsiXImaging-Swift.h"\n' + stand_ins
            .replace('@interface DCMAttribute : NSObject { @public NSArray *values; }\n- (id) value;\n- (NSArray*) values;\n@end\n', '')
            + parts['CATEGORY']
            + 'DCMObject *harnessDataset(NSDictionary *json) { return [dataset(json) autorelease]; }\n'
              'NSException *harnessTry(void (NS_NOESCAPE ^block)(void)) { @try { block(); } @catch (NSException *e) { return e; } return nil; }\n')
    # The stand-ins' own @interface blocks are in the header.
    for declared in ('DCMSequenceAttribute : DCMAttribute', 'DCMTransferSyntax : NSObject', 'DCMPixelDataAttribute : DCMAttribute',
                     'DCMObject : NSObject'):
        start = objc.index('@interface ' + declared)
        objc = objc[:start] + objc[objc.index('@end\n', start) + len('@end\n'):]
    (work / 'Harness.h').write_text(SWIFT_HEADER)
    (work / (name + '-standins.m')).write_text(objc, encoding='latin1')
    program = SWIFT_PROGRAM
    for key, value in parts.items():
        if key != 'CATEGORY':
            program = program.replace('\n' + key + '\n', '\n' + value + '\n')
    (work / (name + '.swift')).write_text(program)
    obj = work / (name + '-standins.o')
    built = subprocess.run(['xcrun', 'clang', '-c', '-Os', '-fno-objc-arc', '-w', '-I', str(work), '-I', str(module_folder),
                            str(work / (name + '-standins.m')), '-o', str(obj)], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stderr
    binary = work / name
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-Onone', *isix_modules.module_flags('IsiXImaging', module_folder),
                            '-import-objc-header', str(work / 'Harness.h'), str(work / (name + '.swift')), str(obj),
                            '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(binary)], capture_output=True, text=True)
    if built.returncode != 0:
        return None, built.stdout + built.stderr
    return binary, ''


LOG_PREFIX = re.compile(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+(?:[+-]\d{4})? \S+\[\d+:\d+\] ')


def run(binary, fixtures, work):
    """The states and the log lines of one program on the fixtures."""
    path = Path(work) / 'frames.json'
    path.write_text(json.dumps(fixtures))
    ran = subprocess.run([str(binary), str(path)], capture_output=True, text=True, timeout=600)
    if ran.returncode != 0:
        raise RuntimeError(f'{binary.name} exited {ran.returncode}: {ran.stderr[-2000:]}')
    states = [json.loads(line) for line in ran.stdout.splitlines() if line.startswith('{')]
    logs = [re.sub(r'0x[0-9a-f]+', '0x…', LOG_PREFIX.sub('', line)) for line in ran.stderr.splitlines()]
    return states, logs
