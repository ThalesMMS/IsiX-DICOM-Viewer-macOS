#!/usr/bin/env python3
"""IsiXLegacyBridge: a legacy plugin that reaches the application by name gets
the porting kit's classes, never the application's.

    python3 tests/test-isix-legacy-dynamic-access.py [HOROSPLUGINS_DIR]

Builds tests/fixtures/isix-legacy-dynamic/DynamicProbe with the kit, once with
manual reference counting and once with ARC, and runs it in
tests/fixtures/isix-legacy-bridge/LegacyHarness.swift compiled with
tests/fixtures/isix-legacy-dynamic/DynamicAccessHost.swift: classes of the
host's own executable named as the application's (ViewerController, DCMPix,
ROI, BrowserController, DicomStudy, which the kit has too, and AppController,
ThumbnailsListPanel, which it has not), and a read-only database of two
studies for the harness's host. Checks that NSClassFromString(),
objc_getClass() and objc_lookUpClass() of a legacy name give the kit's class
when the kit has one and nil (with a message in the log) when it does not,
never the host's; that the plugin's own classes and the system's are found as
before; that performSelector:, objc_msgSend() and key-value coding on the
kit's objects give the right values, through to the kit's database objects,
and that a selector or a key without an equivalent gives nil and a message
instead of an exception.

With HOROSPLUGINS_DIR (a checkout of horosproject/horosplugins, external input)
it also builds Volume Calculator from its original source and runs it on two
synthetic viewers of two studies: it orders the viewers by the date of
-[ViewerController currentStudy], read by key-value coding, and computes the
volumes from the length ROIs, the earlier study's first. Without the checkout
the plugin part is skipped and the test exits with 2 after the probe's checks.
"""
from pathlib import Path
import importlib.util
import json
import math
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-legacy-dynamic'
HARNESS = ROOT / 'tests' / 'fixtures' / 'isix-legacy-bridge' / 'LegacyHarness.swift'
PLUGIN = 'Volume Calculator'
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
collection = Path(sys.argv[1]) if len(sys.argv) > 1 else None
if collection is not None and not (collection / PLUGIN / 'Info.plist').is_file():
    collection = None
exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')

with tempfile.TemporaryDirectory(prefix='isix-legacy-dynamic-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    plugins = work / 'plugins'
    plugins.mkdir()
    bundles = []
    for module, arc in (('DynamicProbeMRC', False), ('DynamicProbeARC', True)):
        warnings = {}
        bundles.append(builder.build(sdk, FIXTURES / 'DynamicProbe', plugins, module, arc=arc, warnings=warnings))
        check(not warnings['kit'] and not warnings['plugin'], f'{module}: warnings {warnings}')
    plugin_warnings = []
    if collection is not None:
        warnings = {}
        try:
            bundles.append(builder.build(sdk, collection / PLUGIN, plugins, 'VolumeCalculator', warnings=warnings))
            check(not warnings['kit'], f'{PLUGIN}: the kit has warnings: {warnings["kit"]}')
            plugin_warnings = warnings['plugin']
        except RuntimeError as error:
            failures.append(f'{PLUGIN} does not build: {error}')

    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', 'arm64-apple-macos15.0'])
    # The harness's top-level code needs the name main.swift once another file is compiled with it.
    shutil.copy(HARNESS, work / 'main.swift')
    host_extras = FIXTURES / 'DynamicAccessHost.swift'
    harness = work / 'LegacyHarness'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0',
                    '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                    '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading',
                    '-o', str(harness), str(work / 'main.swift'), str(host_extras)], check=True)
    probe_output = work / 'dynamic'
    environment = dict(os.environ, ISIX_LEGACY_DYNAMIC_OUTPUT=str(probe_output), NSZombieEnabled='YES')
    run = subprocess.run([str(harness), *map(str, bundles)], capture_output=True, text=True, timeout=120, env=environment)
    if run.returncode != 0:
        failures.append(f'harness exited {run.returncode}: {run.stderr[-3000:]}')
        report = {}
    else:
        report = json.loads(run.stdout)
    log = run.stderr
    check('deallocated instance' not in log, 'a zombie was messaged: ' + log[-2000:])
    probes = {arc: plistlib.loads(Path(f'{probe_output}-{arc}.plist').read_bytes())
              for arc in (0, 1) if Path(f'{probe_output}-{arc}.plist').is_file()}
    check(sorted(probes) == [0, 1], f'probe reports: {sorted(probes)}')

    for module, arc in (('DynamicProbeMRC', 0), ('DynamicProbeARC', 1)):
        outcome = report.get(module, {})
        check(outcome.get('state') == 'active' and 'runError' not in outcome, f'{module}: {outcome}')
        check(outcome.get('renamedInViewer') == 'renamed by key', f'{module}: KVC rename did not reach the viewer: {outcome}')
        probe = probes.get(arc)
        if probe is None:
            continue
        tag = f'{module}: '
        check('exception' not in probe, tag + f'exception {probe.get("exception")}')
        kit = f'IsiXLegacy{module}_'
        classes = probe.get('classes', {})
        for name in ('PluginFilter', 'ViewerController', 'DCMView', 'DCMPix', 'ROI', 'MyPoint', 'BrowserController',
                     'DicomStudy'):
            check(classes.get(name) == kit + name, tag + f'NSClassFromString({name}) gave {classes.get(name)}')
        for name in ('AppController', 'ThumbnailsListPanel', 'NoSuchLegacyClass', '(nil)'):
            check(classes.get(name) == 'nil', tag + f'NSClassFromString({name}) gave {classes.get(name)}')
        check(classes.get('NSString') == 'NSString' and classes.get('DynamicProbeFilter') == 'DynamicProbeFilter',
              tag + f'system or own class not found: {classes}')
        check(probe.get('sameAsKit') == [True, True, True, True], tag + f'not the kit classes: {probe.get("sameAsKit")}')
        check(probe.get('objcGetClass') == kit + 'ViewerController' and probe.get('objcLookUpClass') == 'nil',
              tag + f'objc_getClass {probe.get("objcGetClass")}, objc_lookUpClass {probe.get("objcLookUpClass")}')
        # The host does have a ViewerController of its own: the plugin was kept from it.
        check(probe.get('undiverted') == 'ViewerController'
              and Path(probe.get('undivertedImage', '')).resolve() == harness.resolve(),
              tag + f'host class not present for the comparison: {probe.get("undiverted")} {probe.get("undivertedImage")}')
        for key, expected in (('performPixList', 3), ('performFront', True), ('performUnknown', True),
                              ('performUnknownWithObject', True), ('performUnknownClass', True),
                              ('respondsToUnknown', False), ('msgSendPixList', 3), ('msgSendUnknown', True),
                              ('kvcUnknown', True), ('sameStudy', True), ('renamed', 'renamed by key')):
            check(probe.get(key) == expected, tag + f'{key} = {probe.get(key)}, expected {expected}')
        kvc = probe.get('kvc', {})
        expected_kvc = {'pwidth': 6, 'pheight': 4, 'pixelSpacingX': 0.5, 'pixelSpacingY': 0.75, 'pixListCount': 3,
                        'curImage': 1, 'roiNames': ['probe line'], 'roiType': 5, 'viewerControllerIvar': True,
                        'studyUID': '1.2.3.10'}
        check(kvc == expected_kvc, tag + f'key-value coding gave {kvc}, expected {expected_kvc}')
        # Each name without an equivalent is reported once, with the plugin's name.
        for message in ('the class AppController is the application\'s',
                        'the class ThumbnailsListPanel is the application\'s',
                        '-[ViewerController probeSelectorWithoutEquivalent] has no equivalent',
                        '-[ViewerController probeSelectorWithoutEquivalent:] has no equivalent',
                        '-[ViewerController probeMessageWithoutEquivalent:] has no equivalent',
                        '+[ViewerController legacyClassMethodWithoutEquivalent] has no equivalent',
                        'the key probeKeyWithoutEquivalent of ViewerController has no equivalent',
                        'the key probeSetKeyWithoutEquivalent of ViewerController has no equivalent'):
            check(log.count(f'{module}: {message}') == 1, tag + f'log has {log.count(f"{module}: {message}")} x "{message}"')
        check(f'{module}: the class NoSuchLegacyClass' not in log and f'{module}: the class BrowserController' not in log,
              tag + 'a class absent from the host, or one the kit has, was reported')

    if collection is not None:
        volume = report.get('VolumeCalculator', {})
        check(volume.get('state') == 'active' and 'runError' not in volume, f'{PLUGIN}: {volume}')
        check(volume.get('commands') == ['Volume Calculator|roiTools|viewer'], f'{PLUGIN} commands {volume.get("commands")}')
        check(volume.get('window') != '', f'{PLUGIN} did not open its window: {volume}')
        # Lengths in cm, as the application gave them: 40 columns of 0.5 mm in the first viewer (the
        # later study), 40 columns and 30 rows of 0.75 mm in the second (the earlier study), which the
        # plugin puts first by the studies' dates.
        lengths = [math.hypot(2.0, 2.25), 2.0]
        diameters = [volume.get('diameter1', -1), volume.get('diameter2', -1)]
        # The fields show two decimals.
        check(all(abs(a - b) < 0.006 for a, b in zip(diameters, lengths)),
              f'{PLUGIN} diameters {diameters}, expected {lengths}: not ordered by study date')
        for d, key in zip(diameters, ('volume1', 'volume2')):
            expected = d ** 3 * math.pi / 6
            check(abs(volume.get(key, -1) - expected) < 1e-3 * expected, f'{PLUGIN} {key} {volume.get(key)} != {expected}')
        check('VolumeCalculator: ' not in log, f'{PLUGIN}: the kit reported a missing equivalent')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('IsiXLegacyBridge: classes, messages and keys by name reach the kit (MRC, ARC), never the host\'s classes')
if collection is None:
    print('SKIP: Volume Calculator needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)')
    sys.exit(2)
print(f'{PLUGIN} built from its original source and checked; its own warnings: {len(plugin_warnings)}')
for warning in plugin_warnings:
    print('  ' + warning)
