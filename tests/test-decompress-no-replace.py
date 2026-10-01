#!/usr/bin/env python3
"""What the Decompress helper hands back never takes the place of a file (#1024).

With ListenerCompressionSettings at 2 the importer moves each image to
compress from INCOMING into DECOMPRESSION.noindex under a name that is free
there (#1008), and the helper writes the result back into INCOMING under that
name. When a scan is cut short by its time limit (LISTENERCHECKINTERVAL x 3),
the next scan reuses 1.dcm, 1-1.dcm... in the decompression folder, and the
helper's rename() put the second 1.dcm over the first before the importer had
indexed it: a 4000-file tree of 1.dcm/2.dcm lost 1920 files, with no refusal and
nothing in NOT READABLE.

Run against the built helper, on synthetic files in a temporary folder:

1. two files of the same name converted one after the other into the same
   folder, for compress (JPEG 2000), decompressList and the no-conversion
   relocation: both stay, with their own SOP instance UIDs, the first under its
   name and the second beside it (1-1.dcm);
2. an archive expanded where a folder of its name already is: both stay;
3. a conversion in place still replaces its own source.

And, in the sources: the helper no longer swaps an archive folder over an
existing one or removes the destination before putting an archive back, and
the importer adds to the compression queue under the lock the worker takes it
with.

    python3 tests/test-decompress-no-replace.py [--helper PATH]

Without --helper it uses the helper of build/Build/Products/Debug/Horos.app, or
of build/Development; skipped (exit 2) when neither is built.
"""
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
args = sys.argv[1:]
helper = None
if '--helper' in args:
    helper = Path(args[args.index('--helper') + 1]).resolve()
else:
    # The helper runs from the bundle: it loads DCM.framework from beside it.
    for candidate in (root / 'build/Build/Products/Debug/Horos.app/Contents/Resources/Decompress',
                      root / 'build/Development/HorosDevelopment.app/Contents/Resources/Decompress'):
        if candidate.is_file():
            helper = candidate
            break
if helper is None or not helper.is_file():
    print('skipped: needs the built Decompress helper (build/Build/Products/Debug/Horos.app or --helper PATH)',
          file=sys.stderr)
    raise SystemExit(2)

failures = []


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


def synthetic_ct(path, sop):
    """A 16 x 16 CT image in Explicit VR Little Endian, written by hand."""
    ct = b'1.2.840.10008.5.1.4.1.1.2'
    body = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', ct) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') \
        + element(0x0002, 0x0012, b'UI', b'1.2.826.0.1.3680043.10.1024')
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(body))) + body
    data = element(0x0008, 0x0016, b'UI', ct) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', b'CT') + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^NOREPLACE') \
        + element(0x0010, 0x0020, b'LO', b'SYN-1024') \
        + element(0x0020, 0x000D, b'UI', b'1.2.826.0.1.3680043.10.1024.1') \
        + element(0x0020, 0x000E, b'UI', b'1.2.826.0.1.3680043.10.1024.2') \
        + element(0x0028, 0x0002, b'US', struct.pack('<H', 1)) + element(0x0028, 0x0004, b'CS', b'MONOCHROME2') \
        + element(0x0028, 0x0010, b'US', struct.pack('<H', 16)) + element(0x0028, 0x0011, b'US', struct.pack('<H', 16)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', 16)) + element(0x0028, 0x0101, b'US', struct.pack('<H', 16)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', 15)) + element(0x0028, 0x0103, b'US', struct.pack('<H', 0)) \
        + element(0x7FE0, 0x0010, b'OW', struct.pack('<256H', *range(256)))
    path.write_bytes(b'\0' * 128 + b'DICM' + meta + data)


def settings(folder, compression):
    codec = [{'modality': 'default', 'compression': compression, 'quality': 0}]
    path = folder / f'settings-{compression}.plist'
    path.write_bytes(plistlib.dumps({'CompressionSettings': codec, 'CompressionSettingsLowRes': codec,
                                     'DecompressMoveIfFail': False}))
    return path


def run(destination, plist, mode, source):
    return subprocess.run([str(helper), str(destination), 'SettingsPlist', str(plist), mode, str(source)],
                          capture_output=True, timeout=120)


with tempfile.TemporaryDirectory(prefix='horos-decompress-no-replace-') as folder:
    work = Path(folder)
    cases = (('compress', 3, 'compressed to JPEG 2000'), ('decompressList', 3, 'decompressed'),
             ('compress', 1, 'relocated without conversion'))
    for index, (mode, compression, label) in enumerate(cases):
        case = work / f'case-{index}'
        incoming = case / 'INCOMING'
        incoming.mkdir(parents=True)
        plist = settings(case, compression)
        uids = []
        for scan in (1, 2):
            # A study folder of its own for each, as the importer's two scans see them,
            # and the same name in the decompression folder each time.
            decompression = case / f'DECOMPRESSION-{scan}'
            decompression.mkdir()
            sop = f'1.2.826.0.1.3680043.10.1024.{index}.{scan}'.encode()
            uids.append(sop)
            synthetic_ct(decompression / '1.dcm', sop)
            result = run(incoming, plist, mode, decompression / '1.dcm')
            if result.returncode != 0:
                failures.append(f'{label}, scan {scan}: the helper failed ({result.returncode}): '
                                + result.stderr.decode(errors='replace')[-400:])
            if (decompression / '1.dcm').exists():
                failures.append(f'{label}, scan {scan}: the source was left in the decompression folder')
        names = sorted(p.name for p in incoming.iterdir())
        if names != ['1-1.dcm', '1.dcm']:
            failures.append(f'{label}: expected 1.dcm and 1-1.dcm in INCOMING, found {names}')
        else:
            for name, sop in (('1.dcm', uids[0]), ('1-1.dcm', uids[1])):
                content = (incoming / name).read_bytes()
                if content[128:132] != b'DICM' or sop not in content:
                    failures.append(f'{label}: {name} is not the file of scan {uids.index(sop) + 1}')
        if list(case.rglob('.horos-*')):
            failures.append(f'{label}: a working file was left behind')
        if not failures:
            print(f'ok: two 1.dcm {label} into the same folder both stay')

    # An archive expanded where a folder of its name already is.
    case = work / 'archive'
    incoming, decompression = case / 'INCOMING', case / 'DECOMPRESSION'
    (incoming / 'a.zip').mkdir(parents=True)
    (incoming / 'a.zip' / 'earlier.dcm').write_bytes(b'not yet imported')
    decompression.mkdir()
    with zipfile.ZipFile(decompression / 'a.zip', 'w') as archive:
        archive.writestr('later.dcm', b'expanded now')
    result = run(incoming, settings(case, 3), 'decompressList', decompression / 'a.zip')
    earlier = incoming / 'a.zip' / 'earlier.dcm'
    later = incoming / 'a-1.zip' / 'later.dcm'
    if result.returncode != 0 or not earlier.is_file() or earlier.read_bytes() != b'not yet imported' \
            or not later.is_file() or later.read_bytes() != b'expanded now':
        failures.append('an archive expanded over a folder of its name: expected a.zip/earlier.dcm and '
                        f'a-1.zip/later.dcm, found {sorted(str(p.relative_to(incoming)) for p in incoming.rglob("*"))}')
    else:
        print('ok: an archive expanded where a folder of its name is leaves that folder alone')

    # In place, the converted file still replaces its source.
    case = work / 'in-place'
    case.mkdir()
    synthetic_ct(case / '1.dcm', b'1.2.826.0.1.3680043.10.1024.9')
    before = (case / '1.dcm').read_bytes()
    result = run('sameAsDestination', settings(case, 3), 'compress', case / '1.dcm')
    names = sorted(p.name for p in case.iterdir() if p.suffix == '.dcm')
    if result.returncode != 0 or names != ['1.dcm'] or (case / '1.dcm').read_bytes() == before:
        failures.append(f'a conversion in place no longer replaces its source: {names}, exit {result.returncode}')
    else:
        print('ok: a conversion in place replaces its own source')

helper_source = (root / 'Decompress/Decompress.mm').read_bytes().decode('latin1')
extraction = re.search(r'static HorosArchiveExtraction extractDICOMArchive\(.*?\n\}\n', helper_source, re.S)
if not extraction or 'renameWithoutReplacing(output, destination)' not in extraction.group(0) \
        or extraction.group(0).count('RENAME_SWAP') != 1 or 'if (!inPlace)' not in extraction.group(0):
    failures.append('the helper still swaps an expanded archive over an existing folder other than the archive itself')
retry = re.search(r'static BOOL returnArchiveForRetry\(.*?\n\}\n', helper_source, re.S)
if not retry or 'removeItemAtPath:destination' in retry.group(0):
    failures.append('putting an archive back for another attempt still removes what is at the destination')
database = (root / 'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')
if not re.search(r'@synchronized \(_compressQueue\) \{\s*\[_compressQueue addObjectsFromArray:compressedPathArray\];',
                 database) or re.search(r'@synchronized \(_decompressQueue\) \{\s*\[_compressQueue addObjectsFromArray',
                                        database):
    failures.append('the importer adds to the compression queue under the decompression queue\'s lock')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: nothing the helper hands back takes the place of an existing file or folder')
