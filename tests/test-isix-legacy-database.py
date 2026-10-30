#!/usr/bin/env python3
"""IsiXLegacyBridge, database part: legacy Horos/OsiriX database plugins built
from their original source as plugins of the IsiX plugin API 1, without the
application.

    python3 tests/test-isix-legacy-database.py HOROSPLUGINS_DIR

HOROSPLUGINS_DIR is a checkout of horosproject/horosplugins; it is external
input and not part of this repository. Without it the test exits with 2.

The test exports the SDK a plugin sees, builds with
tools/build-isix-legacy-plugin.py (only the build and the Info.plist change):

- 32BitFloatDICOMExport: the current image of a viewer written as a DICOM
  file of its study by DICOMExport, from -[DCMPix sourceFile], and added to
  the database with +[BrowserController addFiles:toContext:...];
- VolumeGenerator: its modal dialog (Create pressed by the harness), a
  volume of 16 DICOM files written with DCMObject, added with
  -addFilesAndFolderToDatabase:, and the new series opened;
- the test's own probe (tests/fixtures/isix-legacy-bridge/DatabaseProbe),
  with manual reference counting and with ARC: selection, key-value coding
  of the legacy names, NSFetchRequest and NSPredicate, comments, state,
  report and key image, albums, DCMObject written and read back, a derived
  series of two images, and two changes the database must refuse.

It checks that the kit compiles without warnings, that each bundle links
only the kit and the system and declares the database capabilities it uses, and,
through tests/fixtures/isix-legacy-bridge/LegacyDatabaseHarness.swift (the
application's loading path, a synthetic database that applies the
application's rules from the IsiXDatabase module, and a synthetic viewer),
what each plugin did. With ISIX_LEGACY_DATABASE_REPORT set to a path, the
harness's report is written there.
"""
from pathlib import Path
import importlib.util
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module, dependencies  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-legacy-bridge'
PROOFS = {'32BitFloatDICOMExport': 'FloatDICOMExport', 'VolumeGenerator': 'VolumeGenerator'}
ALLOWED_LIBRARY = re.compile(r'^(@rpath/IsiXPluginKit\.framework/Versions/A/IsiXPluginKit'
                             r'|/usr/lib/(libSystem\.B|libobjc\.A|swift/libswift\w+)\.dylib'
                             r'|/System/Library/Frameworks/\w+\.framework/Versions/\w+/\w+)$')
# The capabilities follow what the sources use: the two plugins read and write
# DICOM into the database; the probe also changes what the user can edit.
BASE_CAPABILITIES = ['viewer.read', 'viewer.write', 'roi']
EXPECTED_CAPABILITIES = {'FloatDICOMExport': BASE_CAPABILITIES + ['database.read', 'database.import'],
                         'VolumeGenerator': BASE_CAPABILITIES + ['database.read', 'database.import'],
                         'DatabaseProbeMRC': BASE_CAPABILITIES + ['database.read', 'database.write', 'database.import'],
                         'DatabaseProbeARC': BASE_CAPABILITIES + ['database.read', 'database.write', 'database.import']}
STUDY = '1.2.826.0.1.3680043.9.1544.1'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sample(s, r, c):
    return float(-50 + 7 * s + 3 * r + c)


if len(sys.argv) < 2 or not all((Path(sys.argv[1]) / p / 'Info.plist').is_file() for p in PROOFS):
    sys.stderr.write('SKIP: needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)\n')
    sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
collection = Path(sys.argv[1])
# Each database class of the kit gives the legacy source its legacy name.
for name in ('DicomStudy', 'DicomSeries', 'DicomImage', 'DicomAlbum', 'DicomDatabase', 'BrowserController', 'DICOMExport',
             'DCMObject', 'DCMAttribute', 'DCMAttributeTag', 'DCMPixelDataAttribute', 'DCMTransferSyntax', 'DCMCalendarDate'):
    header = ROOT / 'IsiXLegacyBridge' / 'Headers' / f'{name}.h'
    check(f'@compatibility_alias {name} IsiXLegacy{name};' in header.read_text(), f'{header.name} does not give the legacy name')
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

with tempfile.TemporaryDirectory(prefix='isix-legacy-database-') as temporary:
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
        # A legacy call the kit does not declare is a warning of the plugin's own files.
        missing = [w for w in warnings['plugin'] if 'not found' in w or 'may not respond' in w]
        check(not missing, f'{folder}: calls the kit does not cover: {missing}')
    for module, arc in (('DatabaseProbeMRC', False), ('DatabaseProbeARC', True)):
        warnings = {}
        bundles.append(builder.build(sdk, FIXTURES / 'DatabaseProbe', plugins, module, arc=arc, warnings=warnings))
        check(not warnings['kit'] and not warnings['plugin'], f'{module}: warnings {warnings}')
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Contents' / 'Info.plist').read_bytes())
        check(info.get('IsiXPluginCapabilities') == EXPECTED_CAPABILITIES[bundle.stem],
              f'{bundle.name}: capabilities {info.get("IsiXPluginCapabilities")}')
        binary = bundle / 'Contents' / 'MacOS' / bundle.stem
        libraries = [line.split(' (compatibility')[0].strip() for line in
                     subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout.splitlines()[1:]]
        bad = [library for library in libraries if not ALLOWED_LIBRARY.match(library)]
        check(not bad, f'{bundle.name}: links {bad}')

    modules = work / 'modules'
    target = ['-target', 'arm64-apple-macos15.0']
    for name in ('IsiXPluginLoading', 'IsiXDatabase'):
        build_module(name, modules, extra=target)
    harness = work / 'LegacyDatabaseHarness'
    libraries = ['-lIsiXPluginLoading', '-lIsiXDatabase', *(f'-l{each}' for each in dependencies('IsiXDatabase'))]
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target,
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(modules), '-L', str(modules), *libraries,
                    '-o', str(harness), str(FIXTURES / 'LegacyDatabaseHarness.swift')], check=True)
    probe_output = work / 'probe'
    environment = dict(os.environ, ISIX_LEGACY_PROBE_OUTPUT=str(probe_output), NSZombieEnabled='YES')
    run = subprocess.run([str(harness), *map(str, bundles)], capture_output=True, text=True, timeout=120, env=environment)
    if run.returncode != 0:
        failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        report = {}
    else:
        report = json.loads(run.stdout)
        if os.environ.get('ISIX_LEGACY_DATABASE_REPORT'):
            Path(os.environ['ISIX_LEGACY_DATABASE_REPORT']).write_text(run.stdout)
    check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])
    probes = {arc: plistlib.loads(Path(f'{probe_output}-database-{arc}.plist').read_bytes())
              for arc in (0, 1) if Path(f'{probe_output}-database-{arc}.plist').is_file()}

    if report:
        check(report['unprefixedLegacyClasses'] == [], f'legacy names in the runtime: {report["unprefixedLegacyClasses"]}')
        for name, outcome in report.items():
            if isinstance(outcome, dict):
                check(outcome.get('state') == 'active', f'{name}: {outcome.get("state")} {outcome.get("activationError")}')
                check(outcome.get('kitClass') is True, f'{name}: the kit classes are not named after the plugin')

        exported = report.get('FloatDICOMExport', {})
        check(exported.get('commands') == ['Export in DICOM 32-bit float|imageFilters|viewer'], f'Float commands {exported.get("commands")}')
        check('runError' not in exported, f'Float: {exported.get("runError")}')
        # The current image (slice 1) of the viewer, its own file as the source, added as a new series of its study.
        check(exported.get('derived') == 1 and exported.get('valuesEqual') is True and exported.get('size') == [6, 4],
              f'Float derived image: {exported}')
        check(exported.get('source') == f'{STUDY}.1.2' and exported.get('study') == STUDY, f'Float source: {exported}')
        check(exported.get('importedSeries') == 2 and exported.get('importedImages') == 4, f'Float import: {exported}')

        volume = report.get('VolumeGenerator', {})
        check(volume.get('commands') == ['VolumeGenerator|database|none'], f'VolumeGenerator commands {volume.get("commands")}')
        check('runError' not in volume, f'VolumeGenerator: {volume.get("runError")}')
        check(volume.get('dialog') is not None and volume.get('dialog') != '', 'VolumeGenerator did not show its dialog')
        files = sorted(volume.get('files', []), key=lambda f: f['instance'])
        check(len(files) == 16, f'VolumeGenerator wrote {len(files)} files')
        for z, file in enumerate(files):
            # 64 x 36, 16-bit words, a checkerboard (x + y + z) % 2, as the plugin computes it.
            expected = [(x + y + z) % 2 for y in range(36) for x in range(64)]
            check(file['instance'] == z and file['rows'] == 36 and file['columns'] == 64 and file['bitsAllocated'] == 16
                  and file['words'] == expected, f'VolumeGenerator file {z}: {dict((k, v) for k, v in file.items() if k != "words")}')
            check(file['study'] == 'de Medica Industria' and file['series'] == 'Ulm' and file['patient'] == 'Paracelsus',
                  f'VolumeGenerator identity {z}: {file["study"]} {file["series"]} {file["patient"]}')
            check(file['spacing'] in ('0.5\\0.5',) and file['orientation'] == '1\\0\\0\\0\\1\\0',
                  f'VolumeGenerator geometry {z}: {file["spacing"]} {file["orientation"]}')
            # Text that is not ASCII, in UTF-8 and declared so.
            check(file['characterSet'] == 'ISO_IR 192' and file['seriesDescription'] == 'Die große Wundarzney'
                  and file['referringPhysician'].startswith('Ἱπποκράτης'),
                  f'VolumeGenerator text {z}: {file["characterSet"]} {file["seriesDescription"]} {file["referringPhysician"]}')
        check(volume.get('opened') == ['Ulm'], f'VolumeGenerator opened {volume.get("opened")}')

        for module in ('DatabaseProbeMRC', 'DatabaseProbeARC'):
            probe = report.get(module, {})
            check('runError' not in probe, f'{module}: {probe.get("runError")}')
            check(probe.get('stateAfterProbe') == 2 and probe.get('commentsAfterProbe', [''])[0] == 'from a legacy plugin',
                  f'{module} edits: {probe}')
            # A refused change: the error reaches the user, the study keeps its state.
            check('state 9 does not exist' in probe.get('refusedStateError', '') and probe.get('stateAfterRefusal') == 2,
                  f'{module} refused state: {probe.get("refusedStateError")} {probe.get("stateAfterRefusal")}')
            check('cannot change name' in probe.get('readOnlyError', '') and probe.get('nameAfterRefusal') == 'SYNTH^LEGACY',
                  f'{module} read-only: {probe.get("readOnlyError")} {probe.get("nameAfterRefusal")}')
            check(f'Legacy album:{STUDY}' in probe.get('albums', []), f'{module} albums {probe.get("albums")}')
            derived = probe.get('derivedFiles', [])
            values = [(i * 3 - 20) * 0.5 for i in range(24)]
            check(len(derived) == 2 and derived[0]['series'] == derived[1]['series'] and [d['instance'] for d in derived] == [1, 2]
                  and all(d['values'] == values and d['spacing'] == [0.5, 0.5] and d['source'] == f'{STUDY}.1.1' for d in derived),
                  f'{module} derived: {derived}')
            # The former setter of DICOMExport takes the bits of a sample, as the application did.
            colour = probe.get('derivedColour', [])
            check(colour == [{'description': 'Legacy colour', 'width': 2, 'height': 2,
                              'rgba': [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255]}],
                  f'{module} colour export: {colour}')
            # The image a viewer shows, exported twice under one name: one series, numbered 1 and 2,
            # with the viewer's values and spacing; a capture of the viewer as drawn is refused.
            exported = probe.get('viewerExport', [])
            check(len(exported) == 2 and all(e['description'] == 'Legacy viewer export' and e['valuesEqual']
                                             and e['source'] == f'{STUDY}.1.2' and e['spacing'] == [0.5, 0.5] for e in exported)
                  and [e['instance'] for e in exported] == [1, 2] and exported[0]['series'] == exported[1]['series'],
                  f'{module} viewer export: {exported}')
            check('only the image in memory' in probe.get('viewerExportError', ''), f'{module} capture: {probe.get("viewerExportError")}')
            dicom = probe.get('importedDICOM', [])
            check(len(dicom) == 1 and dicom[0]['patient'] == 'PROBE^OBJECT' and dicom[0]['words'] == [1, 2, 300, 40000]
                  and dicom[0]['rows'] == 2 and dicom[0]['frames'] == '1', f'{module} DCMObject file: {dicom}')

    check(sorted(probes) == [0, 1], f'probe reports: {sorted(probes)}')
    for arc, probe in probes.items():
        tag = f'probe arc={arc}: '
        check(probe['selection'] == ['Study'] and probe['patient'] == 'SYNTH^LEGACY' and probe['studyName'] == 'Database probe',
              tag + f'selection {probe}')
        check(probe['seriesCount'] == 1 and probe['entity'] == 'Study' and probe['seriesStudyIsSame'] == 1, tag + f'objects {probe}')
        check(probe['instanceNumbers'] == [1, 2, 3] and probe['imagePatientID'] == 'LEGACY-1', tag + f'images {probe}')
        check(probe['fetchedStudies'] == [STUDY] and probe['fetchedImages'] == [3, 2] and probe['countedSeries'] == 1
              and probe['objectsForEntity'] == 1, tag + f'fetches {probe}')
        check(probe['comment'] == 'from a legacy plugin' and probe['state'] == 2 and probe['report'] == 'http://reports.example/legacy'
              and probe['seriesComment2'] == 'series note' and probe['keyImages'] == [2], tag + f'edits {probe}')
        check(probe['albumStudies'] == [STUDY] and probe['studyAlbums'] == ['Legacy album'], tag + f'albums {probe}')
        check(probe['objectWritten'] == 1 and probe['rereadName'] == 'PROBE^OBJECT' and probe['rereadSpacing'] == [0.5, 0.75]
              and probe['rereadDate'] == '20260102' and probe['rereadRows'] == 2 and probe['rereadPixels'] == 8
              and probe['tagByString'] == 'PatientName', tag + f'DCMObject {probe}')
        check(probe['addedObjectImages'] == 1 and probe['addedObjectPatient'] == 'PROBE^OBJECT', tag + f'added object {probe}')
        check(probe['derivedImages'] == 2 and probe['derivedSameSeries'] == 1 and probe['derivedSeriesName'] == 'Legacy export'
              and probe['kitFilesLeft'] == 0 and probe['colourWritten'] == 1, tag + f'derived {probe}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'IsiXLegacyBridge database: {", ".join(PROOFS)} and the probe (MRC, ARC) built from source and checked')
