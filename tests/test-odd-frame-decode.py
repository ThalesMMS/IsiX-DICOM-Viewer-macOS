#!/usr/bin/env python3
"""An encapsulated frame of an odd number of bytes decodes.

DCMTK decodes a frame only into a buffer of an even number of bytes, one more
than the frame when the frame is odd - an eight-bit image whose rows times
columns (times three, in colour) is odd. Handed a buffer of the frame's own
size it refuses the frame before any codec runs, and the viewer showed such an
image empty: a radiograph of 2505 by 3015 in JPEG Baseline, where one of 2000
by 2510 opened.

The driver builds small images with the host's DCMTK - grey 7 by 5, the same
in two frames, colour 3 by 3, and grey 8 by 6 whose frame is even - writes each
in JPEG Baseline, JPEG Lossless, JPEG-LS, JPEG 2000 and RLE, and reads them
back with the reader DCMPix uses. Every frame must come back with rows times
columns times samples bytes, and the pixels it was built from: exactly in the
lossless syntaxes, closely in JPEG Baseline.

Usage: python test-odd-frame-decode.py PRODUCTS_DIR
       PRODUCTS_DIR is build/Build/Products/Debug, of a build that left its DCMTK
"""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from horos_reader import compile_reader, missing

if len(sys.argv) < 2:
    print('skipped: needs the dataset model and DCMTK of the Debug build: PRODUCTS_DIR', file=sys.stderr)
    raise SystemExit(2)
products = Path(sys.argv[1]).resolve()
why = missing(products)
if why:
    print('skipped: %s: PRODUCTS_DIR' % why, file=sys.stderr)
    raise SystemExit(2)

program = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import "HorosDCMTKObject.h"
#undef verify
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include "HorosDICOMRepresentation.h"
#include <vector>
extern "C" void HorosTestRegisterDecoders(void);

struct Shape { const char *name; Uint16 columns, rows, samples; int frames; };
struct Syntax { const char *name; E_TransferSyntax xfer; int tolerance; };

static std::vector<Uint8> picture(const Shape &shape)
{
    // A smooth ramp, so that JPEG Baseline stays close to it; each frame and
    // each sample differs, so that a frame or a plane taken for another shows.
    std::vector<Uint8> pixels;
    for (int f = 0; f < shape.frames; f++)
        for (int y = 0; y < shape.rows; y++)
            for (int x = 0; x < shape.columns; x++)
                for (int s = 0; s < shape.samples; s++)
                    pixels.push_back((Uint8) (40 + 12 * x + 9 * y + 30 * s + 25 * f));
    return pixels;
}

static BOOL write(const Shape &shape, const Syntax &syntax, const std::vector<Uint8> &pixels, NSString *path)
{
    DcmFileFormat file;
    DcmDataset *dataset = file.getDataset();
    char uid[100];
    dataset->putAndInsertString(DCM_SOPClassUID, UID_SecondaryCaptureImageStorage);
    dataset->putAndInsertString(DCM_SOPInstanceUID, dcmGenerateUniqueIdentifier(uid, SITE_INSTANCE_UID_ROOT));
    dataset->putAndInsertString(DCM_StudyInstanceUID, dcmGenerateUniqueIdentifier(uid, SITE_STUDY_UID_ROOT));
    dataset->putAndInsertString(DCM_SeriesInstanceUID, dcmGenerateUniqueIdentifier(uid, SITE_SERIES_UID_ROOT));
    dataset->putAndInsertString(DCM_Modality, "OT");
    dataset->putAndInsertUint16(DCM_Rows, shape.rows);
    dataset->putAndInsertUint16(DCM_Columns, shape.columns);
    dataset->putAndInsertUint16(DCM_SamplesPerPixel, shape.samples);
    dataset->putAndInsertString(DCM_PhotometricInterpretation, shape.samples == 3 ? "RGB" : "MONOCHROME2");
    if (shape.samples == 3) dataset->putAndInsertUint16(DCM_PlanarConfiguration, 0);
    if (shape.frames > 1) dataset->putAndInsertString(DCM_NumberOfFrames, [[NSString stringWithFormat: @"%d", shape.frames] UTF8String]);
    dataset->putAndInsertUint16(DCM_BitsAllocated, 8);
    dataset->putAndInsertUint16(DCM_BitsStored, 8);
    dataset->putAndInsertUint16(DCM_HighBit, 7);
    dataset->putAndInsertUint16(DCM_PixelRepresentation, 0);
    if (dataset->putAndInsertUint8Array(DCM_PixelData, pixels.data(), (unsigned long) pixels.size()).bad()) return NO;

    DJ_RPLossy lossy(95);
    DJ_RPLossless lossless;
    const DcmRepresentationParameter *parameters = syntax.xfer == EXS_JPEGProcess1 ? (const DcmRepresentationParameter *) &lossy
        : (syntax.xfer == EXS_JPEGProcess14SV1 ? (const DcmRepresentationParameter *) &lossless : NULL);
    OFCondition result = HorosChooseDICOMRepresentation(file, syntax.xfer, parameters, syntax.xfer == EXS_JPEGProcess1 ? 1 : 0);
    if (result.good()) result = file.saveFile(path.fileSystemRepresentation, syntax.xfer);
    if (result.bad()) fprintf(stderr, "%s %s not written: %s\n", shape.name, syntax.name, result.text());
    return result.good();
}

int main(int argc, char **argv) { @autoreleasepool {
    HorosTestRegisterDecoders();
    NSString *folder = [NSString stringWithUTF8String: argv[1]];
    const Shape shapes[] = { {"grey-7x5", 7, 5, 1, 1}, {"grey-7x5-two-frames", 7, 5, 1, 2},
                             {"colour-3x3", 3, 3, 3, 1}, {"grey-8x6-even", 8, 6, 1, 1} };
    const Syntax syntaxes[] = { {"jpeg-baseline", EXS_JPEGProcess1, 6}, {"jpeg-lossless", EXS_JPEGProcess14SV1, 0},
                                {"jpeg-ls", EXS_JPEGLSLossless, 0}, {"jpeg-2000", EXS_JPEG2000LosslessOnly, 0},
                                {"rle", EXS_RLELossless, 0} };
    int failures = 0, frames = 0;
    for (const Shape &shape : shapes) for (const Syntax &syntax : syntaxes)
    {
        // The colour of a lossy JPEG is another question (YBR, by the stream's
        // own markers), and the JPEG-LS encoder takes no RGB; the size of the
        // frame is the same as in the syntaxes that are tried.
        if (shape.samples == 3 && (syntax.xfer == EXS_JPEGProcess1 || syntax.xfer == EXS_JPEGLSLossless)) continue;
        const std::vector<Uint8> pixels = picture(shape);
        NSString *path = [folder stringByAppendingPathComponent: [NSString stringWithFormat: @"%s-%s.dcm", shape.name, syntax.name]];
        if (!write(shape, syntax, pixels, path)) { failures++; continue; }
        DCMObject *object = [HorosDCMTKObject objectWithContentsOfFile: path];
        DCMPixelDataAttribute *attribute = (DCMPixelDataAttribute *) [object attributeWithName: @"PixelData"];
        const NSUInteger frameSize = (NSUInteger) shape.rows * shape.columns * shape.samples;
        for (int f = 0; f < shape.frames; f++)
        {
            NSData *frame = [attribute decodeFrameAtIndex: f];
            frames++;
            if (frame.length != frameSize)
            {
                printf("FAIL: %s %s frame %d: %lu bytes, %lu expected\n", shape.name, syntax.name, f,
                       (unsigned long) frame.length, (unsigned long) frameSize);
                failures++;
                continue;
            }
            const Uint8 *decoded = (const Uint8 *) frame.bytes;
            // DCMTK's lossy encoder stores a grey image from its lowest value
            // (the stream itself holds the shifted samples): the picture is
            // compared from its own lowest value too. Lossless is compared as is.
            int shift = 0;
            if (syntax.tolerance)
            {
                int lowest = 255, lowestDecoded = 255;
                for (NSUInteger i = 0; i < frameSize; i++)
                {
                    lowest = MIN(lowest, (int) pixels[f * frameSize + i]);
                    lowestDecoded = MIN(lowestDecoded, (int) decoded[i]);
                }
                shift = lowest - lowestDecoded;
            }
            int worst = 0;
            for (NSUInteger i = 0; i < frameSize; i++)
                worst = MAX(worst, abs((int) decoded[i] + shift - (int) pixels[f * frameSize + i]));
            if (worst > syntax.tolerance)
            {
                printf("FAIL: %s %s frame %d differs by %d, at most %d allowed\n", shape.name, syntax.name, f, worst, syntax.tolerance);
                failures++;
            }
        }
    }
    printf("%d frames, %d failures\n", frames, failures);
    return failures ? 1 : 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-odd-frame-') as tmp:
    work = Path(tmp)
    (work / 'bin').mkdir()
    (work / 'files').mkdir()
    (work / 'Frameworks').symlink_to(products)
    (work / 'read.m').write_text(program)
    compile_reader(products, work / 'read.m', work / 'bin/read', work)
    result = subprocess.run([str(work / 'bin/read'), str(work / 'files')], capture_output=True, text=True, timeout=120)
    report = [line for line in result.stdout.splitlines() if line.startswith('FAIL') or line.endswith('failures')]
    print('\n'.join(report))
    if result.returncode:
        print(result.stderr[-2000:], file=sys.stderr)
        raise SystemExit('FAIL: frames of an odd number of bytes do not decode to the pixels written')
print('PASS: grey, two-frame and colour images of odd size decode in JPEG Baseline, JPEG Lossless, JPEG-LS, JPEG 2000 and RLE')
