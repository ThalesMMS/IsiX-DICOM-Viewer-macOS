#!/usr/bin/env python3
"""The VTK adapter of libtiff turns libtiff's refusals and C++ exceptions into NSError.

Horos/Sources/Adapters/VTK/IsiXVTKTIFF is the only Objective-C++ through which
the import (DicomFile, now Swift) reaches the libtiff VTK builds with: whether a
file opens, its pages and their largest size, and the Olympus FluoView header.
Its header carries no C++ type; every call into libtiff runs inside a guard.

The adapter is compiled here with IsiXVTKFluoView.mm (the FluoView tags,
header and description) and IsiXVTKError.mm against the libtiff headers and
library and the VTK of the Debug build (exit 2 without that build), with a
driver that:
- reads a two-page TIFF and a FluoView TIFF written here byte by byte;
- provokes a libtiff error: a file that is not a TIFF is an NSError of
  IsiXVTKErrorDomain (CannotOpen), and a TIFF without the FluoView header is
  NoFluoViewHeader;
- provokes a C++ exception: an error handler that throws, installed in libtiff
  the way a host may install one, is called by libtiff for a damaged file; the
  exception crosses libtiff and comes back as an NSError (Exception, with the
  exception's text) instead of terminating the process.

The FluoView reading came from FVTiff.m: the former file, read from the
history, is built in a second driver that prints the XML of the description
and the header's dimensions for the same files, and the adapter must print the
same. A description line longer than the former 255-character buffer is left
out of that comparison: it overran the buffer, as did a shorter one after a
block's end line, which moved the former copy one character further into it.
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT  # noqa: E402
import history_reference  # noqa: E402

ADAPTER = ROOT / 'Horos/Sources/Adapters/VTK'
TIFF = BUILD / 'ExternalInputs.build/Install'
VTK = BUILD / 'VTK.build/Install/include'
VTK_LIBRARY = BUILD / 'VTK.build/Install/wlib/libVTK.a'
missing = [p for p in (TIFF / 'include/tiffio.h', TIFF / 'lib/libtiff.dylib', VTK / 'vtk_tiff.h', VTK_LIBRARY)
           if not p.exists()]
if missing:
    print('skipped: needs a current build from script/build_and_run.sh --verify: %s' % missing[0])
    raise SystemExit(2)


def tiff(pages, extra=()):
    """A little-endian TIFF of 8-bit grey `pages` [(width, height)], the first
    directory with the `extra` [(tag, type, count, bytes)] entries."""
    data = bytearray(b'II*\0' + struct.pack('<I', 0))
    offsets = []
    for index, (width, height) in enumerate(pages):
        pixels = bytes((x + y) % 256 for y in range(height) for x in range(width))
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


def fluoview_header(dimensions):
    """An Olympus MM header: 284 bytes, then ten dimensions of 104 bytes (name,
    size, origin, resolution)."""
    header = bytearray(284 + 10 * 104 + 132)
    for index, (name, size, *place) in enumerate(dimensions):
        at = 284 + 104 * index
        header[at:at + len(name)] = name.encode()
        struct.pack_into('<I', header, at + 16, size)
        if place:
            struct.pack_into('<dd', header, at + 20, *place)
    return bytes(header)


DESCRIPTION = (b'[Acquisition Parameters]\r\nDate=02/29/2024\r\nTime=12:34:56\r\n[Acquisition Parameters End]\r\n'
               b'[Description]\r\nA synthetic FluoView file\r\n[Description End]\r\n\0')

# Lines of descriptions both readings must turn into the same XML: blocks,
# values, comments, an empty value, a block left open at the end, CR, LF and
# CRLF ends, a lone "[End]" line and a long line the former buffer still held
# after one block's end line (252 characters).
DESCRIPTIONS = [
    DESCRIPTION,
    b'[A End]\n[Block]\nKey=Value=More\nKey2=\nPlain comment\n[Block End]\rTrailing=1\n\0',
    b'[End]\n[X]\n' + b'L=' + b'v' * 250 + b'\n[X End]\n[Open]\nNever=closed\n\0',
    b'NoNewlineAtAll\0',
]

FORMER_DRIVER = r'''
#import <Foundation/Foundation.h>
#include "FVTiff.h"
int main(int argc, char **argv)
{
    @autoreleasepool {
        FVTIFFInitialize();
        for (int i = 1; i < argc; i++) {
            NSString *path = [NSString stringWithUTF8String:argv[i]];
            NSXMLDocument *xml = XML_from_FVTiff(path);
            printf("%s\n", [[xml XMLStringWithOptions:NSXMLNodePrettyPrint] UTF8String]);
            [xml release];
            TIFF *tif = TIFFOpen(argv[i], "r");
            short size = 0;
            char *data = 0;
            if (tif && TIFFGetField(tif, TIFFTAG_FV_MMHEADER, &size, &data)) {
                FV_MM_HEAD head;
                FV_Read_MM_HEAD(data, &head);
                for (int d = 0; d < FV_SPATIAL_DIMENSION; d++)
                    printf("%s %d %u %.17g %.17g\n", head.DimInfo[d].Name, head.DimInfo[d].Name[0], head.DimInfo[d].Size,
                           head.DimInfo[d].Origin, head.DimInfo[d].Resolution);
            } else printf("no header\n");
            if (tif) TIFFClose(tif);
        }
    }
    return 0;
}
'''

ADAPTER_DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXVTKTIFF.h"
int main(int argc, char **argv)
{
    @autoreleasepool {
        [IsiXVTKTIFF registerFluoViewTags];
        for (int i = 1; i < argc; i++) {
            NSString *path = [NSString stringWithUTF8String:argv[i]];
            NSXMLDocument *xml = [IsiXVTKTIFF fluoViewXMLOfFileAtPath:path];
            printf("%s\n", [[xml XMLStringWithOptions:NSXMLNodePrettyPrint] UTF8String]);
            IsiXVTKFluoViewHeader *header = [IsiXVTKTIFF fluoViewHeaderOfFileAtPath:path error:NULL];
            if (header) {
                for (IsiXVTKFluoViewDimension *d in header.dimensions)
                    printf("%s %d %lu %.17g %.17g\n", d.name.UTF8String, d.initial, (unsigned long)d.size, d.origin, d.resolution);
            } else printf("no header\n");
        }
    }
    return 0;
}
'''

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXVTKTIFF.h"
#include "IsiXVTKFluoView.hpp"
#import "IsiXVTKInternal.hpp"
#include <stdexcept>
#include <string>
#include <cstdio>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

static void throwingHandler(const char *module, const char *format, va_list arguments)
{
    char text[512];
    vsnprintf(text, sizeof(text), format, arguments);
    throw std::runtime_error(std::string("libtiff: ") + text);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        [IsiXVTKTIFF registerFluoViewTags];
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSString *pages = [folder stringByAppendingPathComponent:@"pages.tif"];
        NSString *fluoview = [folder stringByAppendingPathComponent:@"fluoview.tif"];
        NSString *text = [folder stringByAppendingPathComponent:@"text.tif"];
        NSString *damaged = [folder stringByAppendingPathComponent:@"damaged.tif"];

        check([IsiXVTKTIFF opensFileAtPath:pages], "a TIFF opens");
        NSError *error = nil;
        IsiXVTKTIFFPages *read = [IsiXVTKTIFF pagesOfFileAtPath:pages error:&error];
        check(read && !error && read.count == 2 && read.width == 7 && read.height == 9,
              "its two pages are counted, with the largest width and height");
        check(![IsiXVTKTIFF hasFluoViewHeaderAtPath:pages], "a plain TIFF has no FluoView header");
        error = nil;
        check([IsiXVTKTIFF fluoViewHeaderOfFileAtPath:pages error:&error] == nil &&
              [error.domain isEqualToString:IsiXVTKErrorDomain] && error.code == IsiXVTKErrorCodeNoFluoViewHeader,
              "asking it for one is NoFluoViewHeader");

        check([IsiXVTKTIFF hasFluoViewHeaderAtPath:fluoview], "a FluoView TIFF has its header");
        error = nil;
        IsiXVTKFluoViewHeader *header = [IsiXVTKTIFF fluoViewHeaderOfFileAtPath:fluoview error:&error];
        check(header && !error && header.dimensions.count == 10 && header.width == 6 && header.height == 4,
              "its header gives ten dimensions and the first page's size");
        check([header.dimensions[2].name isEqualToString:@"Z"] && header.dimensions[2].size == 3 &&
              [header.dimensions[3].name isEqualToString:@"Ch"] && header.dimensions[3].size == 2 &&
              header.dimensions[3].initial == 'C' && header.dimensions[2].origin == 1.5 &&
              header.dimensions[2].resolution == 2.25,
              "each dimension has its name, initial, size, origin and resolution");
        NSXMLDocument *xml = [IsiXVTKTIFF fluoViewXMLOfFileAtPath:fluoview];
        check([[[xml.rootElement elementsForName:@"Acquisition Parameters"].firstObject elementsForName:@"Date"].firstObject
                  .stringValue isEqualToString:@"02/29/2024"], "its description is the XML of the metadata window");

        // A libtiff error: a file that is not a TIFF.
        check(![IsiXVTKTIFF opensFileAtPath:text], "a file that is not a TIFF does not open");
        error = nil;
        check([IsiXVTKTIFF pagesOfFileAtPath:text error:&error] == nil &&
              [error.domain isEqualToString:IsiXVTKErrorDomain] && error.code == IsiXVTKErrorCodeCannotOpen &&
              [error.userInfo[NSFilePathErrorKey] isEqualToString:text],
              "libtiff's refusal is CannotOpen, with the path");

        // A C++ exception: libtiff calls the process's error handler, which throws.
        TIFFErrorHandler previous = TIFFSetErrorHandler(throwingHandler);
        error = nil;
        IsiXVTKTIFFPages *thrown = [IsiXVTKTIFF pagesOfFileAtPath:damaged error:&error];
        check(thrown == nil && [error.domain isEqualToString:IsiXVTKErrorDomain] &&
              error.code == IsiXVTKErrorCodeException &&
              [error.userInfo[IsiXVTKMessageKey] hasPrefix:@"libtiff: "] &&
              [error.userInfo[NSFilePathErrorKey] isEqualToString:damaged],
              "an exception out of libtiff is an NSError, not a terminated process");
        printf("  %s\n", [error.userInfo[IsiXVTKMessageKey] UTF8String]);
        check(![IsiXVTKTIFF opensFileAtPath:text] && ![IsiXVTKTIFF hasFluoViewHeaderAtPath:text],
              "the calls without an error give NO for it");
        TIFFSetErrorHandler(previous);
        check([IsiXVTKTIFF opensFileAtPath:pages], "and the adapter keeps working afterwards");
    }
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='isix-vtk-tiff-') as folder:
    work = Path(folder)
    (work / 'pages.tif').write_bytes(tiff([(5, 9), (7, 3)]))
    fluoview = fluoview_header([('X', 6, 0.0, 0.5), ('Y', 4, -1.0, 0.75), ('Z', 3, 1.5, 2.25), ('Ch', 2)])
    (work / 'fluoview.tif').write_bytes(tiff([(6, 4)], [(270, 2, len(DESCRIPTION), DESCRIPTION),
                                                        (34361, 1, len(fluoview), fluoview)]))
    (work / 'text.tif').write_text('not a TIFF at all')
    # A header whose first directory lies past the end of the file.
    (work / 'damaged.tif').write_bytes(b'II*\0' + struct.pack('<I', 1 << 20) + b'\0' * 16)
    (work / 'driver.mm').write_text(DRIVER)
    binary = work / 'driver'
    def link(driver, output):
        """The adapter, compiled with ARC as the app builds it, and `driver`."""
        (work / (output + '.mm')).write_text(driver)
        built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-x', 'objective-c++',
                                str(work / (output + '.mm')), str(ADAPTER / 'IsiXVTKTIFF.mm'),
                                str(ADAPTER / 'IsiXVTKFluoView.mm'), str(ADAPTER / 'IsiXVTKError.mm'), '-x', 'none',
                                '-I' + str(ADAPTER), '-I' + str(ROOT / 'Horos/Sources'), '-I' + str(VTK),
                                '-I' + str(TIFF / 'include'), str(VTK_LIBRARY), '-L' + str(TIFF / 'lib'), '-ltiff',
                                '-Wl,-rpath,' + str(TIFF / 'lib'), '-framework', 'Foundation', '-o', str(work / output)],
                               capture_output=True, text=True)
        if built.returncode:
            print('FAIL: the adapter does not compile with the driver:\n' + built.stderr[-4000:])
            raise SystemExit(1)
        return work / output

    link(DRIVER, 'driver')
    run = subprocess.run([str(binary), str(work)], capture_output=True, text=True, timeout=60)
    print(run.stdout, end='')
    if run.returncode:
        print('FAIL: the driver exited with %d\n%s' % (run.returncode, run.stderr[-2000:]))
        raise SystemExit(1)

    # The FluoView reading against the former FVTiff.m, from the history.
    former = (history_reference.before_removal_no_renames('Horos/Sources/FVTiff.m')
              or ('HEAD' if history_reference.show('HEAD', 'Horos/Sources/FVTiff.m') else None))
    if former is None:
        print('skipped: the history does not reach FVTiff.m')
        raise SystemExit(2)
    (work / 'FVTiff.m').write_bytes(history_reference.show(former, 'Horos/Sources/FVTiff.m'))
    (work / 'FVTiff.h').write_bytes(history_reference.show(former, 'Horos/Sources/FVTiff.h'))
    (work / 'former.m').write_text(FORMER_DRIVER)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', str(work / 'former.m'), str(work / 'FVTiff.m'),
                            '-I' + str(work), '-I' + str(ROOT / 'Horos/Sources'), '-I' + str(VTK),
                            '-I' + str(TIFF / 'include'), '-L' + str(TIFF / 'lib'), '-ltiff',
                            '-Wl,-rpath,' + str(TIFF / 'lib'), '-framework', 'Foundation', '-o', str(work / 'former')],
                           capture_output=True, text=True)
    if built.returncode:
        print('FAIL: the former FVTiff.m does not compile:\n' + built.stderr[-4000:])
        raise SystemExit(1)
    adapter = link(ADAPTER_DRIVER, 'reading')
    files = [str(work / 'fluoview.tif'), str(work / 'pages.tif')]
    for index, text in enumerate(DESCRIPTIONS):
        path = work / ('description-%d.tif' % index)
        path.write_bytes(tiff([(2, 2)], [(270, 2, len(text), text), (34361, 1, len(fluoview), fluoview)]))
        files.append(str(path))
    outputs = [subprocess.run([str(binary), *files], capture_output=True, text=True, timeout=60)
               for binary in (work / 'former', adapter)]
    for output in outputs:
        if output.returncode:
            print('FAIL: a reading driver exited with %d\n%s' % (output.returncode, output.stderr[-2000:]))
            raise SystemExit(1)
    if outputs[0].stdout != outputs[1].stdout:
        print('FAIL: the adapter reads FluoView files differently from FVTiff.m (%s)' % former)
        print('former:\n' + outputs[0].stdout + '\nadapter:\n' + outputs[1].stdout)
        raise SystemExit(1)
    print('PASS: the XML and the header of %d files are those of FVTiff.m (%s)' % (len(files), former[:12]))
print('PASS: libtiff through the VTK adapter: pages, FluoView header and XML; a refusal and a C++ exception are NSErrors')
