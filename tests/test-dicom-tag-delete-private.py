#!/usr/bin/env python3
"""Removing a tag removes it, emptying keeps it, and a private value persists.

The production parser, element helpers and complete NSArray writer method are
extracted from XMLControllerDCMTKCategory.mm. A synthetic file checks persisted
remove/empty/replace, refused private and sequence edits, complete nested paths,
and preservation of the original bytes after partial write, close and rename
faults. Built DCMTK inputs are read only and may be supplied by --install.
Historical GDCM sources remain available only as optional benchmark baselines.
--benchmark and --revision reuse this driver for matched successful-write runs.
--charset-fixtures adds mixed batches and item inheritance/override cases, using
the production character-set table and an independent pydicom reopen.
"""
from pathlib import Path
import harness_defaults
import argparse
import os
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--install', type=Path, help='existing writer backend Install directory (read only)')
parser.add_argument('--preservation', action='store_true', help='roundtrip/edit valid native, encapsulated, deflated and dataset-only fixtures with an independent reader')
parser.add_argument('--charset-fixtures', type=Path, help='directory from generate-sequence-edit-fixture.py --charset-cases')
parser.add_argument('--python', default=os.environ.get('HOROS_TEST_PYTHON', sys.executable), help='independent pydicom interpreter')
parser.add_argument('--revision', help='source revision for a matched baseline benchmark')
parser.add_argument('--benchmark', type=int, default=0, metavar='EDITS', help='run only repeated successful edits for measurement')
parser.add_argument('--keep-binary', type=Path, help='keep this existing driver and synthetic input locally for /usr/bin/time')
args = parser.parse_args()
if args.charset_fixtures or args.preservation:
    if args.revision or args.benchmark:
        parser.error('--charset-fixtures is a correctness run, not a baseline benchmark')
    if subprocess.run([args.python, '-c', 'import pydicom; import PIL' if args.preservation else 'import pydicom'], capture_output=True).returncode:
        print('skipped: charset reopens need pydicom: --python PYTHON', file=sys.stderr)
        raise SystemExit(2)
if args.revision and not args.benchmark:
    parser.error('--revision requires --benchmark')
source_path = 'Horos/Sources/XMLControllerDCMTKCategory.mm'
source = (subprocess.check_output(['git', '-C', str(root), 'show', args.revision + ':' + source_path])
          if args.revision else (root / source_path).read_bytes()).decode('latin1')
sys.path.insert(0, str(root / 'tests'))
from dcmtk_build import BUILD

dcmtk_backend = 'gdcm::' not in source
gdcm = (args.install if not dcmtk_backend else None) or BUILD / 'GDCM.build/Install'
dcmtk = (args.install if dcmtk_backend else gdcm.parent.parent / 'DCMTK.build/Install') or BUILD / 'DCMTK.build/Install'
openjpeg = gdcm.parent.parent / 'OpenJPEG.build/Install/lib/libopenjp2.a'
dcmtk_archives = [dcmtk / ('lib/lib%s.a' % name) for name in ('dcmdata', 'oflog', 'ofstd', 'oficonv')]
required = [dcmtk / 'include/dcmtk/config/osconfig.h', *dcmtk_archives]
if not dcmtk_backend:
    required += [gdcm / 'wlib/libGDCM.a', openjpeg, gdcm / 'include/GDCM/gdcmReader.h']
missing = [str(path) for path in required if not path.is_file()]
if missing:
    print('skipped: needs current writer build inputs: ' + ', '.join(missing))
    sys.exit(2)


def between(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


extraction = between('typedef struct', '@implementation XMLController')
method = between('+ (BOOL) modifyDicom:(NSArray*) tagAndValues dicomFiles:(NSArray*) dicomFiles reasons:', '\n\n+ (int) modifyDicom:')

# ---------------------------------------------------------------- the fixture
#
# Explicit VR little endian, written here so the private block is exactly what
# the test needs: a creator at (0009,0010) owning (0009,1001) as a text element
# and (0009,1002) as a binary one, plus an optional public tag to remove.

def element(group, number, vr, payload):
    if len(payload) % 2:
        payload += b'\x00' if vr == b'UI' else b' '
    if vr in (b'OB', b'OW', b'OF', b'SQ', b'UT', b'UN'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(payload)) + payload
    return struct.pack('<HH2sH', group, number, vr, len(payload)) + payload


CLASS_UID = b'1.2.840.10008.5.1.4.1.1.7'          # Secondary Capture
INSTANCE_UID = b'1.2.826.0.1.3680043.8.498.10001'
EXPLICIT_LITTLE = b'1.2.840.10008.1.2.1'

meta = (element(0x0002, 0x0002, b'UI', CLASS_UID)
        + element(0x0002, 0x0003, b'UI', INSTANCE_UID)
        + element(0x0002, 0x0010, b'UI', EXPLICIT_LITTLE)
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.8.498.1'))
meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(meta))) + meta

dataset = (element(0x0008, 0x0016, b'UI', CLASS_UID)
           + element(0x0008, 0x0018, b'UI', INSTANCE_UID)
           + element(0x0008, 0x0060, b'CS', b'OT')
           + element(0x0008, 0x1030, b'LO', b'Tag editor fixture')      # optional
           + element(0x0010, 0x0010, b'PN', b'FIXTURE^TAG')
           + element(0x0010, 0x0020, b'LO', b'TAG-0001')
           + element(0x0009, 0x0010, b'LO', b'HOROS TEST CREATOR')      # private creator
           + element(0x0009, 0x1001, b'LO', b'original private')        # text
           + element(0x0009, 0x1003, b'DS', b'1.25')
           + element(0x0009, 0x1004, b'UI', b'1.2.826.0.1.3680043.8.498.1084004')
           + element(0x0009, 0x1005, b'UN', b'\x00\\\xffQ')
           + element(0x0009, 0x1002, b'OB', b'\x01\x02\x03\x04')        # binary
           + element(0x0042, 0x0011, b'OB', b'\x05\x06\x07\x08')        # public binary
           + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.8.498.2')
           + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.8.498.3')
           + element(0x0020, 0x0013, b'IS', b'1')
           + element(0x0008, 0x1140, b'SQ', struct.pack('<HHI', 0xfffe, 0xe000, len(element(0x0008, 0x1155, b'UI', INSTANCE_UID))) + element(0x0008, 0x1155, b'UI', INSTANCE_UID)))

fixture = b'\x00' * 128 + b'DICM' + meta + dataset

# ---------------------------------------------------------------- the harness
code = r'''
#import <Foundation/Foundation.h>
#include <fstream>
#include <iostream>
#include <algorithm>
#include <sstream>
#include <string>
#include <vector>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/oflog/oflog.h>
#include "HorosDCMTKSeekableInput.h"
BACKEND_INCLUDES
#if !DCMTK_BACKEND
#include <GDCM/gdcmReader.h>
#include <GDCM/gdcmWriter.h>
#include <GDCM/gdcmAnonymizer.h>
#include <GDCM/gdcmGlobal.h>
#include <GDCM/gdcmDicts.h>
#include <GDCM/gdcmDefs.h>
#include <GDCM/gdcmSystem.h>
#include <GDCM/gdcmSequenceOfItems.h>
#include <GDCM/gdcmItem.h>
#endif

static int failures;
#define check(...) do { if (!(__VA_ARGS__)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #__VA_ARGS__); failures++; } } while (0)

// Stands in for the tag object the editor builds from the row's path.
@interface DCMAttributeTag : NSObject
@property int group, element;
+ (instancetype) group:(int)g element:(int)e;
@end
@implementation DCMAttributeTag
@synthesize group, element;
+ (instancetype) group:(int)g element:(int)e {
    DCMAttributeTag *tag = [DCMAttributeTag new];
    tag.group = g; tag.element = e;
    return tag;
}
@end

@interface TagStep : NSObject
@property int group, element;
@property long long item;
@end
@implementation TagStep
@end
@interface TagPath : NSObject
@property int group, element;
@property(nonatomic, retain) NSArray *steps;
@end
@implementation TagPath
@end
static TagPath *nested(long long item, int group, int element) {
    TagStep *step = [TagStep new]; step.group = 0x0008; step.element = 0x1140; step.item = item;
    TagPath *path = [TagPath new]; path.group = group; path.element = element; path.steps = @[step]; return path;
}

CHARACTER_SET

EXTRACTION

@interface DicomFile : NSObject
+ (NSArray *)getEncodingArrayForFile:(NSString *)path;
@end
@implementation DicomFile
+ (NSArray *)getEncodingArrayForFile:(NSString *)path { return @[@"ISO_IR 100"]; }
@end

// Faults are injected at the stream and rename boundaries of the real method.
static bool failWrite, failClose, failRename;
static int TestRename(const char *from, const char *to) {
    if (failRename) { errno = EIO; return -1; }
    return rename(from, to);
}
#define rename TestRename
#import "HorosAtomicFileWriter.h"
#undef rename

class LimitedBuffer : public std::streambuf {
    std::streambuf *target;
    std::streamsize remaining = 180;
public:
    explicit LimitedBuffer(std::streambuf *buffer) : target(buffer) {}
    std::streamsize xsputn(const char *bytes, std::streamsize count) override {
        std::streamsize allowed = std::min(count, remaining);
        std::streamsize written = target->sputn(bytes, allowed);
        remaining -= written;
        return written;
    }
    int_type overflow(int_type byte) override {
        if (traits_type::eq_int_type(byte, traits_type::eof())) return traits_type::not_eof(byte);
        if (!remaining) return traits_type::eof();
        --remaining;
        return target->sputc(traits_type::to_char_type(byte));
    }
    int sync() override { return target->pubsync(); }
};
class FaultStream : public std::ofstream {
    LimitedBuffer buffer;
public:
    FaultStream(const char *path, std::ios::openmode mode) : std::ofstream(path, mode), buffer(std::ofstream::rdbuf()) {
        if (failWrite) static_cast<std::ostream &>(*this).rdbuf(&buffer);
    }
    void close() {
        static_cast<std::ostream &>(*this).rdbuf(std::ofstream::rdbuf());
        std::ofstream::close();
        if (failWrite || failClose) setstate(std::ios::failbit);
    }
};

#if DCMTK_BACKEND
static OFCondition TestSaveFile(DcmFileFormat &file, const char *path, E_TransferSyntax syntax,
    E_EncodingType encoding, E_GrpLenEncoding groupLength, E_PaddingEncoding padding,
    Uint32 padLength, Uint32 subPadLength, E_FileWriteMode mode)
{
    if (failWrite) {
        std::ofstream stream(path, std::ios::binary);
        stream << "partial staged header";
        stream.close();
        return EC_InvalidStream;
    }
    OFCondition result = file.saveFile(path, syntax, encoding, groupLength, padding, padLength, subPadLength, mode);
    return failClose ? OFCondition(EC_InvalidStream) : result;
}
#endif

@interface XMLController : NSObject
+ (BOOL)modifyDicom:(NSArray *)entries dicomFiles:(NSArray *)files reasons:(NSArray **)reasons;
@end
@implementation XMLController
METHOD
@end

static BOOL applyEdits(NSString *path, NSArray *entries, NSArray **reasons, NSUInteger *rejectedOut) {
    if (rejectedOut) {
        *rejectedOut = 0;
        PARSER_COUNT;
    }
    return [XMLController modifyDicom:entries dicomFiles:@[path] reasons:reasons];
}

// Read persisted data through the safe input owner, without eager deflated loads.
static bool present(NSString *path, unsigned short group, unsigned short element)
{
    HorosDCMTKSeekableInput input;
    if (input.load(path.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).bad()) return false;
    return input.fileFormat().getDataset()->tagExists(DcmTagKey(group, element), OFFalse);
}

static std::string valueOf(NSString *path, unsigned short group, unsigned short number)
{
    HorosDCMTKSeekableInput input;
    if (input.load(path.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).bad()) return "<unreadable>";
    DcmElement *element = nullptr;
    if (input.fileFormat().getDataset()->findAndGetElement(DcmTagKey(group, number), element, OFFalse).bad()) return "<absent>";
    char *bytes = nullptr;
    Uint32 length = 0;
    if (element->getString(bytes, length).bad() || !bytes) return "";
    std::string text(bytes, length);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\0')) text.pop_back();
    return text;
}

static NSString *pristine;   // the untouched fixture
static NSString *working;    // a disposable copy, remade before each case

static void reset(void)
{
    [NSFileManager.defaultManager removeItemAtPath:working error:nil];
    [NSFileManager.defaultManager copyItemAtPath:pristine toPath:working error:nil];
}

#define TAG(g, e) [DCMAttributeTag group:0x##g element:0x##e]

static TagPath *nameInItem(int item, bool deep) {
    TagPath *path = nested(item, 0x0010, 0x0010);
    ((TagStep *)path.steps.firstObject).group = 0x0054;
    ((TagStep *)path.steps.firstObject).element = 0x0016;
    if (deep) {
        TagStep *child = [TagStep new]; child.group = 0x0040; child.element = 0x0275; child.item = 0;
        path.steps = @[path.steps.firstObject, child];
    }
    return path;
}
static NSString *copyCase(NSString *root, NSString *name, NSString *output) {
    NSString *input = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"charset-%@-edição.dcm", name]];
    NSString *result = [root stringByAppendingPathComponent:output];
    [NSFileManager.defaultManager removeItemAtPath:result error:nil];
    check([NSFileManager.defaultManager copyItemAtPath:input toPath:result error:nil]);
    return result;
}
static void charsetCases(NSString *root) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"DefaultCharacterSetWhenAbsent"];
    NSString *name = @"José^Müller=Teste\\Deux^Élodie";
    std::string latin = "Jos\xe9^M\xfcller=Teste\\Deux^\xc9lodie";
    NSArray *reasons = nil;
    for (int order = 0; order < 2; ++order) {
        NSString *l = copyCase(root, @"latin1", [NSString stringWithFormat:@"order-%d-latin.dcm", order]);
        NSString *u = copyCase(root, @"utf8", [NSString stringWithFormat:@"order-%d-utf8.dcm", order]);
        NSArray *files = order ? @[u,l] : @[l,u];
        check([XMLController modifyDicom:@[@[TAG(0010,0010), name]] dicomFiles:files reasons:&reasons]);
        check(reasons.count == 0);
        check(valueOf(l, 0x0010, 0x0010) == latin);
        check(valueOf(u, 0x0010, 0x0010) == name.UTF8String);
        check([NSFileManager.defaultManager copyItemAtPath:l toPath:[l stringByAppendingString:@".representable"] error:nil]);
        check([NSFileManager.defaultManager copyItemAtPath:u toPath:[u stringByAppendingString:@".representable"] error:nil]);
        NSData *unchanged = [NSData dataWithContentsOfFile:l];
        check(![XMLController modifyDicom:@[@[TAG(0010,0010), @"猫^TEST"]] dicomFiles:files reasons:&reasons]);
        check([reasons.firstObject containsString:@"Saved 1 edits in 1 files"]);
        check([reasons.lastObject containsString:@"ISO_IR 100"]);
        check([reasons.lastObject containsString:@"(0010,0010)"]);
        check([[NSData dataWithContentsOfFile:l] isEqual:unchanged]);
        check(valueOf(u, 0x0010, 0x0010) == "猫^TEST");
    }
    for (NSString *charset in @[@"latin1", @"utf8"]) {
        NSString *file = copyCase(root, charset, [@"nested-" stringByAppendingFormat:@"%@.dcm", charset]);
        NSMutableArray *edits = [NSMutableArray array];
        for (int item = 0; item < 2; ++item)
            for (int deep = 0; deep < 2; ++deep) [edits addObject:@[nameInItem(item, deep), name]];
        check(applyEdits(file, edits, &reasons, NULL));
        edits = [NSMutableArray array];
        for (int item = 0; item < 2; ++item)
            for (int deep = 0; deep < 2; ++deep) [edits addObject:@[nameInItem(item, deep), @"猫^TEST"]];
        check(!applyEdits(file, edits, &reasons, NULL));
        check([reasons.firstObject containsString:@"Saved 2 edits in 1 files"]);
        check(reasons.count == 3);
        check([reasons.lastObject containsString:@"(0040,0275)[0].(0010,0010)"]);
        check(valueOf(file, 0x0010, 0x0010) == "SEQUENCE^EDIT");
    }
    NSString *vm = copyCase(root, @"latin1", @"vm-empty.dcm");
    check(applyEdits(vm, @[@[TAG(0010,0010), @"\\José^TEST"]], &reasons, NULL));
    check(valueOf(vm, 0x0010, 0x0010) == "\\Jos\xe9^TEST");
    NSString *absent = copyCase(root, @"absent", @"absent-default.dcm");
    check(applyEdits(absent, @[@[TAG(0010,0010), name]], &reasons, NULL));
    check(valueOf(absent, 0x0010, 0x0010) == latin);
    absent = copyCase(root, @"absent", @"absent-utf8.dcm");
    [NSUserDefaults.standardUserDefaults setObject:@"ISO_IR 192" forKey:@"DefaultCharacterSetWhenAbsent"];
    check(applyEdits(absent, @[@[TAG(0010,0010), @"猫^TEST"]], &reasons, NULL));
    check(valueOf(absent, 0x0010, 0x0010) == "猫^TEST");
    check(!present(absent, 0x0008, 0x0005));
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"DefaultCharacterSetWhenAbsent"];

    NSString *extensions = copyCase(root, @"extensions", @"extensions-work.dcm");
    NSData *original = [NSData dataWithContentsOfFile:extensions];
    check(!applyEdits(extensions, @[@[TAG(0010,0010), @"ASCII^TEST"]], &reasons, NULL));
    check([reasons.lastObject containsString:@"no safe text encoder"]);
    check([[NSData dataWithContentsOfFile:extensions] isEqual:original]);
    TagPath *dose = nameInItem(0, false); dose.group = 0x0018; dose.element = 0x1074;
    check(applyEdits(extensions, @[@[dose, @"123456789"]], &reasons, NULL));
    check(applyEdits(extensions, @[@[TAG(0010,0010), @""]], &reasons, NULL));

    NSString *limits = copyCase(root, @"latin1", @"limits.dcm");
    original = [NSData dataWithContentsOfFile:limits];
    NSString *tooLong = [@"A" stringByPaddingToLength:65535 withString:@"A" startingAtIndex:0];
    check(!applyEdits(limits, @[@[TAG(0010,0010), tooLong]], &reasons, NULL));
    check([reasons.lastObject containsString:@"exceeds the DICOM value length"]);
    unichar nul[] = {'A', 0, 'B'};
    check(!applyEdits(limits, @[@[TAG(0010,0010), [NSString stringWithCharacters:nul length:3]]], &reasons, NULL));
    check([reasons.lastObject containsString:@"NUL"]);
    check(!applyEdits(limits, @[@[nested(4294967296LL, 0x0010, 0x0010), @"overflow"]], &reasons, NULL));
    check([[NSData dataWithContentsOfFile:limits] isEqual:original]);
}

int main(int argc, const char **argv) { @autoreleasepool {
    OFLog::configure(OFLogger::ERROR_LOG_LEVEL);
#if DCMTK_BACKEND
    if (argc > 2 && (strcmp(argv[2], "roundtrip") == 0 || strcmp(argv[2], "preserve") == 0 || strcmp(argv[2], "refuse") == 0)) {
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSArray *reasons = nil;
        if (strcmp(argv[2], "roundtrip") == 0) {
            HorosDCMTKSeekableInput input;
            check(input.load(path.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).good());
            DcmFileFormat &file = input.fileFormat();
            OFString uid;
            file.getMetaInfo()->findAndGetOFStringArray(DCM_TransferSyntaxUID, uid);
            E_TransferSyntax syntax = uid.empty() ? file.getDataset()->getOriginalXfer() : DcmXfer(uid.c_str()).getXfer();
            check(syntax != EXS_Unknown && file.canWriteXfer(syntax));
            bool hasMeta = file.getMetaInfo()->card() != 0;
            check(HorosWriteFileAtomically(path, ^BOOL(NSString *prepared) {
                return file.saveFile(prepared.fileSystemRepresentation, syntax, EET_UndefinedLength,
                    EGL_recalcGL, EPD_noChange, 0, 0, hasMeta ? EWM_dontUpdateMeta : EWM_dataset).good();
            }));
        } else {
            BOOL result = [XMLController modifyDicom:@[@[TAG(0008,103e), @"DCMTK metadata edit"]] dicomFiles:@[path] reasons:&reasons];
            check(result == (strcmp(argv[2], "preserve") == 0));
            if (!result) check(reasons.count >= 2 && [reasons.firstObject containsString:@"Saved 0 edits in 0 files"]);
        }
        return failures ? 1 : 0;
    }
#endif
    pristine = [NSString stringWithUTF8String:argv[1]];
    working = [pristine stringByAppendingString:@".work"];

    if (argc > 2 && atoi(argv[2]) > 0) {
        reset();
        for (int i = 0; i < atoi(argv[2]); ++i)
            check(applyEdits(working, @[@[TAG(0009, 1001), @"benchmark value"]], NULL, NULL));
        printf("%d edits, %d failures\n", atoi(argv[2]), failures);
        return failures ? 1 : 0;
    }

    // Publication boundaries reject unsafe file types and invalid prepared
    // outputs, preserve the destination and clean only their own staging path.
    reset();
    NSData *boundaryOriginal = [NSData dataWithContentsOfFile:working];
    NSString *link = [working stringByAppendingString:@".link"];
    check(symlink(working.fileSystemRepresentation, link.fileSystemRepresentation) == 0);
    __block BOOL called = NO;
    check(!HorosWriteFileAtomically(link, ^BOOL(NSString *prepared) { called = YES; return YES; }));
    check(!called);
    check(unlink(link.fileSystemRepresentation) == 0);
    check(!HorosWriteFileAtomically(working.stringByDeletingLastPathComponent, ^BOOL(NSString *prepared) { called = YES; return YES; }));
    check(!called);
    for (int invalid = 0; invalid < 3; ++invalid) {
        check(!HorosWriteFileAtomically(working, ^BOOL(NSString *prepared) {
            struct stat stage;
            // Existing directory-staged publishers may not precreate the file.
            if (lstat(prepared.fileSystemRepresentation, &stage) == 0) {
                check(S_ISREG(stage.st_mode));
                check((stage.st_mode & 0777) == 0600);
            }
            if (invalid == 0) { // An empty output reported as success.
                FILE *empty = fopen(prepared.fileSystemRepresentation, "wb");
                check(empty != NULL && fclose(empty) == 0);
            } else {
                unlink(prepared.fileSystemRepresentation);
                if (invalid == 1)
                    check(symlink(working.fileSystemRepresentation, prepared.fileSystemRepresentation) == 0);
                else {
                    check(mkdir(prepared.fileSystemRepresentation, 0700) == 0);
                    check([@"invalid output" writeToFile:[prepared stringByAppendingPathComponent:@"child"] atomically:NO encoding:NSUTF8StringEncoding error:nil]);
                }
            }
            return YES;
        }));
        check([[NSData dataWithContentsOfFile:working] isEqual:boundaryOriginal]);
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:working.stringByDeletingLastPathComponent error:nil])
            check(![name hasPrefix:@".horos-write-"]);
    }
    @try {
        HorosWriteFileAtomically(working, ^BOOL(NSString *prepared) {
            [@"partial" writeToFile:prepared atomically:NO encoding:NSUTF8StringEncoding error:nil];
            [NSException raise:@"WriterFault" format:@"synthetic writer exception"];
            return NO;
        });
        check(false);
    } @catch (NSException *exception) {
        check([exception.name isEqualToString:@"WriterFault"]);
    }
    check([[NSData dataWithContentsOfFile:working] isEqual:boundaryOriginal]);
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:working.stringByDeletingLastPathComponent error:nil])
        check(![name hasPrefix:@".horos-write-"]);

    check(HorosWriteFileAtomically(working, ^BOOL(NSString *prepared) {
        BOOL written = [boundaryOriginal writeToFile:prepared atomically:NO];
        check(chmod(prepared.fileSystemRepresentation, 0644) == 0);
        return written;
    }));
    struct stat published;
    check(lstat(working.fileSystemRepresentation, &published) == 0 && (published.st_mode & 07777) == 0600);
    check([[NSData dataWithContentsOfFile:working] isEqual:boundaryOriginal]);

    // The fixture is what the test says it is.
    reset();
    check(present(working, 0x0008, 0x1030));
    check(valueOf(working, 0x0009, 0x1001) == "original private");
    check(present(working, 0x0009, 0x1002));

    // Removing takes the element out. An entry of one element is a removal.
    reset();
    check(applyEdits(working, @[@[TAG(0008, 1030)]], NULL, NULL) == YES);
    check(present(working, 0x0008, 0x1030) == false);

    // NSNull is the marker the editor already puts in a row it will delete.
    reset();
    check(applyEdits(working, @[@[TAG(0008, 1030), NSNull.null]], NULL, NULL) == YES);
    check(present(working, 0x0008, 0x1030) == false);

    // Emptying is a different request: the element stays, with no value.
    reset();
    check(applyEdits(working, @[@[TAG(0008, 1030), @""]], NULL, NULL) == YES);
    check(present(working, 0x0008, 0x1030));
    check(valueOf(working, 0x0008, 0x1030) == "");

    // And replacing still replaces.
    reset();
    check(applyEdits(working, @[@[TAG(0008, 1030), @"Edited description"]], NULL, NULL) == YES);
    check(valueOf(working, 0x0008, 0x1030) == "Edited description");

    // A private element with a text VR takes a new value and keeps it, which
    // gdcm::Anonymizer::Replace refuses outright.
    reset();
    check(applyEdits(working, @[@[TAG(0009, 1001), @"edited private"]], NULL, NULL) == YES);
    check(valueOf(working, 0x0009, 0x1001) == "edited private");
    // The private creator that owns the block is untouched.
    check(valueOf(working, 0x0009, 0x0010) == "HOROS TEST CREATOR");

    // An odd length is padded, and comes back without the padding.
    reset();
    check(applyEdits(working, @[@[TAG(0009, 1001), @"odd"]], NULL, NULL) == YES);
    check(valueOf(working, 0x0009, 0x1001) == "odd");

    // Emptying and removing a private element are still distinct.
    reset();
    check(applyEdits(working, @[@[TAG(0009, 1001), @""]], NULL, NULL) == YES);
    check(present(working, 0x0009, 0x1001));
    check(valueOf(working, 0x0009, 0x1001) == "");
    reset();
    check(applyEdits(working, @[@[TAG(0009, 1001)]], NULL, NULL) == YES);
    check(present(working, 0x0009, 0x1001) == false);

    // A private element whose value the editor's text cannot express is refused
    // with a reason, and the file keeps what it had.
    reset();
    NSArray *reasons = nil;
    check(applyEdits(working, @[@[TAG(0009, 1002), @"text"]], &reasons, NULL) == NO);
    check(reasons.count == 2);
    check([reasons.lastObject containsString:@"0009,1002"]);
    check([reasons.lastObject containsString:@"OB"]);
    check(present(working, 0x0009, 0x1002));

    // A private element the file does not carry is refused, and said so.
    reset();
    reasons = nil;
    check(applyEdits(working, @[@[TAG(0009, 10ff), @"text"]], &reasons, NULL) == NO);
    check(reasons.count == 2);
    check([reasons.lastObject containsString:@"does not carry"]);

    // One refused element does not cost the others: everything else in the same
    // request is applied, and only the refusal is reported.
    reset();
    reasons = nil;
    check(applyEdits(working, @[@[TAG(0009, 1002), @"text"],
                                @[TAG(0009, 1001), @"still written"],
                                @[TAG(0008, 1030)]], &reasons, NULL) == NO);
    check(valueOf(working, 0x0009, 0x1001) == "still written");
    check(present(working, 0x0008, 0x1030) == false);
    check(reasons.count == 2);

    // An entry that is not shaped like an edit is counted, not applied.
    reset();
    NSUInteger rejected = 0;
    reasons = nil;
    check(applyEdits(working, @[@[TAG(0009, 1001), @42], @[]], &reasons, &rejected) == NO);
    check(rejected == 2);
    check(valueOf(working, 0x0009, 0x1001) == "original private");

    check([reasons.firstObject containsString:@"Saved 0 edits in 0 files"]);
    check([reasons[1] containsString:@"(0009,1001)"]);

    // Nested refusals identify the item and leaf, and a valid sibling edit
    // still reaches disk without touching the sequence's original leaf.
    reset();
    check(!applyEdits(working, @[@[nested(1, 0x0008, 0x1155), @"missing item"],
                                 @[TAG(0009, 1001), @"accepted"]], &reasons, NULL));
    check([reasons.firstObject containsString:@"Saved 1 edits in 1 files"]);
    check([reasons.lastObject containsString:@"(0008,1140)[1].(0008,1155)"]);
    check(valueOf(working, 0x0009, 0x1001) == "accepted");
    HorosDCMTKSeekableInput nestedReader;
    check(nestedReader.load(working.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).good());
    DcmSequenceOfItems *items = nullptr;
    check(nestedReader.fileFormat().getDataset()->findAndGetSequence(DcmTagKey(0x0008,0x1140), items).good());
    check(items && items->card() == 1);
    check(items && items->getItem(0)->tagExists(DcmTagKey(0x0008,0x1155)));

    reset();
    check(applyEdits(working, @[@[TAG(0009,1003), @"5.25"],
                                 @[TAG(0009,1004), @"1.2.826.0.1.3680043.8.498.1084009"],
                                 @[TAG(0009,1005), @"HELLO"]], &reasons, NULL));
    check(valueOf(working, 0x0009, 0x1003) == "5.25");
    check(valueOf(working, 0x0009, 0x1004) == "1.2.826.0.1.3680043.8.498.1084009");
    check(valueOf(working, 0x0009, 0x0010) == "HOROS TEST CREATOR");
    HorosDCMTKSeekableInput privateReader;
    check(privateReader.load(working.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).good());
    DcmElement *rawUN = nullptr, *privateDS = nullptr, *privateUI = nullptr;
    auto &privateDataset = *privateReader.fileFormat().getDataset();
    check(privateDataset.findAndGetElement(DcmTagKey(0x0009,0x1003), privateDS).good() && privateDS->getVR() == EVR_DS);
    check(privateDataset.findAndGetElement(DcmTagKey(0x0009,0x1004), privateUI).good() && privateUI->getVR() == EVR_UI);
    check(privateDataset.findAndGetElement(DcmTagKey(0x0009,0x1005), rawUN).good() && rawUN->getVR() == EVR_UN);
    Uint8 *rawBytes = nullptr;
    check(rawUN && rawUN->getUint8Array(rawBytes).good() && rawUN->getLength() == 6 && memcmp(rawBytes, "HELLO ", 6) == 0);

    // Refusals alone preserve the exact original bytes, not just its values.
    reset();
    NSData *original = [NSData dataWithContentsOfFile:working];
    check(!applyEdits(working, @[@[TAG(0009, 1002), @"text"]], &reasons, NULL));
    check([[NSData dataWithContentsOfFile:working] isEqual:original]);
    reset();
    check(!applyEdits(working, @[@[TAG(0008, 1140), @"text"]], &reasons, NULL));
    check([[NSData dataWithContentsOfFile:working] isEqual:original]);

    check(applyEdits(working, @[@[TAG(0008, 103e)]], &reasons, NULL));
    check([[NSData dataWithContentsOfFile:working] isEqual:original]);
    // Invalid addresses do not get rewritten to a top-level tag.
    check(!applyEdits(working, @[@[nested(0, 0x0008, 0x1155), @42]], &reasons, NULL));
    check([reasons.lastObject containsString:@"(0008,1140)[0].(0008,1155)"]);
    check([[NSData dataWithContentsOfFile:working] isEqual:original]);

    check(!applyEdits(working, @[@[TAG(0042, 0011), @"text"]], &reasons, NULL));
    check([[NSData dataWithContentsOfFile:working] isEqual:original]);
    check(!applyEdits(working, @[@[TAG(0009, 10ff), @""]], &reasons, NULL));
    check([[NSData dataWithContentsOfFile:working] isEqual:original]);

    TagPath *malformed = [TagPath new]; malformed.group = 0x0008; malformed.element = 0x1155;
    malformed.steps = @[@"unreadable step"];
    check(!applyEdits(working, @[@[malformed, @"text"], @[TAG(0009,1001), @"accepted"]], &reasons, NULL));
    check(valueOf(working, 0x0009, 0x1001) == "accepted");
    check([reasons.firstObject containsString:@"Saved 1 edits in 1 files"]);

    // Public empty SQ is accepted and is empty on reopening, rather than a
    // mutation concealed behind a false return from the library.
    reset();
    check(applyEdits(working, @[@[TAG(0008, 1140), @""]], &reasons, NULL));
    HorosDCMTKSeekableInput sequenceReader;
    check(sequenceReader.load(working.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).good());
    DcmSequenceOfItems *sequence = nullptr;
    check(sequenceReader.fileFormat().getDataset()->findAndGetSequence(DcmTagKey(0x0008,0x1140), sequence).good());
    check(sequence && sequence->card() == 0);

    // Failed writing after a partial header, failed close and failed rename
    // all preserve the original; no staging directory survives.
    for (int fault = 0; fault < 3; ++fault) {
        reset();
        failWrite = fault == 0; failClose = fault == 1; failRename = fault == 2;
        check(!applyEdits(working, @[@[TAG(0009, 1001), @"not published"]], &reasons, NULL));
        check([[NSData dataWithContentsOfFile:working] isEqual:original]);
        check([reasons.firstObject containsString:@"Saved 0 edits in 0 files"]);
        check([reasons.lastObject containsString:@"original file is unchanged"]);
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:working.stringByDeletingLastPathComponent error:nil])
            check(![name hasPrefix:@".horos-write-"]);
        failWrite = failClose = failRename = false;
    }

    // Deliberately deleting a dataset UID also deletes its meta counterpart;
    // the editor never silently generates a replacement identity.
    reset();
    check(applyEdits(working, @[@[TAG(0008, 0018)]], &reasons, NULL));
    check(!present(working, 0x0008, 0x0018));
    HorosDCMTKSeekableInput identityReader;
    check(identityReader.load(working.fileSystemRepresentation, NSTemporaryDirectory().fileSystemRepresentation).good());
    check(!identityReader.fileFormat().getMetaInfo()->tagExists(DCM_MediaStorageSOPInstanceUID));

    // Identifiers still name the same instance after a successful edit.
    reset();
    check(applyEdits(working, @[@[TAG(0009, 1001), @"final"]], NULL, NULL) == YES);
    check(valueOf(working, 0x0008, 0x0018) == "1.2.826.0.1.3680043.8.498.10001");
    check(valueOf(working, 0x0020, 0x000e) == "1.2.826.0.1.3680043.8.498.3");

    [NSFileManager.defaultManager removeItemAtPath:working error:nil];
    if (argc > 3 && strlen(argv[3])) charsetCases([NSString stringWithUTF8String:argv[3]]);
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("ok\n");
    return 0;
} }
'''

# Compile the actual shared code-page table and absent-charset preference.
character_set_source = (root / 'DCM Framework/DCMCharacterSet.m').read_bytes().decode('latin1')
def method_source(signature):
    begin = character_set_source.index(signature)
    opening = character_set_source.index('{', begin)
    depth = 0
    for end in range(opening, len(character_set_source)):
        depth += (character_set_source[end] == '{') - (character_set_source[end] == '}')
        if depth == 0:
            return character_set_source[begin:end + 1]
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
parser_count = ('HorosTagEditsFromEntries(entries, NSISOLatin1StringEncoding, rejectedOut)'
                if 'NSArray *entries, NSStringEncoding encoding' in source else
                'HorosTagEditsFromEntries(entries, rejectedOut)')
code = code.replace('CHARACTER_SET', character_set).replace('PARSER_COUNT', parser_count)

if dcmtk_backend:
    method = method.replace('file.saveFile(', 'TestSaveFile(file, ')
else:
    method = method.replace('std::ofstream stream(', 'FaultStream stream(')
code = code.replace('BACKEND_INCLUDES', '#include "HorosDCMTKTagEditing.h"\n#include "HorosDICOMEditingStorage.h"' if dcmtk_backend else '')
code = '#define DCMTK_BACKEND %d\n' % dcmtk_backend + code
code = code.replace('EXTRACTION', extraction).replace('METHOD', method)

INDEPENDENT_CHARSET_READ = r"""
from pathlib import Path
from copy import deepcopy
import sys, pydicom
root = Path(sys.argv[1])
name = ['José^Müller=Teste', 'Deux^Élodie']
def names(value):
    return [str(x) for x in value] if isinstance(value, pydicom.multival.MultiValue) else [str(value)]
def read(name):
    ds = pydicom.dcmread(root / name)
    assert str(ds.file_meta.TransferSyntaxUID) == '1.2.840.10008.1.2.1'
    return ds
def prune_names(ds, nested=False):
    ds = deepcopy(ds)
    if not nested: del ds.PatientName
    else:
        for item in ds.RadiopharmaceuticalInformationSequence:
            del item.PatientName
            del item.RequestAttributesSequence[0].PatientName
    return ds
for order in range(2):
    for charset, original in [('latin', 'latin1'), ('utf8', 'utf8')]:
        ds = read(f'order-{order}-{charset}.dcm.representable')
        assert names(ds.PatientName) == name
        assert prune_names(ds) == prune_names(read(f'charset-{original}-edição.dcm'))
        ds = read(f'order-{order}-{charset}.dcm')
        assert names(ds.PatientName) == (name if charset == 'latin' else ['猫^TEST'])
        assert prune_names(ds) == prune_names(read(f'charset-{original}-edição.dcm'))
for charset in ['latin1', 'utf8']:
    ds = read(f'nested-{charset}.dcm')
    for index, item in enumerate(ds.RadiopharmaceuticalInformationSequence):
        expected = ['猫^TEST'] if (index == 1) == (charset == 'latin1') else name
        assert names(item.PatientName) == expected
        assert names(item.RequestAttributesSequence[0].PatientName) == expected
    assert prune_names(ds, True) == prune_names(read(f'charset-{charset}-edição.dcm'), True)
ds = read('vm-empty.dcm')
assert names(ds.PatientName) == ['', 'José^TEST']
assert prune_names(ds) == prune_names(read('charset-latin1-edição.dcm'))
ds = read('absent-default.dcm')
assert names(ds.PatientName) == name and 'SpecificCharacterSet' not in ds
assert prune_names(ds) == prune_names(read('charset-absent-edição.dcm'))
ds = read('absent-utf8.dcm')
assert 'SpecificCharacterSet' not in ds
# Emulate the explicit missing-charset preference in this independent reader.
assert str(ds.PatientName.decode(['UTF8'])) == '猫^TEST'
assert ds.PixelData == read('charset-absent-edição.dcm').PixelData
ds = read('extensions-work.dcm')
assert str(ds.PatientName) == ''
assert ds.RadiopharmaceuticalInformationSequence[0].RadionuclideTotalDose == 123456789
assert list(ds.SpecificCharacterSet) == ['', 'ISO 2022 IR 100']
assert ds.PixelData == read('charset-extensions-edição.dcm').PixelData
assert (root / 'limits.dcm').read_bytes() == (root / 'charset-latin1-edição.dcm').read_bytes()
print('PASS: independent reopen of batches in both orders, partial refusals, two-level inheritance/overrides, VM/PN, absent defaults, ISO 2022 refusal, bounds and preserved non-target tree/pixels')
"""


PRESERVATION_CASES = r"""
from pathlib import Path
from copy import deepcopy
from io import BytesIO
import json, sys
import numpy as np
from PIL import Image
import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import (SecondaryCaptureImageStorage, ExplicitVRLittleEndian,
    ImplicitVRLittleEndian, ExplicitVRBigEndian, DeflatedExplicitVRLittleEndian,
    JPEGBaseline8Bit)
from pydicom.encaps import encapsulate
folder = Path(sys.argv[1]); folder.mkdir()
def jpeg(data):
    output = BytesIO(); Image.fromarray(data).save(output, format='JPEG', quality=90)
    return output.getvalue()
base = Dataset(); base.file_meta = FileMetaDataset()
base.file_meta.MediaStorageSOPClassUID = SecondaryCaptureImageStorage
base.file_meta.MediaStorageSOPInstanceUID = '1.2.826.0.1.3680043.8.498.1084001'
base.file_meta.ImplementationClassUID = '1.2.826.0.1.3680043.8.498.1084'
base.SOPClassUID = base.file_meta.MediaStorageSOPClassUID
base.SOPInstanceUID = base.file_meta.MediaStorageSOPInstanceUID
base.StudyInstanceUID = '1.2.826.0.1.3680043.8.498.1084002'
base.SeriesInstanceUID = '1.2.826.0.1.3680043.8.498.1084003'
base.SpecificCharacterSet = 'ISO_IR 100'; base.Modality = 'OT'
base.PatientName = 'PRESERVATION^SYNTHETIC'; base.PatientID = 'PRESERVATION'
base.ImageType = ['ORIGINAL','PRIMARY']; base.SeriesDescription = 'original series'
base.add_new((0x0010,0x1000), 'LO', ['', 'B','C'])
base.Rows = 128; base.Columns = 128; base.SamplesPerPixel = 1
base.PhotometricInterpretation = 'MONOCHROME2'; base.PixelRepresentation = 0
base.BitsAllocated = 16; base.BitsStored = 16; base.HighBit = 15
base.add_new((0x0009,0x0010), 'LO', 'PRESERVATION CREATOR')
base.add_new((0x0009,0x1001), 'LO', 'private text')
base.add_new((0x0009,0x1002), 'DS', '1.25')
base.add_new((0x0009,0x1003), 'UI', '1.2.826.0.1.3680043.8.498.1084004')
base.add_new((0x0009,0x1004), 'UN', b'\x00\\\xffQ')
base.add_new((0x0009,0x1005), 'OB', b'\x00\\\xffQ')
children = []
for n in range(2):
    child = Dataset(); child.PatientName = 'child-%d' % n
    child.add_new((0x0009,0x0010), 'LO', 'LOCAL CREATOR')
    child.add_new((0x0009,0x1001), 'UN', b'\x00\\\xffQ')
    child.ReferencedImageSequence = Sequence([Dataset()])
    child.ReferencedImageSequence[0].ReferencedSOPInstanceUID = base.SOPInstanceUID
    children.append(child)
base.add_new((0x0009,0x1010), 'SQ', Sequence(children))
base[(0x0009,0x1010)].is_undefined_length = True
ramp = np.arange(128*128, dtype=np.uint16).reshape(128,128)
base.PixelData = ramp.astype('<u2').tobytes(); base['PixelData'].VR = 'OW'
icon = Dataset(); icon.Rows = 8; icon.Columns = 8; icon.SamplesPerPixel = 1
icon.PhotometricInterpretation = 'MONOCHROME2'; icon.PixelRepresentation = 0
icon.BitsAllocated = 8; icon.BitsStored = 8; icon.HighBit = 7
icon.PixelData = bytes(range(64)); icon['PixelData'].VR = 'OB'
base.IconImageSequence = Sequence([icon])
cases = []
for name, syntax in [('explicit-le',ExplicitVRLittleEndian),('implicit-le',ImplicitVRLittleEndian),
                     ('explicit-be',ExplicitVRBigEndian),('deflated',DeflatedExplicitVRLittleEndian),
                     ('jpeg',JPEGBaseline8Bit)]:
    ds = deepcopy(base); ds.file_meta.TransferSyntaxUID = syntax
    if syntax == ExplicitVRBigEndian: ds.PixelData = ramp.astype('>u2').tobytes()
    if syntax == JPEGBaseline8Bit:
        ds.BitsAllocated = 8; ds.BitsStored = 8; ds.HighBit = 7; ds.NumberOfFrames = 2
        ds.PixelData = encapsulate([jpeg((ramp % 256).astype('u1')), jpeg((255-ramp % 256).astype('u1'))], has_bot=True)
        ds['PixelData'].VR = 'OB'; ds['PixelData'].is_undefined_length = True
        ds.IconImageSequence[0].PixelData = encapsulate([jpeg(np.arange(64,dtype='u1').reshape(8,8))], has_bot=True)
        ds.IconImageSequence[0]['PixelData'].is_undefined_length = True
    path = folder / (name + '.dcm')
    pydicom.dcmwrite(path, ds, implicit_vr=syntax == ImplicitVRLittleEndian,
                    little_endian=syntax != ExplicitVRBigEndian, enforce_file_format=True)
    cases.append(name)
raw = deepcopy(base); raw.file_meta = FileMetaDataset()
pydicom.dcmwrite(folder/'dataset-only.dcm', raw, implicit_vr=True, little_endian=True, enforce_file_format=False)
cases.append('dataset-only')
# Benign unsupported/invalid storage, not large or adversarial inputs.
unsupported = deepcopy(base); unsupported.SOPClassUID = '1.2.840.10008.5.1.4.1.1.130'
unsupported.file_meta.MediaStorageSOPClassUID = unsupported.SOPClassUID
unsupported.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
unsupported.save_as(folder/'unsupported.dcm', enforce_file_format=True)
meta_only = Dataset(); meta_only.file_meta = deepcopy(base.file_meta)
meta_only.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
meta_only.save_as(folder/'meta-only.dcm', enforce_file_format=True)
unknown = bytearray((folder/'explicit-le.dcm').read_bytes())
old = b'1.2.840.10008.1.2.1'; position = unknown.index(old)
unknown[position:position+len(old)] = b'1.2.840.10008.1.2.9'
(folder/'unknown-syntax.dcm').write_bytes(unknown)
(folder/'cases.json').write_text(json.dumps(cases))
"""

PRESERVATION_VERIFY = r"""
from pathlib import Path
from copy import deepcopy
import json, sys, pydicom
from pydicom.encaps import generate_fragments
folder = Path(sys.argv[1])
def read(path): return pydicom.dcmread(path, force=True)
def syntax(ds): return str(ds.file_meta.get('TransferSyntaxUID','dataset-only'))
def snapshot(ds):
    result = []
    for element in ds:
        if element.tag.element == 0: continue  # serializer may recalculate group lengths
        value = ([snapshot(item) for item in element.value] if element.VR == 'SQ'
                 else (element.value if isinstance(element.value,bytes) else str(element.value)))
        result.append((int(element.tag), element.VR, element.VM, value))
    return result
for name in json.loads((folder/'cases.json').read_text()):
    original = read(folder/(name+'.dcm'))
    for mode in ['roundtrip','preserve']:
        written_path = folder/(name+'-'+mode+'.dcm'); written = read(written_path)
        assert syntax(written) == syntax(original), (name, mode, 'syntax changed')
        assert original.PixelData == written.PixelData, (name, mode, 'pixel payload changed')
        assert original.IconImageSequence[0].PixelData == written.IconImageSequence[0].PixelData, (name, mode, 'icon payload changed')
        if name == 'jpeg':
            assert list(generate_fragments(original.PixelData)) == list(generate_fragments(written.PixelData))
            # Includes the Basic Offset Table as the first fragment.
            assert list(generate_fragments(original.PixelData))[0] != b''
        expected = deepcopy(original)
        if mode == 'preserve':
            expected.SeriesDescription = 'DCMTK metadata edit'
            assert str(written.SeriesDescription) == 'DCMTK metadata edit'
        assert snapshot(expected) == snapshot(written), (name, mode, 'VR/VM/tree/non-target value changed')
        for key in ['MediaStorageSOPClassUID','MediaStorageSOPInstanceUID']:
            assert original.file_meta.get(key) == written.file_meta.get(key), (name,mode,key)
        if name == 'dataset-only': assert written_path.read_bytes()[128:132] != b'DICM'
for name in ['unsupported','meta-only','unknown-syntax']:
    assert (folder/(name+'.dcm')).read_bytes() == (folder/(name+'-refuse.dcm')).read_bytes(), name
print('PASS: independent no-edit roundtrip and production edit preserve native/BOT/fragments/icon/private payload, VR/VM/tree and TS across explicit LE/BE, implicit, deflated, JPEG and dataset-only; invalid storage/syntax unchanged')
"""

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'fixture.dcm').write_bytes(fixture)
    (path / 'main.mm').write_text(code + harness_defaults.OBJC)
    backend_flags = [] if dcmtk_backend else ['-I' + str(gdcm / 'include'), str(gdcm / 'wlib/libGDCM.a'), str(openjpeg), '-lexpat']
    subprocess.run(['xcrun', 'clang++', '-fno-objc-arc', '-std=c++17',
                    '-O2' if os.environ.get('HOROS_TEST_CONFIGURATION') == 'Release' else '-O0',
                    '-I' + str(dcmtk / 'include'), '-I' + str(root / 'Horos/Sources'),
                    str(path / 'main.mm'), *map(str, dcmtk_archives), *backend_flags,
                    '-lz', '-liconv', '-framework', 'Foundation', '-framework', 'CoreFoundation',
                    '-o', str(path / 'test')], check=True)
    if args.keep_binary:
        import shutil
        args.keep_binary.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path / 'test', args.keep_binary / 'test')
        shutil.copy2(path / 'fixture.dcm', args.keep_binary / 'fixture.dcm')
    charset_dir = path / 'charset'
    if args.charset_fixtures:
        import shutil
        shutil.copytree(args.charset_fixtures, charset_dir)
        originals = {p.name: p.read_bytes() for p in args.charset_fixtures.glob('*.dcm')}
    env = dict(os.environ)
    env.setdefault('DCMDICTPATH', str(root / 'DCMTK/dcmdata/data/dicom.dic'))
    subprocess.run([str(path / 'test'), str(path / 'fixture.dcm'), str(args.benchmark),
                    str(charset_dir) if args.charset_fixtures else ''], check=True, env=env)
    if args.preservation:
        import json, shutil
        corpus = path / 'preservation'
        subprocess.run([args.python, '-c', PRESERVATION_CASES, str(corpus)], check=True)
        for name in json.loads((corpus / 'cases.json').read_text()):
            for mode in ('roundtrip', 'preserve'):
                copy = corpus / (name + '-' + mode + '.dcm')
                shutil.copy2(corpus / (name + '.dcm'), copy)
                subprocess.run([str(path / 'test'), str(copy), mode], check=True, env=env)
        for name in ('unsupported', 'meta-only', 'unknown-syntax'):
            copy = corpus / (name + '-refuse.dcm')
            shutil.copy2(corpus / (name + '.dcm'), copy)
            subprocess.run([str(path / 'test'), str(copy), 'refuse'], check=True, env=env)
        subprocess.run([args.python, '-c', PRESERVATION_VERIFY, str(corpus)], check=True)
        if args.keep_binary:
            shutil.copytree(corpus, args.keep_binary / 'preservation', dirs_exist_ok=True)
    if args.charset_fixtures:
        assert originals == {p.name: p.read_bytes() for p in args.charset_fixtures.glob('*.dcm')}, 'original fixtures changed'
        subprocess.run([args.python, '-c', INDEPENDENT_CHARSET_READ, str(charset_dir)], check=True)
