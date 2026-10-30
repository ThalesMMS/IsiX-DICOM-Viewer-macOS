#!/usr/bin/env python3
"""A plugin's command cannot end the application with an exception, nor run
without the viewer it requires.

Builds two probe plugins against the SDK a plugin sees (exported as
tests/test-isix-plugin-kit.py does):

- ExceptionProbe, of API 1 (tests/fixtures/plugin-command-exceptions): Swift
  commands that call the plugin's own Objective-C++ code, which raises an
  NSException, throws std::runtime_error or throws an int; a command that
  throws a Swift error, one that returns, and one that needs a viewer;
- LegacyExceptionProbe, a legacy plugin ported with IsiXLegacyBridge by
  tools/build-isix-legacy-plugin.py, whose -filterImage: raises an
  NSException or throws std::logic_error.

A host harness (ExceptionHarness.swift) compiled with the application's own
boundary - Horos/Sources/IsiXPluginCommandGuard.swift, IsiXPluginExceptionGuard.mm
and HorosObjCException.m - runs the commands as IsiXPluginHost does and
reports each outcome. The test checks that every exception, of either
language and of either kind of plugin, is caught with its type and reason,
that an activation an exception escapes from (RaisingActivationPlugin,
ThrowingActivationPlugin) leaves the plugin failed, with nothing it
registered left and no command run,
that the plugin stays active and its next command runs, that a Swift error
is still a failure of its own, and that the runtime refuses the viewer
command without a viewer, without calling it, and runs it with one. As a
control, the same harness without the boundary must die on the C++ and the
Objective-C exception, from a command and from an activation: otherwise the
test would not tell.
"""
from pathlib import Path
import importlib.util
import json
import shutil
import signal
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'plugin-command-exceptions'
SOURCES = ROOT / 'Horos' / 'Sources'
TARGET = 'arm64-apple-macos15.0'
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
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('builder', 'build-isix-example-plugin.py')
legacy_builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')


def compile_object(source, output, *flags):
    compiler = 'clang++' if source.suffix == '.mm' else 'clang'
    subprocess.run(['xcrun', compiler, '-c', '-target', TARGET, '-fobjc-arc', '-fobjc-exceptions', *flags,
                    '-o', str(output), str(source)], check=True)
    return output


def verify(tag, harness, probe, legacy):
    run = subprocess.run([str(harness), str(probe), str(legacy)], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        failures.append(f'{tag}: the harness exited {run.returncode} with the boundary in place: {run.stderr[-2000:]}')
        report = None
    else:
        report = json.loads(run.stdout.strip().splitlines()[-1])

    if report is not None:
        outcomes = report['probe']['outcomes']
        expected = {
            'raise-objc': 'raised|Objective-C|ProbeObjCException|the probe raised an Objective-C exception',
            'throw-cxx': 'raised|C++|std::runtime_error|the probe threw a C++ exception',
            'throw-int': 'raised|C++|int|int',
            'throw-swift': 'failed|the probe threw a Swift error',
            'return': 'ran',
            'viewer-without': 'failed|"Exception Probe: Viewer Command" needs an open 2D viewer. '
                              'Open a series and choose the command again.',
            'viewer-with': 'ran',
            'throw-cxx-again': 'raised|C++|std::runtime_error|the probe threw a C++ exception',
            'return-after': 'ran',
        }
        for key, value in expected.items():
            check(outcomes.get(key) == value, f'{tag}: probe {key}: {outcomes.get(key)!r}, expected {value!r}')
        check(report['probe']['state'] == 'active', f'{tag}: probe state after the exceptions: {report["probe"]["state"]}')
        # The viewer command was entered once, with the viewer: refused without one before its handler ran.
        check(report['probe']['record'] == 'entered raise-objc,throw-cxx,throw-int,throw-swift,return,viewer,throw-cxx,return',
              f'{tag}: probe record: {report["probe"]["record"]}')

        legacy_outcomes = report['legacy']['outcomes']
        legacy_expected = {
            '0:Raise Objective-C': 'raised|Objective-C|LegacyProbeException|the legacy probe raised an Objective-C exception',
            '1:Throw C++': 'raised|C++|std::logic_error|the legacy probe threw a C++ exception',
            '2:Return': 'ran',
            'again:Return': 'ran',
        }
        check(legacy_outcomes == legacy_expected, f'{tag}: legacy outcomes: {legacy_outcomes}')
        check(report['legacy']['state'] == 'active', f'{tag}: legacy state after the exceptions: {report["legacy"]["state"]}')

        activations = report['activations']
        expected_activations = {
            'ExceptionProbe.RaisingActivationPlugin':
                'raised|Objective-C|ProbeObjCException|the probe raised an Objective-C exception',
            'ExceptionProbe.ThrowingActivationPlugin': 'raised|C++|std::runtime_error|the probe threw a C++ exception',
        }
        for entry, value in expected_activations.items():
            found = activations.get(entry, {})
            check(found.get('outcome') == value, f'{tag}: activation of {entry}: {found.get("outcome")!r}, expected {value!r}')
            check(found.get('state', '').startswith('failed') and found.get('instance') is False,
                  f'{tag}: {entry} was not refused: {found}')
            check((found.get('commands'), found.get('observations'), found.get('tasks')) == (0, 0, 0),
                  f'{tag}: {entry} left registrations behind: {found}')
            check(found.get('runAfter') == 'failed|The plugin is not active.', f'{tag}: {entry} ran a command: {found}')
        check(activations.get('probeAfter') == 'ran', f'{tag}: after the refused activations: {activations.get("probeAfter")}')

    # The control: without the boundary each exception ends the process.
    controls = [('--unguarded', command) for command in ('throw-cxx', 'raise-objc')]
    controls += [('--unguarded-activation', entry) for entry in ('ExceptionProbe.ThrowingActivationPlugin',
                                                                 'ExceptionProbe.RaisingActivationPlugin')]
    for mode, name in controls:
        control = subprocess.run([str(harness), mode, str(probe), name], capture_output=True, text=True, timeout=60)
        check(control.returncode == -signal.SIGABRT and 'survived' not in control.stdout,
              f'{tag}: without the boundary, {name} did not abort the host (exit {control.returncode}): '
              f'the test cannot tell a caught exception from none')


with tempfile.TemporaryDirectory(prefix='plugin-command-exceptions-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')

    throwers = compile_object(FIXTURES / 'ProbeThrowers.mm', work / 'ProbeThrowers.o', '-std=c++17')
    probe = builder.build(sdk, work, 'arm64', name='ExceptionProbe', module='ExceptionProbe',
                          sources=[FIXTURES / 'ExceptionProbePlugin.swift'],
                          info_changes={'CFBundleIdentifier': 'org.isix.exception-probe', 'CFBundleName': 'Exception Probe',
                                        'NSPrincipalClass': 'ExceptionProbe.ExceptionProbePlugin',
                                        'IsiXPluginCapabilities': ['viewer.read']},
                          extra=['-import-objc-header', str(FIXTURES / 'ProbeThrowers.h'), str(throwers), '-lc++'])
    legacy = legacy_builder.build(sdk, FIXTURES / 'LegacyExceptionProbe', work, name='LegacyExceptionProbe')

    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', TARGET])
    objects = [compile_object(SOURCES / 'HorosObjCException.m', work / 'HorosObjCException.o'),
               compile_object(SOURCES / 'IsiXPluginExceptionGuard.mm', work / 'IsiXPluginExceptionGuard.o',
                              '-std=c++17', '-I', str(SOURCES))]
    bridging = work / 'Bridging.h'
    bridging.write_text(f'#import "{SOURCES / "HorosObjCException.h"}"\n#import "{SOURCES / "IsiXPluginExceptionGuard.h"}"\n')

    def build_harness(optimization):
        harness = work / f'ExceptionHarness{optimization}'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-target', TARGET, optimization,
                        '-F', str(host_kit), '-framework', 'IsiXPluginKit', '-Xlinker', '-rpath', '-Xlinker', str(host_kit),
                        '-I', str(loading), '-L', str(loading), '-lIsiXPluginLoading', '-import-objc-header', str(bridging),
                        '-o', str(harness), str(FIXTURES / 'ExceptionHarness.swift'),
                        str(SOURCES / 'IsiXPluginCommandGuard.swift'), *map(str, objects), '-lc++'], check=True)
        return harness

    # Unoptimized as in Debug, optimized as in Release.
    for optimization in ('-Onone', '-O'):
        harness = build_harness(optimization)
        verify(optimization, harness, probe, legacy)

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('plugin command exceptions caught at the boundary (API 1 and ported), viewer requirement enforced')
