#!/usr/bin/env python3
"""The host's DCMTK JPEG 2000 codec round-trips pixels exactly and fails safely.

Compiles Horos/Sources/HorosJPEG2000Codec.cpp with the DCMTK and OpenJPEG
archives of a current build, then, through DcmDataset::chooseRepresentation:

- encodes native 8/16-bit, signed and unsigned, mono and RGB (both planar
  configurations), single and multiframe pixels to .90 and back, identical;
- decodes single frames through getUncompressedFrame;
- encodes .91 with a lossy quality and records the compression attributes;
- decodes a codestream in a JP2 wrapper, which the DCM Framework wrote;
- leaves the dataset as it was when a codestream is invalid (#362).

With --python pointing to an interpreter that has pydicom and
pylibjpeg-openjpeg (for example local-validation/fixture-venv/bin/python),
the encoded files are also decoded by that independent implementation.
"""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT, dcmtk_flags

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--python', type=Path, help='interpreter with pydicom and pylibjpeg-openjpeg')
args = parser.parse_args()

openjpeg = BUILD / 'OpenJPEG.build/Install'
if not (openjpeg / 'lib/libopenjp2.a').is_file():
    print('skipped: needs OpenJPEG from a current build of script/build_and_run.sh --verify')
    raise SystemExit(2)
flags = dcmtk_flags()

driver = r'''
#include "HorosJPEG2000Codec.h"
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcpixel.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <OpenJPEG/openjpeg.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int failures = 0;
#define CHECK(condition, what) do { if (!(condition)) { std::printf("FAIL: %s: %s\n", name.c_str(), what); ++failures; return; } } while (0)

struct Case { int bits; bool isSigned; int spp; int planar; int frames; };

static void describe(DcmDataset* d, const Case& c, int rows, int columns)
{
    d->putAndInsertString(DCM_SOPClassUID, UID_SecondaryCaptureImageStorage);
    char uid[100]; d->putAndInsertString(DCM_SOPInstanceUID, dcmGenerateUniqueIdentifier(uid));
    d->putAndInsertUint16(DCM_Rows, rows);
    d->putAndInsertUint16(DCM_Columns, columns);
    d->putAndInsertUint16(DCM_SamplesPerPixel, c.spp);
    d->putAndInsertString(DCM_PhotometricInterpretation, c.spp == 1 ? "MONOCHROME2" : "RGB");
    if (c.spp == 3) d->putAndInsertUint16(DCM_PlanarConfiguration, c.planar);
    d->putAndInsertUint16(DCM_BitsAllocated, c.bits > 8 ? 16 : 8);
    d->putAndInsertUint16(DCM_BitsStored, c.bits);
    d->putAndInsertUint16(DCM_HighBit, c.bits - 1);
    d->putAndInsertUint16(DCM_PixelRepresentation, c.isSigned ? 1 : 0);
    if (c.frames > 1) d->putAndInsertString(DCM_NumberOfFrames, std::to_string(c.frames).c_str());
}

// Samples in file order, and the same samples interleaved (what decoding yields).
static void pixels(const Case& c, int rows, int columns, std::vector<long>& stored, std::vector<long>& interleaved)
{
    const long n = long(rows) * columns;
    for (int f = 0; f < c.frames; ++f)
        for (long i = 0; i < n; ++i)
            for (int s = 0; s < c.spp; ++s) {
                long v = (i * 37 + s * 91 + f * 53 + (i / columns) * 11) % (1L << c.bits);
                if (c.isSigned) v -= 1L << (c.bits - 1);
                interleaved.push_back(v);
            }
    stored = interleaved;
    if (c.planar == 1 && c.spp == 3)
        for (int f = 0; f < c.frames; ++f)
            for (long i = 0; i < n; ++i)
                for (int s = 0; s < 3; ++s)
                    stored[f * n * 3 + s * n + i] = interleaved[f * n * 3 + i * 3 + s];
}

static void putPixels(DcmDataset* d, const Case& c, const std::vector<long>& samples)
{
    if (c.bits > 8) {
        std::vector<Uint16> words; for (long v : samples) words.push_back(Uint16(v));
        d->putAndInsertUint16Array(DCM_PixelData, words.data(), Uint32(words.size()));
    } else {
        std::vector<Uint8> bytes; for (long v : samples) bytes.push_back(Uint8(v));
        d->putAndInsertUint8Array(DCM_PixelData, bytes.data(), Uint32(bytes.size()));
    }
}

static bool samePixels(DcmDataset* d, const Case& c, const std::vector<long>& expected)
{
    const Uint16 words = c.bits > 8;
    const void* data = NULL;
    if (words) { const Uint16* w = NULL; if (d->findAndGetUint16Array(DCM_PixelData, w).bad()) return false; data = w; }
    else { const Uint8* b = NULL; if (d->findAndGetUint8Array(DCM_PixelData, b).bad()) return false; data = b; }
    for (size_t i = 0; i < expected.size(); ++i) {
        long v = words ? long(static_cast<const Uint16*>(data)[i]) : long(static_cast<const Uint8*>(data)[i]);
        long e = words ? long(Uint16(expected[i])) : long(Uint8(expected[i]));
        if (v != e) { std::printf("  sample %zu: %ld != %ld\n", i, v, e); return false; }
    }
    return true;
}

static void roundTrip(const Case& c, const std::string& directory)
{
    const int rows = 24, columns = 20;
    std::string name = std::to_string(c.bits) + (c.isSigned ? "s" : "u") + "-spp" + std::to_string(c.spp) +
        "-pc" + std::to_string(c.planar) + "-f" + std::to_string(c.frames);
    std::vector<long> stored, interleaved;
    pixels(c, rows, columns, stored, interleaved);
    DcmFileFormat file;
    DcmDataset* d = file.getDataset();
    describe(d, c, rows, columns);
    putPixels(d, c, stored);
    HorosJPEG2000RepresentationParameter lossless(0);
    CHECK(d->chooseRepresentation(EXS_JPEG2000LosslessOnly, &lossless).good(), "encode");
    CHECK(d->canWriteXfer(EXS_JPEG2000LosslessOnly), "encoded representation");
    const std::string path = directory + "/" + name + ".dcm";
    CHECK(file.saveFile(path.c_str(), EXS_JPEG2000LosslessOnly).good(), "save");
    std::printf("file %s %d %d %d %d\n", path.c_str(), c.bits, c.isSigned, c.spp, c.frames);

    DcmFileFormat loaded;
    CHECK(loaded.loadFile(path.c_str()).good(), "load");
    DcmDataset* e = loaded.getDataset();
    CHECK(e->getOriginalXfer() == EXS_JPEG2000LosslessOnly, "stored syntax");
    DcmElement* element = NULL;
    CHECK(e->findAndGetElement(DCM_PixelData, element).good(), "pixel element");
    DcmPixelData* pixel = static_cast<DcmPixelData*>(element);
    DcmPixelSequence* sequence = NULL;
    CHECK(pixel->getEncapsulatedRepresentation(EXS_JPEG2000LosslessOnly, NULL, sequence).good() && sequence, "sequence");
    CHECK(sequence->card() == unsigned(c.frames + 1), "one fragment per frame and an offset table");

    // Frame access without decoding the whole object.
    const Uint32 frameBytes = rows * columns * c.spp * (c.bits > 8 ? 2 : 1);
    std::vector<Uint8> frame(frameBytes + 1);
    Uint32 fragment = 0; OFString model;
    const int last = c.frames - 1;
    CHECK(pixel->getUncompressedFrame(e, last, fragment, frame.data(), frameBytes, model).good(), "decode last frame");
    for (long i = 0; i < long(rows) * columns * c.spp; ++i) {
        long expected = interleaved[last * long(rows) * columns * c.spp + i];
        long value = c.bits > 8 ? long(reinterpret_cast<Uint16*>(frame.data())[i]) : long(frame[i]);
        CHECK(value == (c.bits > 8 ? long(Uint16(expected)) : long(Uint8(expected))), "frame samples");
    }

    CHECK(e->chooseRepresentation(EXS_LittleEndianExplicit, NULL).good(), "decode");
    CHECK(e->canWriteXfer(EXS_LittleEndianExplicit), "native representation");
    CHECK(samePixels(e, c, interleaved), "identical pixels");
    if (c.spp == 3) { Uint16 pc = 9; e->findAndGetUint16(DCM_PlanarConfiguration, pc); CHECK(pc == 0, "planar configuration 0"); }
    std::printf("ok %s\n", name.c_str());
}

static void lossy(const std::string& directory)
{
    std::string name = "lossy";
    Case c = {12, false, 1, 0, 1};
    const int rows = 64, columns = 64;
    std::vector<long> stored, interleaved;
    pixels(c, rows, columns, stored, interleaved);
    DcmFileFormat file;
    DcmDataset* d = file.getDataset();
    describe(d, c, rows, columns);
    putPixels(d, c, stored);
    HorosJPEG2000RepresentationParameter medium(2);
    CHECK(d->chooseRepresentation(EXS_JPEG2000, &medium).good(), "encode");
    OFString flag, ratio, method;
    d->findAndGetOFString(DCM_LossyImageCompression, flag);
    d->findAndGetOFString(DCM_LossyImageCompressionRatio, ratio);
    d->findAndGetOFString(DCM_LossyImageCompressionMethod, method);
    CHECK(flag == "01" && method == "ISO_15444_1" && atof(ratio.c_str()) > 1.0, "lossy attributes");
    const std::string path = directory + "/lossy.dcm";
    CHECK(file.saveFile(path.c_str(), EXS_JPEG2000).good(), "save");
    std::printf("lossyfile %s\n", path.c_str());
    DcmFileFormat loaded;
    CHECK(loaded.loadFile(path.c_str()).good(), "load");
    CHECK(loaded.getDataset()->chooseRepresentation(EXS_LittleEndianExplicit, NULL).good(), "decode");
    std::printf("ok lossy ratio %s\n", ratio.c_str());
}

static void encapsulate(DcmDataset* d, const std::vector<Uint8>& stream, E_TransferSyntax syntax)
{
    DcmPixelSequence* sequence = new DcmPixelSequence(DCM_PixelSequenceTag);
    sequence->insert(new DcmPixelItem(DCM_PixelItemTag));
    DcmOffsetList offsets;
    sequence->storeCompressedFrame(offsets, const_cast<Uint8*>(stream.data()), Uint32(stream.size()), 0);
    DcmPixelData* pixel = new DcmPixelData(DCM_PixelData);
    pixel->putOriginalRepresentation(syntax, NULL, sequence);
    d->insert(pixel, OFTrue);
}

static void jp2Wrapper(const std::string& directory)
{
    std::string name = "jp2";
    const int rows = 16, columns = 16;
    opj_image_cmptparm_t plane = {}; plane.dx = plane.dy = 1; plane.w = columns; plane.h = rows; plane.prec = 16;
    opj_image_t* image = opj_image_create(1, &plane, OPJ_CLRSPC_GRAY);
    image->x1 = columns; image->y1 = rows;
    for (int i = 0; i < rows * columns; ++i) image->comps[0].data[i] = i * 97;
    opj_cparameters_t p; opj_set_default_encoder_parameters(&p);
    p.tcp_numlayers = 1; p.tcp_rates[0] = 0; p.cp_disto_alloc = 1; p.numresolution = 3;
    opj_codec_t* codec = opj_create_compress(OPJ_CODEC_JP2);
    // The JP2 writer seeks back to size its boxes, so go through a file.
    const std::string path = directory + "/wrapped.jp2";
    opj_stream_t* out = opj_stream_create_default_file_stream(path.c_str(), OPJ_FALSE);
    bool encoded = out && opj_setup_encoder(codec, &p, image) && opj_start_compress(codec, image, out) &&
        opj_encode(codec, out) && opj_end_compress(codec, out);
    if (out) opj_stream_destroy(out);
    opj_destroy_codec(codec); opj_image_destroy(image);
    CHECK(encoded, "JP2 fixture");
    std::vector<Uint8> stream;
    if (FILE* in = std::fopen(path.c_str(), "rb")) {
        int byte; while ((byte = std::fgetc(in)) != EOF) stream.push_back(Uint8(byte));
        std::fclose(in);
    }
    CHECK(stream.size() > 12 && stream[4] == 0x6A, "JP2 signature box");
    if (stream.size() & 1) stream.push_back(0);

    DcmDataset d;
    Case c = {16, false, 1, 0, 1};
    describe(&d, c, rows, columns);
    encapsulate(&d, stream, EXS_JPEG2000LosslessOnly);
    CHECK(d.chooseRepresentation(EXS_LittleEndianExplicit, NULL).good(), "decode JP2");
    const Uint16* w = NULL;
    CHECK(d.findAndGetUint16Array(DCM_PixelData, w).good() && w, "pixels");
    for (int i = 0; i < rows * columns; ++i) CHECK(w[i] == Uint16(i * 97), "JP2 samples");
    std::printf("ok jp2\n");
}

static void invalid()
{
    std::string name = "invalid";
    DcmDataset d;
    Case c = {8, false, 1, 0, 1};
    describe(&d, c, 8, 8);
    std::vector<Uint8> garbage = {0xFF, 0x4F, 0xFF, 0x51, 0x00, 0x2F, 1, 2, 3, 4};
    encapsulate(&d, garbage, EXS_JPEG2000LosslessOnly);
    CHECK(d.chooseRepresentation(EXS_LittleEndianExplicit, NULL).bad(), "invalid stream rejected");
    CHECK(!d.canWriteXfer(EXS_LittleEndianExplicit), "no native representation");
    CHECK(d.canWriteXfer(EXS_JPEG2000LosslessOnly), "compressed pixels kept");
    std::printf("ok invalid\n");
}

int main(int argc, char** argv)
{
    HorosJPEG2000Registration::registerCodecs();
    HorosJPEG2000Registration::registerCodecs(); // idempotent
    const std::string directory = argv[1];
    const Case cases[] = {
        {8, false, 1, 0, 1}, {8, true, 1, 0, 1}, {12, false, 1, 0, 1}, {16, false, 1, 0, 1},
        {16, true, 1, 0, 1}, {12, true, 1, 0, 3}, {8, false, 3, 0, 1}, {8, false, 3, 1, 2},
        {16, false, 3, 0, 1},
    };
    for (const Case& c : cases) roundTrip(c, directory);
    lossy(directory);
    jp2Wrapper(directory);
    invalid();
    HorosJPEG2000Registration::cleanup();
    HorosJPEG2000Registration::cleanup();
    if (HorosJPEG2000RateForQuality(2, 512, 512) != 6 || HorosJPEG2000RateForQuality(2, 1024, 1024) != 8 ||
        HorosJPEG2000RateForQuality(0, 1, 1) != 0 || HorosJPEG2000RateForQuality(3, 1, 1) != 16) {
        std::printf("FAIL: rates\n"); ++failures;
    }
    return failures ? 1 : 0;
}
'''

independent = r'''
import sys
import numpy as np
import pydicom
for line in sys.stdin:
    kind, path, *rest = line.split()
    ds = pydicom.dcmread(path)
    array = ds.pixel_array
    if kind == 'file':
        bits, signed, spp, frames = map(int, rest)
        rows, columns = ds.Rows, ds.Columns
        n = rows * columns
        expected = []
        for f in range(frames):
            for i in range(n):
                for s in range(spp):
                    v = (i * 37 + s * 91 + f * 53 + (i // columns) * 11) % (1 << bits)
                    if signed: v -= 1 << (bits - 1)
                    expected.append(v)
        got = array.reshape(-1).astype(np.int64)
        if not np.array_equal(got, np.array(expected, dtype=np.int64)):
            print('FAIL: pydicom disagrees on', path); sys.exit(1)
    else:
        assert array.shape == (64, 64), array.shape
print('ok independent decoder')
'''

with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    (work / 'driver.cpp').write_text(driver)
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-g', '-fsanitize=address,undefined',
                    '-I' + str(openjpeg / 'include'), *flags[:2],
                    str(work / 'driver.cpp'), str(ROOT / 'Horos/Sources/HorosJPEG2000Codec.cpp'),
                    str(openjpeg / 'lib/libopenjp2.a'), *flags[2:], '-o', str(work / 'driver')], check=True)
    output = work / 'files'
    output.mkdir()
    result = subprocess.run([str(work / 'driver'), str(output)], capture_output=True, text=True)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr[-4000:], end='')
        raise SystemExit(1)
    if args.python:
        listing = '\n'.join(line.replace('lossyfile', 'lossy', 1) for line in result.stdout.splitlines()
                            if line.startswith(('file ', 'lossyfile ')))
        check = subprocess.run([str(args.python), '-c', independent], input=listing, text=True)
        if check.returncode:
            raise SystemExit(1)
print('PASS')
