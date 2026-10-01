#!/usr/bin/env python3
"""The host's DCMTK JPEG 2000 codec round-trips pixels exactly and fails safely.

Compiles Horos/Sources/HorosJPEG2000Codec.cpp with the DCMTK and OpenJPEG
archives of a current build, then, through DcmDataset::chooseRepresentation:

- encodes native 8/16-bit, signed and unsigned, mono and RGB (both planar
  configurations), single and multiframe pixels to .90 and back, identical;
- decodes single frames through getUncompressedFrame;
- encodes .91 with a lossy quality and records the compression attributes;
- decodes a codestream in a JP2 wrapper, which the DCM Framework wrote;
- leaves the dataset as it was when a codestream is invalid (#362);
- decodes High-Throughput JPEG 2000 (.201, .202 multiframe, .203 lossy, and
  YBR_RCT colour) to the samples it was made from (#1019). OpenJPEG does not
  encode HTJ2K, so the codestreams below were made once with the OpenJPH 0.32
  library (codestream::exchange of the signed or unsigned samples; three
  decompositions; reversible, or irreversible with step 0.0005 for .203; RPCL
  for .202; colour transform for RGB) from the same synthetic 16 x 16 samples
  the driver computes. The ojph_compress tool is not used for this: it does
  not sign-extend raw signed input.

An isolated current OpenJPEG build can be selected with --openjpeg-install
and its generated configuration headers with --openjpeg-config.

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
parser.add_argument('--openjpeg-install', type=Path, help='isolated OpenJPEG archive and headers for focused source validation')
parser.add_argument('--openjpeg-config', type=Path, help='generated OpenJPEG configuration headers for an isolated source build')
args = parser.parse_args()

openjpeg = args.openjpeg_install or BUILD / 'OpenJPEG.build/Install'
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

static std::vector<Uint8> readStream(const std::string& path)
{
    std::vector<Uint8> stream;
    if (FILE* in = std::fopen(path.c_str(), "rb")) {
        int byte; while ((byte = std::fgetc(in)) != EOF) stream.push_back(Uint8(byte));
        std::fclose(in);
    }
    if (stream.size() & 1) stream.push_back(0);
    return stream;
}

static void encapsulateFrames(DcmDataset* d, const std::vector<std::vector<Uint8> >& streams, E_TransferSyntax syntax)
{
    DcmPixelSequence* sequence = new DcmPixelSequence(DCM_PixelSequenceTag);
    DcmPixelItem* table = new DcmPixelItem(DCM_PixelItemTag);
    sequence->insert(table);
    DcmOffsetList offsets;
    for (const std::vector<Uint8>& stream : streams)
        sequence->storeCompressedFrame(offsets, const_cast<Uint8*>(stream.data()), Uint32(stream.size()), 0);
    table->createOffsetTable(offsets);
    DcmPixelData* pixel = new DcmPixelData(DCM_PixelData);
    pixel->putOriginalRepresentation(syntax, NULL, sequence);
    d->insert(pixel, OFTrue);
}

// HTJ2K codestreams (see the module docstring) wrapped in a dataset of the
// given syntax; decoded frame by frame and as a whole, identical for the
// reversible streams, within `tolerance` for the lossy one.
static void htj2k(const std::string& name, const std::string& directory, const std::vector<std::string>& files,
                  const Case& c, E_TransferSyntax syntax, const char* photometric, long tolerance)
{
    const int rows = 16, columns = 16;
    std::vector<long> stored, interleaved;
    pixels(c, rows, columns, stored, interleaved);
    std::vector<std::vector<Uint8> > streams;
    for (const std::string& file : files) streams.push_back(readStream(directory + "/" + file));
    for (const std::vector<Uint8>& stream : streams) CHECK(stream.size() > 4 && stream[0] == 0xFF && stream[1] == 0x4F, "codestream");
    DcmDataset d;
    describe(&d, c, rows, columns);
    if (photometric) d.putAndInsertString(DCM_PhotometricInterpretation, photometric);
    encapsulateFrames(&d, streams, syntax);
    DcmElement* element = NULL;
    CHECK(d.findAndGetElement(DCM_PixelData, element).good(), "pixel element");
    DcmPixelData* pixel = static_cast<DcmPixelData*>(element);

    const long perFrame = long(rows) * columns * c.spp;
    long worst = 0;
    auto compare = [&](long index, long value) {
        long expected = interleaved[index];
        expected = c.bits > 8 ? long(Uint16(expected)) : long(Uint8(expected));
        long error = value > expected ? value - expected : expected - value;
        if (error > worst) worst = error;
    };
    const Uint32 frameBytes = Uint32(perFrame * (c.bits > 8 ? 2 : 1));
    for (int frame = c.frames - 1; frame >= 0; --frame) {
        std::vector<Uint8> buffer(frameBytes + 1);
        Uint32 fragment = 0; OFString model;
        CHECK(pixel->getUncompressedFrame(&d, frame, fragment, buffer.data(), frameBytes, model).good(), "decode frame");
        CHECK(model == "RGB" || model == "MONOCHROME2", "decoded colour model");
        for (long i = 0; i < perFrame; ++i)
            compare(frame * perFrame + i, c.bits > 8 ? long(reinterpret_cast<Uint16*>(buffer.data())[i]) : long(buffer[i]));
    }
    CHECK(worst <= tolerance, "frame samples");

    CHECK(d.chooseRepresentation(EXS_LittleEndianExplicit, NULL).good(), "decode");
    CHECK(d.canWriteXfer(EXS_LittleEndianExplicit), "native representation");
    if (tolerance == 0) CHECK(samePixels(&d, c, interleaved), "identical pixels");
    OFString decoded;
    d.findAndGetOFString(DCM_PhotometricInterpretation, decoded);
    CHECK(decoded == (c.spp == 3 ? "RGB" : "MONOCHROME2"), "photometric interpretation");
    std::printf("ok %s max error %ld\n", name.c_str(), worst);
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

    DcmDataset h;
    describe(&h, c, 8, 8);
    encapsulate(&h, garbage, EXS_HighThroughputJPEG2000LosslessOnly);
    CHECK(h.chooseRepresentation(EXS_LittleEndianExplicit, NULL).bad(), "invalid HTJ2K stream rejected");
    CHECK(h.canWriteXfer(EXS_HighThroughputJPEG2000LosslessOnly), "compressed HTJ2K pixels kept");
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
    const std::string streams = argv[2];
    htj2k("htj2k-201-16s", streams, {"ht-s16.j2c"}, Case{16, true, 1, 0, 1},
          EXS_HighThroughputJPEG2000LosslessOnly, NULL, 0);
    htj2k("htj2k-201-12s", streams, {"ht-s12-f0.j2c"}, Case{12, true, 1, 0, 1},
          EXS_HighThroughputJPEG2000LosslessOnly, NULL, 0);
    htj2k("htj2k-202-12u-f2", streams, {"ht-u12-f0.j2c", "ht-u12-f1.j2c"}, Case{12, false, 1, 0, 2},
          EXS_HighThroughputJPEG2000withRPCLOptionsLosslessOnly, NULL, 0);
    htj2k("htj2k-201-rgb-rct", streams, {"ht-rgb8.j2c"}, Case{8, false, 3, 0, 1},
          EXS_HighThroughputJPEG2000LosslessOnly, "YBR_RCT", 0);
    htj2k("htj2k-203-lossy", streams, {"ht-lossy12.j2c"}, Case{12, false, 1, 0, 1},
          EXS_HighThroughputJPEG2000, NULL, 8);
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

# HTJ2K codestreams made by the OpenJPH 0.32 library from the driver's 16 x 16
# samples (see the module docstring).
htj2k = {
    'ht-s16.j2c': (
        'ff4fff5100294000000000100000001000000000000000000000001000000010000000000000000000018f0101ff5000'
        '0800020000000aff52000c00000001000304044001ff5c000d2088909090909090888888ff64001700014f70656e4a50'
        '482056657220302e33322e302eff90000a0000000000790001ff93c0002b00ff7fefd45bfd4bd20281b400c000134000'
        '15005050018274007c95affe00e35400c0001530000560241289f4aa71027500988a294c61eac06301ecb600c0002ba0'
        '0016a8088220088220e7ca7a7a70827800b4a485165a68a185165afefd94a07bf65281ecba00ffd9'
    ),
    'ht-s12-f0.j2c': (
        'ff4fff5100294000000000100000001000000000000000000000001000000010000000000000000000018b0101ff5000'
        '08000200000006ff52000c00000001000304044001ff5c000d2068707070707070686868ff64001700014f70656e4a50'
        '482056657220302e33322e302eff90000a0000000000f00001ff93c002a4218ed5ba2c01433400c0015100055c001520'
        '03096c1300639400bc133e0447ff7f01c73400036450d0ef00a39400c00168c0016e400168000e6c64c9e6bca60e6623'
        'e183431c839600feed5f03b8f916ee2b2b0750560da0ac6ca7acfe00a06b90801358001ee01bff717fbd77fcc780168c'
        'e39600c002db8005dd4002b008e29fff210224f00f1290e0bfff08e4e7802427ec5040b0827b00ff7fff7fff7fff7f7f'
        'ff70bff9877ff03f2df93f2df93f2df99f96fc8796fc2f2df97f5afa3f2dfde98e073666301cdb801cc073f66301ecb2'
        '01fef7bfff7ff988c270a3b700ffd9'
    ),
    'ht-u12-f0.j2c': (
        'ff4fff5100294000000000100000001000000000000000000000001000000010000000000000000000010b0101ff5000'
        '08000200000006ff52000c00020001000304044001ff5c000d2068707070707070686868ff64001700014f70656e4a50'
        '482056657220302e33322e302eff90000a0000000000f00001ff93c002a4218ed5ba2c01433400c0015100055c001520'
        '03096c1300639400bc133e0447ff7f01c73400036450d0ef00a39400c00168c0016e400168000e6c64c9e6bca60e6623'
        'e183431c839600feed5f03b8f916ee2b2b0750560da0ac6ca7acfe00a06b90801358001ee01bff717fbd77fcc780168c'
        'e39600c002db8005dd4002b008e29fff210224f00f1290e0bfff08e4e7802427ec5040b0827b00ff7fff7fff7fff7f7f'
        'ff70bff9877ff03f2df93f2df93f2df99f96fc8796fc2f2df97f5afa3f2dfde98e073666301cdb801cc073f66301ecb2'
        '01fef7bfff7ff988c270a3b700ffd9'
    ),
    'ht-u12-f1.j2c': (
        'ff4fff5100294000000000100000001000000000000000000000001000000010000000000000000000010b0101ff5000'
        '08000200000006ff52000c00020001000304044001ff5c000d2068707070707070686868ff64001700014f70656e4a50'
        '482056657220302e33322e302eff90000a0000000000ec0001ff93c002a4bfed53b53701433400c00153000554001520'
        '131a7c99f300839400bc1355cc86d901c73400035035d91900a39400c00168c0016dc0015e8eec09691edc0c9da641e9'
        '804894619600feed5f23708fc378bbb27a0065d528caca60caea306b94801357001ee1fb1ffced7bed0780168cc19600'
        'c002db8005dd4002ac08f21ffe43907f2420e1ff7f23c8e5d2427ec6398cd05e30827d00ff7fff7fff7fff6f7ffc47ff'
        '7e1ffeef7f5af27f5af27f5af23f2df92f5af23fb4e4ff69d2ff69d2e8c7039f33180e6dc018e017966301ecb201ff7f'
        'ff7ff72184e1423700ffd9'
    ),
    'ht-rgb8.j2c': (
        'ff4fff51002f400000000010000000100000000000000000000000100000001000000000000000000003070101070101'
        '070101ff500008000200000003ff52000c00000001010304044001ff5c000d2050585858585858505050ff6400170001'
        '4f70656e4a50482056657220302e33322e302eff90000a0000000003fc0001ff93c013802708f100019400c0128073f5'
        '22b300c013808baaf200033400c0096004f002a021e760b300b519e60006b40095acb2cc0081b400c009e004d002a47e'
        '89170042b40015a3fe66b3006c608131fd00c1b400c00a880151002a40d831bdf50083340095c0e3fe0021940023b84e'
        '8dfe00619400c00b420057c00b54799861df202025275cf231c892233600df24fa21a545aaebd7094a94a196004e21cf'
        '0670355d2bdacc86d45cfe03c14000329700c00b5a005af002d94f38089961dc63e3aeb32c7d4c02ad17340080969700'
        '6646c9160e7de968499535a4923edf0052a384200338009efe1774d155f2f404d33a758cee8a87d90050538820473800'
        'c00b56005af002da4d10dfb565aec3ba11c77db39cee1abc4000219700404f921daddb8a140dff2bbc433c03fd022d00'
        '206997000b627eeedd172bff0c5cca4cbfde0f1e1efc0055170880333800c017a340177d005db09ef161fcc77b7f8f8e'
        'a3eb23886b34ba867118f771bc8f032b8cbfd1700dc3358cc3b81f8aa5e3f73f8cdb705dc3308d4e24f2011af565eca5'
        'facbfadee597820cb1c971b301dee3669c6b8e6d1cf6611b8ff7dcc673338edb386ce3371faff1369edb786ec6b9ee78'
        'e9412746d24d3e8941bef4062976f1d4f6a540de0fc8f43261b001fefbfcf7df7bff7df7ff7bff73bfff3dfeff3dff3f'
        'ff3fff3ffef3bfeffdcff7ff6fff6f0012c1b22f75ed58c0bbbd0a87f1a949b201c017a14017acc017a680feeffb7e3f'
        'ff7fff7cbe9f9e9ffecfefff7cbf7cff3f9e9ebf8fe7a7ff73f7ff7c3f5e9eff4fd7f3f3f17ffd9fdf098bef67fd87f3'
        '97b8e7c1f58222f7a089a07401bf7cfbf9efebe7e7fbefe7f9efe9f9e9e3ef97574fff5efcfe7dfdfcf8fefb79fef4e1'
        'ef97274fbfbc7afaf7f2fbf7f5f3e0f9f3bfd7bf9e7cfcfac3d32fafbeff7d79fafd033cac3ade97558ef3da5c210806'
        '6a11017334017f7eff7cfbfbfbfbf3fbf3f7f3f3ff6bef9fdfdfdfdfdfdf9fdfbffefcfdfdfdfbd7ef9fdfdfdf9f3fff'
        '7ef3ebff6fff5fff7f7efdfdf9fb00dfdbee6ff25fdfbd079cbde1080bd2842041b501c017a34017acc017a1803fcf2f'
        'dff7eff17d7e3eff67c7f3f3ebf97e3ddf4f8fefa7cfebf57e3c3fbf9eefd7f3ebc7e7f37ebc3eefc7e3f97f79fdfe04'
        'd7755e9ca87cff2f6aee00007d2800023a7401bfff3cfef2f4fcf2fcf4d5d7a74fbefe7df2f5fb93ff2f9f9ebf3c7bfe'
        'eaf9d3572f3ffe7c7efef4ff7ce9ff75d3f397a7e797cfcf9fbf9fcfbe3fff72ff4f4f3ebe7e3d7ffe195cac93fadee5'
        '97f067a91080c8084031b3017fff7efbe7e7d7cfcfef5fbf7fff7efbd72f7fff7ffdfdf3fbebf7efdfbffef5f3f7e7ff'
        '7fff6f3fbf7ffeff7ef70879f873e9d3f9d3dd53e9f584203fd610805ed501ffd9'
    ),
    'ht-lossy12.j2c': (
        'ff4fff5100294000000000100000001000000000000000000000001000000010000000000000000000010b0101ff5000'
        '08000200000025ff52000c00000001000304044000ff5c0017227f937faa7faa7fc2683568356878601a601a6fbfff64'
        '001700014f70656e4a50482056657220302e33322e302eff90000a0000000001530001ff93c000aacdd32e2fec1f01c3'
        '3400c000a98001550002a40760b03afb00839400389e992c9bfa01c73400043832555c00a39400c002d68005d04002d5'
        '886b05307406624c829aaf3f3b25fb034288854a7700c7b06132483018b8ac8892c822bc1423bb0ca4b84cec92fe00a0'
        '63908066b8009d018cc9824b0d103918c404e130c107b204c7d600c005d7c005ec9000ba20761170308d44a654958176'
        '9a121018c09420328041879b151822401405c7fd2c08d4efc234afc02a8f7e104c8b7001921289442209481e49fe1da2'
        '190fa1190fd18c4334e3219af1865a4065de3041875bdee296b7b8e52d6e498b5bfea2965a9024110d38041820060c10'
        '0303c4ccef31cac86bb7866c88377322ce00044b85c82ce00d43073998c0537420011580006a37019da069b262f5ed1b'
        '82141870064454a2d0204c1cf0dc8000a0f6450b889422b7dd00ffd9'
    ),
}

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
                    '-I' + str(openjpeg / 'include'),
                    *(['-I' + str(args.openjpeg_config)] if args.openjpeg_config else []), *flags[:2],
                    str(work / 'driver.cpp'), str(ROOT / 'Horos/Sources/HorosJPEG2000Codec.cpp'),
                    str(openjpeg / 'lib/libopenjp2.a'), *flags[2:], '-o', str(work / 'driver')], check=True)
    output = work / 'files'
    output.mkdir()
    streams = work / 'htj2k'
    streams.mkdir()
    for name, text in htj2k.items():
        (streams / name).write_bytes(bytes.fromhex(''.join(text)))
    result = subprocess.run([str(work / 'driver'), str(output), str(streams)], capture_output=True, text=True)
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
