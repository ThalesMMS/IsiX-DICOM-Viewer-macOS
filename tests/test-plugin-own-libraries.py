#!/usr/bin/env python3
"""A plugin that carries its own ITK lives next to the application's ITK.

    python3 tests/test-plugin-own-libraries.py --plugin-itk <folder> [--app-itk <folder>] [--app <IsiX app or executable>]

The application links ITK statically and exports its symbols, among them
ITK's templates and inline functions as weak definitions (Image<float, 3>,
ImageRegion<3>, the function-local statics behind itk::Singleton, which hold
ITK's global settings). When a bundle that exports a weak definition of the
same name loads, dyld binds the bundle's uses to the application's copy. A
plugin with its own ITK therefore builds it with hidden visibility and links
it into a bundle that exports no symbol: the recipe of the plugin template
(script/build-library.py) and of the kit's README.

--plugin-itk is an ITK installed by that recipe (include/ and lib/libITK.a),
of a different version or build than the application's, so that a mix-up is
visible: for the record of this test, the same ITK release with
ITK_VERSION_PATCH changed in a copy of its CMake/itkVersion.cmake.
--app-itk is the application's ITK installation from its build
(build/Build/Intermediates.noindex/Horos.build/Debug/ITK.build/Install by
default). Exit status 2 when either is missing. --app, when given or found in
build/Development, is used to confirm that the application really exports the
weak definitions this test looks at.

The test builds:

- a host that links the application's archive the way the application does
  (default visibility, an executable that exports its symbols, dead code
  stripped) and loads plugins through the application's loading path
  (tests/fixtures/own-libraries/OwnLibrariesHost.swift);
- the probe plugin with the recipe: tests/fixtures/own-libraries/ITKStateProbe.cpp
  compiled with -fvisibility=hidden -fvisibility-inlines-hidden against the
  plugin's ITK, linked with lib/libITK.a and an empty exported symbols list;
- the same probe built the naive way (default visibility, the application's
  archive, symbols exported): the control, whose ITK code must end up
  calling the host's copies of the templates, or the test could not tell a
  mix-up;
- the probe with a copy of IsiXPluginKit.framework inside, which the loader
  must refuse before mapping any of its code.

and checks, for the probe: the bundle exports nothing and binds no ITK symbol
from outside; each side keeps its own version, its own global settings (the
default number of threads and the output window, set by each side before and
after the other) and runs its own code (dladdr of the functions it calls);
every ITK symbol the host looks up after the plugin loaded is still the
host's, and the plugin's image exports none of them.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'own-libraries'
ARCH = 'arm64'
TARGET = f'{ARCH}-apple-macos15.0'
HOST_WINDOW = 'IsiXHostProbeOutputWindow'
PLUGIN_WINDOW = 'IsiXPluginProbeOutputWindow'
# 21 pixels in each of 4 slices; see ITKStateProbe.cpp.
CONNECTED = 84
# Weak definitions the application exports and the probe uses, then ordinary ones.
WEAK = ['__ZZN3itk9SingletonINS_19OutputWindowGlobalsEEEPT_PKcNSt3__18functionIFvvEEEE14singletonIndex',
        '__ZZN3itk9SingletonINS_24MultiThreaderBaseGlobalsEEEPT_PKcNSt3__18functionIFvvEEEE14singletonIndex',
        '__ZN3itk5ImageIfLj3EE10FillBufferERKf',
        '__ZNK3itk11ImageRegionILj3EE17GetNumberOfPixelsEv',
        '__ZN3itk29ConnectedThresholdImageFilterINS_5ImageIfLj3EEES2_E7AddSeedERKNS_5IndexILj3EEE']
# The probe's report names for the weak functions among them.
WEAK_FUNCTIONS = {'Image<float,3>::FillBuffer', 'ImageRegion<3>::GetNumberOfPixels', 'ConnectedThresholdImageFilter::AddSeed'}
STRONG = ['__ZN3itk7Version13GetITKVersionEv', '__ZN3itk17MultiThreaderBase31SetGlobalDefaultNumberOfThreadsEj']
LIBRARY_SYMBOL = re.compile(r'itk|vnl|vcl|kwsys|double_conversion', re.I)
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def itk_version(install):
    text = (install / 'include' / 'itkConfigure.h').read_text()
    parts = [re.search(r'#define ITK_VERSION_%s (\d+)' % part, text) for part in ('MAJOR', 'MINOR', 'PATCH')]
    return '.'.join(match.group(1) for match in parts) if all(parts) else None


def run(command, **options):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True, timeout=600, **options)
    if result.returncode != 0:
        raise SystemExit(f'{" ".join(map(str, command[:4]))} ... failed:\n{result.stderr[-4000:]}')
    return result.stdout


def real(path):
    return os.path.realpath(path) if path else ''


def symbols(binary, *options):
    return run(['xcrun', 'nm', *options, binary]).splitlines()


def app_executable(path):
    path = Path(path)
    if path.suffix == '.app':
        executables = sorted((path / 'Contents' / 'MacOS').iterdir())
        return executables[0] if executables else None
    return path


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--plugin-itk', type=Path)
parser.add_argument('--app-itk', type=Path,
                    default=ROOT / 'build/Build/Intermediates.noindex/Horos.build/Debug/ITK.build/Install')
parser.add_argument('--app', type=Path, default=ROOT / 'build/Development/HorosDevelopment.app')
parser.add_argument('--keep', type=Path, help='build in this empty folder and keep what was built')
arguments = parser.parse_args()

for name, install, library in (('--plugin-itk', arguments.plugin_itk, 'lib/libITK.a'),
                               ('--app-itk', arguments.app_itk, 'wlib/libITK.a')):
    if install is None or not (install / library).is_file() or not (install / 'include/itkConfigure.h').is_file():
        sys.stderr.write(f'{name}: no ITK installation with include/ and {library} at {install}\n')
        sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

plugin_itk, app_itk = arguments.plugin_itk.resolve(), arguments.app_itk.resolve()
plugin_version, app_version = itk_version(plugin_itk), itk_version(app_itk)
if plugin_version == app_version:
    sys.exit(f'the plugin\'s ITK and the application\'s are both {app_version}: build the plugin\'s copy from a '
             'different version, or the same release with another ITK_VERSION_PATCH, so a mix-up shows')
for line in symbols(plugin_itk / 'lib/libITK.a', '-m', '-g', '-U'):
    if ' external ' in line and 'private external' not in line and LIBRARY_SYMBOL.search(line):
        failures.append(f'the plugin\'s archive was not built with hidden visibility: {line.split()[-1]}')
        break

exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('builder', 'build-isix-example-plugin.py')

if arguments.keep and (not arguments.keep.is_dir() or any(arguments.keep.iterdir())):
    sys.exit(f'--keep {arguments.keep}: not an empty folder')
with tempfile.TemporaryDirectory(prefix='isix-own-libraries-') as temporary:
    work = Path(os.path.realpath(arguments.keep or temporary))
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, [ARCH])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    header = FIXTURES / 'ITKStateProbe.h'
    probe = FIXTURES / 'ITKStateProbe.cpp'

    # The host: the application's archive, compiled and linked as the application does.
    loading = work / 'loading'
    build_module('IsiXPluginLoading', loading, extra=['-target', TARGET])
    run(['xcrun', 'clang++', '-c', '-std=c++17', '-target', TARGET, '-DISIX_PROBE_HOST', '-I', app_itk / 'include',
         '-o', work / 'host-probe.o', probe])
    host = work / 'OwnLibrariesHost'
    run(['xcrun', 'swiftc', '-swift-version', '6', '-target', TARGET, '-F', host_kit, '-framework', 'IsiXPluginKit',
         '-Xlinker', '-rpath', '-Xlinker', host_kit, '-I', loading, '-L', loading, '-lIsiXPluginLoading',
         '-import-objc-header', header, '-Xcc', '-DISIX_PROBE_HOST', work / 'host-probe.o', app_itk / 'wlib/libITK.a',
         '-lc++', '-lz', '-Xlinker', '-dead_strip', '-o', host, FIXTURES / 'OwnLibrariesHost.swift'])

    def plugin(name, compile_flags, link_flags):
        objects = work / name
        objects.mkdir()
        run(['xcrun', 'clang++', '-c', '-std=c++17', '-target', TARGET, *compile_flags, '-o', objects / 'probe.o', probe])
        return builder.build(sdk, work, ARCH, name=name, module=name, sources=[FIXTURES / 'OwnLibraryProbePlugin.swift'],
                             info_changes={'CFBundleIdentifier': f'org.isix.test.{name.lower()}', 'CFBundleName': name,
                                           'NSPrincipalClass': f'{name}.OwnLibraryProbePlugin',
                                           'IsiXPluginCapabilities': []},
                             extra=['-import-objc-header', str(header), str(objects / 'probe.o'), *map(str, link_flags)])

    # The recipe: hidden visibility, the plugin's own archive, nothing exported.
    exports = work / 'exports.exp'
    exports.write_text('# The plugin exports no symbol.\n')
    recipe_flags = ['-fvisibility=hidden', '-fvisibility-inlines-hidden', '-I', plugin_itk / 'include']
    recipe_links = ['-L', plugin_itk / 'lib', '-lITK', '-lz', '-lc++', '-Xlinker', '-exported_symbols_list', '-Xlinker', exports]
    isolated = plugin('OwnLibraryProbe', recipe_flags, recipe_links)
    # The naive way: what the recipe prevents.
    control = plugin('OwnLibraryControl', ['-I', app_itk / 'include'], [app_itk / 'wlib/libITK.a', '-lz', '-lc++'])
    # The recipe's bundle with a copy of the kit inside.
    embedded = plugin('OwnLibraryEmbeddedKit', recipe_flags, recipe_links)
    shutil.copytree(sdk / 'IsiXPluginKit.framework', embedded / 'Contents/Frameworks/IsiXPluginKit.framework', symlinks=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(embedded)], check=True, capture_output=True)

    # What the bundle built with the recipe exports and imports.
    binary = isolated / 'Contents/MacOS/OwnLibraryProbe'
    flags = run(['xcrun', 'otool', '-hv', binary]).split()
    check('TWOLEVEL' in flags, f'the probe is not linked with two-level namespace: {flags}')
    check('WEAK_DEFINES' not in flags, 'the probe exports weak definitions (MH_WEAK_DEFINES)')
    exported = [line.split()[-1] for line in symbols(binary, '-g', '-U')]
    check(not [s for s in exported if s != '__mh_bundle_header'], f'the probe exports symbols: {exported[:10]}')
    imported = [line.split()[-1] for line in symbols(binary, '-u')]
    check(not [s for s in imported if LIBRARY_SYMBOL.search(s)],
          f'the probe binds ITK symbols from outside: {[s for s in imported if LIBRARY_SYMBOL.search(s)][:10]}')
    check(not any('dynamically looked up' in line for line in symbols(binary, '-m', '-u')),
          'the probe leaves symbols to be found at run time')
    control_exports = [line.split()[-1] for line in symbols(control / 'Contents/MacOS/OwnLibraryControl', '-g', '-U')]
    check(all(name in control_exports for name in WEAK),
          'the control does not export the weak definitions it should share with the host')

    # The host exports the same weak definitions as the application.
    def weak_exports(executable):
        found = {line.split()[-1] for line in symbols(executable, '-m', '-g', '-U') if 'weak external' in line
                 and 'non-external' not in line}
        return [name for name in WEAK if name not in found]
    check(not weak_exports(host), f'the host does not export {weak_exports(host)} as the application does')
    application = app_executable(arguments.app) if arguments.app.exists() else None
    if application:
        check(not weak_exports(application), f'{application} does not export {weak_exports(application)}: '
                                             'the weak definitions this test looks at changed')
    else:
        print(f'{arguments.app} not found: the application\'s own exports were not compared')

    def host_run(bundle):
        result = subprocess.run([str(host), str(bundle), *WEAK, *STRONG], capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            failures.append(f'{bundle.name}: the host exited {result.returncode}: {result.stderr[-2000:]}')
            return None
        return json.loads(result.stdout)

    def all_in(report, image):
        return real(report.get('ownImage')) == image and all(real(p) == image for p in report.get('images', {}).values())

    def host_report_ok(report, threads, label):
        check(report.get('side') == 'host' and report.get('version') == app_version,
              f'{label}: host version {report.get("version")}, expected {app_version}')
        check(report.get('threads') == threads, f'{label}: host threads {report.get("threads")}, expected {threads}')
        check(report.get('outputWindow') == HOST_WINDOW, f'{label}: host output window {report.get("outputWindow")}')
        check(report.get('connected') == CONNECTED, f'{label}: host region growing gave {report.get("connected")}')

    # The recipe: nothing crosses in either direction.
    report = host_run(isolated)
    if report is not None:
        host_image, plugin_image = real(report['hostImage']), real(report.get('pluginImage'))
        check(report.get('state') == 'active', f'probe: {report.get("state")} {report.get("error")}')
        host_report_ok(report['hostBefore'], 3, 'before loading')
        host_report_ok(report.get('hostAfterActivation', {}), 3, 'after the plugin set its copy')
        host_report_ok(report.get('hostReconfigured', {}), 5, 'host reconfigured')
        host_report_ok(report.get('hostFinal', {}), 5, 'after the plugin reported')
        for key in ('hostBefore', 'hostAfterActivation', 'hostFinal'):
            check(all_in(report.get(key, {}), host_image), f'{key}: the host ran code outside its image: {report.get(key)}')
        reports = report.get('plugin', [])
        check(isinstance(reports, list) and len(reports) == 3, f'plugin reports: {reports}')
        if isinstance(reports, list) and len(reports) == 3:
            first, configured, last = reports
            for each in reports:
                check(each.get('side') == 'plugin' and each.get('version') == plugin_version,
                      f'the plugin ran ITK {each.get("version")}, expected its own {plugin_version}')
                check(each.get('connected') == CONNECTED, f'the plugin\'s region growing gave {each.get("connected")}')
                check(all_in(each, plugin_image), f'the plugin ran code outside its image: {each.get("images")}')
            check(first.get('outputWindow') != HOST_WINDOW and first.get('threads') != 3,
                  f'the plugin saw the host\'s settings: {first.get("outputWindow")}, {first.get("threads")} threads')
            check(configured.get('threads') == 8 and configured.get('outputWindow') == PLUGIN_WINDOW,
                  f'the plugin could not set its own copy: {configured}')
            check(last.get('threads') == 8 and last.get('outputWindow') == PLUGIN_WINDOW,
                  f'the host\'s change reached the plugin: {last.get("threads")}, {last.get("outputWindow")}')
        for when in ('lookupsBefore', 'lookupsAfter'):
            for name, lookup in report.get(when, {}).items():
                check(real(lookup['process']) == host_image, f'{when}: {name} resolves in {lookup["process"]}')
                check(not lookup['exportedByPlugin'], f'{when}: the plugin exports {name}')
        check(len(report.get('lookupsAfter', {})) == len(WEAK + STRONG), 'the lookups after loading did not run')

    # The control mixes: the plugin's own ITK code calls the host's copies of
    # the templates, so this test can see a mix-up.
    report = host_run(control)
    if report is not None:
        host_image = real(report['hostImage'])
        reports = report.get('plugin', [])
        borrowed = sorted({name for each in reports if isinstance(each, dict)
                           for name, path in each.get('images', {}).items() if real(path) == host_image})
        check(set(borrowed) == WEAK_FUNCTIONS,
              f'the control built without the recipe ran the host\'s {borrowed}, not all of {sorted(WEAK_FUNCTIONS)}: '
              'this test could not tell a mix-up')
        print(f'control without the recipe: the plugin ran the host\'s {", ".join(borrowed)}')

    # A copy of the kit inside the bundle: refused before any of its code is mapped.
    report = host_run(embedded)
    if report is not None:
        check(report.get('diagnostics') == ['embedsKitCopy'], f'embedded kit: {report.get("diagnostics")}')
        check(report.get('mapped') is False and 'state' not in report, 'the bundle with its own kit was loaded')
        host_report_ok(report.get('hostAfter', {}), 3, 'after the refusal')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'plugin ITK {plugin_version} and application ITK {app_version} kept apart in one process; '
      'the naive control mixed; a bundle with its own IsiXPluginKit was refused')
