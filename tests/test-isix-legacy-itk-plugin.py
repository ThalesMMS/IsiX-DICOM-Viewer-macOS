#!/usr/bin/env python3
"""A legacy plugin that uses ITK, ported with IsiXLegacyBridge and its own ITK.

    python3 tests/test-isix-legacy-itk-plugin.py HOROSPLUGINS_DIR --plugin-itk ITK_DIR

HOROSPLUGINS_DIR is a checkout of horosproject/horosplugins and ITK_DIR an ITK
installed for a plugin by the plugin template's script/build-library.py
(include/ and lib/libITK.a, built static with hidden visibility); both are
external input, and the test exits with 2 without them.

NMSegmentation (region growing in 3D from a seed, in a window of its own,
written for ITK 3 and manual reference counting) is built from its original
source by tools/build-isix-legacy-plugin.py with --library ITK_DIR. Only the
build changes, with the converter's rewrites of deprecated calls
(tools/port-legacy-plugin.py), and, in a copy of the source, the ITK smart
pointers set to 0, which ITK 5 no longer accepts; the test checks that the
builder changed nothing else for ITK. The bundle must link only the kit, the system, libc++ and zlib,
export only its Objective-C classes and bind no ITK symbol from outside.

The plugin then runs in tests/fixtures/isix-legacy-bridge/LegacyHarness.swift,
the application's loading path with a synthetic viewer: a 32 x 32 series of
five images with a 10 x 10 square of 2000 on a background of 40. The command
opens the plugin's window; the harness sets the seed in the square and the
thresholds 1000 to 3000 in that window, as the user would, and presses
Compute. The region growing must give, on each image, one brush ROI of the
100 pixels of the square, named with the volume the plugin computes
(500 voxels of 0.5 x 0.75 x 2 mm: 0.375 cm3).
"""
from pathlib import Path
import argparse
import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / 'tests' / 'fixtures' / 'isix-legacy-bridge' / 'LegacyHarness.swift'
PLUGIN = 'NMSegmentation'
ALLOWED_LIBRARY = re.compile(r'^(@rpath/IsiXPluginKit\.framework/Versions/A/IsiXPluginKit'
                             r'|/usr/lib/(libSystem\.B|libobjc\.A|libc\+\+\.1|libz\.1|swift/libswift\w+)\.dylib'
                             r'|/System/Library/Frameworks/\w+\.framework/Versions/\w+/\w+)$')
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('horosplugins', type=Path, nargs='?')
parser.add_argument('--plugin-itk', type=Path)
parser.add_argument('--keep', type=Path, help='build in this empty folder and keep what was built')
arguments = parser.parse_args()
if arguments.horosplugins is None or not (arguments.horosplugins / PLUGIN / 'Info.plist').is_file():
    sys.stderr.write('SKIP: needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)\n')
    sys.exit(2)
if arguments.plugin_itk is None or not (arguments.plugin_itk / 'lib/libITK.a').is_file():
    sys.stderr.write('SKIP: needs --plugin-itk, an ITK installed by the plugin template\'s script/build-library.py\n')
    sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

if arguments.keep and (not arguments.keep.is_dir() or any(arguments.keep.iterdir())):
    sys.exit(f'--keep {arguments.keep}: not an empty folder')
with tempfile.TemporaryDirectory(prefix='isix-legacy-itk-') as temporary:
    work = Path(os.path.realpath(arguments.keep or temporary))
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    warnings = {}
    try:
        bundle = builder.build(sdk, arguments.horosplugins / PLUGIN, work, PLUGIN, warnings=warnings,
                               libraries=[arguments.plugin_itk], defines=['nmITK=itk'])
    except RuntimeError as error:
        print(f'{PLUGIN} does not build: {error}')
        sys.exit(1)
    check(not warnings['kit'], f'the kit has warnings: {warnings["kit"]}')
    # The plugin renamed ITK's namespace for its own copy (ITKNS nmITK); the
    # only source change is ITK 5's null smart pointer, in the region growing.
    check(warnings.get('adapted') == {'ITKRegionGrowing3D.mm': 5}, f'source adapted: {warnings.get("adapted")}')
    # Calls the kit does not cover stay warnings, in code the test does not reach:
    # merging into existing brush ROIs, when a user default asks for it.
    missing = sorted({m.group(1) for line in warnings['plugin']
                      for m in [re.search(r"(?:instance method|may not respond to) '-?([^']+)'", line)] if m})
    check(missing == ['mergeBrushROI:'], f'legacy calls the kit does not declare: {missing}')

    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    check(info.get('IsiXPluginAPIVersion') == 1 and info.get('NSPrincipalClass') == f'{PLUGIN}.IsiXLegacyPluginEntry',
          f'Info.plist {info}')
    binary = bundle / 'Contents/MacOS' / PLUGIN
    libraries = [line.split(' (compatibility')[0].strip() for line in
                 subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout.splitlines()[1:]]
    check(not [l for l in libraries if not ALLOWED_LIBRARY.match(l)], f'links {libraries}')
    # Only its Objective-C classes, which the kit looks up in the plugin's own image.
    exported = [line.split()[-1] for line in
                subprocess.run(['nm', '-gU', str(binary)], capture_output=True, text=True, check=True).stdout.splitlines()]
    others = [s for s in exported if not s.startswith(('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'))]
    check(exported and not others, f'the plugin exports {others[:10] or "nothing"}')
    imported = subprocess.run(['nm', '-u', str(binary)], capture_output=True, text=True, check=True).stdout.split()
    check(not [s for s in imported if re.search(r'itk|vnl|vcl', s)], 'the plugin binds ITK symbols from outside')
    flags = subprocess.run(['otool', '-hv', str(binary)], capture_output=True, text=True, check=True).stdout
    check('TWOLEVEL' in flags and 'WEAK_DEFINES' not in flags, f'Mach-O flags: {flags.splitlines()[-1]}')

    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', 'arm64-apple-macos15.0'])
    harness = work / 'LegacyHarness'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0',
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                    '-o', str(harness), str(HARNESS)], check=True)
    run = subprocess.run([str(harness), str(bundle)], capture_output=True, text=True, timeout=120,
                         env=dict(os.environ, NSZombieEnabled='YES'))
    if run.returncode != 0:
        failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        report = {}
    else:
        report = json.loads(run.stdout).get(PLUGIN, {})
    check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])
    if report:
        check(report.get('state') == 'active', f'state: {report}')
        check(report.get('commands') == ['NMSegmentation Region Growing|roiTools|viewer'], f'commands {report.get("commands")}')
        check('runError' not in report, f'run: {report.get("runError")}')
        check(report.get('kitClass') is True, 'the kit classes are not named after the plugin')
        check(report.get('window') not in (None, ''), 'the plugin did not open its window')
        check(report.get('algorithm') == 0, f'algorithm {report.get("algorithm")}, expected Connected Threshold (0)')
        expected = [f'slice {s} Segmented Region -> Volume: 0.375 cm3 mask 4,4 10x10 inside 100' for s in range(5)]
        check(sorted(report.get('brushes', [])) == expected, f'brush ROIs {report.get("brushes")}, expected {expected}')
        check(report.get('otherROIs') == [], f'other ROIs left: {report.get("otherROIs")}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'{PLUGIN} ported with its own ITK: one brush ROI of the square on each of the 5 images')
