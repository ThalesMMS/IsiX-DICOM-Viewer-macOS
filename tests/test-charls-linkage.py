#!/usr/bin/env python3
"""DCMTK's CharLS ABI stays private and JPEG-LS decodes correctly.

The production adapter partially links its codec before localizing its
symbols. Verify that boundary and decode synthetic monochrome/RGB streams
with the application's helper against an independent CharLS decoder.
"""
from pathlib import Path
import subprocess
import argparse
import sys
import tempfile

from dcmtk_build import ROOT as root, BUILD, CONFIGURATION
failures = []
parser = argparse.ArgumentParser()
parser.add_argument('--build', type=Path, default=BUILD,
                    help='configuration intermediates from the candidate build')
parser.add_argument('--products', type=Path, default=next(
    (path for path in (root / 'build/Build/Products' / CONFIGURATION,
                      root / 'build/Products' / CONFIGURATION) if path.is_dir()),
    root / 'build/Build/Products' / CONFIGURATION))
parser.add_argument('--python', type=Path, default=root / 'local-validation/dcmtk-venv/bin/python',
                    help='Python with imagecodecs, pydicom and numpy')
args = parser.parse_args()
build, products = args.build.resolve(), args.products.resolve()


def exported(archive):
    """Symbols an archive defines."""
    listed = subprocess.run(['nm', '-g', str(archive)], capture_output=True, text=True)
    return {line.split()[-1] for line in listed.stdout.splitlines()
            if len(line.split()) >= 3 and line.split()[-2] in 'TDSBW'}



# ---------------------------------------------------- 1. who actually runs
copies = {
    'dcmtkcharls': build / 'DCMTK.build/Install/lib/libdcmtkcharls.a',     # pinned DCMTK, CharLS 1.x
}
symbols = {}
for name, archive in copies.items():
    if not archive.exists():
        print('skip: %s is not built' % name)
        sys.exit(2)
    symbols[name] = exported(archive)
    if '_JpegLsDecode' not in symbols[name]:
        failures.append('%s does not define JpegLsDecode; this test is stale' % name)

application = products / 'IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer'
helper = products / 'IsiX DICOM Viewer.app/Contents/Resources/Decompress'
for binary in (application, helper):
    if not binary.exists():
        print('skip: %s is not built' % binary.name)
        sys.exit(2)
    # The codec belongs to the adapter; the host must not expose its C API.
    defining = [line for line in subprocess.check_output(['nm', '-g', str(binary)], text=True)
                .splitlines() if line.endswith(' T _JpegLsDecode')]
    public_codec = {name for name in exported(binary)
                    if name.startswith(('_JpegLs', '_charls_'))}
    if public_codec:
        failures.append('%s exposes the private CharLS API' % binary.name)
    print('%s: %d global CharLS API definitions; DCMTK codec is private' % (binary.name, len(defining)))

# DCM.framework used to run the standalone CharLS; it has no codec now.
framework = products / 'IsiX DICOM Viewer.app/Contents/Frameworks/DCM.framework/Versions/A/DCM'
if not framework.exists():
    print('skip: DCM.framework is not built')
    sys.exit(2)
carried = {line.split()[-1] for line in subprocess.check_output(['nm', str(framework)], text=True).splitlines()
           if line.split()}
if any(name.startswith('_JpegLs') for name in carried):
    failures.append('DCM.framework carries the CharLS API')
print('DCM.framework: no CharLS')

# DCMTK's adapter and codec are partially linked before their private
# definitions are localized, so plugins cannot interpose another codec ABI.
isolated = build / 'DCMTK.build/Install/lib/libhorosdcmjpls.a'
if not isolated.is_file():
    print('skipped: rebuild the isolated DCMTK JPEG-LS archive')
    raise SystemExit(2)
if exported(isolated) & symbols['dcmtkcharls']:
    failures.append('isolated DCMTK JPEG-LS still exports codec symbols')
undefined = subprocess.check_output(['nm', '-u', str(isolated)], text=True)
if any(name in undefined for name in ('_JpegLsDecode', '_JpegLsEncode', '_JpegLsReadHeader')):
    failures.append('DCMTK JPEG-LS still resolves its codec outside the isolated object')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if '"-ldcmjpls"' in project or '"-ldcmtkcharls"' in project:
    failures.append('the host must link the isolated archive, not the colliding stock archives')

# ------------------------------------------ 2. the ABI they pass across
headers = {
    'dcmtkcharls': root / 'DCMTK/dcmjpls/libcharls/pubtypes.h',
}
probe = r'''
#include <cstdio>
#include <cstddef>
#include "HEADER"
int main() {
    printf("%zu %zu %zu %zu %zu %zu %zu %zu %zu %zu %zu\n",
           sizeof(JlsParameters),
           offsetof(JlsParameters, width), offsetof(JlsParameters, height),
           offsetof(JlsParameters, FIELD_BITS), offsetof(JlsParameters, FIELD_STRIDE),
           offsetof(JlsParameters, components), offsetof(JlsParameters, FIELD_ERROR),
           offsetof(JlsParameters, FIELD_ILV), offsetof(JlsParameters, outputBgr),
           offsetof(JlsParameters, custom), offsetof(JlsParameters, jfif));
    return 0;
}
'''
# Measure the parameter layout expected by the private adapter.
names = {
    'dcmtkcharls': {'FIELD_BITS': 'bitspersample', 'FIELD_STRIDE': 'bytesperline',
                    'FIELD_ERROR': 'allowedlossyerror', 'FIELD_ILV': 'ilv'},
}
default = {'FIELD_BITS': 'bitsPerSample', 'FIELD_STRIDE': 'stride',
           'FIELD_ERROR': 'allowedLossyError', 'FIELD_ILV': 'interleaveMode'}

layouts = {}
with tempfile.TemporaryDirectory() as directory:
    for name, header in headers.items():
        if not header.exists():
            failures.append('%s: %s is gone' % (name, header))
            continue
        source = probe.replace('HEADER', str(header))
        for placeholder, field in names.get(name, default).items():
            source = source.replace(placeholder, field)
        path = Path(directory) / ('%s.cc' % name)
        path.write_text(source)
        built = subprocess.run(['xcrun', 'clang++', '-std=c++14', str(path),
                                '-o', str(Path(directory) / name)],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stderr)
            failures.append('%s: the parameter block could not be measured' % name)
            continue
        layouts[name] = subprocess.run([str(Path(directory) / name)],
                                       capture_output=True, text=True).stdout.strip()

for name, layout in sorted(layouts.items()):
    print('  %-14s %s' % (name, layout))
print("The DCMTK CharLS ABI is local to its adapter")

# ------------------------------------------------- 3. decoding is correct
if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
venv = args.python
if not venv.exists():
    print('skip: no python environment with an independent JPEG-LS decoder')
    raise SystemExit(2)
else:
    check = subprocess.run([str(venv), '-c', 'import imagecodecs, pydicom, numpy'],
                           capture_output=True)
    if check.returncode != 0:
        print('skip: install imagecodecs, pydicom and numpy in the --python environment '
              'to check JPEG-LS decoding')
        raise SystemExit(2)
    else:
        with tempfile.TemporaryDirectory() as directory:
            script = r'''
import sys, numpy as np, pydicom, imagecodecs, subprocess
from pathlib import Path
from pydicom.dataset import FileDataset, FileMetaDataset
from pydicom.uid import UID
from pydicom.encaps import encapsulate

directory, helper, collection = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
failures = []

def dicom(pixels, near, name):
    """Wrap JPEG-LS encoded pixels in a DICOM the helper can read."""
    encoded = imagecodecs.jpegls_encode(pixels, level=near)
    meta = FileMetaDataset()
    meta.MediaStorageSOPClassUID = UID("1.2.840.10008.5.1.4.1.1.7")
    meta.MediaStorageSOPInstanceUID = UID("1.2.826.0.1.3680043.8.498.7001")
    meta.TransferSyntaxUID = UID("1.2.840.10008.1.2.4.80" if near == 0 else "1.2.840.10008.1.2.4.81")
    meta.ImplementationClassUID = UID("1.2.826.0.1.3680043.8.498.1")
    dataset = FileDataset(str(directory / name), {}, file_meta=meta, preamble=b"\0" * 128)
    dataset.SOPClassUID = meta.MediaStorageSOPClassUID
    dataset.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
    dataset.StudyInstanceUID = UID("1.2.826.0.1.3680043.8.498.7002")
    dataset.SeriesInstanceUID = UID("1.2.826.0.1.3680043.8.498.7003")
    dataset.Modality = "OT"
    dataset.PatientName = "FIXTURE^JPEGLS"
    dataset.PatientID = "JLS-0001"
    dataset.Rows, dataset.Columns = pixels.shape
    dataset.SamplesPerPixel = 1
    dataset.PhotometricInterpretation = "MONOCHROME2"
    dataset.BitsAllocated = 8 if pixels.dtype == np.uint8 else 16
    dataset.BitsStored = dataset.BitsAllocated
    dataset.HighBit = dataset.BitsStored - 1
    dataset.PixelRepresentation = 0
    dataset.PixelData = encapsulate([encoded])
    dataset["PixelData"].is_undefined_length = True
    path = directory / name
    dataset.save_as(path, enforce_file_format=True)
    return path

def decoded(path, output):
    output.mkdir(exist_ok=True)
    for stale in output.iterdir():
        stale.unlink()
    run = subprocess.run([helper, str(output), "decompressList", str(path)],
                         capture_output=True, text=True)
    if run.returncode != 0:
        return None
    produced = output / path.name
    if not produced.exists():
        return None
    return pydicom.dcmread(produced)

# A round trip through the application's decoder, on data it did not produce.
rng = np.random.default_rng(20260909)
cases = [
    ("8 bit gradient, lossless", np.tile(np.arange(256, dtype=np.uint8), (64, 1)), 0),
    ("8 bit noise, lossless", rng.integers(0, 256, (64, 64), dtype=np.uint8), 0),
    ("16 bit ramp, lossless", (np.arange(128 * 128, dtype=np.uint16) % 4096).reshape(128, 128), 0),
    ("16 bit noise, lossless", rng.integers(0, 4096, (96, 96)).astype(np.uint16), 0),
    ("16 bit ramp, near-lossless 2", (np.arange(64 * 64, dtype=np.uint16) % 4096).reshape(64, 64), 2),
]
for label, pixels, near in cases:
    path = dicom(pixels, near, "roundtrip-%d.dcm" % len(label))
    out = decoded(path, directory / "out")
    if out is None:
        failures.append("%s: the helper did not decompress it" % label)
        continue
    if out.file_meta.TransferSyntaxUID != "1.2.840.10008.1.2.1":
        failures.append("%s: came back as %s" % (label, out.file_meta.TransferSyntaxUID.name))
        continue
    got = np.frombuffer(out.PixelData, dtype=pixels.dtype)[:pixels.size].reshape(pixels.shape)
    worst = int(np.abs(got.astype(int) - pixels.astype(int)).max())
    if near == 0:
        if worst != 0:
            failures.append("%s: %d off the original" % (label, worst))
    elif worst > near:
        failures.append("%s: %d off, more than the %d asked for" % (label, worst, near))
print("round trip: %d cases" % len(cases))

# And the real thing, when the example collection is here.
samples, checked = [], 0
if collection.is_dir():
    import struct
    def transfer_syntax(path):
        try:
            head = path.open("rb").read(4096)
        except OSError:
            return None
        if head[128:132] != b"DICM":
            return None
        i = head.find(b"\x02\x00\x10\x00UI")
        if i < 0:
            return None
        n = struct.unpack("<H", head[i + 6:i + 8])[0]
        return head[i + 8:i + 8 + n].rstrip(b"\x00 ").decode("ascii", "replace")
    for path in collection.rglob("*"):
        if len(samples) >= 6:
            break
        if path.is_file() and path.stat().st_size > 200:
            if transfer_syntax(path) in ("1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81"):
                samples.append(path)

for path in samples:
    working = directory / ("sample-%d.dcm" % checked)
    working.write_bytes(path.read_bytes())
    source = pydicom.dcmread(working)
    out = decoded(working, directory / "out")
    if out is None:
        failures.append("a JPEG-LS sample did not decompress")
        continue
    frames = pydicom.encaps.decode_data_sequence(source.PixelData)
    reference = imagecodecs.jpegls_decode(frames[0])
    got = np.frombuffer(out.PixelData, dtype=reference.dtype)[:reference.size].reshape(reference.shape)
    if not np.array_equal(reference, got):
        failures.append("a JPEG-LS sample decoded differently from the reference")
    checked += 1
print("local samples: %d decoded byte for byte against an independent CharLS" % checked)

for failure in failures:
    print("FAIL: %s" % failure)
sys.exit(1 if failures else 0)
'''
            path = Path(directory) / 'decode.py'
            path.write_text(script)
            ran = subprocess.run([str(venv), str(path), directory, str(helper), str(Path(directory) / 'no-historical-samples')],
                                 capture_output=True, text=True)
            print(ran.stdout.strip())
            if ran.returncode != 0:
                if ran.stderr:
                    print(ran.stderr[-2000:])
                failures.append('JPEG-LS decoding did not match an independent decoder')


if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('PASS: private DCMTK JPEG-LS linkage and ABI')
