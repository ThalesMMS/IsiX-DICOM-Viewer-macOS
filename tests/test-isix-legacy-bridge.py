#!/usr/bin/env python3
"""IsiXLegacyBridge: legacy Horos/OsiriX plugins built from their original source
as plugins of the IsiX plugin API 1, without the application.

    python3 tests/test-isix-legacy-bridge.py HOROSPLUGINS_DIR

HOROSPLUGINS_DIR is a checkout of horosproject/horosplugins; it is external
input and not part of this repository. Without it the test exits with 2.

The test exports the SDK a plugin sees (as tests/test-isix-plugin-kit.py does)
and builds with tools/build-isix-legacy-plugin.py, which converts each plugin
with tools/port-legacy-plugin.py (the build, the Info.plist and the mechanical
rewrites of deprecated calls; nothing by hand):

- four plugins of horosplugins: Cardiac Tagging MRI (an image filter that
  works on the whole series and opens a new viewer), ROIRotation (a ROI tool
  with its own dialog from a nib), ROICorrectDisplayTextualData (every ROI of
  every image of every viewer) and Vertebra (the series copied into a new
  viewer); all are written for manual reference counting;
- the test's own probe (tests/fixtures/isix-legacy-bridge/KitProbe), once with
  manual reference counting and once with ARC: pixels changed and given back,
  window level, ROIs created, renamed, selected and removed.

It checks that the kit compiles without warnings; that each bundle links only
the kit and the system, carries no former Info.plist key and no former SDK;
and, through tests/fixtures/isix-legacy-bridge/LegacyHarness.swift, which runs
the application's loading path with synthetic viewers, that the loader accepts
each one and that each does what the original did.
"""
from pathlib import Path
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
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-legacy-bridge'
KIT = ROOT / 'IsiXLegacyBridge'
PROOFS = {'Cardiac Tagging MRI': 'CardiacTaggingMRI', 'ROIRotation': 'ROIRotation',
          'ROICorrectDisplayTextualData': 'ROICorrectDisplayTextualData', 'Vertebra': 'Vertebra'}
ALLOWED_LIBRARY = re.compile(r'^(@rpath/IsiXPluginKit\.framework/Versions/A/IsiXPluginKit'
                             r'|/usr/lib/(libSystem\.B|libobjc\.A|swift/libswift\w+)\.dylib'
                             r'|/System/Library/Frameworks/\w+\.framework/Versions/\w+/\w+)$')
FORMER_KEYS = {'pluginType', 'MenuTitles', 'ToolbarNames', 'FileFormats', 'HorosCompatiblePlugin', 'Requirements'}
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if len(sys.argv) < 2 or not Path(sys.argv[1]).is_dir() or not all((Path(sys.argv[1]) / p / 'Info.plist').is_file() for p in PROOFS):
    sys.stderr.write('SKIP: needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)\n')
    sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
collection = Path(sys.argv[1])
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

# The kit talks to the application through the public plugin API only; objc is
# the system's Objective-C runtime, for the lookups by name.
for source in sorted((KIT / 'Sources').iterdir()) + sorted((KIT / 'Headers').iterdir()):
    text = source.read_text()
    check('@_spi' not in text and 'IsiXHost' not in text, f'{source.name} reaches the host interface')
    imports = set(re.findall(r'^\s*import (\w+)', text, re.M)) | set(re.findall(r'#import <(\w+)/', text))
    check(imports <= {'AppKit', 'Foundation', 'Cocoa', 'CoreData', 'UniformTypeIdentifiers', 'IsiXPluginKit',
                      'objc'}, f'{source.name} imports {sorted(imports)}')
for header in sorted((KIT / 'Headers').glob('*.h')):
    if header.stem in ('PluginFilter', 'ViewerController', 'DCMPix', 'DCMView', 'ROI', 'MyPoint'):
        check(f'@compatibility_alias {header.stem} IsiXLegacy{header.stem};' in header.read_text(),
              f'{header.name} does not give the legacy name')


def scan(bundle):
    tag = bundle.name + ': '
    info = plistlib.loads((bundle / 'Contents' / 'Info.plist').read_bytes())
    check(not FORMER_KEYS & info.keys(), tag + f'former keys {sorted(FORMER_KEYS & info.keys())}')
    check(info.get('IsiXPluginAPIVersion') == 1 and info.get('NSPrincipalClass') == f'{bundle.stem}.IsiXLegacyPluginEntry',
          tag + f'Info.plist {info}')
    binary = bundle / 'Contents' / 'MacOS' / bundle.stem
    libraries = [line.split(' (compatibility')[0].strip() for line in
                 subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout.splitlines()[1:]]
    bad = [library for library in libraries if not ALLOWED_LIBRARY.match(library)]
    check(not bad, tag + f'links {bad}')
    check(not list(bundle.rglob('*.framework')), tag + 'carries a framework')


with tempfile.TemporaryDirectory(prefix='isix-legacy-bridge-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    plugins = work / 'plugins'
    plugins.mkdir()
    bundles = []
    for folder, module in PROOFS.items():
        warnings = {}
        try:
            bundles.append(builder.build(sdk, collection / folder, plugins, module, warnings=warnings))
        except RuntimeError as error:
            failures.append(f'{folder} does not build: {error}')
            continue
        check(not warnings['kit'], f'{folder}: the kit has warnings: {warnings["kit"]}')
    # The probe once more from a copy whose Info.plist names no principal class,
    # as some legacy plugins had none: the kit takes the plugin's only PluginFilter.
    unnamed = work / 'KitProbeUnnamed'
    shutil.copytree(FIXTURES / 'KitProbe', unnamed)
    info = plistlib.loads((unnamed / 'Info.plist').read_bytes())
    del info['NSPrincipalClass']
    (unnamed / 'Info.plist').write_bytes(plistlib.dumps(info))
    for module, arc, folder in (('KitProbeMRC', False, FIXTURES / 'KitProbe'), ('KitProbeARC', True, FIXTURES / 'KitProbe'),
                                ('KitProbeUnnamed', False, unnamed)):
        warnings = {}
        bundles.append(builder.build(sdk, folder, plugins, module, arc=arc, warnings=warnings))
        check(not warnings['kit'] and not warnings['plugin'], f'{module}: warnings {warnings}')
    for bundle in bundles:
        scan(bundle)

    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', 'arm64-apple-macos15.0'])
    harness = work / 'LegacyHarness'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0',
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                    '-o', str(harness), str(FIXTURES / 'LegacyHarness.swift')], check=True)
    probe_output = work / 'probe'
    environment = dict(os.environ, ISIX_LEGACY_PROBE_OUTPUT=str(probe_output), NSZombieEnabled='YES')
    run = subprocess.run([str(harness), *map(str, bundles)], capture_output=True, text=True, timeout=120, env=environment)
    if run.returncode != 0:
        failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        report = {}
    else:
        report = json.loads(run.stdout)
    check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])
    probes = {arc: plistlib.loads(Path(f'{probe_output}-{arc}.plist').read_bytes())
              for arc in (0, 1) if Path(f'{probe_output}-{arc}.plist').is_file()}

    if report:
        check(report['unprefixedLegacyClasses'] == [], f'legacy names in the runtime: {report["unprefixedLegacyClasses"]}')
        for name, outcome in report.items():
            if isinstance(outcome, dict):
                check(outcome.get('state') == 'active', f'{name}: {outcome}')
                check('runError' not in outcome, f'{name}: {outcome.get("runError")}')
                check(outcome.get('kitClass') is True, f'{name}: the kit classes are not named after the plugin')

        cardiac = report.get('CardiacTaggingMRI', {})
        check(cardiac.get('commands') == ['Tagging MRI|imageFilters|viewer'], f'Cardiac commands {cardiac.get("commands")}')
        check(cardiac.get('viewers') == 2 and cardiac.get('derivedFrom') == [0, 1, 2, 3], f'Cardiac new viewer: {cardiac}')
        check(cardiac.get('maxDifference', 1) <= 1e-4 and cardiac.get('sourceUnchanged') is True, f'Cardiac values: {cardiac}')

        vertebra = report.get('Vertebra', {})
        check(vertebra.get('viewers') == 2 and vertebra.get('copyEqual') is True, f'Vertebra: {vertebra}')

        text = report.get('ROICorrectDisplayTextualData', {})
        check(text.get('commands') == ['ROI Info|imageFilters|viewer'], f'ROI Info commands {text.get("commands")}')
        check(text.get('textBoxesBefore') == 0 and text.get('textBoxesAfter') == text.get('rois') == 6
              and text.get('unchangedOtherwise') is True, f'ROI Info: {text}')

        rotation = report.get('ROIRotation', {})
        check(rotation.get('commands') == ['ROI Rotation|roiTools|viewer'], f'ROI Rotation commands {rotation.get("commands")}')
        check(rotation.get('dialog') != '', 'ROI Rotation did not show its dialog')
        check(rotation.get('turned') == f'polygon turned [{rotation.get("expected")}] selected true text true',
              f'ROI Rotation turned {rotation.get("turned")}, expected {rotation.get("expected")}')
        check(rotation.get('kept') == 'rectangle kept [0.0000,0.0000 1.0000,1.0000] selected false text true',
              f'ROI Rotation kept {rotation.get("kept")}')

        for module in ('KitProbeMRC', 'KitProbeARC', 'KitProbeUnnamed'):
            probe = report.get(module, {})
            check(probe.get('commits') == 1 and probe.get('slice1Doubled') is True and probe.get('othersUnchanged') is True,
                  f'{module} pixels: {probe}')
            check(probe.get('level') == [123, 456], f'{module} window level {probe.get("level")}')
            check(probe.get('roisLeft') == [], f'{module} left ROIs {probe.get("roisLeft")}')

    check(sorted(probes) == [0, 1], f'probe reports: {sorted(probes)}')
    for arc, probe in probes.items():
        tag = f'probe arc={arc}: '
        check(probe['images'] == 3 and probe['size'] == [6, 4] and probe['spacing'] == [0.5, 0.75] and probe['current'] == 2
              and probe['phases'] == 1, tag + f'{probe}')
        # Pixel (2.5, 1.5) at half coordinates is the centre of column 2, row 1 of slice 1.
        check(probe['patient'] == [-9.0, 20.75, 32.0], tag + f'patient point {probe["patient"]}')
        check(probe['volumeIsFirstImage'] == 1, tag + 'the volume is not the images one after the other')
        check(probe['windowLevel'] == [123, 456], tag + f'window level {probe["windowLevel"]}')
        # Rectangle (1.5, 1.5)-(4.5, 3.5) at half coordinates: columns 1-4, rows 1-3 of slice 2.
        expected_mean = sum(10 + 3 * 2 + 2 * r + c for r in (1, 2, 3) for c in (1, 2, 3, 4)) / 12
        check(abs(probe['rectangleMean'] - expected_mean) < 1e-4, tag + f'rectangle mean {probe["rectangleMean"]} != {expected_mean}')
        check(abs(probe['rectangleArea'] - 3 * 0.5 * 2 * 0.75 / 100) < 1e-6, tag + f'rectangle area {probe["rectangleArea"]}')
        check(probe['roisAfterAdd'] == ['probe rectangle', 'probe polygon'] and probe['sameObjectAfterRead'] == 1,
              tag + f'ROIs {probe["roisAfterAdd"]}')
        check(abs(probe['polygonCentroid'][0] - 2.5) < 1e-4 and abs(probe['polygonCentroid'][1] - 13 / 6) < 1e-4,
              tag + f'centroid {probe["polygonCentroid"]}')
        check(probe['roisAtEnd'] == 0, tag + f'ROIs at the end {probe["roisAtEnd"]}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'IsiXLegacyBridge: {", ".join(PROOFS)} and the probe (MRC, ARC) built from source and checked')
