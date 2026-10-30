#!/usr/bin/env python3
"""A conversion follows the preferences of the application that asks for it.

The Decompress helper took CompressionSettings and the other keys it reads from
the persistent domain thalesmms.isis.workstation (BUNDLE_IDENTIFIER), whatever
bundle it shipped in, so the development bundle compressed and decompressed
with the settings of the Horos installed on the computer; then from the domain
of the nearest .app above it. The Decompress XPC service that replaced it reads
no preferences at all - in the App Store build it could not read the
application's - and converts with the settings the application sends it, which
the application reads from its own defaults (DecompressConversion.settings).

Checked with the built service, through the tests' client
(decompress_service.py):

1. the settings sent decide the transfer syntax the service writes, for two
   different settings (JPEG-LS lossless and JPEG 2000 lossless), while the
   domains of the client and of the service say the other one;
2. in the source, the application sends what its own defaults say, and the
   service reads no defaults.

    python3 tests/test-decompress-defaults-domain.py [--helper PATH]

--helper names another Decompress.xpc. The test domains are removed at the
end; no other preferences are written. Skipped (exit 2) without a built service.
"""
from pathlib import Path
import os
import plistlib
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import decompress_service  # noqa: E402

args = sys.argv[1:]
service = Path(args[args.index('--helper') + 1]).resolve() if '--helper' in args else decompress_service.built_service()
if service is None or not (service / 'Contents/Info.plist').is_file():
    print('skipped: needs the built Decompress service (build Debug or --helper PATH to a Decompress.xpc)',
          file=sys.stderr)
    raise SystemExit(2)

failures = []

# ---- Source -------------------------------------------------------------------------

caller = (root / 'Horos/Sources/DicomDatabase+DCMTK.swift').read_text(encoding='utf-8')
if 'DecompressConversion.settings(from: defaults)' not in caller or 'let defaults = UserDefaults.standard' not in caller:
    failures.append('the application no longer sends the settings of its own defaults')
for name in ('CodecService.swift', 'main.swift', 'FirstFrameTest.swift'):
    text = (root / 'Decompress' / name).read_text(encoding='utf-8')
    if 'UserDefaults' in text or 'persistentDomain' in text:
        failures.append(f'the service reads defaults of its own ({name})')

# ---- A native DICOM, written here -----------------------------------------------------------


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


def native_dicom(path, sop):
    width = height = 32
    sop_class = b'1.2.840.10008.5.1.4.1.1.7'  # secondary capture
    body = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', sop_class) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') \
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.10.1032')
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(body))) + body
    pixels = bytes((x * 8 + y * 3) % 256 for y in range(height) for x in range(width))
    data = element(0x0008, 0x0016, b'UI', sop_class) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', b'OT') + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^DOMAIN') \
        + element(0x0010, 0x0020, b'LO', b'SYN-1032') \
        + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.10.1032.1') \
        + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.10.1032.2') \
        + element(0x0028, 0x0002, b'US', struct.pack('<H', 1)) \
        + element(0x0028, 0x0004, b'CS', b'MONOCHROME2') \
        + element(0x0028, 0x0010, b'US', struct.pack('<H', height)) \
        + element(0x0028, 0x0011, b'US', struct.pack('<H', width)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', 8)) \
        + element(0x0028, 0x0101, b'US', struct.pack('<H', 8)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', 7)) \
        + element(0x0028, 0x0103, b'US', struct.pack('<H', 0)) \
        + element(0x7FE0, 0x0010, b'OB', pixels)
    path.write_bytes(b'\0' * 128 + b'DICM' + meta + data)


def written_syntax(path):
    data = path.read_bytes()[:2048]
    at = data.find(b'\x02\x00\x10\x00UI')
    if at < 0:
        return None
    length = struct.unpack('<H', data[at + 6:at + 8])[0]
    return data[at + 8:at + 8 + length].rstrip(b'\0 ').decode()


def compress(tool, work, name, plist):
    source = work / f'{name}.dcm'
    native_dicom(source, f'1.2.826.0.1.3680043.10.1032.3.{abs(hash(name)) % 10**8}'.encode())
    out = work / f'out-{name}'
    out.mkdir()
    result = subprocess.run([str(tool), str(out), 'SettingsPlist', str(plist), 'compress', str(source)],
                            capture_output=True, timeout=120)
    written = out / source.name
    if result.returncode != 0 or not written.is_file():
        failures.append(f'{name}: the conversion failed ({result.returncode}): '
                        + result.stderr.decode(errors='replace')[-300:])
        return None
    return written_syntax(written)


def settings(compression):
    codec = [{'modality': 'default', 'compression': compression, 'quality': 0}]
    return {'CompressionSettings': codec, 'CompressionSettingsLowRes': codec, 'CompressionResolutionLimit': 512,
            'DecompressMoveIfFail': False}


client = decompress_service.client(service)
domains = [decompress_service.BUNDLE_ID,
           plistlib.loads((service / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']]
with tempfile.TemporaryDirectory(prefix='horos-decompress-domain-') as folder:
    work = Path(folder)
    try:
        for compression, other, expected in ((4, 3, '1.2.840.10008.1.2.4.80'), (3, 4, '1.2.840.10008.1.2.4.90')):
            # The domains the service could have read say the other compression.
            for domain in domains:
                stored = work / f'domain-{other}.plist'
                stored.write_bytes(plistlib.dumps(settings(other)))
                subprocess.run(['defaults', 'import', domain, str(stored)], check=True)
            sent = work / f'sent-{compression}.plist'
            sent.write_bytes(plistlib.dumps(settings(compression)))
            syntax = compress(client, work, f'sent-{compression}', sent)
            if syntax is not None and syntax != expected:
                failures.append(f'the settings sent say compression {compression}: wrote {syntax}, {expected} expected')
            elif syntax:
                print(f'ok: the settings sent say {compression}, the service wrote {syntax}')
    finally:
        for domain in domains:
            subprocess.run(['defaults', 'delete', domain], capture_output=True)
            preferences = Path.home() / f'Library/Preferences/{domain}.plist'
            if preferences.exists():
                preferences.unlink()

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: a conversion follows the settings of the application that asks for it')
