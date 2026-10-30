#!/usr/bin/env python3
"""IsiXLegacyBridge: a legacy plugin deactivated and activated again in the
same process gets the viewer's (a click, another image shown), the ROIs' and
the database's notifications again, once each.

    python3 tests/test-isix-legacy-reactivation.py

The test exports the SDK a plugin sees, builds the test's own legacy plugin
(tests/fixtures/isix-legacy-viewer/ReactivationProbe) with
tools/build-isix-legacy-plugin.py and runs it in
tests/fixtures/isix-legacy-viewer/ViewerHarness.swift: the application's
loading path with a synthetic viewer. The probe observes, in -initPlugin,
mouseDown, DCMUpdateCurrentImage, addROI and OsirixAddToDBNotification, and
stops in -willUnload. The host activates it, clicks the image, shows another
image, draws a ROI and announces images added to the database; deactivates it
and does the same (nothing arrives); then activates it again and does the
same: each of the four notifications arrives once more.
"""
from pathlib import Path
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
EXPECTED = sorted(['mouseDown', 'DCMUpdateCurrentImage', 'addROI', 'OsirixAddToDBNotification'])
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

with tempfile.TemporaryDirectory(prefix='isix-legacy-reactivation-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    plugins = work / 'plugins'
    plugins.mkdir()
    warnings = {}
    bundle = builder.build(sdk, FIXTURES / 'ReactivationProbe', plugins, 'ReactivationProbe', warnings=warnings)
    check(not warnings['kit'] and not warnings['plugin'], f'warnings {warnings}')

    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', 'arm64-apple-macos15.0'])
    harness = work / 'ViewerHarness'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0',
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                    '-o', str(harness), str(FIXTURES / 'ViewerHarness.swift')], check=True)
    environment = dict(os.environ, NSZombieEnabled='YES', ISIX_LEGACY_ITK_PLUGIN='0')
    report = {}
    try:
        run = subprocess.run([str(harness), str(bundle)], capture_output=True, text=True, timeout=120, env=environment)
    except subprocess.TimeoutExpired as expired:
        failures.append(f'the harness did not finish: {(expired.stderr or b"")[-3000:]}')
        run = None
    if run is not None:
        if run.returncode != 0:
            failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        else:
            report = json.loads(run.stdout)
        check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])

    probe = report.get('ReactivationProbe', {})
    check(probe.get('firstState') == 'active' and probe.get('state') == 'active', f'states {probe}')
    check(sorted(probe.get('first', [])) == EXPECTED, f'first activation heard {probe.get("first")}')
    check(probe.get('afterDeactivation') == [], f'heard while deactivated {probe.get("afterDeactivation")}')
    check(sorted(probe.get('second', [])) == EXPECTED, f'second activation heard {probe.get("second")}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('IsiXLegacyBridge reactivation: click, image, ROI and database notifications arrive once each after a new activation')
