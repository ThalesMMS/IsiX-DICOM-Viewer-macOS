#!/usr/bin/env python3
"""Unify Patient Identity and Merge Studies keep the former identity in the files.

With "Database & DICOM", the files of a study that takes another identity keep
the names and IDs it had in OtherPatientNames and OtherPatientIDs. Two faults:

* the existing values were read crossed (OtherPatientIDs into the names,
  OtherPatientNames into the IDs) and from the file of the study whose identity
  is kept, so a file's own former identities went to the other field or were
  lost;
* a name the file's character set cannot encode was refused by the writer in
  silence: a file without Specific Character Set, read as Latin-1, lost a
  former name such as «Anonˆ» (U+02C6).

The writer now says, per file, which character set the text needs: none when
the file's own encodes it, ISO_IR 192 when the file declares none and holds
only ASCII text, and a refusal otherwise. Unify declares ISO_IR 192 before
writing, and asks the user before writing files that would refuse a value.

The production writer (XMLControllerDCMTKCategory.mm, its static helpers, the
NSArray writer and the new character-set method) is compiled against the
build's DCMTK and run on synthetic files; the values read back are the bytes in
the files. The BrowserController wiring is read from the source.
"""
from pathlib import Path
import os
import struct
import subprocess
import sys
import tempfile

import harness_defaults

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from dcmtk_build import BUILD  # noqa: E402
from sources import source_text  # noqa: E402

dcmtk = BUILD / 'DCMTK.build/Install'
archives = [dcmtk / ('lib/lib%s.a' % name) for name in ('dcmdata', 'oflog', 'ofstd', 'oficonv')]
missing = [str(path) for path in [dcmtk / 'include/dcmtk/config/osconfig.h', *archives] if not path.is_file()]
if missing:
    print('skipped: needs a current build from script/build_and_run.sh --verify: ' + missing[0])
    sys.exit(2)

source = (root / 'Horos/Sources/XMLControllerDCMTKCategory.mm').read_bytes().decode('latin1')


def between(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


extraction = between(source, 'typedef struct', '@implementation XMLController')
writer = between(source, '+ (BOOL) modifyDicom:(NSArray*) tagAndValues dicomFiles:(NSArray*) dicomFiles reasons:', '\n\n+ (int) modifyDicom:')
declare = between(source, '+ (NSString*) characterSetToDeclareForValues:', '\n\n+ (BOOL) modifyDicom:')

charset_source = (root / 'DCM Framework/DCMCharacterSet.m').read_bytes().decode('latin1')


def method_source(signature):
    begin = charset_source.index(signature)
    opening = charset_source.index('{', begin)
    depth = 0
    for end in range(opening, len(charset_source)):
        depth += (charset_source[end] == '{') - (charset_source[end] == '}')
        if depth == 0:
            return charset_source[begin:end + 1]
    raise AssertionError('unterminated method')


character_set = """
@interface DCMCharacterSet : NSObject
+ (NSString *)characterSetWhenAbsent;
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)characterSet;
@end
@implementation DCMCharacterSet
""" + method_source('+ (NSString*) characterSetWhenAbsent') + '\n' + method_source('+ (NSStringEncoding)encodingForDICOMCharacterSet:') + """
@end
@interface NSString (HarnessEncoding)
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)charset;
@end
@implementation NSString (HarnessEncoding)
+ (NSStringEncoding)encodingForDICOMCharacterSet:(NSString *)charset { return [DCMCharacterSet encodingForDICOMCharacterSet:charset]; }
@end
"""


def element(group, number, vr, payload):
    if len(payload) % 2:
        payload += b'\x00' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'SQ', b'UT', b'UN'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(payload)) + payload
    return struct.pack('<HH2sH', group, number, vr, len(payload)) + payload


def fixture(number, charset=None, description=b'Unify fixture', other_names=b'', other_ids=b''):
    uid = b'1.2.826.0.1.3680043.8.498.1358%d' % number
    meta = (element(0x0002, 0x0002, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(0x0002, 0x0003, b'UI', uid)
            + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.8.498.1'))
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(meta))) + meta
    data = ((element(0x0008, 0x0005, b'CS', charset) if charset else b'')
            + element(0x0008, 0x0016, b'UI', b'1.2.840.10008.5.1.4.1.1.7') + element(0x0008, 0x0018, b'UI', uid)
            + element(0x0008, 0x0060, b'CS', b'OT') + element(0x0008, 0x1030, b'LO', description)
            + element(0x0010, 0x0010, b'PN', b'FORMER^NAME') + element(0x0010, 0x0020, b'LO', b'ID-1358')
            + (element(0x0010, 0x1000, b'LO', other_ids) if other_ids else b'')
            + (element(0x0010, 0x1001, b'PN', other_names) if other_names else b'')
            + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.8.498.2') + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.8.498.3'))
    return b'\x00' * 128 + b'DICM' + meta + data


code = r'''
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <dcmtk/dcmdata/dctk.h>
#include "HorosDCMTKSeekableInput.h"
#include "HorosDCMTKTagEditing.h"
#include "HorosDICOMEditingStorage.h"

@interface DCMAttributeTag : NSObject
@property int group, element;
+ (instancetype) tagWithTagString:(NSString *)s;
@end
@implementation DCMAttributeTag
@synthesize group, element;
+ (instancetype) tagWithTagString:(NSString *)s {
    DCMAttributeTag *tag = [DCMAttributeTag new]; unsigned g = 0, e = 0;
    sscanf(s.UTF8String, "(%x,%x)", &g, &e); tag.group = g; tag.element = e; return tag;
}
@end
@interface TagStep : NSObject
@end
@implementation TagStep
@end
@interface TagPath : NSObject
@end
@implementation TagPath
@end

CHARACTER_SET

EXTRACTION

@interface DicomFile : NSObject
+ (NSArray *)getEncodingArrayForFile:(NSString *)path;
@end
@implementation DicomFile
+ (NSArray *)getEncodingArrayForFile:(NSString *)path { return @[@"ISO_IR 100"]; }
@end
#import "HorosAtomicFileWriter.h"

@interface XMLController : NSObject
@end
@implementation XMLController
WRITER

DECLARE
@end

static int failures;
#define check(...) do { if (!(__VA_ARGS__)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #__VA_ARGS__); failures++; } } while (0)

// The bytes of a top-level element, as the file holds them.
static std::string bytesOf(NSString *path, unsigned short g, unsigned short e) {
    DcmFileFormat file;
    if (file.loadFile(path.fileSystemRepresentation).bad()) return "<unreadable>";
    const char *value = nullptr;
    if (file.getDataset()->findAndGetString(DcmTagKey(g, e), value).bad() || !value) return "<absent>";
    return value;
}
static std::string utf8(NSString *s) { return std::string(s.UTF8String); }
static std::string latin1(NSString *s) { NSData *d = [s dataUsingEncoding:NSISOLatin1StringEncoding]; return std::string((const char *)d.bytes, d.length); }
static NSArray *edit(NSString *tag, NSString *value) { return @[[DCMAttributeTag tagWithTagString:tag], value]; }

int main(int argc, char **argv) { @autoreleasepool {
    NSString *folder = [NSString stringWithUTF8String:argv[1]];
    NSString *former = @"Anonˆ";                       // not in Latin-1
    NSString *names = [@"OLDER^NAME - " stringByAppendingString:former];
    NSArray *values = @[@"KEPT^NAME", names, @"OLDER-ID - ID-1358"];
    BOOL refused = YES;

    // A: no Specific Character Set, ASCII text: it declares ISO_IR 192 and
    // keeps the name the Latin-1 default would have refused.
    NSString *a = [folder stringByAppendingPathComponent:@"ascii.dcm"];
    check([[XMLController characterSetToDeclareForValues:values inDicomFile:a refused:&refused] isEqualToString:@"ISO_IR 192"] && !refused);
    check([XMLController characterSetToDeclareForValues:@[@"KEPT^NAME", @"OLDER-ID"] inDicomFile:a refused:&refused] == nil && !refused);
    NSArray *edits = @[edit(@"(0008,0005)", @"ISO_IR 192"), edit(@"(0010,0020)", @"KEPT-ID"), edit(@"(0010,0010)", @"KEPT^NAME"),
                       edit(@"(0010,1000)", @"OLDER-ID - ID-1358"), edit(@"(0010,1001)", names)];
    NSArray *reasons = nil;
    check([XMLController modifyDicom:edits dicomFiles:@[a] reasons:&reasons]);
    check(bytesOf(a, 0x0008, 0x0005) == "ISO_IR 192");
    check(bytesOf(a, 0x0010, 0x1001) == utf8(names));
    check(bytesOf(a, 0x0010, 0x1000) == "OLDER-ID - ID-1358");
    check(bytesOf(a, 0x0010, 0x0010) == "KEPT^NAME");
    check(bytesOf(a, 0x0008, 0x1030) == "Unify fixture");

    // Without the declaration, the same write loses the former name: the fault.
    NSString *silent = [folder stringByAppendingPathComponent:@"ascii-again.dcm"];
    check(![XMLController modifyDicom:[edits subarrayWithRange:NSMakeRange(1, edits.count - 1)] dicomFiles:@[silent] reasons:&reasons]);
    check(bytesOf(silent, 0x0010, 0x1001) == "OLDER^NAME");

    // B: ISO_IR 100 declared: a Latin-1 name fits as it is, U+02C6 is refused
    // (its other text would have to be re-encoded).
    NSString *b = [folder stringByAppendingPathComponent:@"latin1.dcm"];
    check([XMLController characterSetToDeclareForValues:@[@"Müller^Jan"] inDicomFile:b refused:&refused] == nil && !refused);
    check([XMLController characterSetToDeclareForValues:values inDicomFile:b refused:&refused] == nil && refused);

    // C: no declaration, but Latin-1 text already in the file: declaring
    // ISO_IR 192 would change how that text reads, so it is refused.
    NSString *c = [folder stringByAppendingPathComponent:@"latin1-undeclared.dcm"];
    check([XMLController characterSetToDeclareForValues:values inDicomFile:c refused:&refused] == nil && refused);
    check([XMLController characterSetToDeclareForValues:@[@"Müller^Jan"] inDicomFile:c refused:&refused] == nil && !refused);
    check(bytesOf(c, 0x0008, 0x1030) == latin1(@"Étude"));

    // D: an unreadable file is refused, not taken for one that fits.
    check([XMLController characterSetToDeclareForValues:values inDicomFile:[folder stringByAppendingPathComponent:@"none.dcm"] refused:&refused] == nil && refused);

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("PASS: the files take the former identity, declaring ISO_IR 192 where needed, and refuse only what they cannot hold\n");
    return 0;
} }
'''
code = (code.replace('CHARACTER_SET', character_set).replace('EXTRACTION', extraction)
        .replace('WRITER', writer).replace('DECLARE', declare))

failures = []
with tempfile.TemporaryDirectory(prefix='horos-unify-identity-') as directory:
    path = Path(directory)
    (path / 'ascii.dcm').write_bytes(fixture(1, other_names=b'OLDER^NAME', other_ids=b'OLDER-ID'))
    (path / 'ascii-again.dcm').write_bytes(fixture(2, other_names=b'OLDER^NAME', other_ids=b'OLDER-ID'))
    (path / 'latin1.dcm').write_bytes(fixture(3, charset=b'ISO_IR 100'))
    (path / 'latin1-undeclared.dcm').write_bytes(fixture(4, description='Étude'.encode('latin-1')))
    (path / 'main.mm').write_text(code + harness_defaults.OBJC)
    build = subprocess.run(['xcrun', 'clang++', '-fno-objc-arc', '-std=c++17', '-w', '-O0',
                            '-I' + str(dcmtk / 'include'), '-I' + str(root / 'Horos/Sources'),
                            str(path / 'main.mm'), *map(str, archives), '-lz', '-liconv',
                            '-framework', 'Foundation', '-framework', 'CoreFoundation', '-o', str(path / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print('FAIL: the writer does not compile\n' + build.stderr[-3000:])
        sys.exit(1)
    env = dict(os.environ)
    env.setdefault('DCMDICTPATH', str(root / 'DCMTK/dcmdata/data/dicom.dic'))
    run = subprocess.run([str(path / 'test'), str(path)], capture_output=True, text=True, env=env, timeout=120)
    print(run.stdout.strip())
    if run.returncode:
        failures.append('the writer: ' + run.stderr[-1500:])

browser = source_text('BrowserController')
former = between(browser, 'static void HorosFormerIdentity(', '\n}\n')
if ('[own attributeValueWithName:@"OtherPatientNames"]' not in former.split('names =')[1].split(';')[0]
        or '[own attributeValueWithName:@"OtherPatientIDs"]' not in former.split('ids =')[1].split(';')[0]):
    failures.append('the former names and IDs are not read each from its own field')
if '[[study paths] allObjects]' not in former:
    failures.append("the former identity is not read from the study's own files")
if 'NSString *existingOtherPatientNames = [dcmObject attributeValueWithName:@"OtherPatientIDs"]' in browser:
    failures.append('a crossed read of OtherPatientIDs into the names is left')
write = between(browser, 'static BOOL HorosWriteIdentityEdits(', '\n}\n')
if write.index('HorosRunCriticalAlertPanel') > write.index('modifyDicom:'):
    failures.append('the user is asked after the files are written')
if '@"ISO_IR 192"' not in write or 'characterSetToDeclareForValues:' not in write:
    failures.append('the writes do not declare ISO_IR 192 where a file needs it')
for title in ('Unify Patient Identity', 'Merge Studies'):
    if 'HorosWriteIdentityEdits( files, tagAndValues, NSLocalizedString(@"%s", nil))' % title not in browser:
        failures.append(f'{title} does not write through HorosWriteIdentityEdits')
if browser.count('HorosFormerIdentity(study, &existingOtherPatientNames, &existingOtherPatientIDs);') != 2:
    failures.append('Unify and Merge do not both take the former identity from the study')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: Unify and Merge keep the former names and IDs, each in its field, and ask before a file would lose one')
