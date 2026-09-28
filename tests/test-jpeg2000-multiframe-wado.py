#!/usr/bin/env python3
"""A JPEG 2000 multiframe instance survives a WADO retrieval frame for frame.

Tomosynthesis arrives as one multiframe object in JPEG 2000 lossless. The
question is whether what comes back over WADO is what a local import gives:
the same number of frames and the same pixels. Lossless, so any difference is a
defect and not a codec.

The fixture generator is exercised here - it encodes with OpenJPEG and the
frames are decoded back and compared against the digests it recorded, so the
fixture cannot silently be lossy. The comparison of the two routes was made
against a running build; see the validation document.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
# WADODownload is Swift since #716.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
download = sources.source_text('WADODownload')
fixture = (root / 'tools/serve-wado-fixture.py').read_text()


sys.path.insert(0, str(Path(__file__).resolve().parent))
import python_with

# A python that can both encode and decode JPEG 2000; without one the fixture
# cannot be made, which is a skip, not a failure (#706).
python = python_with.interpreter('import pydicom, numpy', 'from openjpeg import encode, decode')
if python is None and not failures:
    print("skipped: needs a Python with pydicom, numpy and pylibjpeg-openjpeg; for example "
          "local-validation/fixture-venv/bin/python -m pip install 'pydicom>=3,<4' numpy pylibjpeg "
          "pylibjpeg-openjpeg", file=sys.stderr)
    raise SystemExit(2)
if python is not None:
    with tempfile.TemporaryDirectory(prefix='horos-tomo-') as directory:
        destination = Path(directory) / 'tomo'
        built = subprocess.run([python, str(root / 'tools/generate-jpeg2000-multiframe-fixture.py'),
                                str(destination), '--frames', '4', '--size', '32'],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the fixture does not generate: %s' % built.stderr[-800:])
        else:
            check = subprocess.run(
                [python, '-c', '''
import hashlib, json, sys
import numpy as np
from pydicom import dcmread
destination = sys.argv[1]
manifest = json.load(open(destination + "/manifest.json"))
report = {}
for name in ("local.dcm", "wado.dcm"):
    ds = dcmread(destination + "/" + name)
    arr = ds.pixel_array
    report[name] = {
        "syntax": str(ds.file_meta.TransferSyntaxUID),
        "frames": int(ds.NumberOfFrames),
        "shape": list(arr.shape),
        "digests": [hashlib.sha256(np.ascontiguousarray(arr[i]).astype("<u2").tobytes()).hexdigest()
                    for i in range(int(ds.NumberOfFrames))],
        "sop_class": str(ds.SOPClassUID),
    }
report["expected"] = manifest["frame_sha256"]
report["studies"] = [manifest["instances"][n]["study"] for n in ("local.dcm", "wado.dcm")]
print(json.dumps(report))
''', str(destination)], capture_output=True, text=True)
            if check.returncode != 0:
                failures.append('the fixture does not read back: %s' % check.stderr[-800:])
            else:
                report = json.loads(check.stdout)
                for name in ('local.dcm', 'wado.dcm'):
                    entry = report[name]
                    if entry['syntax'] != '1.2.840.10008.1.2.4.90':
                        failures.append('%s is not JPEG 2000 lossless: %s' % (name, entry['syntax']))
                    if entry['frames'] != 4 or entry['shape'] != [4, 32, 32]:
                        failures.append('%s is %d frames of %s' % (name, entry['frames'],
                                                                   entry['shape']))
                    if entry['sop_class'] != '1.2.840.10008.5.1.4.1.1.13.1.3':
                        failures.append('%s is not breast tomosynthesis: %s'
                                        % (name, entry['sop_class']))
                    # The encoding has to be lossless, or comparing the two
                    # routes proves nothing.
                    if entry['digests'] != report['expected']:
                        failures.append('%s does not decode back to the pixels it was made from'
                                        % name)
                if report['local.dcm']['digests'] != report['wado.dcm']['digests']:
                    failures.append('the two copies do not hold the same pixels')
                if report['studies'][0] == report['studies'][1]:
                    failures.append('the two copies share a study, so one would not be imported '
                                    'beside the other')

# --- a reply that is not DICOM is not a received instance ---------------------
at = download.find('public func connectionDidFinishLoading(')
body = download[at:at + 4000] if at >= 0 else ''
if not body:
    failures.append('the download completion is gone')
else:
    if 'DICM' not in body:
        failures.append('a WADO reply is written without checking that it is DICOM at all')
    if 'recordFailure(forURL' not in body:
        failures.append('a reply that is not DICOM is still counted as received')
    if not re.search(r'recordFailure\(forURL:[^\n]*statusCode:\s*0', body):
        failures.append('a reply that is not DICOM is not treated as worth asking for again')
    # And the file must not be left for the importer to find.
    if 'removeItem(atPath' not in body:
        failures.append('the file that is not DICOM is left in the incoming folder')

# --- the fixture can produce the case ----------------------------------------
for expected, missing in (('--truncate-instances', 'the fixture cannot truncate a reply'),
                          ('--truncate-to-bytes',
                           'the fixture cannot cut a reply short of the DICOM magic')):
    if expected not in fixture:
        failures.append(missing)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the JPEG 2000 multiframe fixture is lossless and two copies of it match, and a WADO '
      'reply that is not a DICOM object is not counted as an instance received')
