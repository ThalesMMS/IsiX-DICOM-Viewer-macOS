#!/usr/bin/env python3
"""The DCMTK of the browser, database, viewer and XML editor answers through the adapter.

The DCMTK categories of AppController, BrowserController, DicomImage,
XMLController, PreferencesWindowController, DicomDatabase (DCMTK, Scan) and
ViewerController became Swift extensions; what they asked DCMTK is in five
Objective-C++ files of Horos/Sources/Adapters/DCMTK, whose headers carry no
C++ type:

- IsiXDCMTKCodecs: the codec registration, and the JPEG marker policy;
- IsiXDCMTKTranscoding: the name of a UID, what decides whether a file is
  worth compressing, and a copy of a file in another transfer syntax;
- IsiXDCMTKDicomDir: the records of a DICOMDIR that name a file, with the
  elements of the records above them, and their icon;
- IsiXDCMTKStructuredReportReader: whether a file reads as a structured
  report, its title's meaning and the images it references, compared with
  what the former DicomImage category read (history_reference);
- IsiXDCMTKTagEditor: tag edits written into a file, the character set a file
  must declare, and the in-place replacement of a screen capture.

They are compiled here against the DCMTK and OpenJPEG of the Debug build (exit
2 without it) with a driver that writes its own files through DCMTK, checks
each adapter's answers, provokes a DCMTK error (a file that is not DICOM) and a
C++ exception (operator new throws std::bad_alloc inside DCMTK), and checks
that each one is an NSError, or a refusal, and not a terminated process.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SOURCES = [ADAPTERS / name for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKCodecs.mm', 'IsiXDCMTKTranscoding.mm',
                                        'IsiXDCMTKDicomDir.mm', 'IsiXDCMTKStructuredReportReader.mm',
                                        'IsiXDCMTKTagEditor.mm')]
CPP = [ROOT / 'Horos/Sources/Adapters/DCMTK/HorosJPEG2000Codec.cpp', ROOT / 'Horos/Sources/Adapters/DCMTK/HorosStructuredReportBridge.cpp']
CATEGORY = 'Horos/Sources/DicomImageDCMTKCategory.mm'

flags = dcmtk_flags('dcmnet', 'dcmsr', 'dcmjpls', 'dcmtkcharls', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16', 'dcmimage', 'dcmimgle')
openjpeg_archive = BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a'
if not openjpeg_archive.is_file():
    print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(openjpeg_archive))
    raise SystemExit(2)
openjpeg = ['-I' + str(BUILD / 'OpenJPEG.build/Install/include'),
            *['-I' + str(path) for path in sorted((BUILD / 'OpenJPEG.build/Install/include').glob('openjpeg-*'))]]

# What the former category read, to compare the report reader with.
if (ROOT / CATEGORY).exists():
    category = (ROOT / CATEGORY).read_bytes().decode('latin1')
else:
    head = subprocess.run(['git', '-C', str(ROOT), 'show', 'HEAD:' + CATEGORY], capture_output=True)
    revision = None if head.returncode == 0 else history_reference.before_removal(CATEGORY)
    if head.returncode != 0 and revision is None:
        print('skipped: needs the history that has ' + CATEGORY)
        raise SystemExit(2)
    category = (head.stdout if head.returncode == 0 else history_reference.show(revision, CATEGORY)).decode('latin1')


def body(signature):
    at = category.index(signature)
    opening = category.index('{', at)
    depth = 0
    for index in range(opening, len(category)):
        depth += (category[index] == '{') - (category[index] == '}')
        if depth == 0:
            return category[opening:index + 1]
    raise SystemExit('FAIL: unbalanced ' + signature)


former_type = body('- (NSString*) keyObjectType').replace('[[self completePath] UTF8String]', 'path.UTF8String')
former_references = body('- (NSArray*) referencedObjects').replace('[[self completePath] UTF8String]', 'path.UTF8String')

# Stands in for the DICOM value types of IsiXDICOMFile, which the adapters
# import through its generated header.
STUBS = r'''
#import <Foundation/Foundation.h>
@interface IsiXDICOMAttributeTag : NSObject
@property (readonly) int group;
@property (readonly) int element;
+ (id)tagWithGroup:(int)group element:(int)element;
@end
@interface IsiXDICOMCharacterSet : NSObject
+ (NSString *)characterSetWhenAbsent;
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)characterSet;
@end
'''

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKCodecs.h"
#import "IsiXDCMTKTranscoding.h"
#import "IsiXDCMTKDicomDir.h"
#import "IsiXDCMTKStructuredReportReader.h"
#import "IsiXDCMTKTagEditor.h"
#import "IsiXDICOMFile-Swift.h"
#undef verify
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcdicdir.h>
#include <dcmtk/dcmsr/dsrdoc.h>
#include "HorosStructuredReportBridge.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>

@implementation IsiXDICOMAttributeTag {
    int _g, _e;
}
+ (id)tagWithGroup:(int)group element:(int)element { IsiXDICOMAttributeTag *t = [self new]; t->_g = group; t->_e = element; return t; }
- (int)group { return _g; }
- (int)element { return _e; }
@end
@implementation IsiXDICOMCharacterSet
+ (NSString *)characterSetWhenAbsent { return @"ISO_IR 100"; }
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)c { return [c isEqualToString:@"ISO_IR 192"] ? NSUTF8StringEncoding : NSISOLatin1StringEncoding; }
@end

static bool failNew = false;
void *operator new(std::size_t size)
{
    if (failNew) throw std::bad_alloc();
    if (void *memory = std::malloc(size ? size : 1)) return memory;
    throw std::bad_alloc();
}
void operator delete(void *memory) noexcept { std::free(memory); }

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}
static bool thrown(NSError *error)
{
    return [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code == IsiXDCMTKErrorCodeException;
}

// The former DicomImage (DicomImageDCMTKCategory) reading, cut out of the category.
static NSString *formerKeyObjectType(NSString *path)
FORMER_TYPE
static NSArray *formerReferencedObjects(NSString *path)
FORMER_REFERENCES

static void writeImage(NSString *path, const char *modality)
{
    DcmFileFormat file;
    DcmDataset *d = file.getDataset();
    d->putAndInsertString(DCM_SOPClassUID, UID_CTImageStorage);
    d->putAndInsertString(DCM_SOPInstanceUID, "1.2.826.0.1.3680043.10.543.1489.1");
    d->putAndInsertString(DCM_StudyInstanceUID, "1.2.826.0.1.3680043.10.543.1489.2");
    d->putAndInsertString(DCM_SeriesInstanceUID, "1.2.826.0.1.3680043.10.543.1489.3");
    if (modality) d->putAndInsertString(DCM_Modality, modality);
    d->putAndInsertString(DCM_PatientName, "ADAPTER^TEST");
    d->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100");
    d->putAndInsertString(DCM_InstanceNumber, "1");
    d->putAndInsertUint16(DCM_SamplesPerPixel, 1);
    d->putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
    d->putAndInsertUint16(DCM_Rows, 4);
    d->putAndInsertUint16(DCM_Columns, 6);
    d->putAndInsertUint16(DCM_BitsAllocated, 16);
    d->putAndInsertUint16(DCM_BitsStored, 12);
    d->putAndInsertUint16(DCM_HighBit, 11);
    d->putAndInsertUint16(DCM_PixelRepresentation, 0);
    Uint16 pixels[24];
    for (int i = 0; i < 24; i++) pixels[i] = (Uint16)(i * 100);
    d->putAndInsertUint16Array(DCM_PixelData, pixels, 24);
    file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit);
}

static OFString valueOf(NSString *path, const DcmTagKey &key)
{
    DcmFileFormat file;
    OFString value;
    if (file.loadFile(path.fileSystemRepresentation).good()) file.getDataset()->findAndGetOFStringArray(key, value);
    return value;
}

static E_TransferSyntax syntaxOf(NSString *path)
{
    DcmFileFormat file;
    if (file.loadFile(path.fileSystemRepresentation).bad()) return EXS_Unknown;
    return file.getDataset()->getOriginalXfer();
}

// DCMTK reads the SOP of each referenced file, relative to the current folder,
// which the driver runs in.
static void writeDicomDir(NSString *path, bool withIcon)
{
    [NSFileManager.defaultManager createDirectoryAtPath:@"IMAGES" withIntermediateDirectories:YES attributes:nil error:nil];
    writeImage(@"IMAGES/IM1", "CT");
    writeImage(@"IMAGES/IM2", "CT");
    DcmDicomDir dir(path.fileSystemRepresentation, "ADAPTER");
    DcmDirectoryRecord *patient = new DcmDirectoryRecord(ERT_Patient, NULL, NULL);
    patient->putAndInsertString(DCM_PatientID, "P-1489");
    patient->putAndInsertString(DCM_PatientName, "FROM^PATIENT");
    DcmDirectoryRecord *study = new DcmDirectoryRecord(ERT_Study, NULL, NULL);
    study->putAndInsertString(DCM_StudyInstanceUID, "1.2.3.10");
    DcmDirectoryRecord *series = new DcmDirectoryRecord(ERT_Series, NULL, NULL);
    series->putAndInsertString(DCM_SeriesInstanceUID, "1.2.3.20");
    series->putAndInsertString(DCM_Modality, "CT");
    for (int i = 1; i <= 2; i++) {
        char fileID[32];
        snprintf(fileID, sizeof fileID, "IMAGES\\IM%d", i);
        DcmDirectoryRecord *image = new DcmDirectoryRecord(ERT_Image, fileID, NULL);
        image->putAndInsertString(DCM_InstanceNumber, i == 1 ? "1" : "2");
        image->putAndInsertString(DCM_ReferencedSOPInstanceUIDInFile, i == 1 ? "1.2.3.31" : "1.2.3.32");
        if (i == 2) image->putAndInsertString(DCM_PatientName, "FROM^IMAGE");
        if (withIcon && i == 1) {
            DcmItem *icon = new DcmItem();
            icon->putAndInsertUint16(DCM_SamplesPerPixel, 1);
            icon->putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
            icon->putAndInsertUint16(DCM_Rows, 2);
            icon->putAndInsertUint16(DCM_Columns, 2);
            icon->putAndInsertUint16(DCM_BitsAllocated, 8);
            icon->putAndInsertUint16(DCM_BitsStored, 8);
            icon->putAndInsertUint16(DCM_HighBit, 7);
            icon->putAndInsertUint16(DCM_PixelRepresentation, 0);
            Uint8 data[4] = {1, 2, 3, 4};
            icon->putAndInsertUint8Array(DCM_PixelData, data, 4);
            image->insertSequenceItem(DCM_IconImageSequence, icon);
        }
        series->insertSub(image);
    }
    study->insertSub(series);
    patient->insertSub(study);
    dir.getRootRecord().insertSub(patient);
    dir.write(DICOMDIR_DEFAULT_TRANSFERSYNTAX, EET_UndefinedLength, EGL_withoutGL);
}

static void writeReport(NSString *path)
{
    DSRDocument doc(DSRTypes::DT_ComprehensiveSR);
    doc.setPatientName("REPORT^TEST");
    doc.getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
    doc.getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("113000", "DCM", "Of Interest"));
    doc.getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_belowCurrent);
    doc.getTree().getCurrentContentItem().setImageReference(DSRImageReferenceValue(UID_CTImageStorage, "1.2.3.4.5"));
    doc.getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_afterCurrent);
    doc.getTree().getCurrentContentItem().setImageReference(DSRImageReferenceValue(UID_CTImageStorage, "1.2.3.4.6"));
    DcmFileFormat file;
    doc.write(*file.getDataset());
    file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSString *(^at)(NSString *) = ^(NSString *name) { return [folder stringByAppendingPathComponent:name]; };
        NSError *error = nil;
        [@"arbitrary text, not DICOM" writeToFile:at(@"text.dcm") atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // ---- IsiXDCMTKCodecs
        failNew = true;
        BOOL registered = [IsiXDCMTKCodecs registerCodecs:&error];
        failNew = false;
        check(!registered && thrown(error), "codecs: std::bad_alloc while registering is an NSError");
        error = nil;
        check([IsiXDCMTKCodecs registerCodecs:&error] && error == nil, "codecs: they register");
        check([IsiXDCMTKCodecs registerCodecs:&error], "codecs: registering again is a no-op");
        check(IsiXDCMTKCodecs.markersDecideColour, "codecs: JPEG markers decide the colour until told otherwise");
        IsiXDCMTKCodecs.markersDecideColour = NO;
        check(!IsiXDCMTKCodecs.markersDecideColour, "codecs: the marker policy follows the preference");
        IsiXDCMTKCodecs.markersDecideColour = YES;

        // ---- IsiXDCMTKTranscoding
        writeImage(at(@"native.dcm"), "CT");
        writeImage(at(@"nomodality.dcm"), NULL);
        check([[IsiXDCMTKTranscoding nameOfUID:@"1.2.840.10008.1.2.1"] isEqualToString:@"LittleEndianExplicit"],
              "transcoding: a UID's name is DCMTK's");
        check([IsiXDCMTKTranscoding nameOfUID:@"1.2.3.4.5.6.7"] == nil, "transcoding: an unknown UID has none");
        IsiXDCMTKCompressionFacts *facts = [IsiXDCMTKTranscoding compressionFactsOfFileAtPath:at(@"native.dcm") error:&error];
        check(facts && !facts.pixelDataCompressed && [facts.modality isEqualToString:@"CT"] &&
              [facts.SOPClassUID isEqualToString:@UID_CTImageStorage] && facts.rows.intValue == 4 && facts.columns.intValue == 6,
              "transcoding: an uncompressed CT's facts");
        facts = [IsiXDCMTKTranscoding compressionFactsOfFileAtPath:at(@"nomodality.dcm") error:&error];
        check([facts.modality isEqualToString:@"OT"], "transcoding: a missing modality reads OT");
        error = nil;
        check([IsiXDCMTKTranscoding compressionFactsOfFileAtPath:at(@"text.dcm") error:&error] == nil &&
              [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code != IsiXDCMTKErrorCodeException,
              "transcoding: a file that is not DICOM is DCMTK's NSError");
        printf("  %s\n", error.localizedDescription.UTF8String);

        __block int asked = 0;
        BOOL (^never)(NSString *, NSString *) = ^BOOL(NSString *o, NSString *r) { asked++; return NO; };
        IsiXDCMTKTranscodeOutcome outcome = [IsiXDCMTKTranscoding transcodeFileAtPath:at(@"native.dcm") toTransferSyntax:@"1.2.840.10008.1.2.5"
            quality:0 destination:at(@"rle.dcm") servesOriginal:never error:&error];
        check(outcome == IsiXDCMTKTranscodeOutcomeWritten && asked == 1 && syntaxOf(at(@"rle.dcm")) == EXS_RLELossless,
              "transcoding: a copy in RLE, the original syntax asked about once");
        outcome = [IsiXDCMTKTranscoding transcodeFileAtPath:at(@"native.dcm") toTransferSyntax:@"1.2.840.10008.1.2.4.80"
            quality:0 destination:at(@"jls.dcm") servesOriginal:never error:&error];
        check(outcome == IsiXDCMTKTranscodeOutcomeWritten && syntaxOf(at(@"jls.dcm")) == EXS_JPEGLSLossless,
              "transcoding: a copy in JPEG-LS through the registered codec");
        facts = [IsiXDCMTKTranscoding compressionFactsOfFileAtPath:at(@"rle.dcm") error:&error];
        check(facts.pixelDataCompressed, "transcoding: an RLE file's pixels are compressed");
        __block NSString *seen = nil;
        outcome = [IsiXDCMTKTranscoding transcodeFileAtPath:at(@"rle.dcm") toTransferSyntax:@"1.2.840.10008.1.2.5" quality:0
            destination:at(@"none.dcm") servesOriginal:^BOOL(NSString *o, NSString *r) { seen = o; return [o isEqualToString:r]; } error:&error];
        check(outcome == IsiXDCMTKTranscodeOutcomeServesOriginal && [seen isEqualToString:@"1.2.840.10008.1.2.5"] &&
              ![NSFileManager.defaultManager fileExistsAtPath:at(@"none.dcm")], "transcoding: a file that serves the syntax is not copied");
        error = nil;
        outcome = [IsiXDCMTKTranscoding transcodeFileAtPath:at(@"text.dcm") toTransferSyntax:@"1.2.840.10008.1.2.5" quality:0
            destination:at(@"none.dcm") servesOriginal:never error:&error];
        check(outcome == IsiXDCMTKTranscodeOutcomeUnreadable && error != nil, "transcoding: an unreadable file is an NSError");
        error = nil;
        failNew = true;
        outcome = [IsiXDCMTKTranscoding transcodeFileAtPath:at(@"native.dcm") toTransferSyntax:@"1.2.840.10008.1.2.5" quality:0
            destination:at(@"none.dcm") servesOriginal:never error:&error];
        failNew = false;
        check(outcome == IsiXDCMTKTranscodeOutcomeUnreadable && thrown(error), "transcoding: std::bad_alloc while loading is an NSError");
        error = nil;
        failNew = true;
        facts = [IsiXDCMTKTranscoding compressionFactsOfFileAtPath:at(@"native.dcm") error:&error];
        failNew = false;
        check(facts == nil && thrown(error), "transcoding: and so it is for the compression facts");

        // ---- IsiXDCMTKDicomDir
        writeDicomDir(at(@"DICOMDIR"), true);
        NSArray *tags = @[@0x00041500, @0x00100010, @0x00100020, @0x0020000E, @0x00200013, @0x00041511, @0x00080060, @0x00880200, @0x7fe00010];
        NSArray<IsiXDCMTKDirectoryRecord *> *records = [IsiXDCMTKDicomDir fileRecordsOfDicomDirAtPath:at(@"DICOMDIR") tags:tags error:&error];
        NSString *(^text)(IsiXDCMTKDirectoryRecord *, uint32_t) = ^NSString *(IsiXDCMTKDirectoryRecord *r, uint32_t tag) {
            id v = r.values[@(tag)];
            return [v isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:v encoding:NSISOLatin1StringEncoding] : nil;
        };
        check(records.count == 2, "dicomdir: one entry per record that names a file");
        if (records.count != 2) printf("  %lu records, error %s\n", (unsigned long)records.count, error.localizedDescription.UTF8String);
        if (records.count == 2) {
            check([text(records[0], 0x00041500) isEqualToString:@"IMAGES\\IM1"] && [text(records[1], 0x00041500) isEqualToString:@"IMAGES\\IM2"],
                  "dicomdir: in the order of the records, with their file IDs");
            check([text(records[0], 0x00100020) isEqualToString:@"P-1489"] && [text(records[0], 0x0020000E) isEqualToString:@"1.2.3.20"] &&
                  [text(records[0], 0x00080060) isEqualToString:@"CT"], "dicomdir: with the elements of the records above");
            check([text(records[0], 0x00100010) isEqualToString:@"FROM^PATIENT"] && [text(records[1], 0x00100010) isEqualToString:@"FROM^IMAGE"],
                  "dicomdir: a record's own element wins over an ancestor's");
            check(records[0].values[@0x00880200] == NSNull.null && records[0].values[@0x00080016] == nil,
                  "dicomdir: an element without text is NSNull, one not asked for is absent");
            IsiXDCMTKDirectoryIcon *icon = records[0].icon;
            const uint8_t expected[4] = {1, 2, 3, 4};
            check(icon && icon.bitsAllocated == 8 && icon.rows == 2 && icon.columns == 2 &&
                  [icon.photometricInterpretation isEqualToString:@"MONOCHROME2"] &&
                  [icon.pixels isEqualToData:[NSData dataWithBytes:expected length:4]] && records[1].icon == nil,
                  "dicomdir: the icon of the record that has one");
        }
        error = nil;
        records = [IsiXDCMTKDicomDir fileRecordsOfDicomDirAtPath:at(@"text.dcm") tags:tags error:&error];
        check(records != nil && records.count == 0 && error == nil, "dicomdir: a file that is not a DICOMDIR has no records");
        error = nil;
        failNew = true;
        records = [IsiXDCMTKDicomDir fileRecordsOfDicomDirAtPath:at(@"DICOMDIR") tags:tags error:&error];
        failNew = false;
        check(records == nil && thrown(error), "dicomdir: std::bad_alloc while reading is an NSError");

        // ---- IsiXDCMTKStructuredReportReader
        writeReport(at(@"report.dcm"));
        check([IsiXDCMTKStructuredReportReader canReadReportAtPath:at(@"report.dcm") error:&error], "report: it reads");
        NSString *title = [IsiXDCMTKStructuredReportReader titleMeaningOfReportAtPath:at(@"report.dcm") error:&error];
        NSString *formerTitle = formerKeyObjectType(at(@"report.dcm"));
        check(title && [title isEqualToString:formerTitle], "report: its title's meaning is what the category read");
        printf("  title %s\n", title.UTF8String);
        NSArray *references = [IsiXDCMTKStructuredReportReader referencedImageInstancesOfReportAtPath:at(@"report.dcm")];
        check([references isEqualToArray:formerReferencedObjects(at(@"report.dcm"))] && references.count == 2,
              "report: its images are those the category read, in order");
        error = nil;
        check(![IsiXDCMTKStructuredReportReader canReadReportAtPath:at(@"native.dcm") error:&error] &&
              [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code != IsiXDCMTKErrorCodeException,
              "report: an image is not a report, and DCMTK says why");
        printf("  %s\n", error.localizedDescription.UTF8String);
        check([IsiXDCMTKStructuredReportReader titleMeaningOfReportAtPath:at(@"text.dcm") error:NULL] == nil &&
              formerKeyObjectType(at(@"text.dcm")) == nil &&
              [IsiXDCMTKStructuredReportReader referencedImageInstancesOfReportAtPath:at(@"text.dcm")].count == 0,
              "report: nothing of a file that is not DICOM, as before");
        error = nil;
        failNew = true;
        BOOL read = [IsiXDCMTKStructuredReportReader canReadReportAtPath:at(@"report.dcm") error:&error];
        failNew = false;
        check(!read && thrown(error), "report: std::bad_alloc while reading is an NSError");

        // ---- IsiXDCMTKTagEditor
        writeImage(at(@"edit.dcm"), "CT");
        NSArray *reasons = nil;
        BOOL modified = [IsiXDCMTKTagEditor modifyFiles:@[at(@"edit.dcm")]
            withEntries:@[@[[IsiXDICOMAttributeTag tagWithGroup:0x0010 element:0x0010], @"EDITED^NAME"], @[[IsiXDICOMAttributeTag tagWithGroup:0x0020 element:0x0013]]]
            reasons:&reasons];
        check(modified && valueOf(at(@"edit.dcm"), DCM_PatientName) == "EDITED^NAME" && valueOf(at(@"edit.dcm"), DCM_InstanceNumber).empty(),
              "tags: a replacement and a removal are written");
        reasons = nil;
        modified = [IsiXDCMTKTagEditor modifyFiles:@[at(@"text.dcm")]
            withEntries:@[@[[IsiXDICOMAttributeTag tagWithGroup:0x0010 element:0x0010], @"X"]] reasons:&reasons];
        check(!modified && reasons.count == 2 && [reasons[1] containsString:@"could not be read"],
              "tags: a file that is not DICOM is refused with what DCMTK said");
        printf("  %s\n", [reasons[1] UTF8String]);
        NSData *before = [NSData dataWithContentsOfFile:at(@"edit.dcm")];
        reasons = nil;
        failNew = true;
        modified = [IsiXDCMTKTagEditor modifyFiles:@[at(@"edit.dcm")]
            withEntries:@[@[[IsiXDICOMAttributeTag tagWithGroup:0x0010 element:0x0010], @"THROWN"]] reasons:&reasons];
        failNew = false;
        check(!modified && [reasons.lastObject containsString:@"no edits were saved"] &&
              [[NSData dataWithContentsOfFile:at(@"edit.dcm")] isEqualToData:before],
              "tags: std::bad_alloc while editing is a refusal, and the file is unchanged");
        printf("  %s\n", [reasons.lastObject UTF8String]);
        BOOL refused = YES;
        check([IsiXDCMTKTagEditor characterSetToDeclareForValues:@[@"ASCII"] inFileAtPath:at(@"edit.dcm") refused:&refused] == nil && !refused,
              "tags: ASCII text needs no character set");
        refused = NO;
        check([IsiXDCMTKTagEditor characterSetToDeclareForValues:@[@"X"] inFileAtPath:at(@"text.dcm") refused:&refused] == nil && refused,
              "tags: a file that cannot be read cannot take the values");
        refused = NO;
        failNew = true;
        NSString *declared = [IsiXDCMTKTagEditor characterSetToDeclareForValues:@[@"X"] inFileAtPath:at(@"edit.dcm") refused:&refused];
        failNew = false;
        check(declared == nil && refused, "tags: nor one DCMTK throws on");
        error = nil;
        check([IsiXDCMTKTagEditor replaceStringValues:@{@0x00200013: @"7", @0x0020000E: @"1.2.3.99"} inFileAtPath:at(@"edit.dcm") error:&error] &&
              valueOf(at(@"edit.dcm"), DCM_InstanceNumber) == "7" && valueOf(at(@"edit.dcm"), DCM_SeriesInstanceUID) == "1.2.3.99" &&
              syntaxOf(at(@"edit.dcm")) == EXS_LittleEndianExplicit, "tags: a capture joins its series in place");
        error = nil;
        check(![IsiXDCMTKTagEditor replaceStringValues:@{@0x00200013: @"8"} inFileAtPath:at(@"text.dcm") error:&error] &&
              [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code != IsiXDCMTKErrorCodeException,
              "tags: a capture that is not DICOM is DCMTK's NSError");
        error = nil;
        failNew = true;
        BOOL replaced = [IsiXDCMTKTagEditor replaceStringValues:@{@0x00200013: @"9"} inFileAtPath:at(@"edit.dcm") error:&error];
        failNew = false;
        check(!replaced && thrown(error) && valueOf(at(@"edit.dcm"), DCM_InstanceNumber) == "7",
              "tags: std::bad_alloc while replacing is an NSError");

        check([IsiXDCMTKCodecs cleanupCodecs:&error], "codecs: they are removed");
    }
    return failures ? 1 : 0;
}
'''.replace('FORMER_TYPE', former_type).replace('FORMER_REFERENCES', former_references)

with tempfile.TemporaryDirectory(prefix='isix-dcmtk-database-adapters-') as directory:
    work = Path(directory)
    (work / 'IsiXDICOMFile-Swift.h').write_text(STUBS)
    (work / 'driver.mm').write_text(DRIVER)
    (work / 'files').mkdir()
    common = ['xcrun', 'clang++', '-std=gnu++17', '-w', '-I' + str(work), '-I' + str(ADAPTERS), *openjpeg]
    objects = []
    for source in CPP:
        obj = work / (source.stem + '.o')
        built = subprocess.run([*common, '-x', 'c++', '-c', str(source), *flags[:2], '-o', str(obj)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            print(built.stderr[-4000:])
            print('FAIL: %s does not compile against the build\'s DCMTK' % source.name)
            raise SystemExit(1)
        objects.append(str(obj))
    driver = work / 'driver.o'
    built = subprocess.run([*common, '-fno-objc-arc', '-x', 'objective-c++', '-c', str(work / 'driver.mm'), *flags[:2],
                            '-o', str(driver)], capture_output=True, text=True, timeout=300)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the driver does not compile')
        raise SystemExit(1)
    strict = ['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror', '-Wno-unused-parameter',
              '-I' + str(work), '-I' + str(ADAPTERS), *openjpeg]
    linked = subprocess.run([*strict, '-x', 'objective-c++', *map(str, SOURCES), '-x', 'none', str(driver), *objects,
                             *flags, str(openjpeg_archive), '-lxml2', '-framework', 'Foundation', '-o', str(work / 'check')],
                            capture_output=True, text=True, timeout=600)
    if linked.returncode:
        print(linked.stderr[-4000:])
        print('FAIL: the adapters do not compile or link against the build\'s DCMTK')
        raise SystemExit(1)
    try:
        run = subprocess.run([str(work / 'check'), str(work / 'files')], capture_output=True, text=True, timeout=60,
                             cwd=str(work / 'files'))
    except subprocess.TimeoutExpired:
        print('FAIL: the adapter driver did not end within 60 s')
        raise SystemExit(1)
    print(run.stdout, end='')
    if run.returncode:
        print('FAIL: the driver exited with %d\n%s' % (run.returncode, run.stderr[-2000:]))
        raise SystemExit(1)
print('PASS: the codecs, transcoding, DICOMDIR, report and tag editing adapters answer through DCMTK; '
      'a DCMTK refusal and a C++ exception are NSErrors or refusals')
