#!/usr/bin/env python3
"""IsiXPluginKit keeps the ABI and API of version 1.

A plugin compiled against one IsiXPluginKit must run, without recompiling,
inside an application that embeds a later, compatible one. The kit is built
with library evolution; this test compares the kit's ABI and API, as
swift-api-digester dumps them from the public module interface plugins compile
against, with the baseline of version 1 kept beside this test
(tests/fixtures/isix-plugin-kit/IsiXPluginKit-v1.{abi,api}.json). Comparing the
.swiftinterface text alone would miss changes of layout and mangling, and would
flag harmless reformatting.

Any breakage the digester reports fails the test: removing or renaming a
declaration, changing a signature or a type, adding a protocol requirement
without a default, changing a struct's or class's layout where it is frozen.
Additions are allowed; to accept them into the baseline after review, run
with --update.

The test also checks the checker, on copies of the sources: an incompatible
change (a parameter label changed, a declaration made internal) must be reported,
and an additive one (a new method, a new type) must not.

What this cannot show - one plugin binary built against kit A running,
without recompiling, in an application built with kit B - is checked by
building the plugin template against an exported SDK A and loading that same
binary in an application with kit B.
"""
from pathlib import Path
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures' / 'isix-plugin-kit'
BASELINE = {mode: FIXTURES / f'IsiXPluginKit-v1.{mode}.json' for mode in ('abi', 'api')}
TARGET = 'arm64-apple-macos15.0'
update = '--update' in sys.argv[1:]
failures = []

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swift-api-digester'],
                                                   capture_output=True).returncode != 0:
    sys.stderr.write('needs xcrun and swift-api-digester (Xcode)\n')
    sys.exit(2)

spec = importlib.util.spec_from_file_location('exporter', ROOT / 'tools' / 'export-isix-plugin-kit.py')
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


def public_module(sources, folder):
    """A folder with IsiXPluginKit.swiftmodule holding only the public
    interface built from `sources`: what a plugin compiles against."""
    folder = Path(folder)
    module = folder / 'modules' / 'IsiXPluginKit.swiftmodule'
    module.mkdir(parents=True)
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'IsiXPluginKit', '-parse-as-library', '-swift-version', '6',
                    '-enable-library-evolution', '-emit-library', '-target', TARGET,
                    '-emit-module-interface-path', str(module / 'arm64-apple-macos.swiftinterface'),
                    '-o', str(folder / 'libIsiXPluginKit.dylib'), *map(str, sources)],
                   check=True, cwd=folder, capture_output=True)
    # swiftc writes the private interface beside the public one, and the
    # digester would prefer it: plugins never see it.
    for private in module.glob('*.private.swiftinterface'):
        private.unlink()
    return folder / 'modules'


def dump(modules, output, mode, cache):
    command = ['xcrun', 'swift-api-digester', '-dump-sdk', '-module', 'IsiXPluginKit', '-I', str(modules),
               '-o', str(output), '-avoid-location', '-avoid-tool-args', '-target', TARGET, '-module-cache-path', str(cache)]
    if mode == 'abi':
        command.append('-abi')
    subprocess.run(command, check=True, capture_output=True)
    # Only the kit's own declarations: the system modules it imports are not its ABI.
    data = json.loads(Path(output).read_text())
    root = data['ABIRoot']
    root['children'] = [child for child in root.get('children', []) if child.get('kind') != 'Import']
    Path(output).write_text(json.dumps(data, indent=1, sort_keys=True) + '\n')
    return output


def breakages(baseline, current, mode, folder):
    """The incompatibilities the digester reports, one per line."""
    command = ['xcrun', 'swift-api-digester', '-diagnose-sdk', '-input-paths', str(baseline),
               '-input-paths', str(current)]
    if mode == 'abi':
        command.append('-abi')
    run = subprocess.run(command, capture_output=True, text=True, cwd=folder)
    if run.returncode != 0:
        return [f'swift-api-digester exited {run.returncode}: {run.stderr.strip()[-500:]}']
    # The report lists findings under /* section */ headers, one per line.
    # An addition is reported in ABI mode as "a new API without '@available'":
    # the kit marks no system availability, and an addition breaks nothing.
    lines = (run.stdout + run.stderr).splitlines()
    return [line.strip() for line in lines if line.strip() and not line.lstrip().startswith('/*')
            and "is a new API without '@available'" not in line]


def build_dumps(sources, folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    modules = public_module(sources, folder)
    return {mode: dump(modules, folder / f'{mode}.json', mode, folder / 'cache') for mode in ('abi', 'api')}


def mutated(folder, replacements):
    """A copy of the kit's sources with `replacements` applied, file by file."""
    folder = Path(folder)
    folder.mkdir(parents=True)
    copies = []
    for source in exporter.sources():
        text = source.read_text()
        for name, old, new in replacements:
            if source.name == name:
                if old not in text:
                    raise SystemExit(f'mutation does not apply to {name}: {old!r}')
                text = text.replace(old, new)
        copy = folder / source.name
        copy.write_text(text)
        copies.append(copy)
    for name, old, new in replacements:
        if name not in {s.name for s in exporter.sources()}:
            copy = folder / name
            copy.write_text(new)
            copies.append(copy)
    return copies


with tempfile.TemporaryDirectory(prefix='isix-kit-abi-') as temporary:
    work = Path(temporary)
    current = build_dumps(exporter.sources(), work / 'current')
    if update:
        for mode, path in current.items():
            shutil.copyfile(path, BASELINE[mode])
        print('baseline updated: ' + ', '.join(str(p.relative_to(ROOT)) for p in BASELINE.values()))
        sys.exit(0)
    for mode in ('abi', 'api'):
        if not BASELINE[mode].exists():
            failures.append(f'{BASELINE[mode].relative_to(ROOT)} is missing; create it with --update')
            continue
        found = breakages(BASELINE[mode], current[mode], mode, work)
        if found:
            failures.append(f'{mode.upper()} breakage against version 1:\n  ' + '\n  '.join(found))

    # The checker itself: an incompatible change must be caught...
    incompatible = build_dumps(mutated(work / 'incompatible-sources', [
        ('IsiXViewer.swift', 'public func removeROI(_ id: IsiXROIID) throws {', 'public func removeROI(id: IsiXROIID) throws {'),
        ('IsiXImage.swift', 'public func distanceFromPlane(_ point: IsiXVector3) -> Double {', 'func distanceFromPlane(_ point: IsiXVector3) -> Double {'),
    ]), work / 'incompatible')
    for mode in ('abi', 'api'):
        found = breakages(current[mode], incompatible[mode], mode, work)
        if not any('removeROI' in line for line in found) or not any('distanceFromPlane' in line for line in found):
            failures.append(f'{mode}: the digester did not report an incompatible change: {found}')
    # ...and an additive one must not.
    additive = build_dumps(mutated(work / 'additive-sources', [
        ('IsiXViewer.swift', '    public var isOpen: Bool { backend.isOpen }\n',
         '    public var isOpen: Bool { backend.isOpen }\n\n    public func addedLater() -> Int { 1 }\n'),
        ('AddedLater.swift', '', 'public struct IsiXAddedLater: Sendable { public init() {} }\n'),
    ]), work / 'additive')
    for mode in ('abi', 'api'):
        found = breakages(current[mode], additive[mode], mode, work)
        if found:
            failures.append(f'{mode}: an additive change was reported as a breakage: {found}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('IsiXPluginKit ABI and API match version 1; the digester catches an incompatible change and accepts an additive one')
