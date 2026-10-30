#!/usr/bin/env python3
"""DicomFile reads every format as the Objective-C++ it replaced did.

DicomFile.mm was the import's reader: the files that are not DICOM, the
classification of an incoming file, the text of a value and the patient's
identifier. It is Swift now (DicomFile+<category>.swift, the rules in the
IsiXDICOMFile module, libtiff and DCMTK behind the adapters), the DICOM reading
(DicomFileDCMTKCategory.mm) and the class's state (DicomFile.m) included.

The reference is DicomFile.mm, DicomFileDCMTKCategory.mm and DICOMDataDictionary.mm
of the last revision that has DicomFile.mm, with the headers they had there,
compiled here, as the application compiled them, into a library whose class and
dictionary functions are renamed (IsiXLegacyDicomFile), with a driver. The library
is injected into a copy of the Debug development bundle, which provides
everything both readers use: DCMTK with its dictionary and codecs, DCM.framework,
libtiff with the FluoView tags, nifti1_io, the preferences. Both classes then
read the same synthetic files in the running application, and the driver writes
what each answered:

- -init: and -init:DICOMOnly:YES: every element of -dicomElements (strings,
  numbers with their type, dates with their class), the size and the counts;
- +isDICOMFile:compressed:image:mayTranscode:, +isTiffFile:, +isImageFile:,
  +isFVTiffFile:, +isNIfTIFile:, +isXMLDescriptedFile:, +isXMLDescriptorFile:;
- +getNIfTIXML: as XML text;
- +stringWithBytes:encodings:replaceBadCharacters: on byte strings in single
  byte, UTF-8 and ISO 2022 character sets (escape sequences, the Japanese and
  Korean multi-byte sets, unknown and cut escapes, delimiters);
- +NSreplaceBadCharacter: on 400 strings drawn from the characters it cleans,
  with and without combining marks, and +replaceBadCharacter:encoding:;
- +patientUID: of records with and without each part;
- -containsLocalizerInString: and -containsString:inArray:.

The files come from the tools/ generators - DICOM in several character sets,
non-image objects, a multiframe RGB image, an encapsulated PDF, a structured
report, NIfTI and Analyze in every datatype and byte order (and damaged ones),
TIFF, PNG, JPEG, PDF, BMP and GIF (ffmpeg) - and from small writers here: a
multi-page TIFF, a FluoView TIFF, a Bio-Rad PIC, a Zeiss LSM, names that end in
numbers, and files that are none of these.

Exit 2 without the Debug bundle, a Python with pydicom and numpy (HOROS_PYTHON or
the local venvs), or the history.

    python3 tests/test-dicom-file-equivalence.py [--reference REV] [--keep DIR]
"""
import argparse
import base64
import json
import os
import plistlib
import random
import shutil
import struct
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
parser.add_argument('--reference', help='revision whose DicomFile.mm is the reference')
parser.add_argument('--app', type=Path, default=native_app.DEVELOPMENT_APP)
parser.add_argument('--keep', type=Path, help='keep the files, the logs and the answers here')
arguments = parser.parse_args()

SOURCE = 'Horos/Sources/DicomFile.mm'
CATEGORY = 'Horos/Sources/DicomFileDCMTKCategory.mm'
DICTIONARY = 'Horos/Sources/DICOMDataDictionary.mm'
# The headers of the reference that have changed or left since: they are
# written beside its sources, where a quoted import finds them first.
REFERENCE_HEADERS = ['Horos/Sources/DicomFile.h', 'Horos/Sources/DicomFileDCMTKCategory.h',
                     'Horos/Sources/DICOMDataDictionary.h', 'Horos/Sources/HorosDictionaryLookup.h',
                     'Horos/Sources/HorosDICOMLegacyNames.h']
# What the reference defines that the application still defines under the same name.
RENAMED = {'DicomFile': 'IsiXLegacyDicomFile', 'HorosDICOMDictionaries': 'IsiXLegacyDICOMDictionaries',
           'HorosLoadVendoredDicomDictionary': 'IsiXLegacyLoadVendoredDicomDictionary',
           'HorosVendoredDicomDictionaryPath': 'IsiXLegacyVendoredDicomDictionaryPath',
           'HorosResolveDicomKeyword': 'IsiXLegacyResolveDicomKeyword'}
FLUOVIEW, FLUOVIEW_HEADER = 'Horos/Sources/FVTiff.m', 'Horos/Sources/FVTiff.h'
HOROS, LEGACY_HOROS = 'Horos/Sources/Horos.m', 'IsiXLegacyHoros.m'
reference = arguments.reference or history_reference.before_removal(SOURCE)
if reference is None:
    print('skipped: no revision of this history has %s' % SOURCE)
    raise SystemExit(2)
if (ROOT / SOURCE).exists():
    print('skipped: %s is still the reader; there is nothing to compare it with' % SOURCE)
    raise SystemExit(2)

app = arguments.app
executable = app / 'Contents/MacOS/IsiX DICOM Viewer'
derived = BUILD / 'Horos.build/DerivedSources'
needed = [executable, derived / 'Horos-Swift.h', BUILD / 'DCMTK.build/Install/include/dcmtk/config/osconfig.h',
          BUILD / 'VTK.build/Install/include/vtk_tiff.h', BUILD / 'ExternalInputs.build/Install/include/tiffio.h',
          derived / 'NIfTI/nifti1_io.h', ROOT / 'build/Development/entitlements.plist']
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
    print('skipped: the generators need a Python with pydicom and numpy (HOROS_PYTHON)')
    raise SystemExit(2)


# --------------------------------------------------------------- the files
def tiff(pages, extra=(), name_digits=None):
    """A little-endian TIFF of 8-bit grey `pages` [(width, height)]; the first
    directory has the `extra` [(tag, type, count, bytes)] entries too."""
    data = bytearray(b'II*\0' + struct.pack('<I', 0))
    offsets = []
    for index, (width, height) in enumerate(pages):
        pixels = bytes((x * 3 + y * 5) % 256 for y in range(height) for x in range(width))
        strip = len(data)
        data += pixels
        entries = [(256, 4, 1, struct.pack('<I', width)), (257, 4, 1, struct.pack('<I', height)),
                   (258, 3, 1, struct.pack('<HH', 8, 0)), (259, 3, 1, struct.pack('<HH', 1, 0)),
                   (262, 3, 1, struct.pack('<HH', 1, 0)), (273, 4, 1, struct.pack('<I', strip)),
                   (277, 3, 1, struct.pack('<HH', 1, 0)), (278, 4, 1, struct.pack('<I', height)),
                   (279, 4, 1, struct.pack('<I', len(pixels)))]
        if index == 0:
            entries += list(extra)
        entries.sort()
        blobs = {}
        for tag, kind, count, value in entries:
            if len(value) > 4:
                if len(data) % 2:
                    data += b'\0'
                blobs[tag] = len(data)
                data += value
        if len(data) % 2:
            data += b'\0'
        offsets.append(len(data))
        data += struct.pack('<H', len(entries))
        for tag, kind, count, value in entries:
            field = struct.pack('<I', blobs[tag]) if tag in blobs else value.ljust(4, b'\0')
            data += struct.pack('<HHI', tag, kind, count) + field
        data += struct.pack('<I', 0)
    struct.pack_into('<I', data, 4, offsets[0])
    for previous, following in zip(offsets, offsets[1:]):
        count = struct.unpack_from('<H', data, previous)[0]
        struct.pack_into('<I', data, previous + 2 + 12 * count, following)
    return bytes(data)


def fluoview(dimensions, description):
    # The dimensions not listed are unnamed, of size 1: DicomFile.mm read a
    # size of 0 as no series at all, which the import now reads as one
    # position (tests/test-fluoview-unused-dimensions.py), so the two readings
    # are compared where they agree.
    header = bytearray(284 + 10 * 104 + 132)
    for index, (name, size) in enumerate(list(dimensions) + [('', 1)] * (10 - len(dimensions))):
        at = 284 + 104 * index
        header[at:at + len(name)] = name.encode()
        struct.pack_into('<I', header, at + 16, size)
    text = description + b'\0'
    return tiff([(6, 4)], [(270, 2, len(text), text), (34361, 1, len(header), bytes(header))])


def biorad(width, height, frames, byte_format=1):
    header = bytearray(76)
    struct.pack_into('<hhh', header, 0, width, height, frames)
    struct.pack_into('<h', header, 14, byte_format)
    return bytes(header) + bytes(width * height * max(frames, 0))


def lsm(width, height, z, channels, times, scan_type):
    """A Zeiss LSM: a TIFF directory at offset 8 and its CZ_LSMINFO block."""
    count = 10
    info = 8 + 2 + 12 * count + 4
    pixels = info + 512
    entries = [(254, 4, 1, 0), (256, 4, 1, width), (257, 4, 1, height), (258, 3, 1, 8), (259, 3, 1, 1),
               (262, 3, 1, 1), (273, 4, 1, pixels), (277, 3, 1, 1), (279, 4, 1, width * height), (34412, 4, 1, info)]
    data = bytearray(b'II*\0' + struct.pack('<I', 8) + struct.pack('<H', count))
    for tag, kind, number, value in entries:
        data += struct.pack('<HHII', tag, kind, number, value)
    data += struct.pack('<I', 0)
    block = bytearray(512)
    struct.pack_into('<iiiiiI', block, 8, width, height, z, channels, times, 1)
    struct.pack_into('<I', block, 64, scan_type)
    data += block
    data += bytes(width * height * max(z, 1))
    return bytes(data)


def generate(folder):
    files = []

    def run(tool, destination, *extra):
        destination.mkdir(parents=True)
        result = subprocess.run([python, str(ROOT / 'tools' / tool), str(destination), *extra],
                                capture_output=True, text=True, timeout=300)
        if result.returncode:
            print('note: %s did not run (%s); its files are left out' % (tool, result.stderr.strip()[-300:]))
            return []
        return sorted(p for p in destination.rglob('*') if p.is_file() and not p.name.endswith(('.json', '.md')))

    files += run('generate-character-set-fixture.py', folder / 'charset')
    files += run('generate-non-image-fixture.py', folder / 'non-image')
    files += run('generate-print-selection-fixture.py', folder / 'print', '--images', '2')
    files += run('generate-multiframe-fixture.py', folder / 'multiframe', '--frames', '4')
    files += run('generate-nifti-matrix.py', folder / 'nifti')
    if shutil.which('ffmpeg'):
        files += run('generate-raster-import-fixture.py', folder / 'raster')
        files += run('generate-mpeg4-fixture.py', folder / 'mpeg4', '--frames', '4')
        movie = folder / 'movie' / 'clip0007.mov'
        movie.parent.mkdir()
        if subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                           'color=c=gray:s=24x16:r=4', '-frames:v', '5', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                           str(movie)], capture_output=True).returncode == 0:
            files.append(movie)
    else:
        print('note: no ffmpeg; the raster images and the movie are left out')

    own = folder / 'own'
    own.mkdir()
    written = {
        'pages.tif': tiff([(5, 9), (7, 3), (2, 2)]),
        'scan0001.tif': tiff([(4, 4)]),
        'scan12345.tiff': tiff([(3, 5)]),
        'x001.stk': tiff([(4, 2), (4, 2)]),
        'a12.tif': tiff([(2, 6)]),
        'plain.tif': tiff([(8, 8)]),
        'fluoview.tif': fluoview([('X', 6), ('Y', 4), ('Z', 3), ('Ch', 2), ('T', 3)],
                                 b'[Acquisition Parameters]\r\nDate=02/29/2024\r\nTime=12:34:56\r\n'
                                 b'[Acquisition Parameters End]\r\n[Description]\r\nA synthetic FluoView file\r\n'
                                 b'[Description End]\r\n'),
        'fluoview-iso.tif': fluoview([('X', 6), ('Y', 4), ('Ch', 1)],
                                     b'[Acquisition Parameters]\r\nDate=2024-02-29\r\nTime=12:34:56\r\n'
                                     b'[Acquisition Parameters End]\r\n'),
        'cells21.pic': biorad(8, 6, 3),
        'stack.pic': biorad(4, 4, 2, byte_format=2),
        'empty.pic': biorad(4, 4, 0),
        'z.lsm': lsm(10, 8, 4, 2, 3, 0),
        'time.lsm': lsm(6, 6, 1, 1, 5, 3),
        'tiny.lsm': b'II',
        'notes.txt': b'neither DICOM nor anything else',
        'lonely.hdr': b'\0' * 348,
        'empty.dcm': b'',
        'truncated.nii': b'\x5c\x01\0\0' + b'\0' * 100,
    }
    for name, data in written.items():
        (own / name).write_bytes(data)
        files.append(own / name)
    descriptor = own / 'described.dat'
    descriptor.write_bytes(b'data')
    (own / 'described.xml').write_text('<x/>')
    (own / 'described.zip').write_bytes(b'PK')
    files.append(descriptor)
    # Names that end in numbers, from the raster images when they were written.
    raster = sorted((folder / 'raster').glob('*')) if (folder / 'raster').is_dir() else []
    for source, name in zip([p for p in raster if p.suffix in ('.png', '.jpg', '.gif', '.bmp', '.pdf')],
                            ['img12.png', 'shot7.jpg', 'frame0042.gif', 'b99999.bmp', 'report3.pdf']):
        if source.suffix == Path(name).suffix:
            shutil.copy(source, own / name)
            files.append(own / name)
    unicode_name = own / 'Ünïcödé 3.tif'
    unicode_name.write_bytes(tiff([(3, 3)]))
    files.append(unicode_name)
    return files


def text_cases():
    """Byte strings for +stringWithBytes:..., with the first character set of their file."""
    esc = b'\x1b'
    cases = [
        (b'DOE^JOHN', ['ISO_IR 100']),
        (b'M\xfcller^J\xfcrgen  ', ['ISO_IR 100']),
        (b'A,B/C\r\n"D"', ['ISO_IR 100']),
        (b'Yamada^Tarou=' + esc + b'$B;3ED' + esc + b'(B^' + esc + b'$BB@O:' + esc + b'(B=' + esc + b'$B$d$^$@' + esc
         + b'(B^' + esc + b'$B$?$m$&' + esc + b'(B', ['', 'ISO 2022 IR 87']),
        (b'Hong^Gildong=' + esc + b'$)C\xfb\xf3^' + esc + b'$)C\xd1\xce\xd4\xd7=' + esc + b'$)C\xc8\xab^' + esc
         + b'$)C\xb1\xe6\xb5\xbf', ['', 'ISO 2022 IR 149']),
        (b'Dionysios=' + esc + b'-F\xc4\xe9\xef\xed\xf5\xf3\xe9\xef\xf2', ['', 'ISO 2022 IR 126']),
        (b'abc' + esc + b'xyz', ['ISO_IR 100']),
        (b'cut' + esc + b'$', ['ISO_IR 100']),
        (b'cut' + esc + b'$(', ['ISO_IR 100']),
        (b'J' + esc + b'$(Dabc' + esc + b'(Bd', ['', 'ISO 2022 IR 159']),
        (b'\xd0\x98\xd0\xb2\xd0\xb0\xd0\xbd\xd0\xbe\xd0\xb2^\xd0\x98\xd0\xb2\xd0\xb0\xd0\xbd', ['ISO_IR 192']),
        (b'\xb8\xd2\xd0\xdd\xde\xd2', ['ISO_IR 144']),
        (b'\xff\xfe\x80', ['ISO_IR 192']),
        (b'', ['ISO_IR 100']),
        (b'   ', ['ISO_IR 100']),
        (b'a\x0cb\x0dc\x0ad', ['ISO_IR 100']),
    ]
    return [{'bytes': base64.b64encode(data).decode(), 'sets': sets} for data, sets in cases]


def cleaning_cases():
    alphabet = ['a', 'Z', '0', ' ', ' ', ',', '^', '/', '\r', '\n', '"', '-', '=', 'é', 'e\u0301', '\u00a0',
                '\u3042', '\u0301', '\t', ':']
    generator = random.Random(20261028)
    strings = ['', ' ', '  ', 'a', 'a ', ' a', 'DOE^JOHN', 'name   ', 'x      y', 'a     b', 'a    b',
               'JOSÉ^ÁLVARO  ', ' ,x', 'e\u0301,a', 'a^\u0301b', '\u00a0 \u00a0']
    for _ in range(400):
        strings.append(''.join(generator.choice(alphabet) for _ in range(generator.randrange(0, 14))))
    return strings


PATIENTS = [
    {'patientName': 'DOE^JOHN', 'patientID': 'P1', 'patientBirthDate': 0.0},
    {'patientName': 'Doe-Smith^Jane=ドウ', 'patientID': 'id-2'},
    {'patientName': 'O\'Brien, Pat ', 'patientID': 12345, 'patientBirthDate': -86400.0 * 3650},
    {'patientID': 'only'},
    {'patientName': '=x', 'patientBirthDate': 'not a date'},
    {},
]

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#include <CommonCrypto/CommonDigest.h>

@interface NSObject (IsiXEquivalenceMessages)
- (id) init:(NSString *)path;
- (id) init:(NSString *)path DICOMOnly:(BOOL)dicomOnly;
- (NSMutableDictionary *) dicomElements;
- (long) getWidth;
- (long) getHeight;
- (long) NoOfFrames;
- (long) NoOfSeries;
+ (BOOL) isDICOMFile:(NSString *)p compressed:(BOOL *)c image:(BOOL *)i mayTranscode:(BOOL *)t;
+ (BOOL) isTiffFile:(NSString *)p;
+ (BOOL) isImageFile:(NSString *)p;
+ (BOOL) isFVTiffFile:(NSString *)p;
+ (BOOL) isNIfTIFile:(NSString *)p;
+ (BOOL) isXMLDescriptedFile:(NSString *)p;
+ (BOOL) isXMLDescriptorFile:(NSString *)p;
+ (NSXMLDocument *) getNIfTIXML:(NSString *)p;
+ (NSString *) stringWithBytes:(char *)s encodings:(NSStringEncoding *)e replaceBadCharacters:(BOOL)r;
+ (NSString *) stringWithBytes:(char *)s encodings:(NSStringEncoding *)e;
+ (NSString *) NSreplaceBadCharacter:(NSString *)s;
+ (char *) replaceBadCharacter:(char *)s encoding:(NSStringEncoding)e;
+ (NSString *) patientUID:(id)src;
- (BOOL) containsLocalizerInString:(NSString *)s;
- (BOOL) containsString:(NSString *)s inArray:(NSArray *)a;
+ (NSStringEncoding) encodingForDICOMCharacterSet:(NSString *)set;
- (BOOL) commentsFromDICOMFiles;
- (BOOL) autoFillComments;
- (BOOL) splitMultiEchoMR;
- (BOOL) useSeriesDescription;
- (BOOL) noLocalizer;
- (BOOL) combineProjectionSeries;
- (BOOL) oneFileOnSeriesForUS;
- (BOOL) combineProjectionSeriesMode;
- (BOOL) separateCardiac4D;
- (int) commentsGroup;
- (int) commentsElement;
@end

static id Describe(id value)
{
    if (value == nil) return [NSNull null];
    if ([value isKindOfClass:NSString.class]) return @{@"s": value};
    if ([value isKindOfClass:NSNumber.class])
        return @{@"n": [value stringValue], @"t": @([value objCType])};
    if ([value isKindOfClass:NSDate.class])
        return @{@"d": @([value timeIntervalSinceReferenceDate]),
                 // The DICOM date type: the DCM framework's, then IsiXDICOMFile's.
                 @"c": ([value isKindOfClass:NSClassFromString(@"DCMCalendarDate")] ||
                        [value isKindOfClass:NSClassFromString(@"IsiXDICOMCalendarDate")]) ? @"DCMCalendarDate" : @"NSDate"};
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
        return @{@"data": hex};
    }
    return @{@"o": NSStringFromClass([value class]), @"desc": [value description]};
}

static id Guarded(id (^body)(void))
{
    @try { id value = body(); return value ? value : [NSNull null]; }
    @catch (NSException *exception) { return @{@"exception": exception.name ?: @"?", @"reason": exception.reason ?: @""}; }
}

static NSDictionary *ReadFile(Class cls, NSString *path)
{
    NSMutableDictionary *answer = [NSMutableDictionary dictionary];
    answer[@"init"] = Guarded(^id{
        id file = [[cls alloc] init:path];
        if (!file) return nil;
        return @{@"elements": Describe([file dicomElements]),
                 @"size": @[@([file getWidth]), @([file getHeight]), @([file NoOfFrames]), @([file NoOfSeries])],
                 @"settings": @[@([file commentsFromDICOMFiles]), @([file autoFillComments]), @([file splitMultiEchoMR]),
                                @([file useSeriesDescription]), @([file noLocalizer]), @([file combineProjectionSeries]),
                                @([file oneFileOnSeriesForUS]), @([file combineProjectionSeriesMode]),
                                @([file separateCardiac4D]), @([file commentsGroup]), @([file commentsElement])]};
    });
    answer[@"dicomOnly"] = Guarded(^id{
        id file = [[cls alloc] init:path DICOMOnly:YES];
        return file ? Describe([file dicomElements]) : nil;
    });
    answer[@"classify"] = Guarded(^id{
        BOOL compressed = YES, image = YES, transcode = YES;
        BOOL dicom = [cls isDICOMFile:path compressed:&compressed image:&image mayTranscode:&transcode];
        return @[@(dicom), @(compressed), @(image), @(transcode), @([cls isTiffFile:path]), @([cls isImageFile:path]),
                 @([cls isFVTiffFile:path]), @([cls isNIfTIFile:path]), @([cls isXMLDescriptedFile:path]),
                 @([cls isXMLDescriptorFile:path])];
    });
    answer[@"niftiXML"] = Guarded(^id{ return [[cls getNIfTIXML:path] XMLString]; });
    return answer;
}

static NSDictionary *Text(Class cls, NSDictionary *manifest)
{
    NSMutableArray *decoded = [NSMutableArray array];
    for (NSDictionary *item in manifest[@"text"]) {
        NSData *bytes = [[NSData alloc] initWithBase64EncodedString:item[@"bytes"] options:0];
        NSMutableData *table = [NSMutableData dataWithLength:10 * sizeof(NSStringEncoding)];
        NSStringEncoding *encodings = (NSStringEncoding *) table.mutableBytes;
        NSArray *sets = item[@"sets"];
        Class characterSets = NSClassFromString(@"DCMCharacterSet");
        for (NSUInteger i = 0; i < sets.count && i < 10; i++)
            encodings[i] = [sets[i] length] ? [characterSets encodingForDICOMCharacterSet:sets[i]] : NSISOLatin1StringEncoding;
        for (NSNumber *replace in @[@YES, @NO]) {
            NSMutableData *text = [bytes mutableCopy];
            [text appendBytes:"" length:1];
            [decoded addObject:Guarded(^id{ return Describe([cls stringWithBytes:(char *)text.mutableBytes encodings:encodings
                                                                 replaceBadCharacters:replace.boolValue]); })];
        }
        NSMutableData *text = [bytes mutableCopy];
        [text appendBytes:"" length:1];
        [decoded addObject:Guarded(^id{ return Describe([cls stringWithBytes:(char *)text.mutableBytes encodings:encodings]); })];
    }
    NSMutableArray *cleaned = [NSMutableArray array], *cleanedC = [NSMutableArray array];
    for (NSString *string in manifest[@"clean"]) {
        [cleaned addObject:Guarded(^id{ return Describe([cls NSreplaceBadCharacter:string]); })];
        for (NSNumber *encoding in @[@(NSISOLatin1StringEncoding), @(NSUTF8StringEncoding)]) {
            NSMutableData *bytes = nil;
            @try {
                bytes = [[string dataUsingEncoding:encoding.unsignedIntegerValue allowLossyConversion:YES] mutableCopy];
            } @catch (NSException *exception) {}
            if (!bytes) {  // a lone surrogate has no UTF-8 form, even a lossy one
                [cleanedC addObject:@"(no bytes)"];
                continue;
            }
            [bytes appendBytes:"" length:1];
            [cleanedC addObject:Guarded(^id{
                char *result = [cls replaceBadCharacter:(char *)bytes.mutableBytes encoding:encoding.unsignedIntegerValue];
                return [[NSData dataWithBytes:result length:strlen(result)] base64EncodedStringWithOptions:0];
            })];
        }
    }
    NSMutableArray *patients = [NSMutableArray array];
    for (NSDictionary *record in manifest[@"patients"]) {
        NSMutableDictionary *source = [record mutableCopy];
        if ([record[@"patientBirthDate"] isKindOfClass:NSNumber.class])
            source[@"patientBirthDate"] = [NSDate dateWithTimeIntervalSinceReferenceDate:[record[@"patientBirthDate"] doubleValue]];
        [patients addObject:Guarded(^id{ return Describe([cls patientUID:source]); })];
    }
    NSMutableArray *localizers = [NSMutableArray array];
    id file = [[cls alloc] init:manifest[@"anyFile"]];
    for (NSString *string in @[@"LOCALIZER", @"scout view", @"Topogram", @"axial", @"", @"3-plane loc", @"SURVEY"]) {
        [localizers addObject:Guarded(^id{ return @([file containsLocalizerInString:string]); })];
        [localizers addObject:Guarded(^id{ return @([file containsString:string inArray:@[@"LOCALIZER", @1, @"axial"]]); })];
    }
    return @{@"decoded": decoded, @"cleaned": cleaned, @"cleanedC": cleanedC, @"patients": patients,
             @"localizers": localizers, @"localizerStrings": Describe([NSUserDefaults.standardUserDefaults
                                                                         objectForKey:@"NOLOCALIZER_Strings"])};
}

__attribute__((constructor)) static void IsiXEquivalenceStart(void)
{
    NSString *folder = NSProcessInfo.processInfo.environment[@"ISIX_DICOMFILE_EQUIVALENCE"];
    if (!folder) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *go = [folder stringByAppendingPathComponent:@"go.json"];
        while (![NSFileManager.defaultManager fileExistsAtPath:go]) usleep(200000);
        @autoreleasepool {
            NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:go] options:0 error:NULL];
            NSMutableDictionary *answers = [NSMutableDictionary dictionary];
            for (NSString *side in @[@"legacy", @"current"]) {
                Class cls = NSClassFromString([side isEqualToString:@"legacy"] ? @"IsiXLegacyDicomFile" : @"DicomFile");
                NSMutableDictionary *files = [NSMutableDictionary dictionary];
                for (NSString *path in manifest[@"files"]) {
                    NSLog(@"equivalence: %@ reads %@", side, path);
                    @autoreleasepool { files[path] = ReadFile(cls, path); }
                }
                NSLog(@"equivalence: %@ text", side);
                answers[side] = @{@"files": files, @"text": Text(cls, manifest)};
            }
            NSData *data = [NSJSONSerialization dataWithJSONObject:answers options:NSJSONWritingSortedKeys error:NULL];
            [data writeToFile:[folder stringByAppendingPathComponent:@".answers.json"] atomically:YES];
            [NSFileManager.defaultManager moveItemAtPath:[folder stringByAppendingPathComponent:@".answers.json"]
                                                  toPath:[folder stringByAppendingPathComponent:@"answers.json"] error:NULL];
        }
    });
}
'''


def compile_reference(work):
    """The library: the reference's DicomFile.mm and its DCMTK category, under
    the application's flags and current headers, with the class renamed, and
    the driver."""
    sources = work / 'reference'
    sources.mkdir()
    # The FluoView reading the reference called (FVTiff.m, now in the VTK
    # adapter under other names) comes from the same revision, and is built
    # into the library with it.
    for path in (SOURCE, CATEGORY, DICTIONARY, FLUOVIEW, FLUOVIEW_HEADER, *REFERENCE_HEADERS):
        (sources / Path(path).name).write_bytes(history_reference.show(reference, path))
    # The calendar helpers the reference called on the Horos class
    # (+dateWithString:calendarFormat:, +:descriptionWithCalendarFormat:, and
    # HorosDateString behind them) left the application with the DCM
    # framework's date type: the reference's Horos.m is built into the library
    # under another class name, and the reference calls that class.
    legacy_names = {'[Horos ': '[IsiXLegacyHoros ', '[Horos:': '[IsiXLegacyHoros :', 'HorosDateString(': 'IsiXLegacyHorosDateString(',
                    '#include "Horos.h"': '#import "IsiXLegacyHoros.h"',
                    '#import "Horos.h"': '#import "IsiXLegacyHoros.h"'}
    for name in (Path(SOURCE).name, Path(CATEGORY).name):
        text = (sources / name).read_bytes().decode('latin1')
        for old, new in legacy_names.items():
            text = text.replace(old, new)
        (sources / name).write_bytes(text.encode('latin1'))
    horos = history_reference.show(reference, HOROS).decode('latin1')
    helpers = horos[horos.index('@implementation Horos (CalendarDates)'):]
    helpers = helpers[:helpers.index('+ (NSArray<NSString *> *)WeasisCustomizationPaths')] + '@end\n' + \
        helpers[helpers.index('NSString *HorosDateString('):]
    for old, new in {**legacy_names, 'Horos (CalendarDates)': 'IsiXLegacyHoros (CalendarDates)',
                     'NSString *HorosDateString(': 'NSString *IsiXLegacyHorosDateString('}.items():
        helpers = helpers.replace(old, new)
    (sources / 'IsiXLegacyHoros.h').write_text(
        '#import <Foundation/Foundation.h>\n@interface IsiXLegacyHoros : NSObject\n'
        '+ (NSDate *)dateWithString:(NSString *)str calendarFormat:(NSString *)format;\n'
        '+ (NSString *):(NSDate *)date descriptionWithCalendarFormat:(NSString *)format;\n@end\n'
        'extern "C" NSString *IsiXLegacyHorosDateString(id date, NSString *format);\n')
    (sources / LEGACY_HOROS).write_text('#import <DCM/DCMCalendarDate.h>\n#import "IsiXLegacyHoros.h"\n'
                                        'NS_ASSUME_NONNULL_BEGIN\n@implementation IsiXLegacyHoros\n@end\n' + helpers +
                                        '\nNS_ASSUME_NONNULL_END\n', encoding='latin1')
    # The class DICOMDataDictionary.h declares is declared by the application's
    # IsiXDCMTKDictionary.h too, which the generated Horos-Swift.h reaches: the
    # reference keeps the C functions of its header and takes the class's
    # declaration (renamed as its implementation is) from there.
    dictionary_header = sources / Path(REFERENCE_HEADERS[2]).name
    text = dictionary_header.read_text(encoding='utf-8', errors='replace')
    start = text.find('@interface HorosDICOMDictionaries')
    if start >= 0:
        dictionary_header.write_text(text[:start] + text[text.find('@end', start) + len('@end'):])
    # The reference's own headers first; the ones the application still has
    # under the same name are also put in their place for the application's
    # headers that import them (the generated Horos-Swift.h imports the
    # bridging header, which imports DicomFile.h from Horos/Sources), through a
    # file system overlay.
    overlay_file = work / 'reference-headers.json'
    overlay_file.write_text(json.dumps({'version': 0, 'case-sensitive': 'false', 'roots': [{
        'type': 'directory', 'name': str(ROOT / 'Horos/Sources'),
        'contents': [{'type': 'file', 'name': Path(path).name, 'external-contents': str(sources / Path(path).name)}
                     for path in REFERENCE_HEADERS if (ROOT / path).exists()]}]}))
    # Then the Horos target's search paths (Horos.xcodeproj): its header maps, the
    # generated Swift interfaces, the libraries' install folders; its prefix
    # header and definitions.
    target = BUILD / 'Horos.build'
    maps = sorted(target.glob('*.hmap'))
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
    # And every folder of the checkout with a header, as the target's header maps reach them.
    listed = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '*.h'], capture_output=True, text=True).stdout.split('\n')
    folders = sorted({str(Path(p).parent) for p in listed if p and not p.startswith(
        ('DCMTK/', 'ITK/', 'VTK/', 'Binaries/', 'OpenJPEG/', 'tests/', 'tools/', 'Modules/', 'DCM Framework'))})
    includes += ['-I' + str(ROOT / folder) for folder in folders]
    includes += ['-isystem' + str(p) for p in [BUILD / 'VTK.build/Install/include', BUILD / 'ITK.build/Install/include',
                                               BUILD / 'OpenJPEG.build/Install/include']]
    common = ['xcrun', 'clang++', '-std=c++17', '-x', 'objective-c++', '-fno-objc-arc', '-fobjc-exceptions', '-fPIC',
              '-fvisibility=default', '-w', '-mmacosx-version-min=15.0', '-I' + str(overlay), '-F' + str(ROOT / 'Binaries'), '-F' + str(ROOT / 'build/Build/Products/Debug'),
              '-include', str(ROOT / 'Horos/prefix.pch'), '-DDEBUG=1',
              '-ivfsoverlay', str(overlay_file), *('-D%s=%s' % pair for pair in RENAMED.items()), *includes]
    objects = []
    for name, arc in ((Path(SOURCE).name, []), (Path(CATEGORY).name, []), (Path(DICTIONARY).name, ['-fobjc-arc']), (Path(FLUOVIEW).name, []),
                      (LEGACY_HOROS, [])):
        obj = work / (name + '.o')
        built = subprocess.run([*common, *arc, '-c', str(sources / name), '-o', str(obj)], capture_output=True, text=True)
        if built.returncode:
            raise SystemExit('FAIL: the reference %s does not compile:\n%s' % (name, built.stderr[-5000:]))
        objects.append(str(obj))
    (work / 'driver.m').write_text(DRIVER)
    library = work / 'reference.dylib'
    built = subprocess.run(['xcrun', 'clang++', '-dynamiclib', '-fobjc-arc', '-x', 'objective-c', str(work / 'driver.m'),
                            '-x', 'none', *objects, '-undefined', 'dynamic_lookup', '-framework', 'Cocoa',
                            '-framework', 'AVFoundation', '-framework', 'CoreMedia', '-framework', 'CoreVideo',
                            '-o', str(library)], capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the reference library does not link:\n' + built.stderr[-4000:])
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(library)], check=True, capture_output=True)
    return library


def describe_difference(path, what, legacy, current):
    return '%s %s:\n  reference %s\n  current   %s' % (path, what, json.dumps(legacy, ensure_ascii=False)[:1500],
                                                     json.dumps(current, ensure_ascii=False)[:1500])


def main():
    work = Path(tempfile.mkdtemp(prefix='isix-dicomfile-equivalence-'))
    try:
        files = generate(work / 'files')
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
        test_root = work / 'root'
        process = native_app.launch(test_root, work / 'app.log', ['-onlyDICOM', 'NO', '-ApplePersistenceIgnoreState', 'YES'],
                                    app=bundle, environment={'DYLD_INSERT_LIBRARIES': str(library),
                                                             'ISIX_DICOMFILE_EQUIVALENCE': str(exchange)})
        try:
            native_app.wait_for(lambda: (native_app.database_folder(test_root) / 'INCOMING.noindex').is_dir()
                                or process.poll() is not None, 120, description='the database to open')
            if process.poll() is not None:
                raise SystemExit('FAIL: the application ended before reading (%s)' % process.returncode)
            any_file = next(str(p) for p in files if p.suffix == '.tif')
            manifest = {'files': [str(p) for p in files] + ['', str(work / 'missing.dcm'), str(work / 'files')],
                        'text': text_cases(), 'clean': cleaning_cases(), 'patients': PATIENTS, 'anyFile': any_file}
            (exchange / '.go.json').write_text(json.dumps(manifest))
            (exchange / '.go.json').rename(exchange / 'go.json')
            native_app.wait_for(lambda: (exchange / 'answers.json').exists() or process.poll() is not None, 900,
                                interval=1, description='the answers')
            if not (exchange / 'answers.json').exists():
                raise SystemExit('FAIL: the application ended while reading (%s); see %s' % (process.returncode, work / 'app.log'))
        finally:
            native_app.stop(process)
        answers = json.loads((exchange / 'answers.json').read_text())
        legacy, current = answers['legacy'], answers['current']
        failures = []
        read = {'init': 0, 'dicomOnly': 0}
        for path in sorted(legacy['files']):
            for what in ('init', 'dicomOnly', 'classify', 'niftiXML'):
                old, new = legacy['files'][path][what], current['files'][path][what]
                if what in read and old is not None:
                    read[what] += 1
                if old != new:
                    failures.append(describe_difference(path or '(empty path)', what, old, new))
        for what in ('decoded', 'cleaned', 'cleanedC', 'patients', 'localizers'):
            for index, (old, new) in enumerate(zip(legacy['text'][what], current['text'][what])):
                if old != new:
                    failures.append(describe_difference('%s #%d' % (what, index), '', old, new))
            if len(legacy['text'][what]) != len(current['text'][what]):
                failures.append('%s: %d answers against %d' % (what, len(legacy['text'][what]), len(current['text'][what])))
        if arguments.keep:
            arguments.keep.mkdir(parents=True, exist_ok=True)
            shutil.copy(exchange / 'answers.json', arguments.keep / 'answers.json')
            shutil.copy(work / 'app.log', arguments.keep / 'app.log')
        for failure in failures:
            print('FAIL: ' + failure)
        if failures:
            print('%d difference(s); reference %s' % (len(failures), reference))
            raise SystemExit(1)
        print('PASS: %d files (%d read by -init:, %d by -init:DICOMOnly:), %d byte strings, %d cleaned strings and %d '
              'patients answer as DicomFile.mm of %s did' % (len(legacy['files']), read['init'], read['dicomOnly'],
                                                            len(text_cases()), len(cleaning_cases()), len(PATIENTS),
                                                            reference[:9]))
    finally:
        if arguments.keep:
            arguments.keep.mkdir(parents=True, exist_ok=True)
            for name in ('app.log', 'exchange/answers.json'):
                if (work / name).exists():
                    shutil.copy(work / name, arguments.keep / Path(name).name)
        shutil.rmtree(work, ignore_errors=True)


main()
