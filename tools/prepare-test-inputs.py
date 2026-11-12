#!/usr/bin/env python3
"""Prepare the inputs the tests that take arguments need, and the manifest naming them.

Some tests read a built product (the Decompress service, the DCMTK install), a
synthetic fixture this repository does not carry or an external checkout, and
skip without them. This writes those fixtures with the generators in tools/,
into local-validation/test-inputs/ (ignored by Git), and the manifest
local-validation/test-inputs.json that tools/run-tests.py reads by default.
The low-contrast fixture goes to ../DICOM_Example/generated/test-inputs/,
the only place its generator writes.
Nothing here is real patient data.

    python3 tools/prepare-test-inputs.py [--configuration Debug|Release] [--output DIR]

Build first (script/build_and_run.sh --verify), and have a Python with
pydicom, numpy, pylibjpeg-openjpeg, imagecodecs, pyjpegls and Pillow in
local-validation/ (see AGENTS.md) or named in HOROS_PYTHON; the generators run
under it, and ffmpeg encodes the MPEG-4 fixture. Run again after a clean clone
or when a generator changes: existing fixture folders are rebuilt.

--output DIR writes test-inputs/ and test-inputs.json in DIR, not in
local-validation/, and nothing anywhere else, so a run of the suite that is
reading the usual ones is not disturbed; the low-contrast fixture and its test
are then left out. Give that manifest to tools/run-tests.py --inputs-manifest.

What is neither built nor generated is looked for, never fetched: in the
environment variable, then in the folders of local-validation/ named below.
A test whose input is not found is left out of the manifest, or left without
that argument, and a line says which tests will skip and how to provide it.

- A checkout of horosproject/horosplugins, which the tests of the legacy
  plugins build from (tests/test-isix-legacy-*.py): HOROSPLUGINS_DIR,
  local-validation/horosplugins-checkout/horosplugins, local-validation/horosplugins.
- The collection of converted plugins, for test-isix-legacy-ported-plugins.py:
  ISIX_PORTED_PLUGINS_DIR, or a folder of local-validation/ whose folders
  have Porting/source.json.
- An ITK installed for a plugin by the plugin template's
  script/build-library.py, for the plugins that carry their own and for
  test-plugin-own-libraries.py: ISIX_PLUGIN_ITK_DIR,
  local-validation/plugin-libraries/ITK.
- A checkout of the plugin template, for test-sdk-release-zip.py:
  ISIX_PLUGIN_TEMPLATE_DIR, local-validation/template-dev,
  local-validation/template.
- A published release of the application, signed with a Developer ID and
  notarized, which test-update-install.py reads: HOROS_TEST_RELEASE_APP,
  local-validation/published-release/IsiX DICOM Viewer.app. One installed in
  /Applications is found by the test itself.

The server of the shared database is compared with the build of the other
configuration when its objects are there (test-shared-database-server-equivalence.py):
both come from the same sources, so that run tells an optimized server from an
unoptimized one, not this revision from an earlier one.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from python_with import interpreter  # noqa: E402

LOCAL = ROOT / 'local-validation'
# The folders of horosplugins the tests of the legacy plugins build.
LEGACY_PLUGINS = ('32BitFloatDICOMExport', 'Cardiac Tagging MRI', 'CardiacStatistics', 'Exec', 'NMSegmentation',
                  'ROICorrectDisplayTextualData', 'ROIRotation', 'SSH', 'Vertebra', 'Volume Calculator',
                  'VolumeGenerator', 'XploreReports')

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--configuration', default='Debug', choices=('Debug', 'Release'))
parser.add_argument('--output', type=Path, default=LOCAL, metavar='DIR',
                    help='write test-inputs/ and test-inputs.json here and nothing anywhere else '
                         '(default: local-validation/)')
args = parser.parse_args()
elsewhere = args.output.resolve() != LOCAL.resolve()
output = args.output.resolve() if elsewhere else LOCAL

products = ROOT / 'build/Build/Products' / args.configuration
# The Decompress XPC service: the tests run it through their client.
helper = products / 'IsiX DICOM Viewer.app/Contents/XPCServices/Decompress.xpc'
dcmtk = ROOT / 'build/Build/Intermediates.noindex/Horos.build' / args.configuration / 'DCMTK.build/Install'
missing = [str(p.relative_to(ROOT)) for p in (helper, dcmtk) if not p.exists()]
if missing:
    raise SystemExit('build first (script/build_and_run.sh --verify); missing: ' + ', '.join(missing))

# What the generators run below import, and what the tests given this interpreter read with.
python = interpreter('import pydicom', 'import numpy', 'import openjpeg', 'import imagecodecs', 'import jpeg_ls',
                     'import PIL')
if python is None:
    raise SystemExit('needs a Python with pydicom, numpy, pylibjpeg-openjpeg, imagecodecs, pyjpegls and Pillow, '
                     'for example:\n'
                     '  python3 -m venv local-validation/fixture-venv\n'
                     "  local-validation/fixture-venv/bin/python -m pip install 'pydicom>=3,<4' numpy "
                     'pynetdicom pylibjpeg pylibjpeg-openjpeg imagecodecs pyjpegls Pillow')

inputs = output / 'test-inputs'
inputs.mkdir(parents=True, exist_ok=True)
notes = []


def fixture(name, generator, *options, base=inputs):
    """A fresh folder written by tools/generate-<generator>-fixture.py."""
    folder = base / name
    if folder.exists():
        shutil.rmtree(folder)
    script = f'generate-{generator}-fixture.py'
    if subprocess.run([python, str(ROOT / 'tools' / script), str(folder), *options],
                      stdout=subprocess.DEVNULL).returncode != 0:
        raise SystemExit(f'tools/{script} did not write {folder}; the manifest was not written')
    return folder


def first_dicom(folder):
    return next(p for p in sorted(folder.rglob('*')) if p.is_file() and p.suffix.lower() in ('.dcm', ''))


def found(variable, places, accepts):
    """The folder $variable names, or the first of `places`, that `accepts` takes; None without one."""
    named = os.environ.get(variable)
    if named and not (Path(named).is_dir() and accepts(Path(named))):
        notes.append(f'{variable}={named} does not hold what it is meant to name; looking in local-validation/')
        named = None
    for place in [Path(named)] if named else places:
        if place.is_dir() and accepts(place):
            return str(place.resolve())
    return None


jpegls = fixture('jpegls', 'jpegls')
mistyped = fixture('mistyped-metadata', 'mistyped-metadata')
palette = fixture('palette-color', 'palette-color')
private = fixture('private-annotation', 'private-annotation')
sequence = fixture('sequence-edit', 'sequence-edit')
jpeg2000 = fixture('jpeg2000-multiframe', 'jpeg2000-multiframe')
colour = fixture('colour-space', 'colour-space')

product, decompress = str(products), str(helper)
tests = {
    'test-dcm-host-services.py': [product],
    'test-dicom-writer.py': [product, python],
    'test-study-file-import.py': [product, python],
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
}

if shutil.which('ffmpeg'):
    mpeg4 = fixture('mpeg4', 'mpeg4')
    mpeg4_b = fixture('mpeg4-b-frames', 'mpeg4', '--b-frames', '3')
    tests['test-mpeg4-avc-frames.py'] = [str(mpeg4), str(mpeg4_b)]
else:
    notes.append('test-mpeg4-avc-frames.py will skip: its fixture is encoded with ffmpeg, which is not installed')

if elsewhere:
    notes.append('test-planar-low-contrast.py is left out: its fixture is only written beside the checkout, '
                 'in ../DICOM_Example/generated/test-inputs/, which --output leaves alone')
else:
    # This generator writes only inside the examples folder beside the checkout.
    examples = ROOT.parent / 'DICOM_Example/generated/test-inputs'
    examples.mkdir(parents=True, exist_ok=True)
    tests['test-planar-low-contrast.py'] = [str(fixture('planar-low-contrast', 'planar-low-contrast', base=examples))]

itk = found('ISIX_PLUGIN_ITK_DIR', [LOCAL / 'plugin-libraries/ITK'],
            lambda folder: (folder / 'lib/libITK.a').is_file() and (folder / 'include/itkConfigure.h').is_file())
collection = found('HOROSPLUGINS_DIR', [LOCAL / 'horosplugins-checkout/horosplugins', LOCAL / 'horosplugins'],
                   lambda folder: all((folder / plugin).is_dir() for plugin in LEGACY_PLUGINS))
if collection:
    ported = found('ISIX_PORTED_PLUGINS_DIR', sorted(p for p in LOCAL.glob('*') if p.is_dir()),
                   lambda folder: any(folder.glob('*/Porting/source.json')))
    with_itk = ['--plugin-itk', itk] if itk else []
    for name in ('bridge', 'database', 'dynamic-access', 'network'):
        tests[f'test-isix-legacy-{name}.py'] = [collection]
    tests['test-isix-legacy-viewer-events.py'] = [collection, *with_itk]
    # Without the ITK it still skips, and then for that reason.
    tests['test-isix-legacy-itk-plugin.py'] = [collection, *with_itk]
    if ported:
        tests['test-isix-legacy-ported-plugins.py'] = [collection, ported, *with_itk]
    else:
        notes.append('test-isix-legacy-ported-plugins.py will skip: no collection of converted plugins; put it in '
                     'a folder of local-validation/ or name it in ISIX_PORTED_PLUGINS_DIR')
    if not itk:
        notes.append('test-isix-legacy-itk-plugin.py will skip, and the tests that build NMSegmentation leave it '
                     'out: no ITK installed for a plugin; the plugin template\'s script/build-library.py itk '
                     '--source <ITK source> --output local-validation/plugin-libraries writes one, or name one '
                     'in ISIX_PLUGIN_ITK_DIR')
else:
    notes.append('the tests of the legacy plugins that build from horosplugins will skip (test-isix-legacy-bridge, '
                 '-database, -dynamic-access, -itk-plugin, -network, -ported-plugins and -viewer-events): no '
                 'checkout; git clone https://github.com/horosproject/horosplugins local-validation/horosplugins, '
                 'or name one in HOROSPLUGINS_DIR')

if itk:
    tests['test-plugin-own-libraries.py'] = ['--plugin-itk', itk]
else:
    notes.append('test-plugin-own-libraries.py will skip: no ITK installed for a plugin (see the note above, or '
                 'ISIX_PLUGIN_ITK_DIR)' if collection else
                 'test-plugin-own-libraries.py will skip: no ITK installed for a plugin; the plugin template\'s '
                 'script/build-library.py itk --source <ITK source> --output local-validation/plugin-libraries '
                 'writes one, or name one in ISIX_PLUGIN_ITK_DIR')

template = found('ISIX_PLUGIN_TEMPLATE_DIR', [LOCAL / 'template-dev', LOCAL / 'template'],
                 lambda folder: (folder / 'script/sdk.py').is_file())
if template:
    tests['test-sdk-release-zip.py'] = [template]
else:
    notes.append('test-sdk-release-zip.py will skip: no checkout of the plugin template; put one in '
                 'local-validation/template or name it in ISIX_PLUGIN_TEMPLATE_DIR')

# The build of the other configuration, of this same checkout, is the baseline.
other = 'Release' if args.configuration == 'Debug' else 'Debug'
if (ROOT / 'build/Build/Intermediates.noindex/Horos.build' / other
        / 'Horos.build/Objects-normal/arm64/BonjourPublisher.o').is_file():
    tests['test-shared-database-server-equivalence.py'] = [
        '--configuration', args.configuration, '--baseline-objects-root', str(ROOT), '--baseline-configuration', other]
else:
    notes.append(f'test-shared-database-server-equivalence.py will skip: no {other} build of this checkout to '
                 'compare the server with')

environment = {}
release = found('HOROS_TEST_RELEASE_APP', [LOCAL / 'published-release/IsiX DICOM Viewer.app'],
                lambda bundle: (bundle / 'Contents/Info.plist').is_file())
if release:
    tests.setdefault('test-update-install.py', [])
    environment['test-update-install.py'] = {'HOROS_TEST_RELEASE_APP': release}
elif not Path('/Applications/IsiX DICOM Viewer.app').is_dir():
    notes.append('test-update-install.py will skip its last part: no published release of the application; '
                 'unpack one into local-validation/published-release/ or name it in HOROS_TEST_RELEASE_APP')

manifest = output / 'test-inputs.json'
entries = {name: {'args': arguments, **({'env': environment[name]} if name in environment else {})}
           for name, arguments in sorted(tests.items())}
manifest.write_text(json.dumps({'tests': entries}, indent=2) + '\n')
for note in notes:
    print(note)
print('wrote %s for %d tests' % (manifest if elsewhere else manifest.relative_to(ROOT), len(tests)))
