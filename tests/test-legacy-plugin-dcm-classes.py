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
- the instances are of the classes the plugin names;
- the selectors of the SDK the model had lost answer again: the SOP class UIDs
  of DCMAbstractSyntaxUID, with the values of the standard that Horos had, and
  an instance made with -initWithUID:name:type:; the byte order, frame and
  compression selectors of a Pixel Data attribute; the initializers of
  DCMAttribute, DCMCharacterSet and DCMTransferSyntax that take the parts of a
  value; and the accessors of a presentation state's graphic objects;
- the classes the model had lost are found by name: DCMDataContainer,
  DCMValueRepresentation, DCMLimitedObject, DCMObjectDBImport and
  DCMObjectPixelDataImport; a DCMObject written into a container by the two
  writers the known plugins use gives a Part 10 stream, DICM at byte 128, or
  the dataset alone; reading with a last group stops there, and the import
  subclasses answer an instance of their own class.

    python3 tests/test-legacy-plugin-dcm-classes.py
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402
import harness_defaults  # noqa: E402  the host's preferences stay in its own process

MODULE = 'IsiXDICOMDataset'

# The class methods of DCMAbstractSyntaxUID and the UIDs Horos answered.
SOP_CLASS_UIDS = {
    'CTImageStorage': '1.2.840.10008.5.1.4.1.1.2',
    'EnhancedXAImageStorage': '1.2.840.10008.5.1.4.1.1.12.1.1',
    'EnhancedXRFImageStorage': '1.2.840.10008.5.1.4.1.1.12.2.1',
    'MRImageStorage': '1.2.840.10008.5.1.4.1.1.4',
    'MRSpectroscopyStorage': '1.2.840.10008.5.1.4.1.1.4.2',
    'PETImageStorage': '1.2.840.10008.5.1.4.1.1.128',
    'RTBeamsTreatmentRecordStorage': '1.2.840.10008.5.1.4.1.1.481.4',
    'RTBrachyTreatmentRecordStorage': '1.2.840.10008.5.1.4.1.1.481.6',
    'RTDoseStorage': '1.2.840.10008.5.1.4.1.1.481.2',
    'RTImageStorage': '1.2.840.10008.5.1.4.1.1.481.1',
    'RTPlanStorage': '1.2.840.10008.5.1.4.1.1.481.5',
    'RTTreatmentSummaryRecordStorage': '1.2.840.10008.5.1.4.1.1.481.7',
    'XRay3DAngiographicImageStorage': '1.2.840.10008.5.1.4.1.1.13.1.1',
    'XRay3DCraniofacialImageStorage': '1.2.840.10008.5.1.4.1.1.13.1.2',
    'XrayAngiographicBiplaneImageStorage': '1.2.840.10008.5.1.4.1.1.12.3',
    'XrayAngiographicImageStorage': '1.2.840.10008.5.1.4.1.1.12.1',
    'XrayRadioFlouroscopicImageStorage': '1.2.840.10008.5.1.4.1.1.12.2',
    'ambulatoryECGStorage': '1.2.840.10008.5.1.4.1.1.9.1.3',
    'basicColorPrintManagementMetaSOPClassUID': '.2.840.10008.5.1.1.18',
    'basicGrayscalePrintManagementMetaSOPClassUID': '1.2.840.10008.5.1.1.9',
    'basicTextSRStorage': '1.2.840.10008.5.1.4.1.1.88.11',
    'basicVoiceStorage': '1.2.840.10008.5.1.4.1.1.9.4.1',
    'cardiacElectrophysiologyWaveformStorage': '1.2.840.10008.5.1.4.1.1.9.3.1',
    'comprehensiveSRStorage': '1.2.840.10008.5.1.4.1.1.88.33',
    'computedRadiographyImageStorage': '1.2.840.10008.5.1.4.1.1.1',
    'digitalIntraoralXRayImageStorageForPresentation': '1.2.840.10008.5.1.4.1.1.1.3',
    'digitalIntraoralXRayImageStorageForProcessing': '1.2.840.10008.5.1.4.1.1.1.3.1',
    'digitalMammographyXRayImageStorageForPresentation': '1.2.840.10008.5.1.4.1.1.1.2',
    'digitalMammographyXRayImageStorageForProcessing': '1.2.840.10008.5.1.4.1.1.1.2.1',
    'digitalXRayImageStorageForPresentation': '1.2.840.10008.5.1.4.1.1.1.1',
    'digitalXRayImageStorageForProcessing': '1.2.840.10008.5.1.4.1.1.1.1.1',
    'enhancedCTImageStorage': '1.2.840.10008.5.1.4.1.1.2.1',
    'enhancedPETImageStorage': '1.2.840.10008.5.1.4.1.1.130',
    'enhancedSRStorage': '1.2.840.10008.5.1.4.1.1.88.22',
    'enhancedUSVolumeStorage': '1.2.840.10008.5.1.4.1.1.6.2',
    'generalECGStorage': '1.2.840.10008.5.1.4.1.1.9.1.2',
    'grayscaleSoftcopyPresentationStateStorage': '1.2.840.10008.5.1.4.1.1.11.1',
    'hemodynamicWaveformStorage': '1.2.840.10008.5.1.4.1.1.9.2.1',
    'mammographyCADSRStorage': '1.2.840.10008.5.1.4.1.1.88.50',
    'mediaStorageDirectoryStorage': '1.2.840.10008.1.3.10',
    'multiframeGrayscaleByteSecondaryCaptureImageStorage': '1.2.840.10008.5.1.4.1.1.7.2',
    'multiframeGrayscaleWordSecondaryCaptureImageStorage': '1.2.840.10008.5.1.4.1.1.7.3',
    'multiframeSingleBitSecondaryCaptureImageStorage': '1.2.840.10008.5.1.4.1.1.7.1',
    'multiframeTrueColorSecondaryCaptureImageStorage': '1.2.840.10008.5.1.4.1.1.7.4',
    'nuclearMedicineImageStorage': '1.2.840.10008.5.1.4.1.1.20',
    'nuclearMedicineImageStorageRetired': '1.2.840.10008.5.1.4.1.1.5',
    'rawDataStorage': '1.2.840.10008.5.1.4.1.1.66',
    'standaloneCurveStorage': '1.2.840.10008.5.1.4.1.1.10',
    'standaloneModalityLUTStorage': '1.2.840.10008.5.1.4.1.1.10',
    'standaloneOverlayStorage': '1.2.840.10008.5.1.4.1.1.8',
    'standalonePETCurveStorage': '1.2.840.10008.5.1.4.1.1.129',
    'standaloneVOILUTStorage': '1.2.840.10008.5.1.4.1.1.11',
    'studyRootQueryRetrieveInformationModelMove': '1.2.840.10008.5.1.4.1.2.2.2',
    'twelveLeadECGStorage': '1.2.840.10008.5.1.4.1.1.9.1.1',
    'ultrasoundImageStorage': '1.2.840.10008.5.1.4.1.1.6.1',
    'ultrasoundImageStorageRetired': '1.2.840.10008.5.1.4.1.1.6',
    'ultrasoundMultiframeImageStorage': '1.2.840.10008.5.1.4.1.1.3.1',
    'ultrasoundMultiframeImageStorageRetired': '1.2.840.10008.5.1.4.1.1.3',
    'verificationClassUID': '1.2.840.10008.1.1',
    'videoEndoscopicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.1.1',
    'videoMicroscopicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.2.1',
    'videoPhotographicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.4.1',
    'visibleLightDraftImageStorage': '1.2.840.10008.5.1.4.1.1.77.1',
    'visibleLightEndoscopicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.1',
    'visibleLightMicroscopicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.2',
    'visibleLightMultiFrameDraftImageStorage': '1.2.840.10008.5.1.4.1.1.77.2',
    'visibleLightPhotographicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.4',
    'visibleLightSlideCoordinatesMicroscopicImageStorage': '1.2.840.10008.5.1.4.1.1.77.1.3',
    'xrayAngiographicBiplaneImageStorage': '1.2.840.10008.5.1.4.1.1.12.3',
    'xrayAngiographicImageStorage': '1.2.840.10008.5.1.4.1.1.12.1',
    'xrayRadioFlouroscopicImageStorage': '1.2.840.10008.5.1.4.1.1.12.2',
}
# The instance selectors of the SDK the classes answer again, asked by name.
ANSWERED = {
    'DCMAbstractSyntaxUID': ['initWithUID:name:type:', 'isDirectory', 'isImageStorage', 'isNonImageStorage', 'isPresentationState', 'isRadiotherapy', 'isRawData', 'isSpectroscopy', 'isStandalone', 'isStructuredReport', 'isWaveform', 'name', 'type', 'uid'],
    'DCMAttribute': ['initWithAttributeTag:vr:length:dataPtr:'],
    'DCMCharacterSet': ['initWithCharacterSet:'],
    'DCMObject': ['anchorPointAnnotationUnitsIsPixelForGraphicsObject:', 'anchorPointForGraphicsObject:', 'anchorPointVisibiltyForGraphicsObject:', 'boundingBoxBottomRightHandCornerForObject:', 'boundingBoxTextHorizontalJustificationForObject:', 'boundingBoxTopLeftHandCornerForObject:', 'displayedAreaSelectionSequence', 'graphicAnnotationSequence', 'graphicDataForGraphicsObject:', 'graphicFilledForGraphicsObject:', 'graphicLayerSequence', 'graphicObjectSequence', 'graphicObjectSequenceForObject:', 'graphicTypeForGraphicsObject:', 'horizontalFlip', 'imageRotation', 'isPresentationState', 'numberOfGraphicPointsForGraphicsObject:', 'softcopyVOILUTSequence', 'textObjectSequenceForObject:', 'unformattedTextValueForObject:', 'writeToURL:withTransferSyntax:quality:AET:atomically:'],
    'DCMPixelDataAttribute': ['compressJPEG8:compressionSyntax:quality:', 'convertBigEndianToHost', 'convertDataFromLittleEndianToHost:', 'convertHostToBigEndian', 'convertHostToLittleEndian', 'convertJPEG12ToHost:', 'convertJPEG16ToHost:', 'convertJPEG2000ToHost:', 'convertJPEG8LosslessToHost:', 'convertJPEG8ToHost:', 'convertJPEGLSToHost:', 'convertLittleEndianToHost', 'convertRLEToHost:', 'convertToFloat:', 'convertToRGBColorspace', 'createFrames', 'createOffsetTable', 'deencapsulateData:', 'encodeJPEG2000:quality:', 'findMinAndMax:', 'interleavePlanes', 'replaceFrameAtIndex:withFrame:', 'setLossyImageCompressionRatio:quality:'],
    'DCMTransferSyntax': ['initWithTS:isEncapsulated:isLittleEndian:isExplicit:name:'],
}

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
        UserDefaults.standard.set(Int(lastGroup), forKey: "LastGroupRead")
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

// The writer: a stream with the preamble and DICM where Part 10 has them, a
// stand-in for the meta header, and a dataset that names its syntax.
@objc(IsiXDCMTKObjectWriter) final class Writer: NSObject, DCMWriting {
    static func write(_ object: DCMObject, toFile path: String, transferSyntax: String?, quality: Int32, aet: String?) -> Bool {
        var stream = Data(count: 128)
        stream.append(Data("DICMMETA:\(aet ?? "nil"):".utf8))
        stream.append(dataset(of: object, transferSyntax: transferSyntax, quality: quality) ?? Data())
        return FileManager.default.createFile(atPath: path, contents: stream)
    }
    static func dataset(of object: DCMObject, transferSyntax: String?, quality: Int32) -> Data? {
        Data("SET:\(transferSyntax ?? "nil"):\(quality)".utf8)
    }
    static func object(byConverting object: DCMObject, toTransferSyntax transferSyntax: String, quality: Int32) -> DCMObject? { object }
}

// The classes a plugin names, so that the linker takes each from its library.
let named: [AnyClass] = [DCMObject.self, DCMAttribute.self, DCMPixelDataAttribute.self, DCMSequenceAttribute.self,
                         DCMTransferSyntax.self, DICOMAttributeTag.self, DICOMCalendarDate.self, DICOMCharacterSet.self,
                         DICOMSOPClass.self, DICOMLegacyTagDictionary.self, DICOMLegacyTagForNameDictionary.self,
                         DCMDataContainer.self, DCMValueRepresentation.self, DCMLimitedObject.self, DCMObjectDBImport.self,
                         DCMObjectPixelDataImport.self]
// And a method of each extension the model keeps in a file of its own.
let extensions = [#selector(DCMObject.secondaryCaptureObject(withBitDepth:samplesPerPixel:numberOfFrames:)),
                  #selector(DCMObject.encapsulatedPDF(_:)), #selector(DCMObject.anonymizeContents(ofFile:tags:writingToFile:)),
                  #selector(DCMObject.rootUID), #selector(DCMPixelDataAttribute.convertPaletteToRGB(_:))]
if named.count != 16 || extensions.count != 5 || DCMObject.secondaryCaptureObject(withBitDepth: 8, samplesPerPixel: 1, numberOfFrames: 1).attributes == nil { exit(1) }

// The selectors of the former SDK that only a plugin sends are extensions in
// files of their own. The application links every object of the modules; a
// static library gives this host only those it names, so it names one of each.
let onlySentByPlugins: [Any] = [DICOMSOPClass.sdkCapitalCTImageStorage(), DCMObject.sdkIsPresentationState,
                                DCMPixelDataAttribute.sdkConvertLittleEndianToHost,
                                DCMAttribute.init(attributeTag:vr:length:dataPointer:) as (DICOMAttributeTag?, String?, Int, UnsafeMutablePointer<UInt8>?) -> DCMAttribute,
                                DCMObject.getGroup(_:), DCMAttribute.writeBase(to:transferSyntax:)]
if onlySentByPlugins.count != 6 { exit(1) }

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
@interface DCMAttribute (FormerSDKParts)
- (id)initWithAttributeTag:(DCMAttributeTag *)tag vr:(NSString *)vr length:(long)length dataPtr:(unsigned char *)dataPtr;
@end
@interface DCMPixelDataAttribute : DCMAttribute
- (void)addFrame:(NSMutableData *)data;
- (void)replaceFrameAtIndex:(int)index withFrame:(NSMutableData *)data;
- (void)convertLittleEndianToHost;
- (void)convertHostToLittleEndian;
- (NSData *)convertDataFromLittleEndianToHost:(NSMutableData *)data;
- (void)createOffsetTable;
- (void)interleavePlanes;
- (NSData *)convertJPEG8ToHost:(NSData *)data;
@end
@interface DCMCharacterSet : NSObject
- (id)initWithCode:(NSString *)characterSet;
- (id)initWithCharacterSet:(DCMCharacterSet *)characterSet;
- (NSString *)characterSet;
@end
@interface DCMTransferSyntax : NSObject
+ (id)ExplicitVRLittleEndianTransferSyntax;
+ (id)ImplicitVRLittleEndianTransferSyntax;
+ (id)JPEG2000LosslessTransferSyntax;
+ (id)JPEG2000LossyTransferSyntax;
+ (id)JPEGLSLosslessTransferSyntax;
+ (id)JPEGLSLossyTransferSyntax;
- (id)initWithTS:(NSString *)ts;
- (id)initWithTS:(NSString *)ts isEncapsulated:(BOOL)encapsulated isLittleEndian:(BOOL)endian isExplicit:(BOOL)isExplicit name:(NSString *)aName;
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
@interface DCMDataContainer : NSObject
+ (id)dataContainer;
- (id)initWithData:(NSData *)data transferSyntax:(DCMTransferSyntax *)syntax;
- (NSMutableData *)dicomData;
- (unsigned)length;
- (void)addUnsignedShort:(unsigned short)value;
- (unsigned short)nextUnsignedShort;
- (DCMTransferSyntax *)transferSyntaxForDataset;
@end
@interface DCMObject (FormerSDKContainer)
- (BOOL)writeToDataContainer:(DCMDataContainer *)container withTransferSyntax:(DCMTransferSyntax *)ts asDICOM3:(BOOL)flag;
- (BOOL)writeToDataContainer:(DCMDataContainer *)container withTransferSyntax:(DCMTransferSyntax *)ts quality:(int)quality asDICOM3:(BOOL)flag strippingGroupLengthLength:(BOOL)strip;
- (int)getGroup:(DCMDataContainer *)dicomData;
@end
@interface DCMAttribute (FormerSDKContainer)
- (BOOL)writeToDataContainer:(DCMDataContainer *)container withTransferSyntax:(DCMTransferSyntax *)ts;
@end
@interface DCMValueRepresentation : NSObject
+ (BOOL)isValidVR:(NSString *)vr;
+ (BOOL)isShortValueLengthVR:(NSString *)vr;
+ (BOOL)isAffectedBySpecificCharacterSet:(NSString *)vr;
@end
@interface DCMLimitedObject : DCMObject
+ (id)objectWithContentsOfFile:(NSString *)file lastGroup:(unsigned short)lastGroup;
- (id)initWithContentsOfFile:(NSString *)file lastGroup:(unsigned short)lastGroup;
@end
@interface DCMObjectDBImport : DCMObject
- (BOOL)isNeededAttribute:(char *)tagString;
@end
@interface DCMObjectPixelDataImport : DCMObject
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
- (id)initWithUID:(NSString *)uid name:(NSString *)name type:(NSString *)type;
- (NSString *)uid;
- (NSString *)name;
- (NSString *)type;
- (BOOL)isImageStorage;
- (BOOL)isWaveform;
- (BOOL)isStructuredReport;
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

    // The selectors of the SDK the model answers again.
    NSDictionary *uids = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingString:@".uids.plist"]];
    for (NSString *selector in uids) {
        id answer = [DCMAbstractSyntaxUID respondsToSelector:NSSelectorFromString(selector)]
            ? [DCMAbstractSyntaxUID performSelector:NSSelectorFromString(selector)] : nil;
        CHECK([answer isEqual:[uids objectForKey:selector]], ([NSString stringWithFormat:@"+[DCMAbstractSyntaxUID %@] answers %@", selector, [uids objectForKey:selector]]));
    }
    CHECK([uids count] > 60, @"the table of SOP class UIDs was read");
    NSDictionary *answered = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingString:@".answered.plist"]];
    for (NSString *name in answered)
        for (NSString *selector in [answered objectForKey:name])
            CHECK([NSClassFromString(name) instancesRespondToSelector:NSSelectorFromString(selector)],
                  ([NSString stringWithFormat:@"-[%@ %@] answers", name, selector]));
    CHECK([answered count] == 6, @"the list of selectors was read");

    DCMAbstractSyntaxUID *storage = [[[DCMAbstractSyntaxUID alloc] initWithUID:@"1.2.840.10008.5.1.4.1.1.2" name:@"CT Image Storage" type:@"ImageStorage"] autorelease];
    CHECK([[storage uid] isEqual:@"1.2.840.10008.5.1.4.1.1.2"] && [[storage name] isEqual:@"CT Image Storage"] && [[storage type] isEqual:@"ImageStorage"]
          && [storage isImageStorage] && ![storage isWaveform] && ![storage isStructuredReport],
          @"-initWithUID:name:type: keeps the three, and the instance tells its type");

    unsigned char thicknessBytes[] = {'2', '.', '5', ' '};
    DCMAttribute *parsed = [[[DCMAttribute alloc] initWithAttributeTag:[DCMAttributeTag tagWithName:@"SliceThickness"] vr:@"DS" length:4 dataPtr:thicknessBytes] autorelease];
    CHECK([[parsed attrTag] isKindOfClass:[DCMAttributeTag class]] && [[parsed values] count] == 1 && [[parsed value] floatValue] == 2.5f,
          @"-initWithAttributeTag:vr:length:dataPtr: reads the value from the bytes");
    DCMCharacterSet *latin = [[[DCMCharacterSet alloc] initWithCode:@"ISO_IR 100"] autorelease];
    DCMCharacterSet *copied = [[[DCMCharacterSet alloc] initWithCharacterSet:latin] autorelease];
    CHECK([copied isKindOfClass:[DCMCharacterSet class]] && copied != latin && [[copied characterSet] isEqual:@"ISO_IR 100"],
          @"-initWithCharacterSet: makes a character set like the one given");
    DCMTransferSyntax *described = [[[DCMTransferSyntax alloc] initWithTS:@"1.2.3.4.5" isEncapsulated:NO isLittleEndian:YES isExplicit:YES name:@"QA syntax"] autorelease];
    CHECK([[described transferSyntax] isEqual:@"1.2.3.4.5"] && [[described name] isEqual:@"QA syntax"],
          @"-initWithTS:isEncapsulated:isLittleEndian:isExplicit:name: keeps the UID and the name");

    NSMutableData *replacement = [NSMutableData dataWithLength:32];
    [pixels replaceFrameAtIndex:0 withFrame:replacement];
    CHECK([[pixels values] count] == 1 && [[[pixels values] objectAtIndex:0] length] == 32, @"-replaceFrameAtIndex:withFrame: replaces the frame");
    [pixels replaceFrameAtIndex:9 withFrame:replacement];
    [pixels convertLittleEndianToHost];
    [pixels convertHostToLittleEndian];
    [pixels createOffsetTable];
    [pixels interleavePlanes];
    CHECK([pixels convertDataFromLittleEndianToHost:replacement] == replacement && [[pixels values] count] == 1 && [pixels convertJPEG8ToHost:replacement] == nil,
          @"the byte order selectors leave a little-endian frame as it is, and the codec selectors answer nil");

    // The classes of the SDK the model has again, and a DCMObject in a container of bytes.
    DCMDataContainer *whole = [[[DCMDataContainer alloc] initWithData:[NSData data] transferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]] autorelease];
    CHECK([read writeToDataContainer:whole withTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] asDICOM3:YES], @"-writeToDataContainer:withTransferSyntax:asDICOM3: writes");
    NSData *stream = [whole dicomData];
    CHECK([stream length] > 132 && [whole length] == [stream length] && memcmp((const char *)[stream bytes] + 128, "DICM", 4) == 0,
          @"a DCMObject written asDICOM3 has DICM at byte 128 of -dicomData");
    NSString *tail = [[[NSString alloc] initWithData:[stream subdataWithRange:NSMakeRange(132, [stream length] - 132)] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([tail isEqual:@"META:OSIRIX:SET:1.2.840.10008.1.2.1:0"], ([NSString stringWithFormat:@"the stream is the writer's, for the syntax asked, lossless: %@", tail]));
    DCMDataContainer *bare = [DCMDataContainer dataContainer];
    CHECK([bare isKindOfClass:[DCMDataContainer class]]
          && [read writeToDataContainer:bare withTransferSyntax:[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax] quality:1 asDICOM3:NO strippingGroupLengthLength:YES],
          @"-writeToDataContainer:withTransferSyntax:quality:asDICOM3:strippingGroupLengthLength: writes");
    tail = [[[NSString alloc] initWithData:[bare dicomData] encoding:NSUTF8StringEncoding] autorelease];
    CHECK([tail isEqual:@"SET:1.2.840.10008.1.2:1"] && [[bare transferSyntaxForDataset] isEqualToTransferSyntax:[DCMTransferSyntax ImplicitVRLittleEndianTransferSyntax]],
          ([NSString stringWithFormat:@"without asDICOM3 the container has the dataset alone: %@", tail]));
    DCMDataContainer *element = [[[DCMDataContainer alloc] initWithData:[NSData data] transferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]] autorelease];
    DCMAttribute *rows = [[[DCMAttribute alloc] initWithAttributeTag:[DCMAttributeTag tagWithName:@"Rows"] vr:@"US" values:[NSMutableArray arrayWithObject:[NSNumber numberWithInt:64]]] autorelease];
    const unsigned char expected[] = {0x28, 0x00, 0x10, 0x00, 'U', 'S', 0x02, 0x00, 0x40, 0x00};
    CHECK([rows writeToDataContainer:element withTransferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]]
          && [[element dicomData] isEqualToData:[NSData dataWithBytes:expected length:sizeof(expected)]] && [read getGroup:element] == 0x0028 && [element nextUnsignedShort] == 0x0010,
          @"an attribute writes its element into a container, which reads the tag back");
    CHECK([DCMValueRepresentation isValidVR:@"PN"] && ![DCMValueRepresentation isValidVR:@"ZZ"] && [DCMValueRepresentation isShortValueLengthVR:@"US"]
          && ![DCMValueRepresentation isShortValueLengthVR:@"OB"] && [DCMValueRepresentation isAffectedBySpecificCharacterSet:@"LO"],
          @"DCMValueRepresentation tells the value representations apart");
    DCMLimitedObject *limited = [DCMLimitedObject objectWithContentsOfFile:path lastGroup:0x0020];
    CHECK([limited isKindOfClass:[DCMLimitedObject class]] && [[limited attributeValueWithName:@"Rows"] intValue] == 64
          && [[NSUserDefaults standardUserDefaults] integerForKey:@"LastGroupRead"] == 0x0020,
          @"+[DCMLimitedObject objectWithContentsOfFile:lastGroup:] reads up to the group, into a DCMLimitedObject");
    limited = [[[DCMLimitedObject alloc] initWithContentsOfFile:path lastGroup:0x0008] autorelease];
    CHECK([limited isKindOfClass:[DCMLimitedObject class]] && [[NSUserDefaults standardUserDefaults] integerForKey:@"LastGroupRead"] == 0x0008,
          @"-[DCMLimitedObject initWithContentsOfFile:lastGroup:] reads up to the group");
    id imported = [DCMObjectDBImport objectWithContentsOfFile:path decodingPixelData:NO];
    char tagString[] = "0010,0010";
    CHECK([imported isMemberOfClass:[DCMObjectDBImport class]] && [imported isKindOfClass:[DCMObject class]] && [imported isNeededAttribute:tagString]
          && [[imported attributeValueWithName:@"PatientsName"] isEqual:@"SYNTHETIC^DCM"],
          @"+[DCMObjectDBImport objectWithContentsOfFile:decodingPixelData:] answers a DCMObjectDBImport");
    CHECK([[DCMObjectPixelDataImport objectWithContentsOfFile:path decodingPixelData:NO] isMemberOfClass:[DCMObjectPixelDataImport class]],
          @"+[DCMObjectPixelDataImport objectWithContentsOfFile:decodingPixelData:] answers a DCMObjectPixelDataImport");
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
    (work / 'main.swift').write_text(harness_defaults.SWIFT + host)
    (work / 'Legacy.m').write_text(plugin)
    (work / 'image.dcm').write_bytes(b'synthetic')
    (work / 'image.dcm.uids.plist').write_bytes(plistlib.dumps(SOP_CLASS_UIDS))
    (work / 'image.dcm.answered.plist').write_bytes(plistlib.dumps(ANSWERED))
    legacy = work / 'Legacy.bundle'
    (legacy / 'Contents/MacOS').mkdir(parents=True)
    (legacy / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'Legacy', 'CFBundleIdentifier': 'org.example.legacy-dcm', 'CFBundlePackageType': 'BNDL',
        'NSPrincipalClass': 'LegacyDCMProbe'}))
    # The selectors of an extension of DCMObject are sent by name, so nothing in
    # the host names the object that holds them. The application links every
    # object of a module; the host takes every object of the dataset library.
    built = run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Host', *target, *flags,
                 '-Xlinker', '-force_load', '-Xlinker', str(modules / f'lib{MODULE}.a'),
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
