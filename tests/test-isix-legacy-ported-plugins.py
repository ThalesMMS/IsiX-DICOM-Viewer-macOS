#!/usr/bin/env python3
"""The legacy plugins ported to the IsiX plugin API 1, as the private collection
of converted plugins keeps them: each project is the converter's output plus
its hand fixes, and builds for arm64 and x86_64.

    python3 tests/test-isix-legacy-ported-plugins.py HOROSPLUGINS_DIR PORTED_DIR \\
        [--plugin-itk ITK_DIR] [--plugin-itk-x86_64 ITK_DIR]

HOROSPLUGINS_DIR is a checkout of horosproject/horosplugins and PORTED_DIR the
collection of converted plugins (one folder per plugin, as written by
tools/port-legacy-plugin.py, with Porting/source.json naming the folder of
horosplugins it came from and the options of its conversion: the module
name, the ITK adaptation and definitions, and sharedKit, the --shared-kit
path of the one copy of the kit the projects build with, such as
../IsiXLegacyBridge). Both are
external input and not part of this repository: without them the test exits
with 2. A plugin that carries its own ITK is built only with --plugin-itk (and
--plugin-itk-x86_64 for x86_64), libraries installed by the plugin template's
script/build-library.py; otherwise it is reported as not built.

For each converted plugin the test checks:

- that it is not one the compatibility matrix puts out by the maintainer's
  list (redundant, example, planned to become part of the application...);
- the layout: the Xcode project, Config/, the kit's copy (its own, or the
  shared one at sharedKit), Porting/REPORT.md, report.json, source.json and
  ORIGIN.md, and, when the plugin has hand fixes, Porting/hand-fixes.diff and
  HAND-FIXES.md;
- that the project is exactly what the converter writes today from the
  original folder with the same options, with Porting/hand-fixes.diff
  applied: no change outside the recorded hand fixes, and the kit's copy,
  its own or the shared one, is this repository's (a shared copy may add
  SOURCE.md, the revision it was copied from);
- that it builds for arm64 and for x86_64 with the kit and links only the kit
  and the system.

Then, through the hosts of tests/fixtures/isix-legacy-bridge (the
application's loading path with synthetic viewers and database), the main
function of the plugins ported last: grid draws its grid on every image,
SpineCounter renames the selected spine, and BullsEye and Coronary save their
diagram as an RGB image of the viewer's study. The plugins ported before have
tests of their own, built from horosplugins.
"""
from pathlib import Path
import argparse
import filecmp
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import build_module, dependencies  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-legacy-bridge'
ALLOWED_LIBRARY = re.compile(r'^(@rpath/IsiXPluginKit\.framework/Versions/A/IsiXPluginKit'
                             r'|/usr/lib/(libSystem\.B|libobjc\.A|libz\.1|libc\+\+\.1|swift/libswift\w+)\.dylib'
                             r'|/System/Library/Frameworks/\w+\.framework/Versions/\w+/\w+)$')
# What a plugin folder holds besides the converter's output.
ADDED = {'Porting/source.json', 'Porting/ORIGIN.md', 'Porting/hand-fixes.diff', 'Porting/HAND-FIXES.md'}
# What a shared copy of the kit holds besides the kit (the revision it was copied from).
SHARED_KIT_ADDED = {'SOURCE.md'}
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load_tool(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tree(folder, added=ADDED):
    """Relative paths of the files of `folder`, without the additions and the Notices folder."""
    return {str(p.relative_to(folder)) for p in folder.rglob('*')
            if (p.is_file() or p.is_symlink()) and not p.is_dir()} - added - {
        str(p.relative_to(folder)) for p in (folder / 'Notices').rglob('*')} if folder.is_dir() else set()


def differences(staged, fresh, added=ADDED):
    staged_files, fresh_files = tree(staged, added), tree(fresh, added)
    found = sorted(staged_files ^ fresh_files)
    for relative in sorted(staged_files & fresh_files):
        a, b = staged / relative, fresh / relative
        if a.is_symlink() or b.is_symlink():
            if not (a.is_symlink() and b.is_symlink() and os.readlink(a) == os.readlink(b)):
                found.append(relative)
        elif not filecmp.cmp(a, b, shallow=False):
            found.append(relative)
    return found


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('collection', type=Path, nargs='?')
parser.add_argument('ported', type=Path, nargs='?')
parser.add_argument('--plugin-itk', type=Path)
parser.add_argument('--plugin-itk-x86_64', type=Path)
arguments = parser.parse_args()
if not arguments.collection or not arguments.collection.is_dir():
    sys.stderr.write('SKIP: needs a horosplugins checkout as argument (HOROSPLUGINS_DIR)\n')
    sys.exit(2)
projects = sorted(p.parent.parent for p in arguments.ported.glob('*/Porting/source.json')) \
    if arguments.ported and arguments.ported.is_dir() else []
if not projects:
    sys.stderr.write('SKIP: needs the collection of converted plugins as argument (PORTED_DIR)\n')
    sys.exit(2)
if shutil.which('xcrun') is None:
    sys.stderr.write('SKIP: needs xcrun (Xcode command line tools)\n')
    sys.exit(2)

exporter = load_tool('exporter', 'export-isix-plugin-kit.py')
builder = load_tool('legacy_builder', 'build-isix-legacy-plugin.py')
matrix = load_tool('matrix', 'legacy-plugin-compatibility-matrix.py')
converter = builder.converter
libraries = {'arm64': arguments.plugin_itk, 'x86_64': arguments.plugin_itk_x86_64}
not_built = []

with tempfile.TemporaryDirectory(prefix='isix-legacy-ported-') as temporary:
    work = Path(temporary)
    host_kit = work / 'host'
    exporter.compile_framework(host_kit, ['arm64', 'x86_64'])
    sdk = work / 'sdk'
    exporter.export(host_kit / 'IsiXPluginKit.framework', sdk, 'swiftc')
    bundles = {}
    shared_kits = {}
    repository_kit = work / 'kit' / 'IsiXLegacyBridge'
    for part in ('Headers', 'Include', 'Sources'):
        shutil.copytree(ROOT / 'IsiXLegacyBridge' / part, repository_kit / part, symlinks=True)
    shutil.copy2(ROOT / 'IsiXLegacyBridge' / 'README.md', repository_kit / 'README.md')
    for project in projects:
        source = json.loads((project / 'Porting' / 'source.json').read_text())
        folder, module = source['folder'], project.name
        tag = f'{module} ({folder}): '
        check(folder not in matrix.EPIC_REASON, tag + f'out by the maintainer\'s list: {matrix.EPIC_REASON.get(folder)}')
        shared_kit = source.get('sharedKit')
        kit_readme = f'{shared_kit}/README.md' if shared_kit else 'IsiXLegacyBridge/README.md'
        for relative in (f'{module}.xcodeproj/project.pbxproj', 'Config/port.json', 'Config/Info.plist', 'Config/Prefix.pch',
                         kit_readme, 'Porting/REPORT.md', 'Porting/report.json', 'Porting/ORIGIN.md'):
            check((project / relative).is_file(), tag + f'no {relative}')
        if shared_kit:
            kit = (project / shared_kit).resolve()
            if kit not in shared_kits:
                shared_kits[kit] = differences(kit, repository_kit, SHARED_KIT_ADDED)
                check(not shared_kits[kit], f'the shared kit {kit} is not this repository\'s: {shared_kits[kit][:10]}')
        hand_fixes = project / 'Porting' / 'hand-fixes.diff'
        check(hand_fixes.is_file() == (project / 'Porting' / 'HAND-FIXES.md').is_file(),
              tag + 'hand-fixes.diff and HAND-FIXES.md go together')
        original = arguments.collection / folder
        if not original.is_dir():
            failures.append(tag + f'{folder} is not in the horosplugins checkout')
            continue

        # The converter's output today, with the recorded hand fixes, is the project.
        fresh_root = work / 'fresh' / module
        input_folder = original
        if source.get('itk'):
            input_folder = work / 'itk5' / module / original.name
            builder.adapt_to_itk5(original, input_folder)
        report = converter.convert(input_folder, fresh_root, source.get('name'), shared_kit=shared_kit)
        fresh = Path(report['project'])
        check(fresh.name == module, tag + f'the converter names it {fresh.name}')
        if hand_fixes.is_file():
            applied = subprocess.run(['git', 'apply', '-p2', str(hand_fixes.resolve())],
                                     cwd=fresh, capture_output=True, text=True)
            check(applied.returncode == 0, tag + f'hand-fixes.diff does not apply to the converter\'s output: {applied.stderr}')
        changed = differences(project, fresh)
        check(not changed, tag + f'differs from the converter\'s output and its hand fixes: {changed[:10]}')

        for arch in ('arm64', 'x86_64'):
            options = {}
            if source.get('itk'):
                if not libraries[arch]:
                    not_built.append(f'{module} {arch}')
                    continue
                options = {'libraries': [libraries[arch]], 'defines': [*source.get('defines', []), *builder.ITK_LEGACY_DEFINES]}
            output = work / 'bundles' / arch
            output.mkdir(parents=True, exist_ok=True)
            warnings = {}
            try:
                bundle = builder.build_project(sdk, project, output, arch, warnings, **options)
            except RuntimeError as error:
                failures.append(tag + f'does not build for {arch}: {str(error)[-1500:]}')
                continue
            check(not warnings['kit'], tag + f'the kit has warnings for {arch}: {warnings["kit"][:3]}')
            binary = bundle / 'Contents' / 'MacOS' / bundle.stem
            archs = subprocess.run(['lipo', '-archs', str(binary)], capture_output=True, text=True).stdout.split()
            check(archs == [arch], tag + f'{arch} build is {archs}')
            linked = [line.split(' (compatibility')[0].strip() for line in
                      subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True).stdout.splitlines()[1:]]
            bad = [library for library in linked if not ALLOWED_LIBRARY.match(library)]
            check(not bad, tag + f'links {bad}')
            bundles[(module, arch)] = bundle

    # The main function of the plugins ported last, in the hosts of the kit's tests.
    loading = work / 'loading'
    target = ['-target', 'arm64-apple-macos15.0']
    build_module('IsiXPluginLoading', loading, extra=target)
    build_module('IsiXDatabase', loading, extra=target)
    harnesses = {}
    for name, extra in (('LegacyHarness', ['-lIsiXPluginLoading']),
                        ('LegacyDatabaseHarness', ['-lIsiXPluginLoading', '-lIsiXDatabase',
                                                   *(f'-l{each}' for each in dependencies('IsiXDatabase'))])):
        harnesses[name] = work / name
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target, '-F', str(host_kit), '-framework', 'IsiXPluginKit',
                        '-Xlinker', '-rpath', '-Xlinker', str(host_kit), '-I', str(loading), '-L', str(loading), *extra,
                        '-o', str(harnesses[name]), str(FIXTURES / f'{name}.swift')], check=True)

    def host(name, modules):
        present = [bundles[(m, 'arm64')] for m in modules if (m, 'arm64') in bundles]
        if not present:
            return {}
        run = subprocess.run([str(harnesses[name]), *map(str, present)], capture_output=True, text=True, timeout=180,
                             env=dict(os.environ, NSZombieEnabled='YES'))
        check(run.returncode == 0, f'{name} exited {run.returncode}: {run.stderr[-3000:]}')
        check('deallocated instance' not in run.stderr, 'a zombie was messaged: ' + run.stderr[-2000:])
        return json.loads(run.stdout) if run.returncode == 0 else {}

    core = host('LegacyHarness', ['grid', 'SpineCounter'])
    database = host('LegacyDatabaseHarness', ['BullsEye', 'Coronary'])
    for name, outcome in [*core.items(), *database.items()]:
        if isinstance(outcome, dict):
            check(outcome.get('state') == 'active', f'{name}: {outcome.get("state")} {outcome.get("activationError")}')
            check(not outcome.get('runError'), f'{name}: {outcome.get("runError")}')
    if ('grid', 'arm64') in bundles:
        grid = core.get('grid', {})
        # Lines every 8 pixels from the rectangle's corner at (10, 10): rows and columns 2, 10, 18, 26.
        check(grid.get('gridRows') == [2, 10, 18, 26] and grid.get('gridColumns') == [2, 10, 18, 26]
              and grid.get('changedElsewhere') == 0 and grid.get('roisLeft') == [], f'grid: {grid}')
    if ('SpineCounter', 'arm64') in bundles:
        spine = core.get('SpineCounter', {})
        check(spine.get('commands', [])[:1] == ['Switch Spine Type'] and len(spine.get('commands', [])) == 8,
              f'SpineCounter commands {spine.get("commands")}')
        check(spine.get('names') == ['1 S', '1 S', '2'], f'SpineCounter names {spine.get("names")}')
    for module in ('BullsEye', 'Coronary'):
        if (module, 'arm64') not in bundles:
            continue
        outcome = database.get(module, {})
        colour = outcome.get('derivedColour', [])
        check(outcome.get('window') == f'{module} Plugin', f'{module} window {outcome.get("window")}')
        check(len(colour) == 1 and colour[0]['description'] == 'Wall Motion' and colour[0]['source'].endswith('.1.2')
              and colour[0]['width'] == colour[0]['height'] > 100 and colour[0]['colours'] > 10, f'{module} DICOM: {colour}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print(f'legacy ported plugins: {len(projects)} projects match the converter and their hand fixes and build for arm64 and '
      f'x86_64' + (f', on {len(shared_kits)} shared copy of the kit' if shared_kits else '') + (f' (not built without the plugin\'s ITK: {", ".join(not_built)})' if not_built else '')
      + '; grid, SpineCounter, BullsEye and Coronary checked')
