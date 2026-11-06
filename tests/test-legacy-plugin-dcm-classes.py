#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX finds the DICOM dataset classes it reads
tags with.

DCM.framework defined DCMObject, DCMAttribute, DCMAttributeTag,
DCMTransferSyntax, DCMCalendarDate and the others; a plugin's binary names
them through the _OBJC_CLASS_$_ symbols, found by flat lookup in the
application, and a plugin that reads the tags of a file with DCMObject does not
load without them. The dataset model is now Swift, in the IsiXDICOMDataset and
IsiXDICOMFile modules, and keeps those names and selectors in the Objective-C
runtime.

The two modules are linked here into a host executable, with a stand-in for
the application's DCMTK reader and tag dictionaries. A bundle built as the
former plugins were (Objective-C without ARC, -undefined dynamic_lookup), which
declares the classes as the former SDK did, is loaded by the host, which checks
that:

- the bundle loads: every class symbol it names is found;
- +objectWithContentsOfFile:decodingPixelData: and -initWithContentsOfFile:
  decodingPixelData:, sent to +alloc, answer the dataset the reader made;
- -attributeValueWithName:, -attributeWithName:, -attributeForTag: with
  +tagWithName: and +tagWithTagString:, -value and -attributes answer its
  values;
- -setAttributeValues:forName:, -setAttribute:, -newSOPInstanceUID and
  -newSeriesInstanceUID change it;
- the transfer syntaxes a plugin names answer, and compare, by their UID;
- +secondaryCaptureObjectWithBitDepth:samplesPerPixel:numberOfFrames:, a Pixel
  Data attribute's -addFrame:, DCMTagDictionary's +sharedTagDictionary,
  DCMAbstractSyntaxUID's +isImageStorage: and the date makers of
  DCMCalendarDate answer;
- the instances are of the classes the plugin names.

    python3 tests/test-legacy-plugin-dcm-classes.py
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402

MODULE = 'IsiXDICOMDataset'

host = r'''
import Foundation
import IsiXDICOMDataset
import IsiXDICOMFile

// What the application's DCMTK adapter gives the model: the tag dictionaries
// and the reader, each found by its class name.
@objc(HorosDICOMDictionaries) final class Dictionaries: NSObject {
    static let entries: [(String, String, String)] = [
        ("0002,0003", "MediaStorageSOPInstanceUID", "UI"), ("0008,0016", "SOPClassUID", "UI"), ("0008,0018", "SOPInstanceUID", "UI"), ("0010,0010", "PatientsName", "PN"),
        ("0018,0050", "SliceThickness", "DS"), ("0020,000E", "SeriesInstanceUID", "UI"), ("0028,0010", "Rows", "US"),
        ("7FE0,0010", "PixelData", "OW")]
    @objc class func tagDictionary() -> NSDictionary {
        NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: entries.map { ($0.0, ["Description": $0.1, "VR": $0.2, "VM": "1"]) }))
    }
    @objc class func tagForNameDictionary() -> NSDictionary {
        NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: entries.map { ($0.1, $0.0) }))
    }
}

@objc(HorosDCMTKObject) final class Reader: NSObject, DCMReading {
    static func object(contentsOfFile path: String, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject? {
        let object = DCMObject(transferSyntax: DCMTransferSyntax.explicitVRLittleEndianTransferSyntax(), characterSet: nil,
                               isSequence: false)
        object.setAttributeValues(NSMutableArray(object: "SYNTHETIC^DCM"), forName: "PatientsName")
        object.setAttributeValues(NSMutableArray(object: NSNumber(value: 2.5)), forName: "SliceThickness")
        object.setAttributeValues(NSMutableArray(object: NSNumber(value: 64)), forName: "Rows")
        object.setAttributeValues(NSMutableArray(object: "1.2.3.4"), forName: "SOPInstanceUID")
        return object
    }
    static func object(data: Data, transferSyntax: String?, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject? { nil }
}

// The classes a plugin names, so that the linker takes each from its library.
let named: [AnyClass] = [DCMObject.self, DCMAttribute.self, DCMPixelDataAttribute.self, DCMSequenceAttribute.self,
                         DCMTransferSyntax.self, DICOMAttributeTag.self, DICOMCalendarDate.self, DICOMCharacterSet.self,
                         DICOMSOPClass.self, DICOMLegacyTagDictionary.self, DICOMLegacyTagForNameDictionary.self]
// And a method of each extension the model keeps in a file of its own.
let extensions = [#selector(DCMObject.secondaryCaptureObject(withBitDepth:samplesPerPixel:numberOfFrames:)),
                  #selector(DCMObject.encapsulatedPDF(_:)), #selector(DCMObject.anonymizeContents(ofFile:tags:writingToFile:)),
                  #selector(DCMObject.rootUID), #selector(DCMPixelDataAttribute.convertPaletteToRGB(_:))]
if named.count != 11 || extensions.count != 5 || DCMObject.secondaryCaptureObject(withBitDepth: 8, samplesPerPixel: 1, numberOfFrames: 1).attributes == nil { exit(1) }

let bundle = Bundle(path: CommandLine.arguments[1])!
do { try bundle.loadAndReturnError() } catch { print("FAIL: the bundle does not load: \(error)"); exit(1) }
guard let probe = (bundle.principalClass as? NSObject.Type)?.init() else { print("FAIL: no principal class"); exit(1) }
let failures = probe.perform(NSSelectorFromString("run:"), with: CommandLine.arguments[2])?.takeUnretainedValue() as? [String] ?? ["-run: answered nothing"]
for failure in failures { print("FAIL: " + failure) }
if !failures.isEmpty { exit(1) }
print("ok")
'''

plugin = r'''
#import <Foundation/Foundation.h>
// The classes as the former SDK declared them; the classes themselves are the host's.
@interface DCMAttributeTag : NSObject
+ (id)tagWithName:(NSString *)name;
+ (id)tagWithTagString:(NSString *)tagString;
- (NSString *)name;
- (NSString *)stringValue;
- (NSString *)vr;
@end
@interface DCMAttribute : NSObject
+ (id)attributeWithAttributeTag:(DCMAttributeTag *)tag;
- (id)initWithAttributeTag:(DCMAttributeTag *)tag vr:(NSString *)vr values:(NSMutableArray *)values;
- (id)value;
- (NSMutableArray *)values;
- (void)addValue:(id)value;
- (DCMAttributeTag *)attrTag;
@end
@interface DCMPixelDataAttribute : DCMAttribute
- (void)addFrame:(NSMutableData *)data;
@end
@interface DCMTransferSyntax : NSObject
+ (id)ExplicitVRLittleEndianTransferSyntax;
+ (id)ImplicitVRLittleEndianTransferSyntax;
+ (id)JPEG2000LosslessTransferSyntax;
+ (id)JPEG2000LossyTransferSyntax;
+ (id)JPEGLSLosslessTransferSyntax;
+ (id)JPEGLSLossyTransferSyntax;
- (id)initWithTS:(NSString *)ts;
- (BOOL)isEqualToTransferSyntax:(DCMTransferSyntax *)ts;
- (NSString *)name;
- (NSString *)transferSyntax;
@end
@interface DCMObject : NSObject
+ (id)objectWithContentsOfFile:(NSString *)file decodingPixelData:(BOOL)decodePixelData;
+ (id)secondaryCaptureObjectWithBitDepth:(int)bitDepth samplesPerPixel:(int)spp numberOfFrames:(int)nff;
- (id)initWithContentsOfFile:(NSString *)file decodingPixelData:(BOOL)decodePixelData;
- (NSMutableDictionary *)attributes;
- (DCMAttribute *)attributeForTag:(DCMAttributeTag *)tag;
- (DCMAttribute *)attributeWithName:(NSString *)name;
- (id)attributeValueWithName:(NSString *)name;
- (void)setAttribute:(DCMAttribute *)attr;
- (void)setAttributeValues:(NSMutableArray *)values forName:(NSString *)name;
- (void)newSOPInstanceUID;
- (void)newSeriesInstanceUID;
- (DCMTransferSyntax *)transferSyntax;
- (NSXMLDocument *)xmlDocument;
@end
@interface DCMCalendarDate : NSDate
+ (id)dicomDate:(NSString *)string;
+ (id)dicomTime:(NSString *)string;
+ (id)dicomDateWithDate:(NSDate *)date;
+ (id)dicomTimeWithDate:(NSDate *)date;
@end
@interface DCMTagDictionary : NSDictionary
+ (id)sharedTagDictionary;
@end
@interface DCMAbstractSyntaxUID : NSObject
+ (BOOL)isImageStorage:(NSString *)sopClassUID;
+ (BOOL)isMultiframe:(NSString *)sopClassUID;
+ (BOOL)isRadiotherapy:(NSString *)sopClassUID;
+ (BOOL)isWaveform:(NSString *)sopClassUID;
@end

@interface LegacyDCMProbe : NSObject
@end
@implementation LegacyDCMProbe
- (NSArray *)run:(NSString *)path
{
    NSMutableArray *failures = [NSMutableArray array];
#define CHECK(condition, what) if (!(condition)) [failures addObject:what]

    DCMObject *read = [DCMObject objectWithContentsOfFile:path decodingPixelData:NO];
    CHECK([read isKindOfClass:[DCMObject class]], @"+objectWithContentsOfFile:decodingPixelData: answers a DCMObject");
    CHECK([[read attributeValueWithName:@"PatientsName"] isEqual:@"SYNTHETIC^DCM"], @"-attributeValueWithName: answers the patient's name");
    CHECK([[read attributeValueWithName:@"SliceThickness"] floatValue] == 2.5f, @"-attributeValueWithName: answers the slice thickness");
    CHECK([DCMObject objectWithContentsOfFile:@"/nonexistent/file.dcm" decodingPixelData:NO] == nil, @"no file, no object");

    DCMObject *made = [[DCMObject alloc] initWithContentsOfFile:path decodingPixelData:NO];
    CHECK([made isKindOfClass:[DCMObject class]] && [[made attributeValueWithName:@"Rows"] intValue] == 64,
          @"-initWithContentsOfFile:decodingPixelData: answers the dataset read");
    CHECK([[made transferSyntax] isEqualToTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]],
          @"the dataset keeps the transfer syntax it was read with");
    CHECK([[DCMObject alloc] initWithContentsOfFile:@"/nonexistent/file.dcm" decodingPixelData:NO] == nil, @"-init... answers nil without a file");

    DCMAttributeTag *named = [DCMAttributeTag tagWithName:@"PatientsName"];
    DCMAttributeTag *numbered = [DCMAttributeTag tagWithTagString:@"0028,0010"];
    CHECK([[named stringValue] isEqual:@"0010,0010"] && [[named vr] isEqual:@"PN"], @"+tagWithName: answers the tag");
    CHECK([[numbered name] isEqual:@"Rows"], @"+tagWithTagString: answers the tag");
    DCMAttribute *attribute = [made attributeForTag:named];
    CHECK([attribute isKindOfClass:[DCMAttribute class]] && [[attribute value] isEqual:@"SYNTHETIC^DCM"] && [[attribute values] count] == 1,
          @"-attributeForTag: answers the attribute, and -value its first value");
    CHECK([made attributeWithName:@"Rows"] == [made attributeForTag:numbered], @"-attributeWithName: answers the same attribute");
    CHECK([[made attributes] objectForKey:@"0010,0010"] == attribute && [[made attributes] count] == 4, @"-attributes holds them by tag");

    [made setAttributeValues:[NSMutableArray arrayWithObject:@"CHANGED^NAME"] forName:@"PatientsName"];
    CHECK([[made attributeValueWithName:@"PatientsName"] isEqual:@"CHANGED^NAME"], @"-setAttributeValues:forName: replaces the values");
    DCMAttribute *thickness = [DCMAttribute attributeWithAttributeTag:[DCMAttributeTag tagWithName:@"SliceThickness"]];
    [thickness addValue:[NSNumber numberWithFloat:7]];
    [made setAttribute:thickness];
    CHECK([[made attributeValueWithName:@"SliceThickness"] floatValue] == 7, @"-setAttribute: replaces the attribute");
    [made newSOPInstanceUID];
    [made newSeriesInstanceUID];
    CHECK(![[made attributeValueWithName:@"SOPInstanceUID"] isEqual:@"1.2.3.4"] && [[made attributeValueWithName:@"SeriesInstanceUID"] length] > 0,
          @"-newSOPInstanceUID and -newSeriesInstanceUID give new identifiers");
    CHECK([[[made xmlDocument] rootElement] childCount] > 0, @"-xmlDocument describes the dataset");
    [made release];

    CHECK([[[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] transferSyntax] isEqual:@"1.2.840.10008.1.2"]
          && [[[DCMTransferSyntax JPEG2000LosslessTransferSyntax] transferSyntax] isEqual:@"1.2.840.10008.1.2.4.90"]
          && [[[DCMTransferSyntax JPEG2000LossyTransferSyntax] transferSyntax] isEqual:@"1.2.840.10008.1.2.4.91"]
          && [[[DCMTransferSyntax JPEGLSLosslessTransferSyntax] transferSyntax] isEqual:@"1.2.840.10008.1.2.4.80"]
          && [[[DCMTransferSyntax JPEGLSLossyTransferSyntax] transferSyntax] isEqual:@"1.2.840.10008.1.2.4.81"],
          @"the transfer syntaxes answer their UIDs");
    DCMTransferSyntax *syntax = [[[DCMTransferSyntax alloc] initWithTS:@"1.2.840.10008.1.2.1"] autorelease];
    CHECK([syntax isEqualToTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]] && [[syntax name] length] > 0,
          @"-initWithTS: makes the named transfer syntax");

    DCMObject *capture = [DCMObject secondaryCaptureObjectWithBitDepth:8 samplesPerPixel:1 numberOfFrames:1];
    CHECK([DCMAbstractSyntaxUID isImageStorage:[capture attributeValueWithName:@"SOPClassUID"]], @"a secondary capture is of an image storage class");
    CHECK(![DCMAbstractSyntaxUID isMultiframe:@"1.2.840.10008.5.1.4.1.1.2"] && ![DCMAbstractSyntaxUID isWaveform:@"1.2.840.10008.5.1.4.1.1.2"]
          && [DCMAbstractSyntaxUID isRadiotherapy:@"1.2.840.10008.5.1.4.1.1.481.2"], @"DCMAbstractSyntaxUID tells the classes apart");
    DCMPixelDataAttribute *pixels = [[[DCMPixelDataAttribute alloc] initWithAttributeTag:[DCMAttributeTag tagWithName:@"PixelData"] vr:@"OW"
                                                                                 values:[NSMutableArray array]] autorelease];
    [pixels addFrame:[NSMutableData dataWithLength:16]];
    CHECK([pixels isKindOfClass:[DCMPixelDataAttribute class]] && [[pixels values] count] == 1, @"-addFrame: adds a frame to a Pixel Data attribute");

    CHECK([[[[DCMTagDictionary sharedTagDictionary] objectForKey:@"0028,0010"] objectForKey:@"VR"] isEqual:@"US"],
          @"+sharedTagDictionary answers the dictionary of tags");
    CHECK([DCMCalendarDate isSubclassOfClass:[NSDate class]] && [DCMCalendarDate respondsToSelector:@selector(dicomDate:)]
          && [DCMCalendarDate respondsToSelector:@selector(dicomTime:)]
          && [[DCMCalendarDate dicomDateWithDate:[NSDate date]] isKindOfClass:[DCMCalendarDate class]]
          && [[DCMCalendarDate dicomTimeWithDate:[NSDate date]] isKindOfClass:[DCMCalendarDate class]],
          @"DCMCalendarDate is a date and makes DICOM dates and times");
    return failures;
}
@end
'''


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


with tempfile.TemporaryDirectory(prefix='horos-legacy-dcm-') as temporary:
    work = Path(temporary)
    modules = work / 'modules'
    target = ['-target', 'arm64-apple-macos15.0']
    flags = module_flags(MODULE, modules, target)
    (work / 'main.swift').write_text(host)
    (work / 'Legacy.m').write_text(plugin)
    (work / 'image.dcm').write_bytes(b'synthetic')
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy-dcm', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyDCMProbe'}))
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Host', *target, *flags,
                 str(work / 'main.swift'), '-o', str(work / 'host')])
    if built.returncode != 0:
        print('FAIL: the host does not build: ' + built.stderr[-3000:])
        raise SystemExit(1)
    built = run(['xcrun', 'clang', '-bundle', '-fno-objc-arc', '-framework', 'Foundation',
                 '-undefined', 'dynamic_lookup', '-mmacosx-version-min=15.0', str(work / 'Legacy.m'),
                 '-o', str(legacy / 'Contents/MacOS/Legacy')])
    if built.returncode != 0:
        print('FAIL: the plugin does not build: ' + built.stderr[-3000:])
        raise SystemExit(1)
    probe = run([str(work / 'host'), str(legacy), str(work / 'image.dcm')], timeout=60)
    if probe.returncode != 0:
        died = f' (signal {-probe.returncode})' if probe.returncode < 0 else ''
        print((probe.stdout + probe.stderr).strip())
        print(f'FAIL: the host ended with status {probe.returncode}{died}')
        raise SystemExit(1)
print('DCMObject and the other dataset classes: a former plugin finds them by name, reads the tags of a file and changes them')
