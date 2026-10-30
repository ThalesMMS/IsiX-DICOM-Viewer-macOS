#!/usr/bin/env python3
"""The DCMTK probe of an incoming file answers through the adapter, errors as NSError.

+[DicomFile isDICOMFile:...] is Swift (DicomFile+Classification.swift) and asks
Horos/Sources/Adapters/DCMTK/IsiXDCMTKFileProbe whether a file is DICOM. The
adapter refuses a path that cannot be used before DCMTK sees it, runs the lazy
probe (HorosDICOMProbe.h, beside it) and returns a plain structure; its header
carries no C++ type.

The adapter is compiled here against the DCMTK the Debug build installed (exit 2
without it) with a driver that:
- probes a DICOM file, a compressed one and a file wrapped under a private
  transfer syntax, and checks every field against HorosDICOMProbe::inspect;
- provokes a DCMTK error: a file that is not DICOM is not recognized, and with
  an error asked for it is an NSError of IsiXDCMTKErrorDomain with what DCMTK
  said (the probe's diagnostic); nil, an empty path and one with no file system
  representation are refused before DCMTK;
- provokes a C++ exception: operator new throws std::bad_alloc while DCMTK
  reads the file; the process survives, the file is not recognized and the
  error says the probe failed.
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402

ADAPTER = ROOT / 'Horos/Sources/Adapters/DCMTK'
flags = dcmtk_flags('dcmnet')


def element(tag, vr, value):
    header = struct.pack('<HH', *tag)
    if vr in ('OB', 'OW', 'SQ', 'UN', 'UT'):
        return header + vr.encode() + b'\0\0' + struct.pack('<I', len(value)) + value
    return header + vr.encode() + struct.pack('<H', len(value)) + value


def uid(text):
    value = text.encode()
    return value + b'\0' * (len(value) % 2)


def dicom(syntax, pixels=True):
    data = b'\0' * 128 + b'DICM' + element((2, 0x10), 'UI', uid(syntax))
    data += element((8, 0x16), 'UI', uid('1.2.840.10008.5.1.4.1.1.7'))
    data += element((0x20, 0x0E), 'UI', uid('1.2.826.0.1.3680043.2.1125.1.1'))
    if pixels:
        for tag, value in [(2, 1), (0x10, 4), (0x11, 4), (0x100, 8), (0x101, 8)]:
            data += element((0x28, tag), 'US', struct.pack('<H', value))
        data += element((0x7FE0, 0x10), 'OW', b'\0' * 16)
    return data


DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKFileProbe.h"
#import "IsiXDCMTKError.h"
#include "HorosDICOMProbe.h"
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

static bool same(IsiXDCMTKFileProbeResult result, const char *path)
{
    const HorosDICOMProbe::Result probe = HorosDICOMProbe::inspect(path);
    const bool privateSyntax = !probe.recognized && !probe.transferSyntax.empty() &&
        probe.transferSyntax.find("1.2.840.10008.") != 0;
    return result.recognized == probe.recognized && result.compressed == probe.compressed &&
        result.image == probe.image && result.mayTranscode == probe.mayTranscode &&
        result.privateTransferSyntax == privateSyntax;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        for (NSString *name in @[@"native.dcm", @"jpeg.dcm", @"private.dcm", @"text.dcm"]) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            IsiXDCMTKFileProbeResult result = [IsiXDCMTKFileProbe inspectFileAtPath:path];
            check(same(result, path.fileSystemRepresentation), [[@"the adapter answers what the probe found: " stringByAppendingString:name] UTF8String]);
        }
        NSError *error = nil;
        IsiXDCMTKFileProbeResult native = [IsiXDCMTKFileProbe inspectFileAtPath:[folder stringByAppendingPathComponent:@"native.dcm"] error:&error];
        check(native.recognized && native.image && native.mayTranscode && !native.compressed && error == nil,
              "a native image is DICOM, with pixels it may transcode, and no error");
        IsiXDCMTKFileProbeResult jpeg = [IsiXDCMTKFileProbe inspectFileAtPath:[folder stringByAppendingPathComponent:@"jpeg.dcm"]];
        check(jpeg.recognized && jpeg.compressed, "a JPEG one is compressed");
        IsiXDCMTKFileProbeResult wrapped = [IsiXDCMTKFileProbe inspectFileAtPath:[folder stringByAppendingPathComponent:@"private.dcm"]];
        check(!wrapped.recognized && wrapped.privateTransferSyntax, "an envelope with a private syntax asks for the fallback");

        // A DCMTK error: a file that is not DICOM.
        error = nil;
        IsiXDCMTKFileProbeResult text = [IsiXDCMTKFileProbe inspectFileAtPath:[folder stringByAppendingPathComponent:@"text.dcm"] error:&error];
        check(!text.recognized && !text.privateTransferSyntax && [error.domain isEqualToString:IsiXDCMTKErrorDomain] &&
              error.code == IsiXDCMTKErrorCodeFailure && [error.localizedDescription hasPrefix:@"not a DICOM file: "],
              "a file that is not DICOM is an NSError with what DCMTK said");
        printf("  %s\n", error.localizedDescription.UTF8String);

        // Paths DCMTK never sees.
        unichar invalid[] = {0xd800};
        for (NSString *path in @[@"", [NSString stringWithCharacters:invalid length:1]]) {
            error = nil;
            IsiXDCMTKFileProbeResult refused = [IsiXDCMTKFileProbe inspectFileAtPath:path error:&error];
            check(!refused.recognized && error.code == IsiXDCMTKErrorCodeFailure, "an unusable path is refused before DCMTK");
        }
        error = nil;
        check(![IsiXDCMTKFileProbe inspectFileAtPath:nil error:&error].recognized && error != nil, "so is nil");

        // A C++ exception while DCMTK reads.
        error = nil;
        NSString *path = [folder stringByAppendingPathComponent:@"native.dcm"];
        const char *fileSystemPath = path.fileSystemRepresentation;
        (void) fileSystemPath;
        failNew = true;
        IsiXDCMTKFileProbeResult thrown = [IsiXDCMTKFileProbe inspectFileAtPath:path error:&error];
        failNew = false;
        check(!thrown.recognized && [error.domain isEqualToString:IsiXDCMTKErrorDomain] &&
              ([error.localizedDescription containsString:@"DICOM probe failed"] || error.code == IsiXDCMTKErrorCodeException),
              "std::bad_alloc inside DCMTK is an NSError, not a terminated process");
        printf("  %s\n", error.localizedDescription.UTF8String);
        check([IsiXDCMTKFileProbe inspectFileAtPath:path].recognized, "and the next probe reads the file again");
    }
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='isix-dcmtk-probe-') as folder:
    work = Path(folder)
    (work / 'native.dcm').write_bytes(dicom('1.2.840.10008.1.2.1'))
    pixels = (element((0x7FE0, 0x10), 'OB', b'')[:-4] + struct.pack('<I', 0xFFFFFFFF)
              + struct.pack('<HHI', 0xFFFE, 0xE000, 0) + struct.pack('<HHI', 0xFFFE, 0xE000, 4) + b'abcd'
              + struct.pack('<HHI', 0xFFFE, 0xE0DD, 0))
    (work / 'jpeg.dcm').write_bytes(dicom('1.2.840.10008.1.2.4.50', pixels=False) + pixels)
    (work / 'private.dcm').write_bytes(b'\0' * 128 + b'DICM' + element((2, 0x10), 'UI', uid('9.8.7.6.5'))
                                       + element((8, 0x16), 'UI', b'not-a-uid\0'))
    (work / 'text.dcm').write_text('arbitrary text, not DICOM')
    (work / 'driver.mm').write_text(DRIVER)
    binary = work / 'driver'
    built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-x', 'objective-c++',
                            str(work / 'driver.mm'), str(ADAPTER / 'IsiXDCMTKFileProbe.mm'),
                            str(ADAPTER / 'IsiXDCMTKError.mm'), '-x', 'none', '-I' + str(ADAPTER), *flags,
                            '-framework', 'Foundation', '-o', str(binary)], capture_output=True, text=True)
    if built.returncode:
        print('FAIL: the adapter does not compile with the driver:\n' + built.stderr[-4000:])
        raise SystemExit(1)
    run = subprocess.run([str(binary), str(work)], capture_output=True, text=True, timeout=60)
    print(run.stdout, end='')
    if run.returncode:
        print('FAIL: the driver exited with %d\n%s' % (run.returncode, run.stderr[-2000:]))
        raise SystemExit(1)
print('PASS: the DICOM probe through the DCMTK adapter answers as before; a DCMTK refusal and a C++ exception are NSErrors')
