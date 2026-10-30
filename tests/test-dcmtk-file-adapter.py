#!/usr/bin/env python3
"""Reading and writing DICOM files goes through the DCMTK adapters, errors as NSError.

The import's reading (DicomFile+DICOMReading.swift), the field queries, the crop,
DCMTKFileFormat and HorosDICOMWriter are Swift over
Horos/Sources/Adapters/DCMTK: IsiXDCMTKFile (a DcmFileFormat), IsiXDCMTKDictionary,
IsiXDCMTKObjectWriter (DCMObject written by DCMTK), HorosDCMTKObject (DCMObject
read by DCMTK), HorosDICOMServices and the JPEG 2000 codec. Their headers carry
no C++ type.

The adapters are compiled here as the application compiles them, against the
DCMTK and OpenJPEG of the Debug build, with the dataset model (exit 2 without them), with
a driver that:
- reads a file and its values, items and bytes, writes it and transcodes it to
  JPEG 2000 and back;
- provokes DCMTK errors: a file that is not DICOM, a transfer syntax DCMTK does
  not know, a folder that does not exist, a path with no file system
  representation; each is an NSError of IsiXDCMTKErrorDomain with what DCMTK
  said, and nothing is left beside the destination;
- provokes a C++ exception: operator new throws std::bad_alloc while DCMTK
  reads, transcodes, parses a date, writes a DCMObject and reads one; the
  process survives, each call fails as a DCMTK refusal would (NSError with
  IsiXDCMTKErrorCodeException, nil or NO) and the next call works again.
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT  # noqa: E402
import horos_reader  # noqa: E402

PRODUCTS = ROOT / 'build/Build/Products' / BUILD.name
reason = horos_reader.missing(PRODUCTS)
if reason:
    print('skipped: needs a current Debug build from script/build_and_run.sh --verify: ' + reason)
    raise SystemExit(2)


def element(tag, vr, value):
    header = struct.pack('<HH', *tag)
    if vr in ('OB', 'OW', 'SQ', 'UN', 'UT'):
        return header + vr.encode() + b'\0\0' + struct.pack('<I', len(value)) + value
    return header + vr.encode() + struct.pack('<H', len(value)) + value


def text(value):
    value = value.encode()
    return value + b' ' * (len(value) % 2)


def uid(value):
    value = value.encode()
    return value + b'\0' * (len(value) % 2)


def image():
    meta = element((2, 0x10), 'UI', uid('1.2.840.10008.1.2.1'))
    data = b'\0' * 128 + b'DICM' + element((2, 0), 'UL', struct.pack('<I', len(meta))) + meta
    data += element((8, 0x16), 'UI', uid('1.2.840.10008.5.1.4.1.1.7'))
    data += element((8, 0x18), 'UI', uid('1.2.826.0.1.3680043.2.1125.7.1'))
    data += element((8, 0x20), 'DA', text('20260102'))
    data += element((0x10, 0x10), 'PN', text('DOE^JANE'))
    data += element((0x20, 0x0D), 'UI', uid('1.2.826.0.1.3680043.2.1125.7.2'))
    data += element((0x20, 0x0E), 'UI', uid('1.2.826.0.1.3680043.2.1125.7.3'))
    data += element((0x20, 0x32), 'DS', text('1.5\\-2\\30'))
    for tag, value in [(2, 1), (0x10, 8), (0x11, 8), (0x100, 16), (0x101, 12), (0x102, 11), (0x103, 0)]:
        data += element((0x28, tag), 'US', struct.pack('<H', value))
    data += element((0x28, 4), 'CS', text('MONOCHROME2'))
    data += element((0x7FE0, 0x10), 'OW', b''.join(struct.pack('<H', (i * 37) % 4096) for i in range(64)))
    return data


DRIVER = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import "IsiXDCMTKFile.h"
#import "IsiXDCMTKDictionary.h"
#import "IsiXDCMTKObjectWriter.h"
#import "IsiXDCMTKError.h"
#import "HorosDCMTKObject.h"
#import "HorosDICOMServices.h"
#include <cstdio>
#include <cstdlib>
#include <new>

extern "C" void HorosTestRegisterDecoders(void);

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

static bool isCondition(NSError *error)
{
    return [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code != IsiXDCMTKErrorCodeException &&
        [error.userInfo[IsiXDCMTKConditionTextKey] length] > 0;
}

static bool isException(NSError *error)
{
    return [error.domain isEqualToString:IsiXDCMTKErrorDomain] && error.code == IsiXDCMTKErrorCodeException;
}

static NSArray *leftovers(NSString *folder, NSString *name)
{
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL];
    return [names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH %@ AND SELF ENDSWITH '.tmp'", name]];
}

int main(int argc, char **argv)
{
    HorosTestRegisterDecoders();
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSString *source = [folder stringByAppendingPathComponent:@"image.dcm"];

        // Reading.
        NSError *error = nil;
        IsiXDCMTKFile *file = [IsiXDCMTKFile fileAtPath:source error:&error];
        check(file != nil && error == nil, "a DICOM file reads");
        const char *name = [file.dataset stringForTag:0x00100010];
        check(name && strcmp(name, "DOE^JANE") == 0, "a text value is the C string DCMTK holds");
        double position[3] = {9, 9, 9};
        check([file.dataset getFloat64Values:position count:3 forTag:0x00200032] == 3 && position[2] == 30,
              "three positions read");
        double orientation[6] = {1, 0, 0, 0, 1, 0};
        check([file.dataset getFloat64Values:orientation count:6 forTag:0x00200037] == 0 && orientation[0] == 0 &&
              orientation[4] == 1, "an absent value reads nothing and zeroes the slot it tried, as DCMTK does");
        uint16_t rows = 0;
        check([file.dataset getUInt16:&rows forTag:0x00280010 index:0] && rows == 8, "Rows reads");
        unsigned long length = 0;
        check([file.dataset hasElementForTag:0x7FE00010 length:&length] && length == 128 &&
              [file.dataset bytesForTag:0x7FE00010].length == 128 && file.originalTransferSyntaxIsNative,
              "the pixels are there, native, without a copy");
        check([file.metaInfo stringForTag:0x00020010] != NULL, "the meta header reads");

        // Writing and transcoding, JPEG 2000 included.
        NSString *copy = [folder stringByAppendingPathComponent:@"copy.dcm"];
        check([file writeToPath:copy transferSyntax:@"1.2.840.10008.1.2" removingPadding:YES error:&error],
              "the file writes in Implicit VR Little Endian");
        NSString *j2k = [folder stringByAppendingPathComponent:@"j2k.dcm"];
        check([IsiXDCMTKFile transcodeFileAtPath:source toPath:j2k transferSyntax:@"1.2.840.10008.1.2.4.90" quality:0 error:&error],
              "the file transcodes to JPEG 2000 lossless");
        IsiXDCMTKFile *encoded = [IsiXDCMTKFile fileAtPath:j2k error:NULL];
        check(encoded.originalTransferSyntaxIsEncapsulated, "and the copy is encapsulated");
        NSString *back = [folder stringByAppendingPathComponent:@"back.dcm"];
        check([IsiXDCMTKFile transcodeFileAtPath:j2k toPath:back transferSyntax:@"1.2.840.10008.1.2.1" quality:0 error:&error] &&
              [[[IsiXDCMTKFile fileAtPath:back error:NULL].dataset bytesForTag:0x7FE00010] isEqualToData:[file.dataset bytesForTag:0x7FE00010]],
              "and back, with the same pixels");

        // DCMTK errors.
        error = nil;
        check([IsiXDCMTKFile fileAtPath:[folder stringByAppendingPathComponent:@"text.dcm"] error:&error] == nil && isCondition(error),
              "a file that is not DICOM is an NSError with DCMTK's condition");
        printf("  %s\n", [error.userInfo[IsiXDCMTKConditionTextKey] UTF8String]);
        error = nil;
        NSString *unknown = [folder stringByAppendingPathComponent:@"unknown.dcm"];
        check(![IsiXDCMTKFile transcodeFileAtPath:source toPath:unknown transferSyntax:@"1.2.3.4" quality:0 error:&error] &&
              isCondition(error) && leftovers(folder, @"unknown.dcm").count == 0 &&
              ![[NSFileManager defaultManager] fileExistsAtPath:unknown],
              "a transfer syntax DCMTK does not know is its condition, and nothing is written");
        printf("  %s\n", [error.userInfo[IsiXDCMTKConditionTextKey] UTF8String]);
        error = nil;
        check(![file writeToPath:[folder stringByAppendingPathComponent:@"none/copy.dcm"] transferSyntax:nil removingPadding:NO error:&error] &&
              isCondition(error), "a folder that does not exist is DCMTK's condition");
        unichar invalid[] = {0xd800};
        error = nil;
        check([IsiXDCMTKFile fileAtPath:[NSString stringWithCharacters:invalid length:1] error:&error] == nil &&
              error.code == IsiXDCMTKErrorCodeFailure, "a path with no file system representation never reaches DCMTK");
        uint32_t tag = 0;
        check([IsiXDCMTKDictionary getStandardTag:&tag forKeyword:@"PatientName"] && tag == 0x00100010 &&
              ![IsiXDCMTKDictionary getStandardTag:&tag forKeyword:@"NoSuchKeyword"] &&
              [[IsiXDCMTKDictionary valueRepresentationForTag:0x00080020] isEqualToString:@"DA"],
              "the dictionary answers keywords and VRs");

        // C++ exceptions.
        error = nil;
        failNew = true;
        IsiXDCMTKFile *thrown = [IsiXDCMTKFile fileAtPath:source error:&error];
        failNew = false;
        check(thrown == nil && isException(error), "std::bad_alloc while DCMTK reads is an NSError, not a terminated process");
        printf("  %s\n", error.localizedDescription.UTF8String);

        error = nil;
        NSString *failed = [folder stringByAppendingPathComponent:@"failed.dcm"];
        failNew = true;
        BOOL transcoded = [IsiXDCMTKFile transcodeFileAtPath:source toPath:failed transferSyntax:@"1.2.840.10008.1.2.4.90" quality:0 error:&error];
        failNew = false;
        check(!transcoded && isException(error) && ![[NSFileManager defaultManager] fileExistsAtPath:failed],
              "std::bad_alloc while DCMTK transcodes is an NSError, and nothing is published");

        // A value longer than a short string's inline storage, so that DCMTK
        // allocates; a dictionary lookup may not allocate at all, so it only has
        // to survive.
        NSString *longValue = @"20260102123456.123456+0100";
        failNew = true;
        NSString *dateTime = [HorosDICOMDates canonicalDateTime:longValue microseconds:NULL timeZoneSeconds:NULL hasTimeZone:NULL];
        NSString *keywordVR = [IsiXDCMTKDictionary valueRepresentationForTag:0x00080020];
        failNew = false;
        check(dateTime == nil && ([keywordVR isEqualToString:@"UN"] || [keywordVR isEqualToString:@"DA"]),
              "the services and the dictionary answer nothing, and survive");
        check([[HorosDICOMDates canonicalDateTime:longValue microseconds:NULL timeZoneSeconds:NULL hasTimeZone:NULL]
                  isEqualToString:@"20260102123456"] &&
              [[IsiXDCMTKDictionary valueRepresentationForTag:0x00080020] isEqualToString:@"DA"],
              "and answer again afterwards");

        DCMObject *object = [HorosDCMTKObject objectWithContentsOfFile:source];
        check(object != nil && [[object attributeValueWithName:@"Rows"] intValue] == 8, "the DCMObject reader reads");
        NSString *written = [folder stringByAppendingPathComponent:@"object.dcm"];
        failNew = true;
        BOOL wrote = [IsiXDCMTKObjectWriter writeObject:object toFile:written transferSyntax:@"1.2.840.10008.1.2.4.90"
                                                quality:0 AET:@"TEST"];
        DCMObject *unread = [HorosDCMTKObject objectWithContentsOfFile:source];
        failNew = false;
        check(!wrote && unread == nil && ![[NSFileManager defaultManager] fileExistsAtPath:written] &&
              leftovers(folder, @"object.dcm").count == 0,
              "std::bad_alloc while DCMTK writes or reads a DCMObject fails the call, and leaves nothing");

        check([IsiXDCMTKObjectWriter writeObject:object toFile:written transferSyntax:@"1.2.840.10008.1.2.4.90" quality:0 AET:@"TEST"] &&
              [HorosDCMTKObject objectWithContentsOfFile:written] != nil && [IsiXDCMTKFile fileAtPath:source error:NULL] != nil &&
              [[HorosDICOMDates canonicalDate:@"20260102"] isEqualToString:@"20260102"],
              "and the next calls work again");
    }
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='isix-dcmtk-file-') as folder:
    work = Path(folder)
    (work / 'bin').mkdir()
    (work / 'Frameworks').symlink_to(PRODUCTS.resolve())
    files = work / 'files'
    files.mkdir()
    (files / 'image.dcm').write_bytes(image())
    (files / 'text.dcm').write_text('arbitrary text, not DICOM')
    (work / 'driver.mm').write_text(DRIVER)
    binary = work / 'bin/driver'
    try:
        horos_reader.compile_reader(PRODUCTS, work / 'driver.mm', binary, work)
    except subprocess.CalledProcessError as failure:
        print('FAIL: the adapters do not compile with the driver: %s' % failure)
        raise SystemExit(1)
    run = subprocess.run([str(binary), str(files)], capture_output=True, text=True, timeout=60)
    print(run.stdout, end='')
    if run.returncode:
        print('FAIL: the driver exited with %d\n%s' % (run.returncode, run.stderr[-3000:]))
        raise SystemExit(1)
print('PASS: files read, written and transcoded through the DCMTK adapters; DCMTK refusals and C++ exceptions are NSErrors')
