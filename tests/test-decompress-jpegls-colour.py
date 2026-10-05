#!/usr/bin/env python3
"""The Decompress helper compresses colour images to JPEG-LS (#1035).

DCMTK's JPEG-LS encoder prefers its "cooked" path, which reads the pixels
through DicomImage, and near-lossless JPEG-LS always takes it. DicomImage
handles colour only once dcmimage's colour support is registered
(dcmtk/dcmimage/diregist.h). The application had it; the helper did not, so
with CompressionSettings at JPEG-LS every RGB image failed with "unsupported
value for 'PhotometricInterpretation' (RGB)" and stayed uncompressed.

Checked with the built helper on native images written here (RGB 8-bit, and a
MONOCHROME2 16-bit control):

1. compress with JPEG-LS lossless writes 1.2.840.10008.1.2.4.80, and
   decompressList gives back the original samples;
2. compress with JPEG-LS near-lossless (quality 2) writes .81, within 2 levels;
3. the helper source registers dcmimage's colour support.

    python3 tests/test-decompress-jpegls-colour.py [--helper PATH]

--helper runs another helper (the negative control: the one before the change
fails 1 and 2 for RGB). Skipped (exit 2) without a built helper.
"""
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
products = root / 'build/Build/Products/Debug'
args = sys.argv[1:]
helper = Path(args[args.index('--helper') + 1]).resolve() if '--helper' in args else \
    products / 'IsiX DICOM Viewer.app/Contents/Resources/Decompress'
if not helper.is_file():
    print(f'skipped: needs the built Decompress helper ({helper}; build Debug or --helper PATH)', file=sys.stderr)
    raise SystemExit(2)

failures = []
if 'dcmtk/dcmimage/diregist.h' not in (root / 'Decompress/Decompress.mm').read_bytes().decode('latin1'):
    failures.append("the helper does not register dcmimage's colour support (dcmtk/dcmimage/diregist.h)")


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


WIDTH, HEIGHT = 48, 32


def native_dicom(path, sop, samples, photometric, allocated, pixels):
    sop_class = b'1.2.840.10008.5.1.4.1.1.7'  # secondary capture
    body = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', sop_class) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') \
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.10.1035')
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(body))) + body
    data = element(0x0008, 0x0016, b'UI', sop_class) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', b'OT') + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^JPEGLS') \
        + element(0x0010, 0x0020, b'LO', b'SYN-1035') \
        + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.10.1035.1') \
        + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.10.1035.2') \
        + element(0x0028, 0x0002, b'US', struct.pack('<H', samples)) \
        + element(0x0028, 0x0004, b'CS', photometric)
    if samples > 1:
        data += element(0x0028, 0x0006, b'US', struct.pack('<H', 0))
    data += element(0x0028, 0x0010, b'US', struct.pack('<H', HEIGHT)) \
        + element(0x0028, 0x0011, b'US', struct.pack('<H', WIDTH)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', allocated)) \
        + element(0x0028, 0x0101, b'US', struct.pack('<H', allocated if allocated == 8 else 12)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', (allocated if allocated == 8 else 12) - 1)) \
        + element(0x0028, 0x0103, b'US', struct.pack('<H', 0)) \
        + element(0x7FE0, 0x0010, b'OB' if allocated == 8 else b'OW', pixels)
    path.write_bytes(b'\0' * 128 + b'DICM' + meta + data)


def dataset_element(data, group, number):
    """The value of a top-level element of an Explicit VR Little Endian file written by DCMTK."""
    at = 132
    while at + 8 <= len(data):
        g, n, vr = struct.unpack('<HH2s', data[at:at + 6])
        if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT', b'OF', b'UC', b'UR', b'OD', b'OL', b'OV'):
            length = struct.unpack('<I', data[at + 8:at + 12])[0]
            start = at + 12
        else:
            length = struct.unpack('<H', data[at + 6:at + 8])[0]
            start = at + 8
        if (g, n) == (group, number):
            return data[start:start + length]
        if length == 0xFFFFFFFF:
            return None
        at = start + length
    return None


rgb = bytes(v for y in range(HEIGHT) for x in range(WIDTH)
            for v in ((x * 5) % 256, (y * 7 + x) % 256, (255 - x * 3 - y) % 256))
grey = struct.pack(f'<{WIDTH * HEIGHT}H', *[(x * 83 + y * 29) % 4096 for y in range(HEIGHT) for x in range(WIDTH)])
cases = {'rgb.dcm': (3, b'RGB', 8, rgb), 'grey16.dcm': (1, b'MONOCHROME2', 16, grey)}

with tempfile.TemporaryDirectory(prefix='horos-jpegls-colour-') as folder:
    work = Path(folder)
    for quality, syntax, tolerance in ((0, '1.2.840.10008.1.2.4.80', 0), (2, '1.2.840.10008.1.2.4.81', 2)):
        codec = [{'modality': 'default', 'compression': 4, 'quality': quality}]
        settings = work / f'settings-{quality}.plist'
        settings.write_bytes(plistlib.dumps({'CompressionSettings': codec, 'CompressionSettingsLowRes': codec,
                                             'CompressionResolutionLimit': 512, 'DecompressMoveIfFail': False}))
        for index, (name, (samples, photometric, allocated, pixels)) in enumerate(sorted(cases.items())):
            where = f'{name}, JPEG-LS quality {quality}'
            source = work / f'q{quality}-{name}'
            native_dicom(source, f'1.2.826.0.1.3680043.10.1035.3.{quality}.{index}'.encode(),
                         samples, photometric, allocated, pixels)
            out = work / f'out-{quality}-{index}'
            out.mkdir()
            result = subprocess.run([str(helper), str(out), 'SettingsPlist', str(settings), 'compress', str(source)],
                                    capture_output=True, timeout=120)
            written = out / source.name
            if result.returncode != 0 or not written.is_file():
                failures.append(f'{where}: compress failed ({result.returncode}): '
                                + result.stderr.decode(errors='replace').strip()[-200:])
                continue
            ts = (dataset_element(written.read_bytes(), 0x0002, 0x0010) or b'').rstrip(b'\0 ').decode()
            if ts != syntax:
                failures.append(f'{where}: wrote {ts}, {syntax} expected')
                continue
            back = subprocess.run([str(helper), 'sameAsDestination', 'SettingsPlist', str(settings), 'decompressList',
                                   str(written)], capture_output=True, timeout=120)
            # Lossy compression adds sequences of undefined length before the
            # pixels; the native Pixel Data is the last element of the file.
            data = written.read_bytes()
            at = data.rfind(b'\xe0\x7f\x10\x00')
            decoded = data[at + 12:at + 12 + struct.unpack('<I', data[at + 8:at + 12])[0]] \
                if at > 0 and data[at + 4:at + 6] in (b'OB', b'OW') else None
            if back.returncode != 0 or decoded is None:
                failures.append(f'{where}: decompressList failed ({back.returncode})')
                continue
            decoded = decoded[:len(pixels)]
            width = 1 if allocated == 8 else 2
            a = decoded if width == 1 else struct.unpack(f'<{len(decoded) // 2}H', decoded)
            b = pixels if width == 1 else struct.unpack(f'<{len(pixels) // 2}H', pixels)
            worst = max((abs(x - y) for x, y in zip(a, b)), default=0) if len(a) == len(b) else None
            if worst is None or worst > tolerance:
                failures.append(f'{where}: decoded samples differ by {worst}, at most {tolerance} allowed')
            else:
                print(f'ok: {where} -> {ts}, back within {worst}')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: the helper compresses colour and grey images to JPEG-LS')
