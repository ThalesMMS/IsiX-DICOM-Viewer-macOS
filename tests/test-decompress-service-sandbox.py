#!/usr/bin/env python3
"""The Decompress service converts, tests and prints under the App Sandbox.

In the App Store build the application has the App Sandbox and the service a
sandbox of its own (Horos/Configuration/AppStoreDecompress.entitlements): an
XPC service does not inherit the application's, and cannot open the
application's files by path. The application therefore hands it every file as
an open handle and does the file system work itself.

Here a copy of the built service is signed ad hoc with those entitlements and
put in a client application (decompress_service.py) that has the App Sandbox,
as the App Store build, and whose files are in its own container. Through it:

1. a CT image is compressed to JPEG 2000 lossless beside the original folder,
   and decompressed back to Explicit VR Little Endian;
2. the validation before importing refuses a broken copy and passes the image;
3. an HTML report is printed to its PDF;
4. the service copy has the sandbox and not com.apple.security.inherit.

    python3 tests/test-decompress-service-sandbox.py [--helper PATH] [--arch arm64|x86_64]

--helper names another Decompress.xpc (the one of a package or of the App
Store archive); --arch x86_64 runs an x86_64 client, under Rosetta on Apple
silicon. The service runs a slice of its own: the x86_64 package's, which has
no other, under Rosetta; a Universal 2 one, its arm64 slice whichever the
client's. The client's container and
the service's are removed at the end. Skipped (exit 2) without a built service.
"""
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import decompress_service  # noqa: E402

args = sys.argv[1:]
service = Path(args[args.index('--helper') + 1]).resolve() if '--helper' in args else decompress_service.built_service()
arch = args[args.index('--arch') + 1] if '--arch' in args else 'arm64'
if service is None or not (service / 'Contents/Info.plist').is_file():
    print('skipped: needs the built Decompress service (build Debug or --helper PATH to a Decompress.xpc)',
          file=sys.stderr)
    raise SystemExit(2)


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


def synthetic_ct(path):
    ct, sop = b'1.2.840.10008.5.1.4.1.1.2', b'1.2.826.0.1.3680043.10.7002.1'
    body = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', ct) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') \
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.10.7002')
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(body))) + body
    data = element(0x0008, 0x0016, b'UI', ct) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', b'CT') + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^SANDBOX') \
        + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.10.7002.2') \
        + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.10.7002.3') \
        + element(0x0028, 0x0002, b'US', struct.pack('<H', 1)) + element(0x0028, 0x0004, b'CS', b'MONOCHROME2') \
        + element(0x0028, 0x0010, b'US', struct.pack('<H', 64)) + element(0x0028, 0x0011, b'US', struct.pack('<H', 64)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', 16)) + element(0x0028, 0x0101, b'US', struct.pack('<H', 12)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', 11)) + element(0x0028, 0x0103, b'US', struct.pack('<H', 0)) \
        + element(0x7FE0, 0x0010, b'OW', struct.pack('<4096H', *(i % 4096 for i in range(4096))))
    content = b'\0' * 128 + b'DICM' + meta + data
    path.write_bytes(content)
    return content


def syntax(path):
    data = path.read_bytes()[:2048]
    at = data.find(b'\x02\x00\x10\x00UI')
    return data[at + 8:at + 8 + struct.unpack('<H', data[at + 6:at + 8])[0]].rstrip(b'\0 ').decode() if at >= 0 else None


service_id = plistlib.loads((service / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
containers = [Path.home() / 'Library/Containers' / name for name in (decompress_service.BUNDLE_ID, service_id)]
staging = root / 'build/decompress-client/sandbox' / arch
if staging.exists():
    shutil.rmtree(staging)
client = decompress_service.client(service, staging, sandbox=True, arch=arch)
failures = []
try:
    entitlements = plistlib.loads(subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(client.parents[1] / 'XPCServices/Decompress.xpc')],
        stderr=subprocess.DEVNULL))
    if not entitlements.get('com.apple.security.app-sandbox') or entitlements.get('com.apple.security.inherit'):
        failures.append(f'the service copy is not sandboxed on its own: {entitlements}')
    # The client's container exists once it ran; its files go there.
    subprocess.run([str(client), 'unused', 'none'], capture_output=True, timeout=60)
    work = containers[0] / 'Data/tmp' / ('isix-sandbox-' + uuid.uuid4().hex[:8])
    sources, packed, unpacked = work / 'sources', work / 'packed', work / 'unpacked'
    for folder in (sources, packed, unpacked):
        folder.mkdir(parents=True)
    original = synthetic_ct(sources / 'ct.dcm')
    plist = work / 'settings.plist'
    codec = [{'modality': 'default', 'compression': 3, 'quality': 0}]
    plist.write_bytes(plistlib.dumps({'CompressionSettings': codec, 'CompressionSettingsLowRes': codec,
                                      'CompressionResolutionLimit': 0, 'DecompressMoveIfFail': False}))

    def run(*arguments):
        return subprocess.run([str(client), *map(str, arguments)], capture_output=True, text=True, timeout=120)

    result = run(packed, 'SettingsPlist', plist, 'compress', sources / 'ct.dcm')
    if result.returncode != 0 or syntax(packed / 'ct.dcm') != '1.2.840.10008.1.2.4.90':
        failures.append(f'compress under the sandbox ({result.returncode}): {result.stderr[-400:]}')
    result = run(unpacked, 'SettingsPlist', plist, 'decompressList', packed / 'ct.dcm')
    decompressed = unpacked / 'ct.dcm'
    if result.returncode != 0 or syntax(decompressed) != '1.2.840.10008.1.2.1' or original[-8192:] != decompressed.read_bytes()[-8192:]:
        failures.append(f'decompressList under the sandbox ({result.returncode}): {result.stderr[-400:]}')
    elif not failures:
        print(f'ok ({arch}): compressed to JPEG 2000 and back to the same pixels under the sandbox')

    broken = work / 'broken.dcm'
    broken.write_bytes(original[:len(original) - 4000])
    result = run('unused', 'testFiles', decompressed, broken)
    refused = [line.split('\t', 1)[1] for line in result.stdout.splitlines() if line.startswith('REFUSED\t')]
    if result.returncode == 0 or refused != [str(broken)]:
        failures.append(f'testFiles under the sandbox refused {refused} ({result.returncode})')
    else:
        print(f'ok ({arch}): the validation refuses the broken copy alone under the sandbox')

    report = work / 'report.html'
    report.write_text('<!doctype html><html><body><p>SANDBOX-REPORT</p></body></html>')
    result = run(report, 'pdfFromURL')
    pdf = work / 'report.html.pdf'
    if result.returncode != 0 or not pdf.is_file() or not pdf.read_bytes().startswith(b'%PDF'):
        failures.append(f'pdfFromURL under the sandbox ({result.returncode}): {result.stderr[-400:]}')
    else:
        print(f'ok ({arch}): the report printed to its PDF under the sandbox')
finally:
    for container in containers:
        subprocess.run(['rm', '-rf', str(container)], capture_output=True)
    shutil.rmtree(staging, ignore_errors=True)

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
