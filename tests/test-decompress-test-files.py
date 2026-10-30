#!/usr/bin/env python3
"""The validation before importing refuses a DICOM file that cannot be read.

With validateFilesBeforeImporting on, the importer has the Decompress service
load the first frame of each file it copied (+[DicomDatabase
filesRefusedByValidation:], IsiXImportValidation). Each file that does not load
is refused, and only those: the others of the batch are imported. The helper
the service replaced used to log a file it could not load and exit 0 all the
same, so nothing that did not bring it down was ever refused; then, for a
while, one such file made the importer refuse its whole batch.

Run against the built service, through the tests' client
(decompress_service.py), which takes the helper's `unused testFiles <files>`,
writes "REFUSED", a tab and the path for each refused file, and exits with a
failure when there was one; on synthetic files written by hand in a temporary
folder:

1. a CT image, an encapsulated PDF and an RT STRUCT are tested one by one and
   together: exit 0, and nothing logged as not loaded;
2. a copy of the CT cut short inside its pixel data, and one whose header was
   overwritten: each fails, and fails a batch it is part of, which names it
   and only it;
3. a file that is not DICOM at all (no "DICM" marker, nothing DCMTK reads) is
   not this test's to refuse: exit 0;
4. a mixed batch (the valid files, both broken copies and the text file) names
   the two broken copies and nothing else.

And, in the sources: the importer indexes the files the service did not refuse.

    python3 tests/test-decompress-test-files.py [--helper PATH]

Without --helper it uses the service of build/Build/Products/Debug/IsiX DICOM
Viewer.app, or of build/Development; skipped (exit 2) when neither is built.
--helper names another Decompress.xpc, or an executable to run as it is.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import decompress_service  # noqa: E402

helper = decompress_service.helper(sys.argv[1:])
if helper is None:
    print('skipped: needs the built Decompress service (build/Build/Products/Debug/IsiX DICOM Viewer.app or --helper PATH)',
          file=sys.stderr)
    raise SystemExit(2)

failures = []
UID = b'1.2.826.0.1.3680043.10.2048'


def element(group, number, vr, value):
    if len(value) % 2:
        value += b'\0' if vr in (b'UI', b'OB') else b' '
    if vr in (b'OB', b'OW', b'UN', b'SQ', b'UT'):
        return struct.pack('<HH2sHI', group, number, vr, 0, len(value)) + value
    return struct.pack('<HH2sH', group, number, vr, len(value)) + value


def item(content):
    return struct.pack('<HHI', 0xFFFE, 0xE000, len(content)) + content


def part10(sop_class, sop, modality, body):
    """A Part 10 file in Explicit VR Little Endian: preamble, meta header, data set."""
    meta = element(0x0002, 0x0001, b'OB', b'\0\1') + element(0x0002, 0x0002, b'UI', sop_class) \
        + element(0x0002, 0x0003, b'UI', sop) + element(0x0002, 0x0010, b'UI', b'1.2.840.10008.1.2.1') \
        + element(0x0002, 0x0012, b'UI', UID)
    meta = element(0x0002, 0x0000, b'UL', struct.pack('<I', len(meta))) + meta
    data = element(0x0008, 0x0016, b'UI', sop_class) + element(0x0008, 0x0018, b'UI', sop) \
        + element(0x0008, 0x0060, b'CS', modality) + element(0x0010, 0x0010, b'PN', b'SYNTHETIC^TESTFILES') \
        + element(0x0010, 0x0020, b'LO', b'SYN-2048') + element(0x0020, 0x000D, b'UI', UID + b'.1') \
        + element(0x0020, 0x000E, b'UI', UID + b'.' + modality) + body
    return b'\0' * 128 + b'DICM' + meta + data


def ct():
    pixels = struct.pack('<4096H', *(i % 4096 for i in range(4096)))
    body = element(0x0028, 0x0002, b'US', struct.pack('<H', 1)) + element(0x0028, 0x0004, b'CS', b'MONOCHROME2') \
        + element(0x0028, 0x0010, b'US', struct.pack('<H', 64)) + element(0x0028, 0x0011, b'US', struct.pack('<H', 64)) \
        + element(0x0028, 0x0100, b'US', struct.pack('<H', 16)) + element(0x0028, 0x0101, b'US', struct.pack('<H', 12)) \
        + element(0x0028, 0x0102, b'US', struct.pack('<H', 11)) + element(0x0028, 0x0103, b'US', struct.pack('<H', 0)) \
        + element(0x7FE0, 0x0010, b'OW', pixels)
    return part10(b'1.2.840.10008.5.1.4.1.1.2', UID + b'.2.1', b'CT', body)


def pdf():
    document = b'%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'
    body = element(0x0042, 0x0011, b'OB', document) + element(0x0042, 0x0012, b'LO', b'application/pdf')
    return part10(b'1.2.840.10008.5.1.4.1.1.104.1', UID + b'.3.1', b'DOC', body)


def rtstruct():
    roi = element(0x3006, 0x0022, b'IS', b'1') + element(0x3006, 0x0026, b'LO', b'BOX')
    body = element(0x3006, 0x0002, b'SH', b'SYNTHETIC') + element(0x3006, 0x0020, b'SQ', item(roi))
    return part10(b'1.2.840.10008.5.1.4.1.1.481.3', UID + b'.4.1', b'RTSTRUCT', body)


def test(*paths):
    return subprocess.run([str(helper), 'unused', 'testFiles', *map(str, paths)], capture_output=True, timeout=60)


def named(result):
    """The files the helper names as refused on its standard output."""
    return [line[len('REFUSED\t'):] for line in result.stdout.decode(errors='replace').splitlines()
            if line.startswith('REFUSED\t')]


def not_loaded(result):
    return [line for line in result.stderr.decode(errors='replace').splitlines() if 'could not be loaded' in line]


with tempfile.TemporaryDirectory(prefix='horos-decompress-test-files-') as folder:
    work = Path(folder)
    good = {'ct.dcm': ct(), 'pdf.dcm': pdf(), 'rtstruct.dcm': rtstruct()}
    for name, content in good.items():
        (work / name).write_bytes(content)
    image = good['ct.dcm']
    broken = {
        # Cut inside the pixel data: the element is longer than what is left.
        'ct-truncated.dcm': image[:len(image) - 4000],
        # The data set's first elements overwritten past the meta header.
        'ct-garbage.dcm': image[:132 + 40] + bytes((i * 37 + 11) % 256 for i in range(360)) + image[132 + 400:],
    }
    for name, content in broken.items():
        (work / name).write_bytes(content)
    (work / 'notes.txt').write_text('a text file the importer was given, not DICOM\n')

    for name in good:
        result = test(work / name)
        if result.returncode != 0 or not_loaded(result) or named(result):
            failures.append(f'{name}: a valid file failed the test ({result.returncode}): {not_loaded(result)}')
    result = test(*(work / name for name in good))
    if result.returncode != 0:
        failures.append(f'the three valid files together failed the test ({result.returncode})')
    else:
        print('ok: a CT image, an encapsulated PDF and an RT STRUCT pass, alone and together, with nothing logged')

    for name in broken:
        result = test(work / name)
        if result.returncode == 0:
            failures.append(f'{name}: a broken file passed the test')
        elif not any(name in line for line in not_loaded(result)):
            failures.append(f'{name}: failed without naming the file')
        elif named(result) != [str(work / name)]:
            failures.append(f'{name}: failed without naming the file on the output: {named(result)}')
        together = test(*(work / good_name for good_name in good), work / name)
        if together.returncode == 0:
            failures.append(f'{name}: a batch with a broken file passed the test')
        elif named(together) != [str(work / name)]:
            failures.append(f'{name}: a batch named {named(together)} instead of the broken file alone')
    if not any('broken' in failure or 'batch' in failure or 'naming' in failure for failure in failures):
        print('ok: a CT cut short and a CT with an overwritten header fail, alone and in a batch')

    result = test(work / 'notes.txt')
    if result.returncode != 0:
        failures.append(f'a file that is not DICOM failed the test ({result.returncode})')
    else:
        print('ok: a file that is not DICOM is left to the importer')

    mixed = [work / 'ct.dcm', work / 'ct-truncated.dcm', work / 'pdf.dcm', work / 'notes.txt',
             work / 'ct-garbage.dcm', work / 'rtstruct.dcm']
    result = test(*mixed)
    if result.returncode == 0 or sorted(named(result)) != sorted(str(work / name) for name in broken):
        failures.append(f'a mixed batch named {named(result)} (exit {result.returncode}) instead of the two broken files')
    else:
        print('ok: a mixed batch names its two broken files and nothing else')

# The importer refuses the files the service could not load, and indexes the others.
runner = (root / 'Modules/IsiXDatabase/Sources/ImportValidation.swift').read_text(encoding='utf-8')
if ('extension DecompressService: ImportValidationTester' not in runner
        or 'switch testFile(atPath: file)' not in runner):
    failures.append('IsiXImportValidation no longer tests the files in the Decompress service')
# DicomDatabase (DCMTK) is Swift (DicomDatabase+DCMTK.swift); the service is its tester.
validation = (root / 'Horos/Sources/DicomDatabase+DCMTK.swift').read_text(encoding='utf-8')
start = validation.index('class func filesRefused(byValidation files: [Any]!) -> [Any]!')
body = validation[start:validation.index('\n    class func testFiles', start)]
if 'ImportValidation.refusedFiles(' not in body or 'tester: service' not in body:
    failures.append('+[DicomDatabase filesRefusedByValidation:] no longer asks IsiXImportValidation')
# The copy is DicomDatabase+MediaCopy.swift.
importer = (root / 'Horos/Sources/DicomDatabase+MediaCopy.swift').read_text(encoding='utf-8')
if ('DicomDatabase.filesRefused(byValidation: copiedFiles' not in importer
        or 'addFiles(atPaths: acceptedFiles' not in importer or 'refusedFiles: refusedSources' not in importer):
    failures.append('the importer no longer indexes the files the validation did not refuse, or no longer tells the user')

for failure in failures:
    print('FAIL: ' + failure)
raise SystemExit(1 if failures else 0)
