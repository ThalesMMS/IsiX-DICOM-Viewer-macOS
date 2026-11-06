#!/usr/bin/env python3
"""IsiXLegacyBridge: the viewer's events, drawing over the image and the
plugins' own windows, for legacy plugins built from their original source as
plugins of the IsiX plugin API 1, without the application.

    python3 tests/test-isix-legacy-viewer-events.py HOROSPLUGINS_DIR [--plugin-itk ITK_DIR]

HOROSPLUGINS_DIR is a checkout of horosproject/horosplugins; ITK_DIR, optional,
an ITK installed for a plugin by the plugin template's script/build-library.py.
Both are external input, not part of this repository. Without the checkout
the test exits with 2; without ITK_DIR it leaves NMSegmentation out and says so.

The test exports the SDK a plugin sees, builds with
tools/build-isix-legacy-plugin.py and runs the bundles in
tests/fixtures/isix-legacy-viewer/ViewerHarness.swift: the application's
loading path with synthetic viewers that announce their events, as the
application does, and give the plugins mouse and key events and an image to
draw over, as the application's image view does.

- The test's own legacy plugin (tests/fixtures/isix-legacy-viewer/ViewerProbe):
  each notification of Notifications.h arrives once, with the kit's objects,
  and the application's notifications of the same names never; a click it
  stops is taken from the viewer; -handleEvent:forViewer: gets drags and
  keys; what it draws in the drawing notification lands on its pixels; its
  nib's DCMView is the kit's view, shows the images it is given and converts
  between the view and the image; it changes the phase shown.
- Volume Calculator: the window shows the length of the selected length ROI
  (with one viewer the plugin compares it with itself) and the volume of a
  sphere of that diameter, and follows the user's change to it in the
  viewer; the ROI's removal reaches the plugin as the same object.
- CardiacStatistics: in its own window, four clicks in the viewer place the
  epicardium, the centre, the endocardium and the RV-LV junction; Segment
  makes six sectors, cut along the smoothed outlines of the kit's
  -splinePoints, and opens the sectors' window, whose table shows the
  application's mean of each sector.
- NMSegmentation, with ITK_DIR: a click in the viewer is the region growing's
  seed, and the viewer does nothing else with it.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-legacy-viewer'
PLUGINS = {'Volume Calculator': 'VolumeCalculator', 'CardiacStatistics': 'CardiacStatistics'}
# A call of these plugins the kit does not have, on a path not checked here:
# the merge of brush ROIs (NMSegmentation, only with its preference to merge
# with existing ROIs).
KNOWN_GAPS = ('-mergeBrushROI:',)
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


parser = argparse.ArgumentParser()
parser.add_argument('horosplugins', nargs='?', type=Path)
parser.add_argument('--plugin-itk', type=Path)
arguments = parser.parse_args()
collection = arguments.horosplugins
if not collection or not all((collection / p / 'Info.plist').is_file() for p in PLUGINS):
    sys.stderr.write('SKIP: needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)\n')
    sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
itk = arguments.plugin_itk if arguments.plugin_itk and (arguments.plugin_itk / 'include' / 'itkConfigure.h').is_file() else None
if not itk:
    print('NMSegmentation left out: no --plugin-itk ITK_DIR')
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

with tempfile.TemporaryDirectory(prefix='isix-legacy-viewer-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    plugins = work / 'plugins'
    plugins.mkdir()
    bundles = []
    builds = [(FIXTURES / 'ViewerProbe', 'ViewerProbe', {})] + [(collection / f, m, {}) for f, m in PLUGINS.items()]
    if itk:
        builds.append((collection / 'NMSegmentation', 'NMSegmentation', {'libraries': [itk], 'defines': ['nmITK=itk']}))
    for folder, module, options in builds:
        warnings = {}
        try:
            bundles.append(builder.build(sdk, folder, plugins, module, warnings=warnings, **options))
        except RuntimeError as error:
            failures.append(f'{module} does not build: {error}')
            continue
        check(not warnings['kit'], f'{module}: the kit has warnings: {warnings["kit"]}')
        missing = [w for w in warnings['plugin'] if 'not found' in w and not any(known in w for known in KNOWN_GAPS)]
        check(not missing, f'{module}: calls the kit does not have: {missing}')
        if module == 'ViewerProbe':
            check(not warnings['plugin'], f'ViewerProbe: warnings {warnings["plugin"]}')
            nib = plugins / 'ViewerProbe.isixplugin' / 'Contents' / 'Resources' / 'ViewerProbePanel.nib'
            data = b''.join(p.read_bytes() for p in ([nib] if nib.is_file() else sorted(nib.rglob('*')) if nib.is_dir() else []) if p.is_file())
            check(b'IsiXLegacyViewerProbe_DCMView' in data, 'the nib does not name the plugin\'s own DCMView')

    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', 'arm64-apple-macos15.0'])
    harness = work / 'ViewerHarness'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0',
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                    '-o', str(harness), str(FIXTURES / 'ViewerHarness.swift')], check=True)
    environment = dict(os.environ, NSZombieEnabled='YES', ISIX_LEGACY_ITK_PLUGIN='1' if itk else '0')
    try:
        run = subprocess.run([str(harness), *map(str, bundles)], capture_output=True, text=True, timeout=120, env=environment)
    except subprocess.TimeoutExpired as expired:
        failures.append(f'the harness did not finish: {(expired.stderr or b"")[-3000:]}')
        run = None
    report = {}
    if run is not None:
        if run.returncode != 0:
            failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        else:
            report = json.loads(run.stdout)
        check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])

    for name, outcome in report.items():
        check(outcome.get('state') == 'active', f'{name}: {outcome}')
        check('runError' not in outcome, f'{name}: {outcome.get("runError")}')
        check(outcome.get('kitCenter') is True, f'{name}: no notification center of its own')

    probe = report.get('ViewerProbe', {})
    seen = probe.get('report', {})
    check(seen.get('centerClass') == 'IsiXLegacyViewerProbe_NotificationCenter', f'probe center {seen.get("centerClass")}')
    check(seen.get('ownNotification') == 1, 'a notification of the plugin\'s own name did not arrive')
    check(seen.get('phases') == 2 and seen.get('phaseAfter') == 1 and probe.get('phaseAtEnd') == 0, f'probe phases {seen}')
    check(seen.get('paneClass') == 'IsiXLegacyViewerProbe_DCMView' and seen.get('paneIsKitView') == 1,
          f'the nib\'s view is {seen.get("paneClass")}')
    check(seen.get('paneImage') == 2 and seen.get('paneRoundTrip') == [3, 2], f'probe pane {seen}')
    # Slice 2, row 1: 18 + column; the window 20.5 / 3 (19 to 22) makes columns
    # 0 and 1 black, 4 and 5 white, 2 and 3 grays in between (the grays in
    # between go through the system's colour management).
    row = seen.get('paneRow1', [])
    check(len(row) == 6 and row[:2] == [0, 0] and row[4:] == [255, 255] and 0 < row[2] < row[3] < 255,
          f'the pane shows {row}')
    # The 6 x 4 image of pixels 1.5 times as high as wide, fitted in 120 x 80 points.
    check(abs(seen.get('paneScale', 0) - 80 / 6) < 1e-6, f'pane scale {seen.get("paneScale")}')
    # One click, the kit's, taken from the viewer: X in whole pixels, Y as it is.
    check(seen.get('clicks') == [[2, 1.5, True]] and probe.get('clickTaken') is True, f'clicks {seen.get("clicks")} {probe.get("clickTaken")}')
    check(probe.get('dragTaken') is False and seen.get('drags') == [30], f'drags {seen.get("drags")}')
    check(seen.get('keys') == [['k', True], ['j', True]] and probe.get('keyKTaken') is True and probe.get('keyJTaken') is False,
          f'keys {seen.get("keys")}')
    check(seen.get('images') == [[1, True]], f'images shown {seen.get("images")}')
    check(seen.get('rois') == ['added user box slice 1 1', 'roiChange user box 4 1', 'roiSelected user box 4 1', 'removeROI user box 4 0'],
          f'ROI notifications {seen.get("rois")}')
    check(probe.get('drawsOverlays') is True and seen.get('draws') == [[1, 0.25, True]], f'draws {seen.get("draws")}')
    check(probe.get('redPixels') == ['1,1', '2,1'], f'the drawing covers {probe.get("redPixels")}')
    check(seen.get('closed') == [True], f'closed {seen.get("closed")}')

    volume = report.get('VolumeCalculator', {})
    before, changed, removed = volume.get('before', []), volume.get('afterChange', []), volume.get('afterRemoval', [])
    check(volume.get('window', '') != '' and len(before) == 4, f'Volume Calculator window {volume}')
    if len(before) == 4 and len(changed) == 4 and len(removed) == 4:
        # With one viewer the plugin compares the selected length with itself:
        # 10 pixels of 0.5 mm (0.5 cm), then 15 once the user lengthens it.
        check(abs(before[0] - 0.5) < 1e-4 and before[1] == before[0], f'Volume Calculator lengths {before}')
        check(abs(changed[0] - 0.75) < 1e-4 and changed[1] == changed[0], f'after the change {changed}')
        check(abs(changed[2] - 3.14159265 * 0.75 ** 3 / 6) < 1e-4, f'volume after the change {changed}')
        check(removed == changed, f'after the removal {removed}')

    cardiac = report.get('CardiacStatistics', {})
    check(cardiac.get('panel') is True, 'CardiacStatistics did not show its panel')
    check(cardiac.get('clicksTaken') == [False] * 4, f'CardiacStatistics clicks {cardiac.get("clicksTaken")}')
    check(sorted(cardiac.get('afterClicks', [])) == ['line mySeparator 2', 'polygon myEndoRoi 30', 'polygon myEpiRoi 30'],
          f'CardiacStatistics after the clicks {cardiac.get("afterClicks")}')
    check(len(cardiac.get('sectors', [])) == 6 and cardiac.get('sectorComments') == ['CardiacStatistics'],
          f'CardiacStatistics sectors {cardiac.get("sectors")}')
    check(cardiac.get('sectorPointsNearCorner') == 0,
          f'CardiacStatistics sectors reach the image corner ({cardiac.get("sectorPointsNearCorner")} points)')
    check(cardiac.get('tableRows') == 6 and cardiac.get('tableMaxDifference', 1) < 1e-3,
          f'CardiacStatistics table {cardiac.get("tableMeans")} ({cardiac.get("tableMaxDifference")})')

    if itk:
        segmentation = report.get('NMSegmentation', {})
        check(segmentation.get('clickTaken') is True and segmentation.get('seed') == [6, 7, 2],
              f'NMSegmentation seed {segmentation}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('IsiXLegacyBridge viewer events: ViewerProbe, Volume Calculator, CardiacStatistics'
      + (', NMSegmentation' if itk else '') + ' built from source and checked')
