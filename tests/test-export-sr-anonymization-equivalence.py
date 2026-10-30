#!/usr/bin/env python3
"""Anonymization, DICOMDIR, structured reports and the secondary-capture export
write what the Objective-C++ they replaced wrote.

HorosGDCMAnonymizer, DicomDir, SRAnnotation and DICOMExport are Swift now, over
the DCMTK adapters (IsiXDCMTKAnonymizer, IsiXDCMTKDicomDir,
IsiXDCMTKStructuredReport, IsiXDCMTKFile), with their rules in the
IsiXDICOMFile module. The reference is their .mm, and the structured report
bridge, of the last revision that has DICOMExport.mm, with the headers they had
there, compiled here as the application compiled them into a library whose
classes are renamed (IsiXLegacy...), with a driver. The library is injected into
a copy of the Debug development bundle, which provides DCMTK with its codecs,
DicomFile, the archive staging and the preferences. Both sides then run on the
same synthetic files, each in its own folder:

- anonymization: +anonymizeStagedFile:withTags:failure: on files in several
  transfer syntaxes and character sets, with sets of tags that replace, empty,
  insert, clear a sequence and the pixel data, touch private elements, and give
  values the character set cannot hold; the files written must be the same
  bytes, the failures the same text in the same order;
- DICOMDIR: +createDicomDirAtDir: and +createDicomDirAtDir:error: on a folder
  of images in subfolders with index and Finder files, on one with a file that
  is not DICOM, an empty one and a missing one; the DICOMDIR must have the same
  attributes (its own UID and the record offsets that follow its length aside),
  the errors the same domain, code, description, reason and path;
- structured reports: annotations (new, then rewritten in place), window
  states, a report file, a report URL, ROIs through +archiveROIsAsDICOM:, an
  image that has no file, a study without a UID; the reports must have the same
  attributes (new UIDs, and the date and time of the run, aside), and each side
  must read every report of both as the other does (-initWithContentsOfFile:,
  +roiFromDICOM:, +getImageRefSOPInstanceUID:, +getReportFilenameFromSR:);
- export: DICOMExport of 8, 16 (signed and unsigned) and 32-bit grey, RGB and
  NSImage pixels, turned a quarter, with pixels made square, from a DICOM
  source, from a TIFF and from no source, and the refused layouts; the files
  must have the same attributes (new UIDs and the run's date and time aside)
  and the same pixels.

Exit 2 without the Debug bundle, a Python with pydicom and numpy (HOROS_PYTHON or
the local venvs), or the history.

    python3 tests/test-export-sr-anonymization-equivalence.py [--reference REV] [--keep DIR]
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402
import history_reference  # noqa: E402
import horos_reader  # noqa: E402
from dcmtk_build import BUILD, ROOT  # noqa: E402

sys.path.insert(0, str(ROOT / 'tools'))
import native_app  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--reference', help='revision whose DICOMExport.mm and the others are the reference')
parser.add_argument('--app', type=Path, default=native_app.DEVELOPMENT_APP)
parser.add_argument('--keep', type=Path, help='keep the files, the log and the answers here')
arguments = parser.parse_args()

ANCHOR = 'Horos/Sources/DICOMExport.mm'
SOURCES = ['Horos/Sources/HorosGDCMAnonymizer.mm', 'Horos/Sources/DicomDir.mm', 'Horos/Sources/SRAnnotation.mm',
           'Horos/Sources/DICOMExport.mm', 'Horos/Sources/HorosStructuredReportBridge.cpp']
# The headers of the reference that have changed or left since: they are
# written beside its sources, where a quoted import finds them first, and put
# in their place for the application's headers that import them.
REFERENCE_HEADERS = ['Horos/Sources/SRAnnotation.h', 'Horos/Sources/DICOMExport.h', 'Horos/Sources/DicomDir.h',
                     'Horos/Sources/HorosGDCMAnonymizer.h', 'Horos/Sources/HorosStructuredReportBridge.h']
# What the reference defines that the application still defines under the same name.
RENAMED = {'HorosGDCMAnonymizer': 'IsiXLegacyGDCMAnonymizer', 'DicomDir': 'IsiXLegacyDicomDir',
           'SRAnnotation': 'IsiXLegacySRAnnotation', 'DICOMExport': 'IsiXLegacyDICOMExport',
           'HorosSRDocument': 'IsiXLegacySRDocument', 'HorosSRTree': 'IsiXLegacySRTree',
           'HorosSRItem': 'IsiXLegacySRItem', 'HorosSRImageReference': 'IsiXLegacySRImageReference'}
reference = arguments.reference or history_reference.before_removal(ANCHOR)
if reference is None:
    print('skipped: no revision of this history has %s' % ANCHOR)
    raise SystemExit(2)
if (ROOT / ANCHOR).exists():
    print('skipped: %s is still the exporter; there is nothing to compare it with' % ANCHOR)
    raise SystemExit(2)

app = arguments.app
executable = app / 'Contents/MacOS/IsiX DICOM Viewer'
derived = BUILD / 'Horos.build/DerivedSources'
needed = [executable, derived / 'Horos-Swift.h', BUILD / 'DCMTK.build/Install/include/dcmtk/config/osconfig.h',
          ROOT / 'build/Development/entitlements.plist']
missing = [p for p in needed if not p.exists()]
if missing:
    print('skipped: needs a current Debug build from script/build_and_run.sh --verify: %s' % missing[0])
    raise SystemExit(2)


def find_python():
    candidates = [os.environ.get('HOROS_PYTHON'), str(ROOT / 'local-validation/venv/bin/python'),
                  str(ROOT.parent.parent.parent / 'local-validation/net-venv/bin/python')
                  if ROOT.parent.name == 'worktrees' else None,
                  str(ROOT / 'local-validation/net-venv/bin/python'), sys.executable]
    for candidate in filter(None, candidates):
        if Path(candidate).exists() and subprocess.run([candidate, '-c', 'import pydicom, numpy'],
                                                       capture_output=True).returncode == 0:
            return candidate
    return None


python = find_python()
if python is None:
    print('skipped: the files need a Python with pydicom and numpy (HOROS_PYTHON)')
    raise SystemExit(2)

# --------------------------------------------------------------- the files
GENERATOR = r'''
import json, struct, sys
from pathlib import Path
import numpy
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import (CTImageStorage, MRImageStorage, UltrasoundImageStorage, ExplicitVRLittleEndian,
                         ImplicitVRLittleEndian, ExplicitVRBigEndian, generate_uid)

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
study = generate_uid()
made = {}


def image(name, sop_class, modality, transfer, charset, patient, rows=6, columns=8, rgb=False):
    meta = FileMetaDataset()
    meta.MediaStorageSOPClassUID = sop_class
    meta.MediaStorageSOPInstanceUID = generate_uid()
    meta.TransferSyntaxUID = transfer
    ds = Dataset()
    ds.file_meta = meta
    if charset is not None:
        ds.SpecificCharacterSet = charset
    ds.SOPClassUID = sop_class
    ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
    ds.StudyDate, ds.StudyTime, ds.SeriesDate, ds.ContentDate = '20240305', '101112', '20240305', '20240305'
    ds.AccessionNumber = 'A1488'
    ds.Modality = modality
    ds.InstitutionName = 'Synthetic Hospital'
    ds.ReferringPhysicianName = 'Ref^Doc'
    ds.StudyDescription = 'Synthetic study'
    ds.SeriesDescription = 'Synthetic series ' + name
    ds.PatientName = patient
    ds.PatientID = 'SYN-' + name
    ds.PatientBirthDate = '19700102'
    ds.PatientSex = 'F'
    ds.OtherPatientIDs = 'OTHER-1'
    ds.StudyInstanceUID = study
    ds.SeriesInstanceUID = generate_uid()
    ds.StudyID = '7'
    ds.SeriesNumber = 3
    ds.InstanceNumber = 4
    ds.ReferencedStudySequence = Sequence([Dataset()])
    ds.ReferencedStudySequence[0].ReferencedSOPClassUID = '1.2.840.10008.3.1.2.3.1'
    ds.ReferencedStudySequence[0].ReferencedSOPInstanceUID = generate_uid()
    block = ds.private_block(0x0009, 'ISIX SYNTHETIC', create=True)
    block.add_new(0x01, 'LO', 'private value')
    ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
    ds.ImagePositionPatient = [-10.5, -20.25, 30]
    ds.PixelSpacing = [0.5, 0.75]
    ds.SliceThickness = 1.25
    ds.Rows, ds.Columns = rows, columns
    if rgb:
        ds.SamplesPerPixel, ds.PhotometricInterpretation, ds.PlanarConfiguration = 3, 'RGB', 0
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 8, 8, 7, 0
        pixels = (numpy.arange(rows * columns * 3) * 7 % 256).astype(numpy.uint8)
    else:
        ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, 'MONOCHROME2'
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 12, 11, 0
        ds.RescaleIntercept, ds.RescaleSlope = -1024, 1
        ds.WindowCenter, ds.WindowWidth = 40, 400
        pixels = (numpy.arange(rows * columns) * 37 % 4096).astype(numpy.uint16)
    big = transfer == ExplicitVRBigEndian
    ds.PixelData = pixels.astype(pixels.dtype.newbyteorder('>') if big else pixels.dtype).tobytes()
    path = out / name
    ds.save_as(path, enforce_file_format=True)
    made[name] = str(path)


image('ct_explicit.dcm', CTImageStorage, 'CT', ExplicitVRLittleEndian, 'ISO_IR 100', 'Müller^Jürgen')
image('mr_implicit.dcm', MRImageStorage, 'MR', ImplicitVRLittleEndian, None, 'Plain^Name')
image('us_rgb_utf8.dcm', UltrasoundImageStorage, 'US', ExplicitVRLittleEndian, 'ISO_IR 192', 'José^Ñandú', 4, 5, True)
image('jp_2022.dcm', CTImageStorage, 'CT', ExplicitVRLittleEndian, ['', 'ISO 2022 IR 87'],
      'Yamada^Tarou=山田^太郎=やまだ^たろう')
try:
    image('ct_bigendian.dcm', CTImageStorage, 'CT', ExplicitVRBigEndian, 'ISO_IR 100', 'Big^Endian')
except Exception as error:  # a pydicom that no longer writes it
    print('note: no big endian file: %s' % error, file=sys.stderr)

# A TIFF, as a source that is not DICOM: 8-bit grey, 6 x 4, one strip.
width, height = 6, 4
pixels = bytes((x * 30 + y * 7) % 256 for y in range(height) for x in range(width))
entries = [(256, 3, 1, width), (257, 3, 1, height), (258, 3, 1, 8), (259, 3, 1, 1), (262, 3, 1, 1),
           (273, 4, 1, 8), (277, 3, 1, 1), (278, 3, 1, height), (279, 4, 1, len(pixels))]
directory = 8 + len(pixels)
data = b'II*\0' + struct.pack('<I', directory) + pixels + struct.pack('<H', len(entries))
for tag, kind, count, value in entries:
    data += struct.pack('<HHI', tag, kind, count) + (struct.pack('<HH', value, 0) if kind == 3 else struct.pack('<I', value))
data += struct.pack('<I', 0)
(out / 'source.tif').write_bytes(data)
made['source.tif'] = str(out / 'source.tif')
(out / 'report.rtf').write_text('{\\rtf1\\ansi Synthetic report}')
made['report.rtf'] = str(out / 'report.rtf')
(out / 'notdicom.txt').write_text('not a DICOM file')
made['notdicom.txt'] = str(out / 'notdicom.txt')
made['study'] = study
print(json.dumps(made))
'''


def generate(folder):
    result = subprocess.run([python, '-c', GENERATOR, str(folder)], capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise SystemExit('FAIL: the files could not be made:\n' + result.stderr[-3000:])
    if result.stderr.strip():
        print(result.stderr.strip())
    return json.loads(result.stdout)


# --------------------------------------------------------------- the driver
DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>

@interface NSObject (IsiXEquivalenceProbe)
+ (NSString *)anonymizeStagedFile:(NSString *)path withTags:(NSArray *)tags failure:(void (^)(NSString *, NSString *))failure;
+ (void)createDicomDirAtDir:(NSString *)path;
+ (BOOL)createDicomDirAtDir:(NSString *)path error:(NSError **)error;
+ (NSData *)roiFromDICOM:(NSString *)path;
+ (NSString *)archiveROIsAsDICOM:(NSArray *)rois toPath:(NSString *)path forImage:(id)image;
+ (NSString *)getImageRefSOPInstanceUID:(NSString *)path;
+ (NSString *)getReportFilenameFromSR:(NSString *)path;
- (id)initWithContentsOfFile:(NSString *)path;
- (id)initWithDictionary:(NSDictionary *)dict path:(NSString *)path forImage:(id)image;
- (id)initWithWindowsState:(NSData *)dict path:(NSString *)path forImage:(id)image;
- (id)initWithFileReport:(NSString *)file path:(NSString *)path forImage:(id)image contentDate:(NSDate *)date;
- (id)initWithURLReport:(NSString *)s path:(NSString *)path forImage:(id)image;
- (BOOL)writeToFileAtPath:(NSString *)path;
- (NSString *)seriesInstanceUID;
- (NSString *)sopInstanceUID;
- (NSString *)sopClassUID;
- (NSString *)seriesDescription;
- (NSString *)seriesNumber;
- (NSData *)dataEncapsulated;
- (NSString *)reportURL;
- (NSDictionary *)annotations;
- (NSArray *)ROIs;
@end

@protocol IsiXROICalls
- (id)initWithType:(int)type :(float)x :(float)y :(NSPoint)origin;
- (void)setROIRect:(NSRect)rect;
- (void)setName:(NSString *)name;
- (NSString *)name;
@end

// The exporter's calls, some of whose names AppKit declares with other types.
@protocol IsiXExportCalls
- (void)setSourceFile:(NSString *)source;
- (long)setPixelData:(unsigned char *)data samplesPerPixel:(int)spp bitsPerSample:(int)bps width:(long)width height:(long)height;
- (void)setSigned:(BOOL)s;
- (void)setOffset:(int)o;
- (long)setPixelNSImage:(NSImage *)image;
- (NSString *)writeDCMFile:(NSString *)path;
- (void)setModalityAsSource:(BOOL)v;
- (void)setSeriesDescription:(NSString *)description;
- (void)setSeriesNumber:(long)number;
- (void)setDefaultWWWL:(long)ww :(long)wl;
- (void)setSlope:(float)s;
- (void)setPixelSpacing:(float)x :(float)y;
- (void)setSliceThickness:(double)t;
- (void)setOrientation:(float *)o;
- (void)setPosition:(float *)p;
- (void)setSlicePosition:(float)p;
- (NSMutableDictionary *)metaDataDict;
- (void)setRotateRawDataBy90degrees:(BOOL)v;
@end

// A tag as the anonymizer reads one: by group and element.
@interface IsiXEquivalenceTag : NSObject
@property int group, element;
@end
@implementation IsiXEquivalenceTag
@end

// An image, series, study or ROI series as the reports read them: by key.
@interface IsiXEquivalenceObject : NSObject
@property (copy) NSString *completePath;
@property (strong) NSDictionary *values;
@end
@implementation IsiXEquivalenceObject
- (id)valueForKey:(NSString *)key
{
    if ([key isEqualToString:@"completePath"]) return self.completePath;
    id value = self.values[key];
    return value == NSNull.null ? nil : value;
}
- (id)roiSRSeries { return [self valueForKey:@"roiSRSeries"]; }
@end

static id Describe(id value)
{
    if (value == nil) return [NSNull null];
    if ([value isKindOfClass:NSString.class]) return @{@"s": value};
    if ([value isKindOfClass:NSNumber.class]) return @{@"n": [value stringValue]};
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *items = [NSMutableArray array];
        for (id item in value) [items addObject:Describe(item)];
        return items;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *items = [NSMutableDictionary dictionary];
        for (id key in value) items[[key description]] = Describe(value[key]);
        return items;
    }
    if ([value isKindOfClass:NSData.class]) {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256([value bytes], (CC_LONG) [value length], digest);
        NSMutableString *hex = [NSMutableString string];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
        return @{@"data": hex, @"length": @([value length])};
    }
    if ([value isKindOfClass:NSDate.class]) return @{@"d": @([value timeIntervalSinceReferenceDate])};
    return @{@"o": NSStringFromClass([value class])};
}

static id Guarded(id (^body)(void))
{
    @try { id value = body(); return value ? value : [NSNull null]; }
    @catch (NSException *exception) { return @{@"exception": exception.name ?: @"?", @"reason": exception.reason ?: @""}; }
}

static NSString *Relative(NSString *path, NSString *folder)
{
    if (![path isKindOfClass:NSString.class]) return path;
    return [path hasPrefix:folder] ? [@"<side>" stringByAppendingString:[path substringFromIndex:folder.length]] : path;
}

static NSArray *Tag(int group, int element, id value)
{
    IsiXEquivalenceTag *tag = [IsiXEquivalenceTag new];
    tag.group = group;
    tag.element = element;
    return value ? @[tag, value] : @[tag];
}

static NSDictionary *Anonymize(Class cls, NSDictionary *manifest, NSString *folder)
{
    NSDictionary *sets = @{
        @"replace": @[Tag(0x0010, 0x0010, @"ANON^PATIENT"), Tag(0x0010, 0x0020, nil), Tag(0x0010, 0x0030, @"19000101"),
                      Tag(0x0008, 0x0080, nil), Tag(0x0008, 0x0090, @"Someone^Else"), Tag(0x0010, 0x1000, nil),
                      Tag(0x0008, 0x0050, @12345), Tag(0x0010, 0x0040, @"O")],
        @"insert": @[Tag(0x0010, 0x2160, @"Ethnic"), Tag(0x0010, 0x21B0, nil), Tag(0x0008, 0x1040, @"Department"),
                     Tag(0x0032, 0x1032, nil)],
        @"sequence": @[Tag(0x0008, 0x1110, nil), Tag(0x0010, 0x0010, nil)],
        @"private": @[Tag(0x0009, 0x1001, @"other"), Tag(0x0009, 0x0010, nil), Tag(0x0011, 0x1010, @"absent private")],
        @"pixels": @[Tag(0x7FE0, 0x0010, nil)],
        @"charset": @[Tag(0x0010, 0x0010, @"Ünïcödé^Ψ"), Tag(0x0008, 0x1030, @"Étude ✓"), Tag(0x0008, 0x0005, @"ISO_IR 192")],
        @"identity": @[Tag(0x0008, 0x0018, nil)],
        @"none": @[]};
    NSMutableDictionary *answers = [NSMutableDictionary dictionary];
    for (NSString *name in manifest[@"anonymize"]) {
        for (NSString *set in sets) {
            NSString *caseFolder = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"anonymize/%@-%@", set, name]];
            [NSFileManager.defaultManager createDirectoryAtPath:caseFolder withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *staged = [caseFolder stringByAppendingPathComponent:name];
            [NSFileManager.defaultManager copyItemAtPath:manifest[@"files"][name] toPath:staged error:NULL];
            NSMutableArray *failures = [NSMutableArray array];
            id result = Guarded(^id{
                return [cls anonymizeStagedFile:staged withTags:sets[set] failure:^(NSString *reason, NSString *tag) {
                    [failures addObject:@[reason ?: @"(nil)", tag ?: @"(nil)"]];
                }];
            });
            answers[[NSString stringWithFormat:@"%@-%@", set, name]] = @{@"result": Relative(result, folder), @"failures": failures};
        }
    }
    // A file that is not DICOM, and one that does not exist.
    for (NSString *name in @[@"notdicom.txt", @"missing.dcm"]) {
        NSString *caseFolder = [folder stringByAppendingPathComponent:[@"anonymize/bad-" stringByAppendingString:name]];
        [NSFileManager.defaultManager createDirectoryAtPath:caseFolder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *staged = [caseFolder stringByAppendingPathComponent:name];
        if (manifest[@"files"][name])
            [NSFileManager.defaultManager copyItemAtPath:manifest[@"files"][name] toPath:staged error:NULL];
        NSMutableArray *failures = [NSMutableArray array];
        id result = Guarded(^id{
            return [cls anonymizeStagedFile:staged withTags:sets[@"replace"] failure:^(NSString *reason, NSString *tag) {
                [failures addObject:@[reason ?: @"(nil)", tag ?: @"(nil)"]];
            }];
        });
        answers[[@"bad-" stringByAppendingString:name]] = @{@"result": Relative(result, folder), @"failures": failures};
    }
    return answers;
}

static id DescribeError(NSError *error, NSString *folder)
{
    if (!error) return [NSNull null];
    return @{@"domain": error.domain, @"code": @(error.code), @"description": error.localizedDescription ?: @"",
             @"reason": Relative(error.userInfo[NSLocalizedFailureReasonErrorKey], folder) ?: @"",
             @"path": Relative(error.userInfo[NSFilePathErrorKey], folder) ?: @""};
}

static NSDictionary *Directories(Class cls, NSDictionary *manifest, NSString *folder)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *source = manifest[@"files"];
    NSString *good = [folder stringByAppendingPathComponent:@"dicomdir/good"];
    NSString *bad = [folder stringByAppendingPathComponent:@"dicomdir/bad"];
    NSString *empty = [folder stringByAppendingPathComponent:@"dicomdir/empty"];
    NSString *plain = [folder stringByAppendingPathComponent:@"dicomdir/plain"];
    for (NSString *dir in @[[good stringByAppendingPathComponent:@"SUB1/SUB2"], [bad stringByAppendingPathComponent:@"SUB1"],
                            empty, plain])
        [files createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    [files copyItemAtPath:source[@"ct_explicit.dcm"] toPath:[good stringByAppendingPathComponent:@"IM000001"] error:NULL];
    [files copyItemAtPath:source[@"mr_implicit.dcm"] toPath:[good stringByAppendingPathComponent:@"SUB1/IM000002"] error:NULL];
    [files copyItemAtPath:source[@"us_rgb_utf8.dcm"] toPath:[good stringByAppendingPathComponent:@"SUB1/SUB2/IM000003"] error:NULL];
    [files copyItemAtPath:source[@"jp_2022.dcm"] toPath:[good stringByAppendingPathComponent:@"SUB1/IM000004"] error:NULL];
    [@"finder" writeToFile:[good stringByAppendingPathComponent:@".DS_Store"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [@"fork" writeToFile:[good stringByAppendingPathComponent:@"SUB1/._IM000002"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [@"old" writeToFile:[good stringByAppendingPathComponent:@"DICOMDIR.BAK"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [files copyItemAtPath:source[@"ct_explicit.dcm"] toPath:[plain stringByAppendingPathComponent:@"IM000001"] error:NULL];
    [files copyItemAtPath:source[@"ct_explicit.dcm"] toPath:[bad stringByAppendingPathComponent:@"IM000001"] error:NULL];
    [files copyItemAtPath:source[@"notdicom.txt"] toPath:[bad stringByAppendingPathComponent:@"SUB1/NOTDICOM"] error:NULL];
    NSMutableDictionary *answers = [NSMutableDictionary dictionary];
    for (NSString *dir in @[good, bad, empty, [folder stringByAppendingPathComponent:@"dicomdir/missing"]]) {
        answers[dir.lastPathComponent] = Guarded(^id{
            NSError *error = nil;
            BOOL written = [cls createDicomDirAtDir:dir error:&error];
            return @{@"written": @(written), @"error": DescribeError(error, folder)};
        });
    }
    answers[@"plain"] = Guarded(^id{ [cls createDicomDirAtDir:plain]; return @"returned"; });
    return answers;
}

static NSDictionary *ReadReport(Class cls, NSString *path)
{
    NSMutableDictionary *answer = [NSMutableDictionary dictionary];
    answer[@"instance"] = Guarded(^id{
        id sr = [[cls alloc] initWithContentsOfFile:path];
        if (!sr) return nil;
        NSMutableArray *names = [NSMutableArray array];
        for (id<IsiXROICalls> roi in [sr ROIs] ?: @[]) [names addObject:[roi name] ?: @"(nil)"];
        return @{@"annotations": Describe([sr annotations]), @"data": Describe([sr dataEncapsulated]),
                 @"url": Describe([sr reportURL]), @"seriesDescription": Describe([sr seriesDescription]),
                 @"seriesNumber": Describe([sr seriesNumber]), @"sopClassUID": Describe([sr sopClassUID]),
                 @"sopInstanceUID": Describe([sr sopInstanceUID]), @"seriesInstanceUID": Describe([sr seriesInstanceUID]),
                 @"rois": names};
    });
    answer[@"roiFromDICOM"] = Guarded(^id{ return Describe([cls roiFromDICOM:path]); });
    answer[@"imageReference"] = Guarded(^id{ return Describe([cls getImageRefSOPInstanceUID:path]); });
    answer[@"reportFilename"] = Guarded(^id{ return Describe([cls getReportFilenameFromSR:path]); });
    return answer;
}

// The ROIs both sides archive, made once: a new ROI takes its colour and
// thickness from the ROIs made before it.
static NSArray *SharedROIs;

static NSArray *MakeROIs(void)
{
    Class roiClass = NSClassFromString(@"ROI");
    id<IsiXROICalls> first = [(id<IsiXROICalls>)[roiClass alloc] initWithType:6 :0.5 :0.75 :NSMakePoint(1, 2)];
    [first setROIRect:NSMakeRect(1, 2, 3, 4)];
    [first setName:@"first"];
    id<IsiXROICalls> second = [(id<IsiXROICalls>)[roiClass alloc] initWithType:6 :0.5 :0.75 :NSMakePoint(1, 2)];
    [second setROIRect:NSMakeRect(4, 3, 2, 1)];
    [second setName:@"second"];
    return @[first, second];
}

static NSDictionary *Reports(Class cls, NSDictionary *manifest, NSString *folder)
{
    NSString *reports = [folder stringByAppendingPathComponent:@"sr"];
    [NSFileManager.defaultManager createDirectoryAtPath:reports withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *file = manifest[@"files"];
    NSDate *birth = [NSDate dateWithTimeIntervalSinceReferenceDate:-978307200.0 + 3600.0 * 24 * 365.25 * 40];
    NSDictionary *studyValues = @{@"studyInstanceUID": manifest[@"study"], @"name": @"Ünïcode^Name", @"referringPhysician": @"Ref^Doc",
                                  @"studyName": @"Synthetic study", @"dateOfBirth": birth, @"patientSex": @"F",
                                  @"patientID": @"SYN-STUDY", @"id": @"7", @"accessionNumber": @"A1488"};
    IsiXEquivalenceObject *roiSeries = [IsiXEquivalenceObject new];
    roiSeries.values = @{@"seriesDICOMUID": @"1.2.826.0.1.3680043.10.1488.5002"};
    IsiXEquivalenceObject *study = [IsiXEquivalenceObject new];
    NSMutableDictionary *withSeries = [studyValues mutableCopy];
    withSeries[@"roiSRSeries"] = roiSeries;
    study.values = withSeries;
    IsiXEquivalenceObject *series = [IsiXEquivalenceObject new];
    series.values = @{@"study": study, @"seriesSOPClassUID": @"1.2.840.10008.5.1.4.1.1.2"};
    IsiXEquivalenceObject *image = [IsiXEquivalenceObject new];
    image.completePath = file[@"ct_explicit.dcm"];
    image.values = @{@"series": series, @"sopInstanceUID": @"1.2.826.0.1.3680043.10.1488.1", @"frameID": @2};
    IsiXEquivalenceObject *loose = [IsiXEquivalenceObject new];
    loose.completePath = [folder stringByAppendingPathComponent:@"no-such-image.dcm"];
    loose.values = @{@"series": series, @"sopInstanceUID": @"", @"frameID": @0};
    IsiXEquivalenceObject *jp = [IsiXEquivalenceObject new];
    jp.completePath = file[@"jp_2022.dcm"];
    jp.values = image.values;
    IsiXEquivalenceObject *noStudyUID = [IsiXEquivalenceObject new];
    IsiXEquivalenceObject *bareStudy = [IsiXEquivalenceObject new];
    NSMutableDictionary *bare = [studyValues mutableCopy];
    [bare removeObjectForKey:@"studyInstanceUID"];
    bareStudy.values = bare;
    IsiXEquivalenceObject *bareSeries = [IsiXEquivalenceObject new];
    bareSeries.values = @{@"study": bareStudy, @"seriesSOPClassUID": @"1.2.840.10008.5.1.4.1.1.2"};
    noStudyUID.values = @{@"series": bareSeries, @"sopInstanceUID": @"1.2.826.0.1.3680043.10.1488.1", @"frameID": @1};

    NSDictionary *annotations = @{@"comment": @"Synthetic comment", @"stateText": @4, @"keyImages": @[@"1.2.3.4"]};
    NSDictionary *rewritten = @{@"comment": @"Rewritten ✓", @"stateText": @2};
    NSData *windows = [NSPropertyListSerialization dataWithPropertyList:@[@{@"window": @"one", @"frame": @"0 0 10 10"}]
                                                                 format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    NSDate *contentDate = [NSDate dateWithTimeIntervalSinceReferenceDate:3600.0 * 24 * 33 + 4 * 3600 + 5 * 60 + 6];
    id first = SharedROIs[0], second = SharedROIs[1];

    NSMutableDictionary *written = [NSMutableDictionary dictionary];
    NSString *(^path)(NSString *) = ^NSString *(NSString *name) { return [reports stringByAppendingPathComponent:name]; };
    written[@"annotations"] = Guarded(^id{
        return @([[[cls alloc] initWithDictionary:annotations path:path(@"annotations.dcm") forImage:image] writeToFileAtPath:path(@"annotations.dcm")]);
    });
    [NSFileManager.defaultManager copyItemAtPath:path(@"annotations.dcm") toPath:path(@"annotations-first.dcm") error:NULL];
    written[@"annotations-rewritten"] = Guarded(^id{
        return @([[[cls alloc] initWithDictionary:rewritten path:path(@"annotations.dcm") forImage:image] writeToFileAtPath:path(@"annotations.dcm")]);
    });
    written[@"annotations-nofile"] = Guarded(^id{
        return @([[[cls alloc] initWithDictionary:annotations path:path(@"annotations-nofile.dcm") forImage:loose] writeToFileAtPath:path(@"annotations-nofile.dcm")]);
    });
    written[@"annotations-2022"] = Guarded(^id{
        return @([[[cls alloc] initWithDictionary:annotations path:path(@"annotations-2022.dcm") forImage:jp] writeToFileAtPath:path(@"annotations-2022.dcm")]);
    });
    written[@"annotations-nostudyuid"] = Guarded(^id{
        return @([[[cls alloc] initWithDictionary:annotations path:path(@"annotations-nostudyuid.dcm") forImage:noStudyUID] writeToFileAtPath:path(@"annotations-nostudyuid.dcm")]);
    });
    written[@"windows"] = Guarded(^id{
        return @([[[cls alloc] initWithWindowsState:windows path:path(@"windows.dcm") forImage:image] writeToFileAtPath:path(@"windows.dcm")]);
    });
    written[@"filereport"] = Guarded(^id{
        return @([[[cls alloc] initWithFileReport:file[@"report.rtf"] path:path(@"filereport.dcm") forImage:image contentDate:contentDate] writeToFileAtPath:path(@"filereport.dcm")]);
    });
    written[@"urlreport"] = Guarded(^id{
        return @([[[cls alloc] initWithURLReport:@"https://example.invalid/report?id=7" path:path(@"urlreport.dcm") forImage:image] writeToFileAtPath:path(@"urlreport.dcm")]);
    });
    written[@"rois"] = Guarded(^id{ return Describe([cls archiveROIsAsDICOM:@[first, second] toPath:path(@"rois.dcm") forImage:image]); });
    written[@"rois-added"] = Guarded(^id{ return Describe([cls archiveROIsAsDICOM:@[second] toPath:path(@"rois.dcm") forImage:image]); });
    written[@"rois-loose"] = Guarded(^id{ return Describe([cls archiveROIsAsDICOM:@[] toPath:path(@"rois-loose.dcm") forImage:loose]); });
    return written;
}

static NSImage *TestPicture(void)
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:6 pixelsHigh:4 bitsPerSample:8
        samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:6 * 3 + 8 bitsPerPixel:24];
    for (int y = 0; y < 4; y++) for (int x = 0; x < 6; x++) {
        unsigned char *p = rep.bitmapData + y * rep.bytesPerRow + x * 3;
        p[0] = 20 * x; p[1] = 40 * y; p[2] = 200;
    }
    NSImage *picture = [[NSImage alloc] initWithSize:NSMakeSize(6, 4)];
    [picture addRepresentation:rep];
    return picture;
}

static NSDictionary *Exports(Class cls, NSDictionary *manifest, NSString *folder)
{
    NSString *exports = [folder stringByAppendingPathComponent:@"export"];
    [NSFileManager.defaultManager createDirectoryAtPath:exports withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDictionary *file = manifest[@"files"];
    NSDate *studyDate = [NSDate dateWithTimeIntervalSinceReferenceDate:3600.0 * 24 * 33 + 4 * 3600 + 5 * 60 + 6];
    // name: source, spp, bps, width, height, signed, offset, rotate, spacing x, spacing y, modality as source
    NSArray *cases = @[
        @[@"grey16-source", @"ct_explicit.dcm", @1, @16, @7, @5, @NO, @0, @NO, @0.5, @0.5, @NO],
        @[@"grey16-signed", @"ct_explicit.dcm", @1, @16, @7, @5, @YES, @-1024, @NO, @0.5, @0.5, @YES],
        @[@"grey16-square", @"ct_explicit.dcm", @1, @16, @8, @6, @NO, @0, @NO, @0.5, @0.75, @NO],
        @[@"grey16-turned", @"ct_explicit.dcm", @1, @16, @7, @5, @NO, @0, @YES, @0.5, @0.5, @NO],
        @[@"grey16-nosource", @"", @1, @16, @7, @5, @NO, @0, @NO, @0, @0, @NO],
        @[@"grey8-nosource", @"", @1, @8, @9, @4, @NO, @0, @NO, @0.3, @0.3, @NO],
        @[@"grey8-tiff", @"source.tif", @1, @8, @6, @4, @NO, @0, @NO, @0, @0, @NO],
        @[@"grey32", @"mr_implicit.dcm", @1, @32, @4, @3, @NO, @0, @NO, @1, @1, @YES],
        @[@"rgb", @"us_rgb_utf8.dcm", @3, @8, @5, @3, @NO, @0, @NO, @0, @0, @NO],
        @[@"rgb-turned", @"us_rgb_utf8.dcm", @3, @8, @5, @3, @NO, @0, @YES, @0, @0, @NO],
        @[@"rgb-2022", @"jp_2022.dcm", @3, @8, @5, @3, @NO, @0, @NO, @0, @0, @YES],
        @[@"refused-rgb16", @"", @3, @16, @5, @3, @NO, @0, @NO, @0, @0, @NO],
        @[@"refused-rgba", @"", @4, @8, @5, @3, @NO, @0, @NO, @0, @0, @NO],
        @[@"nsimage", @"ct_explicit.dcm", @0, @0, @0, @0, @NO, @0, @NO, @0, @0, @NO],
        @[@"nsimage-nosource", @"", @0, @0, @0, @0, @NO, @0, @NO, @0, @0, @NO]];
    NSMutableDictionary *answers = [NSMutableDictionary dictionary];
    for (NSArray *c in cases) {
        NSString *name = c[0];
        answers[name] = Guarded(^id{
            id<IsiXExportCalls> exporter = [[cls alloc] init];
            NSMutableDictionary *meta = [exporter metaDataDict];
            meta[@"studyDate"] = studyDate;
            meta[@"patientsBirthdate"] = [NSDate dateWithTimeIntervalSinceReferenceDate:-31536000.0 * 20];
            meta[@"patientsName"] = @"Export^Patient";
            meta[@"studyDescription"] = @"Export study";
            if ([c[1] length]) [exporter setSourceFile:file[c[1]]];
            int spp = [c[2] intValue], bps = [c[3] intValue];
            long width = [c[4] longValue], height = [c[5] longValue];
            NSMutableData *pixels = [NSMutableData dataWithLength:MAX(1, width * height * MAX(spp, 1) * MAX(bps, 8) / 8)];
            unsigned char *bytes = pixels.mutableBytes;
            for (NSUInteger i = 0; i < pixels.length; i++) bytes[i] = (unsigned char) ((i * 29 + 7) % 251);
            if (bps == 32) {
                float *values = (float *) bytes;
                for (long i = 0; i < width * height; i++) values[i] = -100.5f + 3.25f * i;
            }
            long set = spp ? [exporter setPixelData:bytes samplesPerPixel:spp bitsPerSample:bps width:width height:height]
                           : [exporter setPixelNSImage:TestPicture()];
            [exporter setSigned:[c[6] boolValue]];
            [exporter setOffset:[c[7] intValue]];
            [exporter setRotateRawDataBy90degrees:[c[8] boolValue]];
            [exporter setPixelSpacing:[c[9] floatValue] :[c[10] floatValue]];
            [exporter setModalityAsSource:[c[11] boolValue]];
            [exporter setSliceThickness:1.5];
            float orientation[6] = {1, 0, 0, 0, 0.8f, -0.6f}, position[3] = {-12.5f, 30.25f, 7};
            [exporter setOrientation:orientation];
            [exporter setPosition:position];
            [exporter setSlicePosition:7.5f];
            [exporter setSlope:1.0f];
            [exporter setDefaultWWWL:400 :40];
            [exporter setSeriesDescription:@"Exported ✓ series"];
            [exporter setSeriesNumber:7001];
            NSString *path = [exports stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"dcm"]];
            NSString *result = [exporter writeDCMFile:path];
            // A second image of the same series, as an export of several does,
            // also after pixels made square.
            NSString *again = [exporter writeDCMFile:[exports stringByAppendingPathComponent:[name stringByAppendingString:@"-2.dcm"]]];
            return @{@"set": @(set), @"result": Relative(result, folder) ?: [NSNull null],
                     @"again": Relative(again, folder) ?: [NSNull null]};
        });
    }
    return answers;
}

__attribute__((constructor)) static void IsiXEquivalenceStart(void)
{
    NSString *exchange = NSProcessInfo.processInfo.environment[@"ISIX_EXPORT_EQUIVALENCE"];
    if (!exchange) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *go = [exchange stringByAppendingPathComponent:@"go.json"];
        while (![NSFileManager.defaultManager fileExistsAtPath:go]) usleep(200000);
        @autoreleasepool {
            NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:go] options:0 error:NULL];
            NSMutableDictionary *answers = [NSMutableDictionary dictionary];
            SharedROIs = MakeROIs();
            NSDictionary *names = @{@"legacy": @[@"IsiXLegacyGDCMAnonymizer", @"IsiXLegacyDicomDir", @"IsiXLegacySRAnnotation",
                                                 @"IsiXLegacyDICOMExport"],
                                    @"current": @[@"HorosGDCMAnonymizer", @"DicomDir", @"SRAnnotation", @"DICOMExport"]};
            for (NSString *side in @[@"legacy", @"current"]) {
                NSString *folder = [manifest[@"out"] stringByAppendingPathComponent:side];
                NSArray *classes = names[side];
                NSMutableDictionary *answer = [NSMutableDictionary dictionary];
                NSLog(@"equivalence: %@ anonymizes", side);
                @autoreleasepool { answer[@"anonymize"] = Anonymize(NSClassFromString(classes[0]), manifest, folder); }
                NSLog(@"equivalence: %@ writes DICOMDIRs", side);
                @autoreleasepool { answer[@"dicomdir"] = Directories(NSClassFromString(classes[1]), manifest, folder); }
                NSLog(@"equivalence: %@ writes reports", side);
                @autoreleasepool { answer[@"sr"] = Reports(NSClassFromString(classes[2]), manifest, folder); }
                NSLog(@"equivalence: %@ exports", side);
                @autoreleasepool { answer[@"export"] = Exports(NSClassFromString(classes[3]), manifest, folder); }
                answers[side] = answer;
            }
            // Each side reads every report of both.
            NSMutableDictionary *reads = [NSMutableDictionary dictionary];
            for (NSString *reader in @[@"legacy", @"current"]) {
                NSMutableDictionary *read = [NSMutableDictionary dictionary];
                for (NSString *writer in @[@"legacy", @"current"]) {
                    NSString *folder = [[manifest[@"out"] stringByAppendingPathComponent:writer] stringByAppendingPathComponent:@"sr"];
                    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:NULL])
                        @autoreleasepool {
                            read[[NSString stringWithFormat:@"%@/%@", writer, name]] =
                                ReadReport(NSClassFromString(names[reader][2]), [folder stringByAppendingPathComponent:name]);
                        }
                }
                read[@"missing"] = ReadReport(NSClassFromString(names[reader][2]), @"/no/such/report.dcm");
                read[@"notdicom"] = ReadReport(NSClassFromString(names[reader][2]), manifest[@"files"][@"notdicom.txt"]);
                reads[reader] = read;
            }
            answers[@"reads"] = reads;
            NSData *data = [NSJSONSerialization dataWithJSONObject:answers options:NSJSONWritingSortedKeys error:NULL];
            [data writeToFile:[exchange stringByAppendingPathComponent:@".answers.json"] atomically:YES];
            [NSFileManager.defaultManager moveItemAtPath:[exchange stringByAppendingPathComponent:@".answers.json"]
                                                  toPath:[exchange stringByAppendingPathComponent:@"answers.json"] error:NULL];
        }
    });
}
'''


def compile_reference(work):
    """The library: the reference's five sources, under the application's flags
    and current headers, with its own headers where they changed, its classes
    renamed, and the driver."""
    sources = work / 'reference'
    sources.mkdir()
    for path in (*SOURCES, *REFERENCE_HEADERS):
        (sources / Path(path).name).write_bytes(history_reference.show(reference, path))
    horos_reader.without_model_forward_declarations(sources)
    # The reference freed the pixels it made square at the end of the write,
    # while the exporter still pointed at them, so its second write read freed
    # memory. Here the exporter keeps them, as its own pixels until new ones
    # are set, which is what the Swift does: the second writes compare.
    export = (sources / 'DICOMExport.mm').read_bytes().decode('latin1')
    squared = '\n\t\t\t\t\t\t\t\tdata = squaredata;'
    if export.count(squared) != 1:
        raise SystemExit('FAIL: the reference DICOMExport.mm does not make pixels square as expected')
    (sources / 'DICOMExport.mm').write_bytes(export.replace(
        squared, squared + ' if( localData) free( localData); localData = squaredata; squaredata = nil;').encode('latin1'))
    # The reference's SRAnnotation.mm formats the birth date with the
    # HorosDateString of its Horos.m, which left the application with the DCM
    # framework's date type: that function, from the same revision, is built
    # into the library under another name, and its Horos.h says so.
    horos = history_reference.show(reference, 'Horos/Sources/Horos.m').decode('latin1')
    start = horos.index('NSString *HorosDateString(')
    depth, end = 0, horos.index('{', start)
    while True:
        depth += {'{': 1, '}': -1}.get(horos[end], 0)
        end += 1
        if depth == 0:
            break
    (sources / 'Horos.h').write_text('#import <Foundation/Foundation.h>\n'
                                     'extern "C" NSString *IsiXLegacyHorosDateString(id date, NSString *format);\n'
                                     '#define HorosDateString IsiXLegacyHorosDateString\n')
    (sources / 'IsiXLegacyHorosDateString.mm').write_text(
        '#import "Horos.h"\n#import <DCM/DCMCalendarDate.h>\n' + horos[start:end].replace(
            'NSString *HorosDateString(', 'NSString *IsiXLegacyHorosDateString(', 1) + '\n', encoding='latin1')
    overlay_file = work / 'reference-headers.json'
    overlay_file.write_text(json.dumps({'version': 0, 'case-sensitive': 'false', 'roots': [{
        'type': 'directory', 'name': str(ROOT / 'Horos/Sources'),
        'contents': [{'type': 'file', 'name': Path(path).name, 'external-contents': str(sources / Path(path).name)}
                     for path in REFERENCE_HEADERS if (ROOT / path).exists()]}]}))
    target = BUILD / 'Horos.build'
    generated = BUILD.parent.parent / 'GeneratedModuleMaps'
    # The former DCM.framework's names (horos_reader.former_names): <DCM/...> and
    # the value type headers, each the dataset model the application now
    # compiles in, with the framework's class names for the module's classes.
    # Searched before the framework folders: a build that predates the move
    # still holds a DCM.framework in its products, whose <DCM/...> headers
    # would declare the former classes again.
    overlay = horos_reader.former_names(work / 'dcm-headers')
    includes = ['-I' + str(p) for p in [sources,
        target / 'DerivedSources', generated, overlay, ROOT / 'Horos/Sources', ROOT / 'Horos/Sources/Adapters/DCMTK',
        ROOT / 'Nitrogen/Sources', BUILD / 'DCMTK.build/Install/include', BUILD / 'OpenSSL.build/Install/include',
        target / 'DerivedSources/NIfTI', BUILD / 'ExternalInputs.build/Install/include']]
    listed = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '*.h'], capture_output=True, text=True).stdout.split('\n')
    folders = sorted({str(Path(p).parent) for p in listed if p and not p.startswith(
        ('DCMTK/', 'ITK/', 'VTK/', 'Binaries/', 'OpenJPEG/', 'tests/', 'tools/', 'Modules/', 'DCM Framework'))})
    includes += ['-I' + str(ROOT / folder) for folder in folders]
    includes += ['-isystem' + str(p) for p in [BUILD / 'VTK.build/Install/include', BUILD / 'ITK.build/Install/include',
                                               BUILD / 'OpenJPEG.build/Install/include']]
    common = ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-fobjc-exceptions', '-fPIC',
              '-fvisibility=default', '-w', '-mmacosx-version-min=15.0', '-I' + str(overlay), '-F' + str(ROOT / 'Binaries'),
              '-F' + str(ROOT / 'build/Build/Products/Debug'), '-DDEBUG=1',
              '-ivfsoverlay', str(overlay_file), *('-D%s=%s' % pair for pair in RENAMED.items()), *includes]
    objects = []
    for path in (*SOURCES, 'IsiXLegacyHorosDateString.mm'):
        name = Path(path).name
        language = ['-x', 'c++'] if name.endswith('.cpp') else ['-x', 'objective-c++', '-include', str(ROOT / 'Horos/prefix.pch')]
        obj = work / (name + '.o')
        built = subprocess.run([*common, *language, '-c', str(sources / name), '-o', str(obj)], capture_output=True, text=True)
        if built.returncode:
            raise SystemExit('FAIL: the reference %s does not compile:\n%s' % (name, built.stderr[-5000:]))
        objects.append(str(obj))
    (work / 'driver.m').write_text(DRIVER)
    library = work / 'reference.dylib'
    built = subprocess.run(['xcrun', 'clang++', '-dynamiclib', '-fobjc-arc', '-x', 'objective-c', str(work / 'driver.m'),
                            '-x', 'none', *objects, '-undefined', 'dynamic_lookup', '-framework', 'Cocoa',
                            '-o', str(library)], capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the reference library does not link:\n' + built.stderr[-4000:])
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)], check=True, capture_output=True)
    return library


# --------------------------------------------------------------- comparing
COMPARE = r'''
import hashlib, json, sys, time
from pathlib import Path
import pydicom

known = set(json.loads(sys.argv[1]))
today = set(json.loads(sys.argv[2]))
window = json.loads(sys.argv[3])


def seconds(text):
    text = text.strip()
    try:
        return int(text[0:2]) * 3600 + int(text[2:4] or 0) * 60 + int(text[4:6] or 0)
    except ValueError:
        return None


def flatten(path):
    """Every element of a file: tag path, VR and value, with what is new at
    each write (UIDs that are none of the inputs', the run's date and time)
    replaced by the order they first appear in."""
    news = {}
    rows = []

    def value_of(element):
        if element.VR == 'SQ':
            return None
        raw = element.value
        if isinstance(raw, (bytes, bytearray)):
            return 'sha256:%s:%d' % (hashlib.sha256(raw).hexdigest(), len(raw))
        values = list(raw) if isinstance(raw, pydicom.multival.MultiValue) else [raw]
        out = []
        for value in values:
            text = str(value)
            if element.VR == 'UI' and text and text not in known:
                text = news.setdefault(text, '<new %d>' % len(news))
            elif element.VR == 'DA' and text in today:
                text = '<today>'
            elif element.VR == 'DT' and text[:8] in today:
                text = '<now>'
            elif element.VR == 'TM' and seconds(text) is not None and window[0] - 120 <= seconds(text) <= window[1] + 120:
                text = '<now>'
            out.append(text)
        return out

    def walk(dataset, prefix):
        for element in dataset:
            if (element.tag.group, element.tag.element) in ((0x0004, 0x1200), (0x0004, 0x1202), (0x0004, 0x1400),
                                                            (0x0004, 0x1410), (0x0004, 0x1420)):
                continue  # offsets within a DICOMDIR, which follow the length of what comes before
            key = prefix + '(%04X,%04X)' % (element.tag.group, element.tag.element)
            rows.append([key, element.VR, value_of(element)])
            if element.VR == 'SQ':
                for index, item in enumerate(element.value):
                    walk(item, '%s[%d]' % (key, index))

    dataset = pydicom.dcmread(path, force=True)
    walk(dataset.file_meta, '')
    walk(dataset, '')
    return rows


answer = {}
for line in sys.stdin:
    relative, legacy, current = json.loads(line)
    try:
        answer[relative] = [flatten(legacy), flatten(current)]
    except Exception as error:
        answer[relative] = ['unreadable: %s' % error, None]
print(json.dumps(answer))
'''


def all_files(folder):
    return sorted(str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file())


def first_difference(old, new):
    if not isinstance(old, list) or not isinstance(new, list):
        return 'reference %s, current %s' % (str(old)[:300], str(new)[:300])
    for a, b in zip(old, new):
        if a != b:
            return 'reference %s, current %s' % (a, b)
    return 'reference has %d elements, current %d' % (len(old), len(new))


def known_uids(files):
    script = ('import json, sys, pydicom\nseen = set()\n'
              'def walk(d):\n'
              '    for e in d:\n'
              '        if e.VR == "UI": seen.update(str(v) for v in (e.value if isinstance(e.value, pydicom.multival.MultiValue) else [e.value]))\n'
              '        if e.VR == "SQ":\n'
              '            for i in e.value: walk(i)\n'
              'for p in sys.argv[1:]:\n'
              '    d = pydicom.dcmread(p, force=True); walk(d.file_meta); walk(d)\n'
              'print(json.dumps(sorted(seen)))\n')
    return json.loads(subprocess.run([python, '-c', script, *files], capture_output=True, text=True, check=True).stdout)


def main():
    work = Path(tempfile.mkdtemp(prefix='isix-export-equivalence-'))
    failures = []
    try:
        made = generate(work / 'files')
        files = {name: path for name, path in made.items() if name != 'study'}
        library = compile_reference(work)
        bundle = work / 'HorosDevelopment.app'
        shutil.copytree(app, bundle, symlinks=True)
        entitlements = plistlib.loads((ROOT / 'build/Development/entitlements.plist').read_bytes())
        entitlements['com.apple.security.cs.allow-dyld-environment-variables'] = True
        (work / 'entitlements.plist').write_bytes(plistlib.dumps(entitlements))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', '--entitlements',
                        str(work / 'entitlements.plist'), str(bundle)], check=True, capture_output=True)
        exchange = work / 'exchange'
        exchange.mkdir()
        out = work / 'out'
        test_root = work / 'root'
        started = time.time()
        process = native_app.launch(test_root, work / 'app.log', ['-ApplePersistenceIgnoreState', 'YES',
                                                                  '-useDCMTKForDicomExport', 'YES'],
                                    app=bundle, environment={'DYLD_INSERT_LIBRARIES': str(library),
                                                             'ISIX_EXPORT_EQUIVALENCE': str(exchange)})
        try:
            native_app.wait_for(lambda: (native_app.database_folder(test_root) / 'INCOMING.noindex').is_dir()
                                or process.poll() is not None, 120, description='the database to open')
            if process.poll() is not None:
                raise SystemExit('FAIL: the application ended before the cases (%s)' % process.returncode)
            anonymized = [n for n in ('ct_explicit.dcm', 'mr_implicit.dcm', 'us_rgb_utf8.dcm', 'jp_2022.dcm',
                                      'ct_bigendian.dcm') if n in files]
            manifest = {'files': files, 'study': made['study'], 'out': str(out), 'anonymize': anonymized}
            (exchange / '.go.json').write_text(json.dumps(manifest))
            (exchange / '.go.json').rename(exchange / 'go.json')
            native_app.wait_for(lambda: (exchange / 'answers.json').exists() or process.poll() is not None, 600,
                                interval=1, description='the answers')
            if not (exchange / 'answers.json').exists():
                raise SystemExit('FAIL: the application ended during the cases (%s); see %s' % (process.returncode, work / 'app.log'))
        finally:
            native_app.stop(process)
        ended = time.time()
        answers = json.loads((exchange / 'answers.json').read_text())
        legacy, current = answers['legacy'], answers['current']

        # What each call answered: the name of an archive's staging folder is
        # made anew at each call, and a report read from nothing has new UIDs.
        def plain(value):
            return json.loads(re.sub(r'\.horos-zip-[0-9A-F-]{36}', '.horos-zip-<staging>',
                                     re.sub(r'1\.2\.276\.0\.7230010\.3\.[0-9.]+', '<new uid>', json.dumps(value))))

        for part in ('anonymize', 'dicomdir', 'sr', 'export'):
            for case in sorted(set(legacy[part]) | set(current[part])):
                old, new = legacy[part].get(case), current[part].get(case)
                if part == 'dicomdir':
                    old, new = plain(old), plain(new)
                if old != new:
                    failures.append('%s %s answered differently:\n  reference %s\n  current   %s'
                                    % (part, case, json.dumps(old, ensure_ascii=False)[:1500],
                                       json.dumps(new, ensure_ascii=False)[:1500]))
        # The reports, as each side reads them. -annotations answers a
        # dictionary, as declared: the reference also answered the window
        # states' array through that declaration, which a caller could not use
        # as one; the Swift answers nil for a property list that is no
        # dictionary. That is the one difference allowed.
        reads = answers['reads']
        allowed = 0
        for name in sorted(reads['legacy']):
            old, new = reads['legacy'][name], reads['current'].get(name)
            if name in ('missing', 'notdicom'):
                old, new = plain(old), plain(new)
            instance_old, instance_new = (old or {}).get('instance'), (new or {}).get('instance')
            if (isinstance(instance_old, dict) and isinstance(instance_new, dict)
                    and isinstance(instance_old.get('annotations'), list) and instance_new.get('annotations') is None):
                old = json.loads(json.dumps(old))
                old['instance']['annotations'] = None
                allowed += 1
            if old != new:
                failures.append('reading %s:\n  reference %s\n  current   %s'
                                % (name, json.dumps(old, ensure_ascii=False)[:1500],
                                   json.dumps(new, ensure_ascii=False)[:1500]))

        # What each wrote: the same files, the anonymized ones the same bytes,
        # every DICOM the same attributes.
        old_files, new_files = all_files(out / 'legacy'), all_files(out / 'current')
        if old_files != new_files:
            failures.append('the files written differ:\n  reference only %s\n  current only   %s'
                            % (sorted(set(old_files) - set(new_files)), sorted(set(new_files) - set(old_files))))
        common = [f for f in old_files if f in new_files]
        same_bytes = 0
        for relative in common:
            if relative.startswith('anonymize/') and Path(relative).name.startswith('anon_'):
                same_bytes += 1
                if (out / 'legacy' / relative).read_bytes() != (out / 'current' / relative).read_bytes():
                    failures.append('%s: the anonymized bytes differ' % relative)
        dicom = [f for f in common if not f.startswith('anonymize/') and Path(f).name not in ('.DS_Store', 'DICOMDIR.BAK')
                 and not Path(f).name.startswith('._') and f.split('/')[0] in ('dicomdir', 'sr', 'export')
                 and (Path(f).name == 'DICOMDIR' or f.split('/')[0] != 'dicomdir')]
        inputs = [p for n, p in files.items() if n.endswith('.dcm')]
        known = known_uids(inputs) + ['1.2.826.0.1.3680043.10.1488.5002', '1.2.826.0.1.3680043.10.1488.1', made['study']]
        days = sorted({time.strftime('%Y%m%d', time.localtime(t)) for t in (started, ended)})
        window = [time.localtime(started).tm_hour * 3600 + time.localtime(started).tm_min * 60 + time.localtime(started).tm_sec,
                  time.localtime(ended).tm_hour * 3600 + time.localtime(ended).tm_min * 60 + time.localtime(ended).tm_sec]
        lines = ''.join(json.dumps([f, str(out / 'legacy' / f), str(out / 'current' / f)]) + '\n' for f in dicom)
        compared = json.loads(subprocess.run([python, '-c', COMPARE, json.dumps(known), json.dumps(days), json.dumps(window)],
                                             input=lines, capture_output=True, text=True, check=True).stdout)
        kinds = {}
        for relative, (old, new) in sorted(compared.items()):
            kinds[relative.split('/')[0]] = kinds.get(relative.split('/')[0], 0) + 1
            if old != new:
                failures.append('%s: the attributes differ: %s' % (relative, first_difference(old, new)))
        if same_bytes == 0 or kinds.get('sr', 0) == 0 or kinds.get('export', 0) == 0 or kinds.get('dicomdir', 0) == 0:
            failures.append('too little was written to compare: %d anonymized, %s' % (same_bytes, kinds))

        if arguments.keep:
            arguments.keep.mkdir(parents=True, exist_ok=True)
            shutil.copy(exchange / 'answers.json', arguments.keep / 'answers.json')
            (arguments.keep / 'compared.json').write_text(json.dumps(compared, ensure_ascii=False, indent=1))
        for failure in failures:
            print('FAIL: ' + failure)
        if failures:
            print('%d difference(s); reference %s' % (len(failures), reference))
            raise SystemExit(1)
        print('PASS: %d anonymized files the same bytes (%d cases with their failures), %d DICOMDIRs, %d reports '
              '(read crosswise by both; %d window-state arrays answered nil by -annotations) and %d exports the same '
              'attributes, as the Objective-C++ of %s wrote them'
              % (same_bytes, len(legacy['anonymize']), kinds.get('dicomdir', 0), kinds.get('sr', 0), allowed,
                 kinds.get('export', 0), reference[:9]))
    finally:
        if arguments.keep:
            arguments.keep.mkdir(parents=True, exist_ok=True)
            if (work / 'app.log').exists():
                shutil.copy(work / 'app.log', arguments.keep / 'app.log')
            if (work / 'out').exists():
                shutil.copytree(work / 'out', arguments.keep / 'out', dirs_exist_ok=True)
        shutil.rmtree(work, ignore_errors=True)


main()
