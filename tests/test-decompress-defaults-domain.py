#!/usr/bin/env python3
"""The Decompress helper converts with the preferences of the application it belongs to (#1032).

The helper took CompressionSettings and the other keys it reads from the
persistent domain org.horosproject.horos (BUNDLE_IDENTIFIER), whatever bundle
it shipped in. The development bundle (org.horosproject.horos.local-development)
therefore compressed and decompressed with the settings of the Horos installed
on the computer, not with its own. It now reads the domain of the nearest .app
above it, and BUNDLE_IDENTIFIER only outside an application, so the installed
Horos keeps reading the domain it always read.

Checked with copies of the built helper:

1. inside a stand-in application with an identifier of its own, the
   CompressionSettings written to that domain by this test decide the transfer
   syntax the helper writes, for two different settings (JPEG-LS lossless and
   JPEG 2000 lossless);
2. outside any application, the helper converts as the helper of the built
   Horos.app (org.horosproject.horos) does: both read the same domain;
3. in the source, BUNDLE_IDENTIFIER is only the fallback.

    python3 tests/test-decompress-defaults-domain.py [--helper PATH]

--helper runs another helper (the negative control: the one before the change
follows the installed Horos in 1). The test domain is removed at the end; no
other preferences are written. Skipped (exit 2) without a built helper.
"""
from pathlib import Path
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
products = root / 'build/Build/Products' / os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')
args = sys.argv[1:]
helper = Path(args[args.index('--helper') + 1]).resolve() if '--helper' in args else \
    products / 'Horos.app/Contents/Resources/Decompress'
if not helper.is_file():
    print(f'skipped: needs the built Decompress helper ({helper}; build Debug or --helper PATH)', file=sys.stderr)
    raise SystemExit(2)

failures = []

# ---- Source -------------------------------------------------------------------------

text = (root / 'Decompress/Decompress.mm').read_bytes().decode('latin1')
if 'persistentDomainForName:@BUNDLE_IDENTIFIER' in text.replace(' ', ''):
    failures.append('the helper still reads the fixed domain BUNDLE_IDENTIFIER')
if 'persistentDomainForName: HorosHostApplicationDefaultsDomain()' not in text:
    failures.append('the helper does not read the domain of the application it belongs to')

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


def compress(tool, work, name):
    source = work / f'{name}.dcm'
    native_dicom(source, f'1.2.826.0.1.3680043.10.1032.3.{abs(hash(name)) % 10**8}'.encode())
    out = work / f'out-{name}'
    out.mkdir()
    result = subprocess.run([str(tool), str(out), 'compress', str(source)], capture_output=True, timeout=120)
    written = out / source.name
    if result.returncode != 0 or not written.is_file():
        failures.append(f'{name}: the helper failed ({result.returncode}): '
                        + result.stderr.decode(errors='replace')[-300:])
        return None
    return written_syntax(written)


domain = f'org.horosproject.horos.test-defaults-domain-{os.getpid()}-{uuid.uuid4().hex[:8]}'
with tempfile.TemporaryDirectory(prefix='horos-decompress-domain-') as folder:
    work = Path(folder)
    application = work / 'Stand-in.app/Contents'
    (application / 'Resources').mkdir(parents=True)
    (application / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': domain, 'CFBundleName': 'Stand-in', 'CFBundlePackageType': 'APPL',
        'CFBundleExecutable': 'Stand-in'}))
    inside = application / 'Resources/Decompress'
    shutil.copy2(helper, inside)
    outside = work / 'loose/Decompress'
    outside.parent.mkdir()
    shutil.copy2(helper, outside)
    # The helper loads DCM.framework from @executable_path/../Frameworks.
    frameworks = helper.parent.parent / 'Frameworks'
    if not (frameworks / 'DCM.framework').is_dir():
        frameworks = products.resolve()
    (application / 'Frameworks').symlink_to(frameworks)
    (work / 'Frameworks').symlink_to(frameworks)
    try:
        for compression, expected in ((4, '1.2.840.10008.1.2.4.80'), (3, '1.2.840.10008.1.2.4.90')):
            codec = [{'modality': 'default', 'compression': compression, 'quality': 0}]
            settings = work / f'domain-{compression}.plist'
            settings.write_bytes(plistlib.dumps({'CompressionSettings': codec, 'CompressionSettingsLowRes': codec,
                                                 'CompressionResolutionLimit': 512,
                                                 'DecompressMoveIfFail': False}))
            subprocess.run(['defaults', 'import', domain, str(settings)], check=True)
            syntax = compress(inside, work, f'inside-{compression}')
            if syntax is not None and syntax != expected:
                failures.append(f'inside an application whose domain says compression {compression}: '
                                f'wrote {syntax}, {expected} expected')
            elif syntax:
                print(f'ok: the domain of the application says {compression}, the helper wrote {syntax}')
    finally:
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
        preferences = Path.home() / f'Library/Preferences/{domain}.plist'
        if preferences.exists():
            preferences.unlink()

    # The built Horos.app is org.horosproject.horos, the fallback's domain.
    reference = products / 'Horos.app/Contents/Resources/Decompress'
    if reference.is_file():
        loose, bundled = compress(outside, work, 'outside'), compress(reference, work, 'horos-app')
        if loose != bundled:
            failures.append(f'outside an application the helper wrote {loose}; '
                            f'the helper of Horos.app (org.horosproject.horos) wrote {bundled}')
        else:
            print(f'ok: outside an application the helper converts as Horos.app does ({loose})')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: the helper reads the preferences of the application it belongs to')
