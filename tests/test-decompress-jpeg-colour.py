#!/usr/bin/env python3
"""The Decompress helper decodes JPEG to the pixels the viewer shows.

With ListenerCompressionSettings at 1 the importer hands every compressed image
to the helper, which replaces it with its decompressed copy; the "Decompress
DICOM files" command and a transcoding compression go the same way. The helper
registered the JPEG decoders with EDC_guess (the UseJPEGColorSpace default),
and DCMTK then trusts the IJG library's guess of the stream's colour space:

- three components numbered 1, 2, 3 without a JFIF or Adobe marker are
  guessed YCbCr, so lossless RGB (.57, .70) was converted to "RGB" a second
  time - black came out green - and written over the received file;
- every one-component stream is labelled MONOCHROME2, so a MONOCHROME1 image
  kept its pixels under the opposite interpretation and showed inverted.

The application decodes with EDC_photometricInterpretation, and the helper now
does as well. Checked here, on synthetic lossless JPEG written by this test (an
RGB stream with components 1, 2, 3 and no marker, and a 12-bit MONOCHROME1
one), through the built helper and through the reader the viewer uses
(HorosDCMTKObject, from tests/horos_reader.py):

1. decompressList writes the original samples, with the original Photometric
   Interpretation, and the viewer reads the same samples from the original;
2. compress to JPEG 2000 (transcoding, which decodes first) keeps them too;
3. both sources register the JPEG decoders with the same policy.

UseJPEGColorSpace (on by default) now has one meaning in the viewer and in
every transcoding, the helper's included: for a lossy JPEG stream of
three components, a JFIF or Adobe marker that contradicts the Photometric
Interpretation wins - JFIF or Adobe transform 1 under RGB is YCbCr and is
converted, Adobe transform 0 under YBR_FULL is RGB and is not. The test writes
baseline streams whose blocks hold only a DC coefficient, which every decoder
reconstructs exactly, and checks with the preference on and off:

4. RGB with JFIF, RGB with Adobe 1 and YBR_FULL with Adobe 0 decode by the
   marker when it is on, and by the Photometric Interpretation when it is off;
5. controls that never change: RGB with Adobe 0, YBR_FULL with JFIF, lossy RGB
   without a marker (no guess from the component identifiers), lossless RGB
   with a JFIF marker, and the two lossless streams above;
6. the application and the helper both take the policy from UseJPEGColorSpace,
   and the viewer and the change of representation both apply it.

    python3 tests/test-decompress-jpeg-colour.py [--products DIR] [--helper PATH] [--also DIR]

--helper runs another helper (the negative controls: one that does not decode by
the Photometric Interpretation fails 1 and 2, one that ignores the JFIF and
Adobe markers fails 4). --also DIR decompresses every JPEG and RLE file of DIR with the
helper too and requires the frame the viewer reads from the original to be the
one it reads from the helper's copy, byte for byte, with a Photometric
Interpretation that says what the samples are. Skipped (exit 2) without a built
helper and DCM.framework.
"""
from pathlib import Path
import os
import hashlib
import shutil
import plistlib
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from horos_reader import compile_reader, missing  # noqa: E402
from dcmtk_build import CONFIGURATION

root = Path(__file__).resolve().parents[1]
products = root / "build/Build/Products" / CONFIGURATION
args = sys.argv[1:]
if '--products' in args:
    products = Path(args[args.index('--products') + 1]).resolve()
helper = None
also = None
if '--helper' in args:
    helper = Path(args[args.index('--helper') + 1]).resolve()
if '--also' in args:
    also = Path(args[args.index('--also') + 1]).resolve()
if helper is None:
    for candidate in (products / 'Decompress', products / 'IsiX DICOM Viewer.app/Contents/Resources/Decompress'):
        if candidate.is_file():
            helper = candidate
            break
why = missing(products)
if helper is None or not helper.is_file() or why:
    print('skipped: needs the built Decompress helper and DCM.framework '
          f'({why or "no helper"}; configuration={CONFIGURATION}; --products DIR --helper PATH)', file=sys.stderr)
    raise SystemExit(2)

for artifact in (helper, products / "DCM.framework/DCM"):
    print(f"artifact {CONFIGURATION} {artifact}: sha256={hashlib.sha256(artifact.read_bytes()).hexdigest()}")

failures = []

# ---- Sources -------------------------------------------------------------------


def registration(path):
    text = (root / path).read_bytes().decode('latin1')
    start = text.index('DJDecoderRegistration::registerCodecs(')
    return text, text[start:text.index(';', start)]


app_text, app_call = registration('Horos/Sources/AppControllerDCMTKCategory.mm')
helper_text, helper_call = registration('Decompress/Decompress.mm')
for name, text, call in (('the application', app_text, app_call), ('the helper', helper_text, helper_call)):
    if 'EDC_photometricInterpretation' not in call or 'EDC_guess' in call:
        failures.append(f'{name} does not register the JPEG decoders with EDC_photometricInterpretation: {call}')
    if text.count('DJDecoderRegistration::registerCodecs(') != 1:
        failures.append(f'{name} registers the JPEG decoders more than once')
for name, text in (('the application', app_text), ('the helper', helper_text)):
    if '@"UseJPEGColorSpace"' not in text or 'HorosJPEGMarkersDecideColour().store(' not in text:
        failures.append(f'{name} does not take the JPEG marker policy from UseJPEGColorSpace')
for path in ('Horos/Sources/HorosDCMTKObject.mm', 'Horos/Sources/HorosDICOMRepresentation.h'):
    if 'HorosJPEGDecodingColour colour(' not in (root / path).read_bytes().decode('latin1'):
        failures.append(f'{path} does not apply the JPEG marker policy')
if ''.join(app_call.split()) != ''.join(helper_call.split()):
    failures.append(f'the application and the helper register different JPEG decoders: {app_call} / {helper_call}')

# ---- Lossless JPEG (process 14, selection value 1), written here -----------------------


def lossless_jpeg(samples, width, height, components, precision, ids):
    """An SOF3 stream, predictor 1, one Huffman table in which every difference
    category has a five-bit code; no JFIF or Adobe marker."""
    out = bytearray(b'\xff\xd8')
    counts = [0] * 16
    counts[4] = 17
    table = bytes([0x00]) + bytes(counts) + bytes(range(17))
    out += b'\xff\xc4' + struct.pack('>H', 2 + len(table)) + table
    frame = struct.pack('>BHHB', precision, height, width, components)
    for identifier in ids:
        frame += bytes([identifier, 0x11, 0])
    out += b'\xff\xc3' + struct.pack('>H', 2 + len(frame)) + frame
    scan = bytes([components]) + b''.join(bytes([identifier, 0x00]) for identifier in ids) + bytes([1, 0, 0])
    out += b'\xff\xda' + struct.pack('>H', 2 + len(scan)) + scan

    bits = []

    def put(value, length):
        bits.extend((value >> (length - 1 - i)) & 1 for i in range(length))

    def at(x, y, c):
        return samples[(y * width + x) * components + c]

    for y in range(height):
        for x in range(width):
            for c in range(components):
                if x > 0:
                    predicted = at(x - 1, y, c)
                elif y > 0:
                    predicted = at(x, y - 1, c)  # a row starts from the sample above
                else:
                    predicted = 1 << (precision - 1)
                difference = at(x, y, c) - predicted
                category = abs(difference).bit_length()
                put(category, 5)
                if category:
                    put(difference if difference > 0 else difference - 1 + (1 << category), category)
    bits.extend([1] * (-len(bits) % 8))
    for i in range(0, len(bits), 8):
        byte = int(''.join(map(str, bits[i:i + 8])), 2)
        out.append(byte)
        if byte == 0xFF:
            out.append(0)
    out += b'\xff\xd9'
    return bytes(out)


JFIF = b'\xff\xe0' + struct.pack('>H', 16) + b'JFIF\0' + bytes([1, 1, 0]) + struct.pack('>HH', 1, 1) + bytes([0, 0])


def adobe(transform):
    return b'\xff\xee' + struct.pack('>H', 14) + b'Adobe' + struct.pack('>HHHB', 100, 0, 0, transform)


def baseline_jpeg(blocks, width, height, marker=b'', ids=(1, 2, 3)):
    """An SOF0 stream, 4:4:4, in which every 8 x 8 block of every component is
    flat: only the DC coefficient, quantised by 1, which decodes exactly."""
    out = bytearray(b'\xff\xd8') + marker
    out += b'\xff\xdb' + struct.pack('>H', 67) + bytes([0]) + bytes([1] * 64)
    frame = struct.pack('>BHHB', 8, height, width, 3) + b''.join(bytes([i, 0x11, 0]) for i in ids)
    out += b'\xff\xc0' + struct.pack('>H', 2 + len(frame)) + frame
    counts = [0] * 16
    counts[3] = 12  # the DC categories 0-11, four-bit codes
    dc = bytes([0x00]) + bytes(counts) + bytes(range(12))
    counts = [0] * 16
    counts[0] = 1  # the end of block alone, a one-bit code
    ac = bytes([0x10]) + bytes(counts) + bytes([0])
    out += b'\xff\xc4' + struct.pack('>H', 2 + len(dc) + len(ac)) + dc + ac
    scan = bytes([3]) + b''.join(bytes([i, 0x00]) for i in ids) + bytes([0, 63, 0])
    out += b'\xff\xda' + struct.pack('>H', 2 + len(scan)) + scan
    bits = []

    def put(value, length):
        bits.extend((value >> (length - 1 - i)) & 1 for i in range(length))

    previous = [0, 0, 0]
    for block in blocks:
        for c in range(3):
            coefficient = 8 * (block[c] - 128)
            difference = coefficient - previous[c]
            previous[c] = coefficient
            category = abs(difference).bit_length()
            put(category, 4)
            if category:
                put(difference if difference > 0 else difference - 1 + (1 << category), category)
            put(0, 1)
    bits.extend([1] * (-len(bits) % 8))
    for i in range(0, len(bits), 8):
        byte = int(''.join(map(str, bits[i:i + 8])), 2)
        out.append(byte)
        if byte == 0xFF:
            out.append(0)
    out += b'\xff\xd9'
    return bytes(out)


def ycbcr_to_rgb(y, cb, cr):
    """The IJG library's fixed-point conversion (jdcolor.c)."""
    half, fix = 1 << 15, lambda x: int(x * 65536 + 0.5)
    r = y + ((fix(1.40200) * (cr - 128) + half) >> 16)
    g = y + ((-fix(0.34414) * (cb - 128) - fix(0.71414) * (cr - 128) + half) >> 16)
    b = y + ((fix(1.77200) * (cb - 128) + half) >> 16)
    return tuple(max(0, min(255, v)) for v in (r, g, b))


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


def jpeg_dicom(path, sop, stream, width, height, components, allocated, stored, photometric,
               syntax=b'1.2.840.10008.1.2.4.70'):
    sop_class = b'1.2.840.10008.5.1.4.1.1.7'  # secondary capture
    body = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', sop_class) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', syntax) \
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.10.1028')
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(body))) + body
    data = element(0x0008, 0x0016, b'UI', sop_class) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', b'OT') + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^JPEGCOLOUR') \
        + element(0x0010, 0x0020, b'LO', b'SYN-1028') \
        + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.10.1028.1') \
        + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.10.1028.2') \
        + element(0x0028, 0x0002, b'US', struct.pack('<H', components)) \
        + element(0x0028, 0x0004, b'CS', photometric)
    if components > 1:
        data += element(0x0028, 0x0006, b'US', struct.pack('<H', 0))
    data += element(0x0028, 0x0010, b'US', struct.pack('<H', height)) \
        + element(0x0028, 0x0011, b'US', struct.pack('<H', width)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', allocated)) \
        + element(0x0028, 0x0101, b'US', struct.pack('<H', stored)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', stored - 1)) \
        + element(0x0028, 0x0103, b'US', struct.pack('<H', 0))
    fragment = stream + (b'\0' if len(stream) % 2 else b'')
    data += struct.pack('<HH2sHI', 0x7FE0, 0x0010, b'OB', 0, 0xFFFFFFFF) \
        + struct.pack('<HHI', 0xFFFE, 0xE000, 0) + struct.pack('<HHI', 0xFFFE, 0xE000, len(fragment)) + fragment \
        + struct.pack('<HHI', 0xFFFE, 0xE0DD, 0)
    path.write_bytes(b'\0' * 128 + b'DICM' + meta + data)


WIDTH = HEIGHT = 16
rgb = []
for y in range(HEIGHT):
    for x in range(WIDTH):
        # Black first (the issue's G = 135), then primaries, white and ramps.
        rgb += [(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)][x] if x < 5 else \
            [(x * 16 + y) % 256, (255 - y * 16) % 256, (x * y * 3) % 256]
grey = [(x * 256 + y * 17) % 4096 for y in range(HEIGHT) for x in range(WIDTH)]
LOSSLESS, BASELINE = b'1.2.840.10008.1.2.4.70', b'1.2.840.10008.1.2.4.50'
# name: (stream, components, allocated, stored, stated interpretation, syntax,
#        frame with UseJPEGColorSpace on, frame with it off)
cases = {
    'rgb-70.dcm': (lossless_jpeg(rgb, WIDTH, HEIGHT, 3, 8, [1, 2, 3]), 3, 8, 8, b'RGB', LOSSLESS,
                   bytes(rgb), bytes(rgb)),
    'monochrome1-70.dcm': (lossless_jpeg(grey, WIDTH, HEIGHT, 1, 12, [1]), 1, 16, 12, b'MONOCHROME1', LOSSLESS,
                           struct.pack('<%dH' % len(grey), *grey), struct.pack('<%dH' % len(grey), *grey)),
}
# Four flat blocks: black (YCbCr black-as-RGB is the issue's green), red, grey, a mix.
blocks = [(0, 0, 0), (255, 0, 0), (128, 128, 128), (90, 200, 40)]


def picture(colours):
    out = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            out += bytes(colours[(y // 8) * (WIDTH // 8) + x // 8])
    return bytes(out)


raw, converted = picture(blocks), picture([ycbcr_to_rgb(*b) for b in blocks])
for name, marker, stated, on, off in (
        # The marker contradicts the interpretation: it wins with the preference on.
        ('rgb-jfif-50.dcm', JFIF, b'RGB', converted, raw),
        ('rgb-adobe1-50.dcm', adobe(1), b'RGB', converted, raw),
        ('ybr-adobe0-50.dcm', adobe(0), b'YBR_FULL', raw, converted),
        # Controls: the marker agrees, or there is none.
        ('rgb-adobe0-50.dcm', adobe(0), b'RGB', raw, raw),
        ('ybr-jfif-50.dcm', JFIF, b'YBR_FULL', converted, converted),
        ('rgb-plain-50.dcm', b'', b'RGB', raw, raw)):
    cases[name] = (baseline_jpeg(blocks, WIDTH, HEIGHT, marker), 3, 8, 8, stated, BASELINE, on, off)
# Lossless is never corrected, marker or not.
stream = lossless_jpeg(rgb, WIDTH, HEIGHT, 3, 8, [1, 2, 3])
cases['rgb-jfif-70.dcm'] = (stream[:2] + JFIF + stream[2:], 3, 8, 8, b'RGB', LOSSLESS, bytes(rgb), bytes(rgb))

# ---- Reader the viewer uses ---------------------------------------------------------

program = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import "HorosDCMTKObject.h"
#include <stdlib.h>
#include "HorosJPEGColourModel.h"
extern "C" void HorosTestRegisterDecoders(void);

// For each file: its transfer syntax and Photometric Interpretation on one line,
// and the first frame the viewer would draw in <file>.frame.
int main(int argc, char **argv) { @autoreleasepool {
    HorosTestRegisterDecoders();
    // UseJPEGColorSpace off, as the application sets it from its defaults.
    if (getenv("HOROS_TEST_JPEG_COLOR_SPACE_OFF"))
        HorosJPEGMarkersDecideColour().store(false);
    for (int i = 1; i < argc; i++) {
        NSString *path = [NSString stringWithUTF8String: argv[i]];
        DCMObject *object = [HorosDCMTKObject objectWithContentsOfFile: path];
        DCMPixelDataAttribute *attribute = (DCMPixelDataAttribute*) [object attributeWithName:@"PixelData"];
        NSData *frame = [attribute decodeFrameAtIndex: 0];
        if (object == nil || frame == nil) { printf("%s\tunreadable\n", argv[i]); continue; }
        [frame writeToFile: [path stringByAppendingString: @".frame"] atomically: NO];
        printf("%s\t%s\t%s\n", argv[i], [[[attribute transferSyntax] transferSyntax] UTF8String],
               [[object attributeValueWithName:@"PhotometricInterpretation"] UTF8String]);
    }
    return 0;
}}
'''


def settings(folder, compression, use_jpeg_color_space=True):
    codec = [{'modality': 'default', 'compression': compression, 'quality': 0}]
    path = folder / f'settings-{compression}-{use_jpeg_color_space}.plist'
    # UseJPEGColorSpace on is its default (which formerly chose EDC_guess).
    path.write_bytes(plistlib.dumps({'CompressionSettings': codec, 'CompressionSettingsLowRes': codec,
                                     'CompressionResolutionLimit': 512, 'DecompressMoveIfFail': False,
                                     'UseJPEGColorSpace': use_jpeg_color_space}))
    return path


def run_helper(destination, plist, mode, sources):
    result = subprocess.run([str(helper), str(destination), 'SettingsPlist', str(plist), mode, *map(str, sources)],
                            capture_output=True, timeout=300)
    if result.returncode != 0:
        failures.append(f'{mode}: the helper failed ({result.returncode}): '
                        + result.stderr.decode(errors='replace')[-400:])


with tempfile.TemporaryDirectory(prefix='horos-decompress-jpeg-colour-') as folder:
    work = Path(folder)
    (work / 'bin').mkdir()
    (work / 'Frameworks').symlink_to(products.resolve())
    # Decompress links @executable_path/../Frameworks/DCM.framework. Execute
    # an identical local copy beside the selected framework, including raw
    # build products and historical negative-control helpers.
    selected_helper = helper
    helper = work / 'bin/Decompress'
    shutil.copy2(selected_helper, helper)
    assert hashlib.sha256(helper.read_bytes()).digest() == hashlib.sha256(selected_helper.read_bytes()).digest()
    (work / 'read.m').write_text(program)
    compile_reader(products, work / 'read.m', work / 'bin/read', work)

    def read(paths, preference=True):
        environment = dict(os.environ)
        if not preference:
            environment['HOROS_TEST_JPEG_COLOR_SPACE_OFF'] = '1'
        out = subprocess.run([str(work / 'bin/read'), *map(str, paths)], capture_output=True, text=True, timeout=300,
                             env=environment)
        seen = {}
        for line in out.stdout.splitlines():
            path, *rest = line.split('\t')
            seen[path] = rest
        return seen

    originals = work / 'originals'
    originals.mkdir()
    for index, (name, case) in enumerate(sorted(cases.items())):
        stream, components, allocated, stored, photometric, syntax = case[:6]
        jpeg_dicom(originals / name, f'1.2.826.0.1.3680043.10.1028.3.{index}'.encode(), stream,
                   WIDTH, HEIGHT, components, allocated, stored, photometric, syntax)

    for preference in (True, False):
        state = 'on' if preference else 'off'
        decompressed, transcoded = work / f'decompressed-{state}', work / f'transcoded-{state}'
        for mode, destination, compression in (('decompressList', decompressed, 0), ('compress', transcoded, 3)):
            destination.mkdir()
            sources = work / f'sources-{mode}-{state}'
            sources.mkdir()
            for name in cases:
                (sources / name).write_bytes((originals / name).read_bytes())
            run_helper(destination, settings(work, compression, preference), mode, sorted(sources.iterdir()))

        targets = [folder / name for folder in (originals, decompressed, transcoded) for name in cases]
        seen = read((p for p in targets if p.is_file()), preference)
        for name, (_, _, _, _, photometric, syntax, on, off) in sorted(cases.items()):
            expected = on if preference else off
            stated = photometric.decode()
            # Decoding gives RGB for YBR; anything else keeps its interpretation.
            written = 'RGB' if stated.startswith('YBR') else stated
            for label, folder, ts_expected, pi_expected in (
                    ('the viewer, from the original', originals, syntax.decode(), stated),
                    ('decompressList', decompressed, '1.2.840.10008.1.2.1', written),
                    ('compress to JPEG 2000', transcoded, '1.2.840.10008.1.2.4.90', written)):
                path = folder / name
                where = f'{name}, UseJPEGColorSpace {state}, {label}'
                if str(path) not in seen or seen[str(path)] == ['unreadable']:
                    failures.append(f'{where}: no readable file')
                    continue
                ts, pi = seen[str(path)]
                frame = Path(str(path) + '.frame').read_bytes()
                if ts != ts_expected:
                    failures.append(f'{where}: transfer syntax {ts}, {ts_expected} expected')
                if pi != pi_expected:
                    failures.append(f'{where}: Photometric Interpretation {pi}, {pi_expected} expected')
                if frame != expected:
                    differing = sum(a != b for a, b in zip(frame, expected)) + abs(len(frame) - len(expected))
                    failures.append(f'{where}: {differing} of {len(expected)} bytes differ '
                                    f'(first sample {list(frame[:3])}, {list(expected[:3])} expected)')
    if not failures:
        print('ok: lossless RGB (components 1, 2, 3, no marker) and MONOCHROME1 keep their samples and '
              'interpretation through decompressList, compress and the viewer')
        print('ok: with UseJPEGColorSpace on, a JFIF or Adobe marker that contradicts the interpretation of a '
              'lossy stream decides, and nothing else changes; off, the interpretation decides')

    if also:
        checked = work / 'also'
        out = work / 'also-out'
        checked.mkdir()
        out.mkdir()
        syntaxes = (b'1.2.840.10008.1.2.4.50', b'1.2.840.10008.1.2.4.51', b'1.2.840.10008.1.2.4.57',
                    b'1.2.840.10008.1.2.4.70', b'1.2.840.10008.1.2.5\0')
        chosen = [p for p in sorted(also.rglob('*.dcm'))
                  if any(s in p.read_bytes()[:1024] for s in syntaxes)]
        for p in chosen:
            (checked / p.name).write_bytes(p.read_bytes())
        sources = work / 'also-sources'
        sources.mkdir()
        for p in chosen:
            (sources / p.name).write_bytes(p.read_bytes())
        run_helper(out, settings(work, 0), 'decompressList', sorted(sources.iterdir()))
        seen = read([checked / p.name for p in chosen] + [out / p.name for p in chosen])
        for p in chosen:
            original, copy = checked / p.name, out / p.name
            if seen.get(str(original), ['unreadable']) == ['unreadable'] or \
                    seen.get(str(copy), ['unreadable']) == ['unreadable']:
                failures.append(f'{p.name}: not readable before or after the helper')
                continue
            before = Path(str(original) + '.frame').read_bytes()
            after = Path(str(copy) + '.frame').read_bytes()
            stated, written = seen[str(original)][1], seen[str(copy)][1]
            # Decoding YBR gives RGB; anything else keeps its interpretation.
            coherent = written == stated or (stated.startswith('YBR') and written == 'RGB')
            if before != after or not coherent:
                failures.append(f'{p.name}: the helper\'s copy ({written}) is not what the viewer shows for '
                                f'the original ({stated}): {sum(a != b for a, b in zip(before, after))} bytes differ')
            else:
                print(f'ok: {p.name} ({seen[str(original)][0]}, {stated}) -> {written}, same frame')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: the helper decodes JPEG as the viewer does')
