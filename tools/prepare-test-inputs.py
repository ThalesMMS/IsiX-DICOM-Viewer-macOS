#!/usr/bin/env python3
"""Prepare the inputs the tests that take arguments need, and the manifest naming them.

Some tests read a built product (the Decompress service, the DCMTK install) or a synthetic fixture this repository does not carry, and skip
without them. This writes those fixtures with the generators in tools/, into
local-validation/test-inputs/ (ignored by Git), and the manifest
local-validation/test-inputs.json that tools/run-tests.py reads by default.
The low-contrast fixture goes to ../DICOM_Example/generated/test-inputs/,
the only place its generator writes.
Nothing here is real patient data.

    python3 tools/prepare-test-inputs.py [--configuration Debug|Release]

Build first (script/build_and_run.sh --verify), and have a Python with
pydicom, numpy, pylibjpeg-openjpeg and imagecodecs in local-validation/ (see
AGENTS.md); the generators run under it. Run again after a clean clone or
when a generator changes: existing fixture folders are rebuilt.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from python_with import interpreter  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--configuration', default='Debug', choices=('Debug', 'Release'))
args = parser.parse_args()

products = ROOT / 'build/Build/Products' / args.configuration
# The Decompress XPC service: the tests run it through their client.
helper = products / 'IsiX DICOM Viewer.app/Contents/XPCServices/Decompress.xpc'
dcmtk = ROOT / 'build/Build/Intermediates.noindex/Horos.build' / args.configuration / 'DCMTK.build/Install'
missing = [str(p.relative_to(ROOT)) for p in (helper, dcmtk) if not p.exists()]
if missing:
    raise SystemExit('build first (script/build_and_run.sh --verify); missing: ' + ', '.join(missing))

python = interpreter('import pydicom', 'import numpy', 'import openjpeg', 'import imagecodecs')
if python is None:
    raise SystemExit('needs a Python with pydicom, numpy, pylibjpeg-openjpeg and imagecodecs, for example:\n'
                     '  python3 -m venv local-validation/fixture-venv\n'
                     "  local-validation/fixture-venv/bin/python -m pip install 'pydicom>=3,<4' numpy "
                     'pynetdicom pylibjpeg pylibjpeg-openjpeg imagecodecs Pillow')

inputs = ROOT / 'local-validation/test-inputs'
inputs.mkdir(parents=True, exist_ok=True)


def fixture(name, generator, *options, base=inputs):
    """A fresh folder written by tools/generate-<generator>-fixture.py."""
    folder = base / name
    if folder.exists():
        shutil.rmtree(folder)
    subprocess.run([python, str(ROOT / 'tools' / f'generate-{generator}-fixture.py'), str(folder), *options],
                   check=True, stdout=subprocess.DEVNULL)
    return folder


def first_dicom(folder):
    return next(p for p in sorted(folder.rglob('*')) if p.is_file() and p.suffix.lower() in ('.dcm', ''))


jpegls = fixture('jpegls', 'jpegls')
mistyped = fixture('mistyped-metadata', 'mistyped-metadata')
palette = fixture('palette-color', 'palette-color')
private = fixture('private-annotation', 'private-annotation')
mpeg4 = fixture('mpeg4', 'mpeg4')
mpeg4_b = fixture('mpeg4-b-frames', 'mpeg4', '--b-frames', '3')
sequence = fixture('sequence-edit', 'sequence-edit')
# This generator writes only inside the examples folder beside the checkout.
examples = ROOT.parent / 'DICOM_Example/generated/test-inputs'
examples.mkdir(parents=True, exist_ok=True)
low_contrast = fixture('planar-low-contrast', 'planar-low-contrast', base=examples)
jpeg2000 = fixture('jpeg2000-multiframe', 'jpeg2000-multiframe')
colour = fixture('colour-space', 'colour-space')

product, decompress = str(products), str(helper)
tests = {
    'test-dcm-host-services.py': [product],
    'test-dicom-writer.py': [product, python],
    'test-hardcopy-image-storage.py': [product],
    'test-odd-frame-decode.py': [product],
    'test-jpegls-pixels.py': [product, str(jpegls)],
    'test-mistyped-metadata.py': [product, str(mistyped)],
    'test-palette-pixels.py': [product, str(palette), '--python', python],
    'test-pixel-reference.py': [product, str(jpegls), str(mistyped), str(jpeg2000)],
    'test-private-annotation-field.py': [product, str(first_dicom(private))],
    'test-dicom-codec-extraction.py': [decompress],
    # An uncompressed file: the helper compresses it and decompresses it back.
    'test-dicom-codec-input-result.py': [decompress, str(first_dicom(private)), 'jpeg2000'],
    'test-dicom-codec-relocation.py': [decompress, str(first_dicom(colour))],
    'test-dicom-codec-write-result.py': [decompress, str(first_dicom(colour))],
    'test-dicom-representation-bridge.py': [decompress],
    'test-sequence-item-edit.py': [str(dcmtk), str(first_dicom(sequence)), '--python', python],
    'test-mpeg4-avc-frames.py': [str(mpeg4), str(mpeg4_b)],
    'test-planar-low-contrast.py': [str(low_contrast)],
}
manifest = ROOT / 'local-validation/test-inputs.json'
manifest.write_text(json.dumps({'tests': {name: {'args': arguments} for name, arguments in tests.items()}},
                               indent=2) + '\n')
print('wrote %s for %d tests' % (manifest.relative_to(ROOT), len(tests)))
