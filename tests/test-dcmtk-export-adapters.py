#!/usr/bin/env python3
"""The DCMTK of the anonymization, the DICOMDIR, the reports and the export answers through the adapter.

HorosGDCMAnonymizer, DicomDir, SRAnnotation and DICOMExport became Swift; what
they asked DCMTK is in the Objective-C++ of Horos/Sources/Adapters/DCMTK, whose
headers carry no C++ type:

- IsiXDCMTKAnonymizationFile: the staged copy of a file, its identity, the
  facts of a selected tag, a replacement encoded in its character set, the
  replacement itself and the verified copy written beside it;
- IsiXDCMTKDicomDir: the files of an export folder and the DICOMDIR written
  for them, with the series icons;
- IsiXDCMTKStructuredReport: a report read, assembled and written, through
  HorosStructuredReportBridge;
- IsiXDCMTKFile and IsiXDCMTKItem: what the export does to a dataset (empty
  elements, 16-bit words, removals, a group removed through the sequences, the
  representation and the date and time of a new instance).

They are compiled here as the application compiles them (ARC), against the
DCMTK of the Debug build (exit 2 without it), with a driver that writes its own
files through DCMTK, checks the answers, provokes DCMTK errors (a file that is
not DICOM, a UID DCMTK refuses, a file a DICOMDIR cannot take) and a C++
exception (operator new throws std::bad_alloc inside DCMTK), and checks that
each one is an NSError or a refusal and not a terminated process, and that the
next call works.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402

ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'
SOURCES = [ADAPTERS / name for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKFile.mm', 'IsiXDCMTKAnonymizer.mm',
                                        'IsiXDCMTKDicomDir.mm', 'IsiXDCMTKStructuredReportReader.mm')]
CPP = [ADAPTERS / 'HorosStructuredReportBridge.cpp', ADAPTERS / 'HorosJPEG2000Codec.cpp']

flags = dcmtk_flags('dcmnet', 'dcmsr', 'dcmjpls', 'dcmtkcharls', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16', 'dcmimage',
                    'dcmimgle')
# IsiXDCMTKFile changes representation through the host's codecs, JPEG 2000 included.
openjpeg_archive = BUILD / 'OpenJPEG.build/Install/lib/libopenjp2.a'
if not openjpeg_archive.is_file():
    print('skipped: needs a current build from script/build_and_run.sh --verify: ' + str(openjpeg_archive))
    raise SystemExit(2)
openjpeg = ['-I' + str(BUILD / 'OpenJPEG.build/Install/include'),
            *['-I' + str(path) for path in sorted((BUILD / 'OpenJPEG.build/Install/include').glob('openjpeg-*'))]]

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKFile.h"
#import "IsiXDCMTKAnonymizer.h"
#import "IsiXDCMTKDicomDir.h"
#import "IsiXDCMTKStructuredReportReader.h"
#undef verify
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <cstdio>
#include <cstdlib>
#include <new>

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
static bool refusedByDCMTK(NSError *error)
{
    return [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code != IsiXDCMTKErrorCodeException;
}

static void writeImage(NSString *path, const char *instance, const char *series)
{
    DcmFileFormat file;
    DcmDataset *d = file.getDataset();
    d->putAndInsertString(DCM_SOPClassUID, UID_CTImageStorage);
    d->putAndInsertString(DCM_SOPInstanceUID, instance);
    d->putAndInsertString(DCM_StudyInstanceUID, "1.2.826.0.1.3680043.10.543.1488.1");
    d->putAndInsertString(DCM_SeriesInstanceUID, series);
    d->putAndInsertString(DCM_Modality, "CT");
    d->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100");
    d->putAndInsertString(DCM_PatientName, "ADAPTER^TEST");
    d->putAndInsertString(DCM_PatientID, "1488");
    d->putAndInsertString(DCM_StudyDate, "20261028");
    d->putAndInsertString(DCM_StudyTime, "101010");
    d->putAndInsertString(DCM_InstanceNumber, "1");
    d->putAndInsertString(DCM_SeriesNumber, "1");
    d->putAndInsertString(DcmTagKey(0x0009, 0x0010), "ISIX ADAPTER");
    d->putAndInsertString(DcmTag(0x0009, 0x1010, EVR_LO), "private");
    DcmItem *item = NULL;
    d->findOrCreateSequenceItem(DCM_ReferencedStudySequence, item, -2);
    if (item) item->putAndInsertString(DCM_ReferencedSOPInstanceUID, "1.2.3");
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

static NSData *utf8(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSString *(^at)(NSString *) = ^(NSString *name) { return [folder stringByAppendingPathComponent:name]; };
        [@"not DICOM" writeToFile:at(@"text.dcm") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSError *error = nil;

        // ---- IsiXDCMTKAnonymizationFile
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:at(@"anon") withIntermediateDirectories:YES attributes:nil error:NULL];
        writeImage(at(@"anon/IM1"), "1.2.826.0.1.3680043.10.543.1488.10", "1.2.826.0.1.3680043.10.543.1488.2");
        check([IsiXDCMTKAnonymizationFile stagedFileAtPath:at(@"text.dcm")] == nil,
              "anonymization: a file that is not DICOM is not staged");
        check([IsiXDCMTKAnonymizationFile stagedFileAtPath:at(@"anon/missing")] == nil,
              "anonymization: nor a missing one");
        IsiXDCMTKAnonymizationFile *staged = [IsiXDCMTKAnonymizationFile stagedFileAtPath:at(@"anon/IM1")];
        check(staged && [staged.datasetSOPClassUID isEqualToString:@UID_CTImageStorage] &&
              [staged.datasetSOPInstanceUID isEqualToString:@"1.2.826.0.1.3680043.10.543.1488.10"] &&
              staged.metaStorageSOPClassUID != nil && staged.canKeepTransferSyntax && [staged recordShape],
              "anonymization: the staged file's identity, syntax and shape");
        check([staged.characterSet isEqualToData:[@"ISO_IR 100" dataUsingEncoding:NSASCIIStringEncoding]],
              "anonymization: the declared character set");
        IsiXDCMTKSelectedElement *name = [staged elementForTag:0x00100010];
        IsiXDCMTKSelectedElement *pixels = [staged elementForTag:0x7fe00010];
        IsiXDCMTKSelectedElement *absent = [staged elementForTag:0x00081030];
        check(name.exists && [name.valueRepresentation isEqualToString:@"PN"] && name.catalogPolicy == 1 &&
              pixels.exists && pixels.isPixelData && pixels.catalogPolicy == 2 &&
              !absent.exists && [absent.dictionaryValueRepresentation isEqualToString:@"LO"],
              "anonymization: the facts of selected tags");
        NSData *latin = [staged encodeUTF8:utf8(@"Müller^José") valueRepresentation:@"PN" codeExtensions:NO];
        check([latin isEqualToData:[@"Müller^José" dataUsingEncoding:NSISOLatin1StringEncoding]],
              "anonymization: text encoded in ISO_IR 100");
        check([staged encodeUTF8:utf8(@"患者") valueRepresentation:@"PN" codeExtensions:NO] == nil,
              "anonymization: text ISO_IR 100 cannot hold is refused by DCMTK");
        check([staged applyReplacement:IsiXDCMTKSelectedReplacementPutIntoExisting toTag:0x00100010 value:latin],
              "anonymization: text into an existing element");
        check([staged applyReplacement:IsiXDCMTKSelectedReplacementClearExisting toTag:0x00091010 value:[NSData data]],
              "anonymization: a private element emptied");
        check([staged applyReplacement:IsiXDCMTKSelectedReplacementInsertEmptySequence toTag:0x00081110 value:[NSData data]],
              "anonymization: a sequence emptied");
        check([staged applyReplacement:IsiXDCMTKSelectedReplacementInsertText toTag:0x00081030 value:utf8(@"STUDY")],
              "anonymization: text inserted");
        check([staged applyReplacement:IsiXDCMTKSelectedReplacementEmptyPixelData toTag:0x7fe00010 value:[NSData data]],
              "anonymization: the pixel data emptied");
        check(![staged applyReplacement:IsiXDCMTKSelectedReplacementClearExisting toTag:0x00091020 value:[NSData data]],
              "anonymization: an absent element cannot be emptied");
        check([staged recordShape] &&
              [staged writeVerifiedCopyToPath:at(@"anon/anon_IM1") temporaryTemplate:@".horos-anonymized-XXXXXX"
                                 storageClass:@UID_CTImageStorage instance:@"1.2.826.0.1.3680043.10.543.1488.10"] &&
              valueOf(at(@"anon/anon_IM1"), DCM_PatientName) == "M\xfcller^Jos\xe9" &&
              valueOf(at(@"anon/anon_IM1"), DCM_StudyDescription) == "STUDY" &&
              valueOf(at(@"anon/anon_IM1"), DcmTagKey(0x0009, 0x1010)).empty(),
              "anonymization: the verified copy is written");
        check(![staged writeVerifiedCopyToPath:at(@"anon/anon_IM2") temporaryTemplate:@".horos-anonymized-XXXXXX"
                                  storageClass:@UID_CTImageStorage instance:@"1.2.3.4"] &&
              ![manager fileExistsAtPath:at(@"anon/anon_IM2")],
              "anonymization: a copy whose identity does not read back is not committed");
        failNew = true;
        IsiXDCMTKAnonymizationFile *thrownStage = [IsiXDCMTKAnonymizationFile stagedFileAtPath:at(@"anon/IM1")];
        failNew = false;
        check(thrownStage == nil, "anonymization: std::bad_alloc while reading is a refusal");
        failNew = true;
        BOOL applied = [staged applyReplacement:IsiXDCMTKSelectedReplacementInsertText toTag:0x00081030 value:utf8(@"X")];
        BOOL written = [staged writeVerifiedCopyToPath:at(@"anon/anon_IM3") temporaryTemplate:@".horos-anonymized-XXXXXX"
                                          storageClass:@UID_CTImageStorage instance:@"1.2.826.0.1.3680043.10.543.1488.10"];
        failNew = false;
        NSArray *left = [[manager contentsOfDirectoryAtPath:at(@"anon") error:NULL]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.horos-anonymized'"]];
        check(!applied && !written && left.count == 0 && ![manager fileExistsAtPath:at(@"anon/anon_IM3")],
              "anonymization: std::bad_alloc while replacing or writing is a refusal, and nothing is left behind");
        check([[IsiXDCMTKAnonymizationFile stagedFileAtPath:at(@"anon/IM1")] recordShape],
              "anonymization: the next file reads");

        // ---- IsiXDCMTKDicomDir
        [manager createDirectoryAtPath:at(@"burn/IMAGES") withIntermediateDirectories:YES attributes:nil error:NULL];
        writeImage(at(@"burn/IMAGES/IM1"), "1.2.826.0.1.3680043.10.543.1488.11", "1.2.826.0.1.3680043.10.543.1488.3");
        writeImage(at(@"burn/IMAGES/IM2"), "1.2.826.0.1.3680043.10.543.1488.12", "1.2.826.0.1.3680043.10.543.1488.3");
        NSArray<NSString *> *listed = [IsiXDCMTKDicomDir relativePathsOfFilesInFolder:at(@"burn") error:&error];
        NSArray *sorted = [listed sortedArrayUsingSelector:@selector(compare:)];
        check([sorted isEqualToArray:@[@"IMAGES/IM1", @"IMAGES/IM2"]], "dicomdir: the folder's files, relative to it");
        error = nil;
        check([IsiXDCMTKDicomDir writeDicomDirAtPath:at(@"burn/DICOMDIR") folder:at(@"burn") relativePaths:listed error:&error],
              "dicomdir: written");
        NSArray *records = [IsiXDCMTKDicomDir fileRecordsOfDicomDirAtPath:at(@"burn/DICOMDIR") tags:@[@0x00100010] error:&error];
        check(records.count == 2 && [records[0] icon] != nil && [[records[0] values][@0x00100010] isEqual:[@"ADAPTER^TEST" dataUsingEncoding:NSASCIIStringEncoding]],
              "dicomdir: its two records read back, with the series icon");
        [@"not DICOM" writeToFile:at(@"burn/IMAGES/TEXT") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        error = nil;
        check(![IsiXDCMTKDicomDir writeDicomDirAtPath:at(@"burn/DICOMDIR2") folder:at(@"burn")
                                        relativePaths:@[@"IMAGES/IM1", @"IMAGES/TEXT"] error:&error] &&
              refusedByDCMTK(error) && [error.localizedDescription hasPrefix:@"Couldn't add IMAGES/TEXT to DICOMDIR: "],
              "dicomdir: a file it cannot take is DCMTK's NSError, named as the export logs it");
        printf("  %s\n", error.localizedDescription.UTF8String);
        error = nil;
        failNew = true;
        BOOL burnt = [IsiXDCMTKDicomDir writeDicomDirAtPath:at(@"burn/DICOMDIR3") folder:at(@"burn")
                                              relativePaths:@[@"IMAGES/IM1"] error:&error];
        failNew = false;
        check(!burnt && thrown(error) && error.userInfo[IsiXDCMTKConditionTextKey] != nil,
              "dicomdir: std::bad_alloc while writing is an NSError with the exception's text");
        error = nil;
        failNew = true;
        NSArray *thrownList = [IsiXDCMTKDicomDir relativePathsOfFilesInFolder:at(@"burn") error:&error];
        failNew = false;
        check(thrownList == nil && thrown(error), "dicomdir: and while listing");

        // ---- IsiXDCMTKStructuredReport
        IsiXDCMTKStructuredReport *report = [IsiXDCMTKStructuredReport new];
        [report createNewDocument:IsiXDCMTKReportTypeBasicText];
        [report addRootContainerWithCode:@"1" scheme:@"99HUG" meaning:@"Annotations"];
        // The image item below the root (the call goes back up to it), then a text item.
        [report addImageReferenceWithCode:@"IHE.10" scheme:@"99HUG" meaning:@"Image Reference"
                                 SOPClass:@UID_CTImageStorage instance:@"1.2.826.0.1.3680043.10.543.1488.11" frames:@"1"];
        [report addTextWithCode:@"CODE_01" scheme:@"99_OFFIS_DCMTK" meaning:@"Description" value:@"{a = 1;}"];
        [report setValue:"ADAPTER^REPORT" ofField:IsiXDCMTKReportFieldPatientName];
        [report setValue:"7" ofField:IsiXDCMTKReportFieldInstanceNumber];
        error = nil;
        check([report createNewSeriesInStudy:@"1.2.076.1" error:&error], "report: a study UID with a leading zero is taken");
        error = nil;
        check(![report createNewSeriesInStudy:@"not.a.uid" error:&error] && refusedByDCMTK(error),
              "report: a UID DCMTK refuses is its NSError");
        NSData *archive = [@"archived" dataUsingEncoding:NSASCIIStringEncoding];
        error = nil;
        check([report prepareFileWithEncapsulatedDocument:archive seriesInstanceUID:@"1.2.826.0.1.3680043.10.543.1488.4"
                                                    error:&error] &&
              [report writePreparedFileAtomicallyToPath:at(@"report.dcm")], "report: written");
        IsiXDCMTKStructuredReport *read = [IsiXDCMTKStructuredReport new];
        BOOL loaded = NO;
        NSData *encapsulated = nil;
        check([read readFileAtPath:at(@"report.dcm") loaded:&loaded encapsulatedDocument:&encapsulated] && loaded &&
              [encapsulated isEqualToData:archive] &&
              [[read valueOfField:IsiXDCMTKReportFieldPatientName] isEqualToData:[@"ADAPTER^REPORT" dataUsingEncoding:NSASCIIStringEncoding]] &&
              [[read valueOfField:IsiXDCMTKReportFieldSeriesInstanceUID] isEqualToData:[@"1.2.826.0.1.3680043.10.543.1488.4" dataUsingEncoding:NSASCIIStringEncoding]] &&
              [[read valueOfField:IsiXDCMTKReportFieldStudyInstanceUID] isEqualToData:[@"1.2.076.1" dataUsingEncoding:NSASCIIStringEncoding]] &&
              [read.currentConceptMeaning isEqualToString:@"Annotations"],
              "report: it reads back, with its archive and header");
        check([[read referencedInstanceOfItemWithCode:@"IHE.10" scheme:@"99HUG" meaning:@"Image Reference"]
                  isEqualToData:[@"1.2.826.0.1.3680043.10.543.1488.11" dataUsingEncoding:NSASCIIStringEncoding]] &&
              [[IsiXDCMTKStructuredReport archivedDataOfFileAtPath:at(@"report.dcm")] isEqualToData:archive],
              "report: its image reference and archive");
        loaded = YES;
        check(![[IsiXDCMTKStructuredReport new] readFileAtPath:at(@"text.dcm") loaded:&loaded encapsulatedDocument:NULL] &&
              !loaded && [IsiXDCMTKStructuredReport archivedDataOfFileAtPath:at(@"text.dcm")] == nil,
              "report: a file that is not DICOM does not load");
        error = nil;
        failNew = true;
        BOOL prepared = [report prepareFileWithEncapsulatedDocument:archive seriesInstanceUID:nil error:&error];
        BOOL readThrown = [[IsiXDCMTKStructuredReport new] readFileAtPath:at(@"report.dcm") loaded:NULL encapsulatedDocument:NULL];
        failNew = false;
        check(!prepared && thrown(error) && !readThrown && ![report writePreparedFileAtomicallyToPath:at(@"report2.dcm")] &&
              ![manager fileExistsAtPath:at(@"report2.dcm")],
              "report: std::bad_alloc while preparing or reading is an NSError or a refusal");
        check([report prepareFileWithEncapsulatedDocument:nil seriesInstanceUID:nil error:&error] &&
              [report writePreparedFileAtomicallyToPath:at(@"report2.dcm")], "report: the next write works");

        // ---- IsiXDCMTKFile and IsiXDCMTKItem for the export
        IsiXDCMTKFile *file = [IsiXDCMTKFile new];
        error = nil;
        check(![file readFileAtPath:at(@"text.dcm") error:&error] && refusedByDCMTK(error),
              "file: a file that is not DICOM is DCMTK's NSError");
        IsiXDCMTKFile *source = [IsiXDCMTKFile new];
        check([source readFileAtPath:at(@"anon/IM1") error:&error], "file: read into an existing file");
        [source loadAllDataIntoMemory];
        [source.dataset removeAllElementsOfGroup:0x0008];
        [source.dataset removeElementForTag:0x00100020];
        check(![source.dataset hasElementForTag:0x00080016 length:NULL] && ![source.dataset hasElementForTag:0x00100020 length:NULL] &&
              [source.dataset itemAtIndex:0 ofSequence:0x00081110] == nil && [source.dataset hasElementForTag:0x00100010 length:NULL],
              "file: a group is removed, through the sequences, and an element");
        IsiXDCMTKItem *dataset = file.dataset;
        Uint16 words[4] = {1, 2, 300, 65535};
        check([dataset insertEmptyElementForTag:0x00080020 error:&error] && [dataset hasElementForTag:0x00080020 length:NULL] &&
              [dataset insertEmptyElementForTag:0x0040a043 error:&error] &&
              [dataset putUInt16Array:[NSData dataWithBytes:words length:sizeof(words)] forTag:0x7fe00010 error:&error] &&
              [[dataset bytesForTag:0x7fe00010] isEqualToData:[NSData dataWithBytes:words length:sizeof(words)]],
              "file: empty elements and 16-bit words");
        check([file canWriteTransferSyntax:@"1.2.840.10008.1.2.1"] && [file changeRepresentationToTransferSyntax:@"1.2.840.10008.1.2.1"],
              "file: its representation");
        check(IsiXDCMTKFile.currentDate.length == 8 && IsiXDCMTKFile.currentTime.length == 6,
              "file: the date and time of a new instance");
        error = nil;
        failNew = true;
        BOOL inserted = [dataset insertEmptyElementForTag:0x00080030 error:&error];
        failNew = false;
        check(!inserted && thrown(error), "file: std::bad_alloc while inserting is an NSError");
        error = nil;
        failNew = true;
        BOOL putWords = [dataset putUInt16Array:[NSData dataWithBytes:words length:sizeof(words)] forTag:0x00281201 error:&error];
        BOOL sourceRead = [[IsiXDCMTKFile new] readFileAtPath:at(@"anon/IM1") error:NULL];
        [source.dataset removeAllElementsOfGroup:0x0010];
        failNew = false;
        check(!putWords && thrown(error) && !sourceRead, "file: and while putting words or reading");
        check([dataset insertEmptyElementForTag:0x00080030 error:&error], "file: the next call works");
    }
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='isix-dcmtk-export-adapters-') as directory:
    work = Path(directory)
    (work / 'driver.mm').write_text(DRIVER)
    (work / 'files').mkdir()
    common = ['xcrun', 'clang++', '-std=gnu++17', '-w', '-mmacosx-version-min=15.0', '-I' + str(work),
              '-I' + str(ADAPTERS), *openjpeg]
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
    built = subprocess.run([*common, '-fobjc-arc', '-x', 'objective-c++', '-c', str(work / 'driver.mm'), *flags[:2],
                            '-o', str(driver)], capture_output=True, text=True, timeout=300)
    if built.returncode:
        print(built.stderr[-4000:])
        print('FAIL: the driver does not compile')
        raise SystemExit(1)
    # The adapters as the application compiles them, without a warning.
    strict = ['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror', '-Wno-unused-parameter',
              '-mmacosx-version-min=15.0', '-I' + str(work), '-I' + str(ADAPTERS), *openjpeg]
    linked = subprocess.run([*strict, '-x', 'objective-c++', *map(str, SOURCES), '-x', 'none', str(driver), *objects,
                             *flags, str(openjpeg_archive), '-lxml2', '-framework', 'Foundation',
                             '-o', str(work / 'check')],
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
print('PASS: the anonymization, DICOMDIR, report and export adapters answer through DCMTK; '
      'a DCMTK refusal and a C++ exception are NSErrors or refusals')
