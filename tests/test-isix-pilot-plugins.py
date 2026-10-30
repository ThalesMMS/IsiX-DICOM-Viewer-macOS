#!/usr/bin/env python3
"""The pilot plugins of Plugins/Pilots on the plugin API version 1, without the application.

Invert Data, T2 Fit Map, ROI Enhancement, PointsToLine and JPEG to DICOM are
rewritten in Swift against IsiXPluginKit only. This test exports the SDK a
plugin sees (the public interface and the binary, as tests/test-isix-plugin-kit.py
does), builds every pilot with tools/build-isix-pilot-plugins.py for arm64 and
x86_64, and checks:

- that they use the kit and the system only: the libraries each binary links,
  where each of its undefined symbols comes from, no flat-namespace lookup,
  and no class, header, selector or symbol lookup of the application in their
  sources or strings;
- that the loader accepts each one, and refuses an unsigned arm64 copy with a
  reason that says a signature is needed;
- what each does, run by tests/fixtures/isix-pilots/PilotHarness.swift through
  the application's loading path, with synthetic viewers and database built
  from the fixture generators' formulas: Invert Data negates every sample
  exactly (an odd width included) and inverts colour but not alpha; T2 Fit Map
  matches the application's own T2 engine pixel by pixel (Horos/Sources/T2FitMap.swift,
  compiled into the harness) and does not open a map once the viewer closed;
  ROI Enhancement matches the application's ROI Enhancement engine, follows a
  moved ROI and stops when the viewer closes; PointsToLine puts ⌊distance⌋
  points on the nearest slices of an axial and an oblique stack; JPEG to
  DICOM decodes PNG, TIFF and JPEG the right way up into the selected study.

The in-app check, against the application's own viewers, ROIs, DICOM writer
and database, is a separate run; these are the plugins' own contracts.
"""
from pathlib import Path
import importlib.util
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PILOTS = ROOT / 'Plugins' / 'Pilots'
HARNESS = ROOT / 'tests' / 'fixtures' / 'isix-pilots' / 'PilotHarness.swift'
NATIVE = [ROOT / 'Horos' / 'Sources' / 'T2FitMap.swift', ROOT / 'Horos' / 'Sources' / 'ROIEnhancement.swift']
NAMES = ['InvertData', 'T2FitMap', 'ROIEnhancement', 'PointsToLine', 'JPEGToDICOM']
failures = []

# What a pilot may link: the kit, and the system's own libraries and frameworks.
ALLOWED_LIBRARY = re.compile(r'^(@rpath/IsiXPluginKit\.framework/Versions/A/IsiXPluginKit'
                             r'|/usr/lib/(libSystem\.B|libobjc\.A|swift/libswift\w+)\.dylib'
                             r'|/System/Library/Frameworks/\w+\.framework/Versions/\w+/\w+)$')
# Names of the application, its former SDK and of ways around the kit.
FORBIDDEN_SOURCE = re.compile(r'\b(PluginFilter|ViewerController|DCMPix|DCMView|BrowserController|DicomDatabase|DicomStudy|'
                              r'DicomSeries|DicomImage|DICOMExport|ROI\.h|OsiriXAPI|HorosAPI|OsiriX|import Horos|'
                              r'NSClassFromString|NSSelectorFromString|dlsym|dlopen|objc_msgSend|objc_getClass|'
                              r'value\(forKey|perform\(|valueForKey|pixList|roiList|fImage)\b')
FORBIDDEN_STRINGS = ('ViewerController', 'DCMPix', 'PluginFilter', 'BrowserController', 'DicomDatabase', 'DICOMExport',
                     'pixList', 'roiList', 'fImage', 'computeROI', 'OsiriX', 'Horos')


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(condition, message):
    if not condition:
        failures.append(message)


def rosetta_available():
    return subprocess.run(['arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode == 0


def text(command):
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout


if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
pilot_builder = load_tool('pilot_builder', 'build-isix-pilot-plugins.py')
check(pilot_builder.pilots() == sorted(NAMES), f'pilots found: {pilot_builder.pilots()}')


def scan_sources():
    for name in NAMES:
        for source in sorted((PILOTS / name / 'Sources').glob('*.swift')):
            body = source.read_text()
            imports = set(re.findall(r'^import (\w+)', body, re.M))
            check(imports <= {'Foundation', 'AppKit', 'CoreGraphics', 'ImageIO', 'UniformTypeIdentifiers', 'IsiXPluginKit', 'os',
                              'Synchronization'}, f'{source.name} imports {sorted(imports)}')
            check('@_spi' not in body, f'{source.name} imports the host SPI')
            # Comments may name what the plugin replaces; code may not use it.
            code = '\n'.join(line for line in body.splitlines() if not line.lstrip().startswith('//'))
            found = sorted(set(m.group(1) for m in FORBIDDEN_SOURCE.finditer(code)))
            # JPEG to DICOM exposes an Objective-C selector of its own for automation.
            check(not found, f'{source.name} uses {found}')
        info = plistlib.loads((PILOTS / name / 'Info.plist').read_bytes())
        check(info.get('IsiXPluginAPIVersion') == 1 and info.get('NSPrincipalClass', '').startswith(name + '.'),
              f'{name} Info.plist: {info}')
        check(not {'pluginType', 'MenuTitles', 'HorosCompatiblePlugin'} & info.keys(), f'{name} declares former keys')


def scan_binary(bundle, arch):
    binary = bundle / 'Contents' / 'MacOS' / bundle.stem
    tag = f'{arch} {bundle.stem}: '
    libraries = [line.split(' (compatibility')[0].strip() for line in text(['otool', '-L', str(binary)]).splitlines()[1:]]
    bad = [lib for lib in libraries if not ALLOWED_LIBRARY.match(lib)]
    check(not bad, tag + f'links {bad}')
    check(any('IsiXPluginKit' in lib for lib in libraries), tag + 'does not link IsiXPluginKit')
    header = text(['otool', '-hv', str(binary)])
    check('TWOLEVEL' in header, tag + 'not a two-level namespace image (flat lookup)')
    undefined = text(['nm', '-m', '-u', str(binary)]).splitlines()
    sources = set()
    for line in undefined:
        match = re.search(r'\(from (\S+)\)', line)
        if match:
            sources.add(match.group(1))
        elif 'dynamically looked up' in line or line.strip():
            failures.append(tag + f'symbol without a library: {line.strip()}')
    allowed = {'IsiXPluginKit', 'Foundation', 'AppKit', 'CoreGraphics', 'ImageIO', 'UniformTypeIdentifiers', 'libSystem', 'libobjc',
               'CoreFoundation'} | {s for s in sources if s.startswith('libswift')}
    check(sources <= allowed, tag + f'symbols from {sorted(sources - allowed)}')
    strings = text(['strings', '-a', str(binary)])
    found = [word for word in FORBIDDEN_STRINGS if word in strings]
    check(not found, tag + f'strings name {found}')
    check('IsiXPluginKit' in ' '.join(sources), tag + 'uses nothing of the kit')
    return libraries


def verify(arch, report):
    tag = f'{arch}: '
    check(report['hostArchitecture'] == arch, tag + f'harness ran as {report["hostArchitecture"]}')

    invert = report['InvertData']
    check('error' not in invert, tag + f'Invert Data: {invert.get("error")}')
    check(invert.get('greyExact') is True and invert.get('greySamples') == 63 * 63 * 8, tag + f'grey inversion: {invert}')
    check(invert.get('greyLevel') == [-40, 400], tag + f'grey window level {invert.get("greyLevel")}')
    check(invert.get('colourExact') is True and invert.get('colourLevel') == [155, 200], tag + f'colour inversion: {invert}')
    check(invert.get('closedError') == 'viewerClosed' and invert.get('closedCommits') == 3
          and invert.get('closedMessage') == 'The viewer was closed.', tag + f'viewer closed mid-run: {invert}')

    t2 = report['T2FitMap']
    check('error' not in t2, tag + f'T2 Fit Map: {t2.get("error")}')
    check(t2.get('nativeCode') == 0 and t2.get('mapImages') == 1, tag + f'T2: {t2}')
    check(t2.get('maxDifference', 1) <= 1e-3, tag + f'T2 differs from the native engine by {t2.get("maxDifference")} ms')
    check(t2.get('zerosMatch') is True and t2.get('capMatch') is True, tag + 'T2 zero or capped pixels differ from the native engine')
    for mean, nominal in zip(t2.get('compartmentMeans', []), [40, 80, 120, 200]):
        check(abs(mean - nominal) <= 0.01 * nominal, tag + f'T2 compartment mean {mean} not within 1% of {nominal}')
    check(t2.get('geometryEqual') is True, tag + 'the map does not keep the first echo geometry')
    check(t2.get('viewersAfterCancel') == 1 and t2.get('tasksAfterCancel') == 0, tag + f'T2 after closing mid-fit: {t2}')
    check('viewer closed: fit cancelled' in t2.get('journal', ''), tag + f'T2 journal: {t2.get("journal")}')

    roi = report['ROIEnhancement']
    check('error' not in roi, tag + f'ROI Enhancement: {roi.get("error")}')
    for key in ('first', 'moved'):
        curve = roi.get(key, {})
        check(curve.get('samples') == 8 == curve.get('nativeSamples'), tag + f'ROI {key}: {curve}')
        check(curve.get('maxMeanDifference', 1) <= 1e-4 and curve.get('maxMinMaxDifference', 1) <= 1e-4
              and curve.get('maxTimeDifference', 1) <= 1e-3, tag + f'ROI {key} differs from the native engine: {curve}')
    for mean, hu in zip(roi.get('first', {}).get('means', []), [40, 80, 150, 220, 200, 140, 90, 60]):
        check(abs(mean - hu) <= 0.01, tag + f'ROI vessel mean {mean} is not {hu} HU')
    check(roi.get('recomputations') == 1, tag + f'two changes in one turn recomputed {roi.get("recomputations")} times')
    check(roi.get('observationsBeforeClose') == 1 and roi.get('observationsAfterClose') == 0 and roi.get('linesAfterClose') == 0,
          tag + f'ROI after the viewer closed: {roi}')
    check(roi.get('flatMessage') == 'ROI Enhancement needs a dynamic (4D) series with at least two phases.',
          tag + f'ROI on a 3D series: {roi.get("flatMessage")}')

    for stack, points in report['PointsToLine'].items():
        check('error' not in points, tag + f'PointsToLine {stack}: {points.get("error")}')
        check(points.get('count') == points.get('expectedCount') and points.get('count', 0) > 10, tag + f'PointsToLine {stack}: {points}')
        check(points.get('worstInPlane', 1) <= points.get('tolerance', 0), tag + f'PointsToLine {stack} in-plane error {points.get("worstInPlane")}')
        check(points.get('worstPlaneDistance', 9) <= points.get('halfInterval', 0) + 1e-9,
              tag + f'PointsToLine {stack} point not on the nearest slice: {points.get("worstPlaneDistance")}')
        check(points.get('worstRoundTrip', 1) <= 1e-3, tag + f'PointsToLine {stack} round trip {points.get("worstRoundTrip")}')
        check(points.get('countAfterSecondRun') == 2 * points.get('expectedCount', -1), tag + 'generated points were taken as inputs')

    jpeg = report['JPEGToDICOM']
    check('error' not in jpeg, tag + f'JPEG to DICOM: {jpeg.get("error")}')
    check(jpeg.get('withoutSelection') == 0, tag + 'images were written without a selected study')
    check(jpeg.get('series') == [{'study': '1.2.826.0.1.3680043.10.1188.7', 'description': 'loose', 'images': 1},
                                 {'study': '1.2.826.0.1.3680043.10.1188.7', 'description': 'Holiday pictures', 'images': 2}],
          tag + f'JPEG series: {jpeg.get("series")}')
    images = jpeg.get('images', [])
    check(len(images) == 3, tag + f'JPEG images: {images}')
    for index, image in enumerate(images):
        lossy = index == 2  # b.jpg, after a.tiff in the folder
        check(image['width'] == 64 and image['height'] == 48 and image['opaque'], tag + f'JPEG image {index}: {image}')
        check(image['topLeftWhite'] and image['bottomLeftDark'], tag + f'JPEG image {index} is flipped: {image}')
        # Against the file's own samples, decoded without colour conversion.
        if lossy:
            check(image['meanError'] <= 2 and image['maxError'] <= 16, tag + f'JPEG decode error {image}')
        else:
            check(image['maxError'] == 0 and image['maxErrorFromPicture'] == 0, tag + f'lossless image {index} changed: {image}')
    check(jpeg.get('importedBatches') == [1, 2], tag + f'imports {jpeg.get("importedBatches")}')
    check(jpeg.get('temporaryFilesLeft') == 0, tag + 'the plugin left its written files behind')


scan_sources()
with tempfile.TemporaryDirectory(prefix='isix-pilots-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64', 'x86_64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    architectures = ['arm64'] + (['x86_64'] if rosetta_available() else [])
    for arch in ['arm64', 'x86_64']:
        folder = work / arch
        bundles = [pilot_builder.build(sdk, folder, name, arch) for name in NAMES]
        for bundle in bundles:
            scan_binary(bundle, arch)
        if arch == 'arm64':
            from_loader = build_module('IsiXPluginLoading', work / 'loading-arm64', extra=['-target', 'arm64-apple-macos15.0'])
            # An unsigned copy is refused before loading, with the reason.
            unsigned = folder / 'unsigned' / 'InvertData.isixplugin'
            shutil.copytree(bundles[0], unsigned, symlinks=True)
            subprocess.run(['codesign', '--remove-signature', str(unsigned)], check=True)
            probe = work / 'Inspect.swift'
            probe.write_text('import Foundation\nimport IsiXPluginLoading\n'
                             'for path in CommandLine.arguments.dropFirst() {\n'
                             '    let inspection = PluginInspector().inspect(bundleAt: URL(fileURLWithPath: path))\n'
                             '    print("\\(inspection.isLoadable)|\\(inspection.diagnostics)|\\(inspection.summary)")\n}\n')
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-I', str(work / 'loading-arm64'), '-L', str(work / 'loading-arm64'),
                            '-lIsiXPluginLoading', '-o', str(work / 'inspect'), str(probe)], check=True)
            lines = text([str(work / 'inspect'), *map(str, bundles), str(unsigned)]).splitlines()
            for name, line in zip(NAMES, lines):
                check(line.startswith('true|[]|'), f'arm64 {name} not loadable: {line}')
            check(lines[-1].startswith('false|[IsiXPluginLoading.PluginDiagnostic.unsignedExecutable(architecture: "arm64")]|')
                  and 'not signed' in lines[-1], f'unsigned pilot: {lines[-1]}')
        if arch not in architectures:
            continue
        loading = work / f'loading-{arch}'
        build_module('IsiXPluginLoading', loading, extra=['-target', f'{arch}-apple-macos15.0'])
        harness = work / f'PilotHarness-{arch}'
        # Top-level code is allowed only in main.swift when several files are compiled.
        main = work / 'main.swift'
        shutil.copyfile(HARNESS, main)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', f'{arch}-apple-macos15.0', '-module-name', 'PilotHarness',
                        '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                        '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                        '-o', str(harness), str(main), *map(str, NATIVE)], check=True)
        command = [str(harness), *map(str, bundles), str(work / f'run-{arch}')]
        if arch == 'x86_64':
            command = ['arch', '-x86_64', *command]
        run = subprocess.run(command, capture_output=True, text=True, timeout=600)
        if run.returncode != 0:
            failures.append(f'{arch}: harness exited {run.returncode}: {run.stderr[-3000:]}')
            continue
        report = json.loads(run.stdout)
        if '--verbose' in sys.argv:
            print(json.dumps(report, indent=1)[:20000])
        verify(arch, report)
    if 'x86_64' not in architectures:
        print('x86_64 built and scanned, not run: Rosetta is not installed')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'Pilot plugins built, scanned and checked for {", ".join(architectures)}')
