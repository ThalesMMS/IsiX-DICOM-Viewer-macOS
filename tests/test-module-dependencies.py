#!/usr/bin/env python3
"""The app's internal modules depend only downwards, never on the app.

Modules/Package.swift lists the internal modules, IsiX<Area>, each in its own
folder Modules/<Name>. A module may import only the modules listed before it
that it declares as dependencies, and nothing of the app target: not the
`Horos` module, nor a header of Horos/Sources. Otherwise the module stops
building without the app, and its tests stop running without it.

Checked on the package as it is, and on two mutations of a copy that must be
refused: a module that imports the app target, and one that depends on a
module listed after it.

tests/module-map.json is the module map, one entry per line with its keys
sorted. Listed after it in Package.swift is necessary but not enough: a module
depends only on the modules its entry in `modules` lets it depend on
(`may_depend_on`), and its tests only on it and on those. Every module of the
package has an entry, and a module not created yet is in `planned_modules`,
placed after the module it will be listed after, until the change that creates
it moves it to `modules`. A module allowed to depend on another must come after
it in that order, and the lists follow it. No module imports a framework of
`app_frameworks` (AppKit): windows, nibs and bindings stay in the app target.
`areas` gives the modules of each area and what stays in the app target;
`ports` names the capability ports over the database, each with the module
that declares it, its stage, and its consumers: files of Horos/Sources, which
must exist, and modules, which must be allowed to depend on the port's module.
Checked on the map as it is, and on mutations that must be refused: a
dependency the map does not allow, a module the map does not list, a module
that imports AppKit, a module allowed to depend on one listed after it, a
consumer file that does not exist, and a consuming module that may not depend
on the port's module.

The app reaches DCMTK, VTK and ITK only through adapters: small Objective-C++
files under Horos/Sources/Adapters/<Library>/ whose headers carry no C++ type,
and which turn every C++ exception into an NSError. A Swift module built with
C++ interoperability cannot be imported by a target built without it ("was
built with C++ interoperability enabled, but current compilation does not
enable C++ interoperability"), and the app target does not enable it, so the
adapters are Objective-C++ rather than C++ seen from Swift.

A source file of Horos/Sources reaches a library when it includes one of its
headers, or a header of the app that does, followed through the headers of
Horos/Sources and Nitrogen/Sources and through Horos-Swift.h, which imports the
bridging header. An include under `#ifdef __cplusplus` counts only for
Objective-C++ and C++ files, and one under `#ifndef __cplusplus` only for the
others. Compared with the .d files of a Debug build, this finds the same files
the compiler does.

tests/cxx-boundary-registry.json keeps two lists, one entry per line:
- library_pending: the files that still reach a library outside the adapters,
  each with the stage of the conversion that takes it out;
- sources_pending: the Objective-C, Objective-C++ and C++ files (.m, .mm, .c,
  .cpp, .cc, .cxx) still to be converted, with their stage, in Horos/Sources
  outside the adapters, in Nitrogen/Sources (the Nitrogen framework), in
  Decompress (the helper executable that decompresses apart from the app) and
  in DICOMPrint/Helper (the helper executable that prints through DCMTK's
  stored print, built by its own script).
A file that stays for good goes to `exceptions` with its technical reason
instead. Both lists only shrink: a file that is not listed is refused, and so
is a listed one that no longer needs its entry, so that the entry is removed
with the change that cleared it. Checked on the checkout as it is, and on a
new file in each of the four folders and a new .cxx file, which must be
refused.

A file of Horos/Sources is listed by its bare name, as it was before the other
folders joined; a file of Nitrogen/Sources, Decompress or DICOMPrint/Helper by
its path from the repository root (Nitrogen/Sources/N2Shell.mm), which has a
slash, so the two kinds of key cannot collide.

A stage is a number for the conversion of Horos/Sources around the C++
libraries, and a name for the conversion of Nitrogen and Decompress:
- network: N2Connection and the XML-RPC connection over Network.framework;
- smtp: the SMTP client over Network.framework;
- geometry: the N3 geometry and Bézier curves;
- database: N2ManagedDatabase, the Core Data base of the DICOM database;
- helpers: the other helpers and categories, N2Shell and the OpenGL window;
- xpc: Decompress as an XPC service and the HTML report printing.
"""
from pathlib import Path
from copy import deepcopy
import json
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
APP_MODULES = {'Horos'}
IMPORT = re.compile(r'^\s*(?:@testable\s+)?(?:@_\w+\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)', re.M)
APP_HEADER = re.compile(r'^\s*#\s*(?:import|include)\s*[<"](?:[^>"]*/)?(?:Horos/Sources/|Horos-Swift\.h)', re.M)


LIBRARY_HEADER = {
    'DCMTK': re.compile(r'^dcmtk/'),
    'VTK': re.compile(r'(?:^|/)vtk\w*\.h$'),
    'ITK': re.compile(r'(?:^|/)itk\w*\.(?:h|hxx|txx)$'),
}
ADAPTERS = 'Horos/Sources/Adapters/'
REGISTRY = json.loads((root / 'tests/cxx-boundary-registry.json').read_text())
LIBRARY_PENDING = REGISTRY['library_pending']
DIRECTIVE = re.compile(r'^\s*#\s*(\w+)(.*)$')
INCLUDED = re.compile(r'^\s*[<"]([^">]+)[">]')
SOURCE_SUFFIXES = ('.m', '.mm', '.c', '.cpp', '.cc', '.cxx')
REGISTERED_FOLDERS = ('Horos/Sources', 'Nitrogen/Sources', 'Decompress', 'DICOMPrint/Helper')
STAGE_NAMES = {'network', 'smtp', 'geometry', 'database', 'helpers', 'xpc'}
MAP_PATH = root / 'tests/module-map.json'
MAP_TEXT = MAP_PATH.read_text()
MODULE_MAP = json.loads(MAP_TEXT)
MAP_SECTIONS = {'app_frameworks', 'areas', 'modules', 'planned_modules', 'ports'}
CAPABILITIES = {'studies', 'series', 'metadata', 'rois', 'import', 'maintenance', 'remote-query', 'retrieve', 'send'}


def render_map(sections):
    """The map's canonical text: sections and entries sorted, one entry per line."""
    lines = ['{']
    names = sorted(sections)
    for i, name in enumerate(names):
        entries = sections[name]
        lines.append(f' {json.dumps(name)}: {{')
        keys = sorted(entries)
        for j, key in enumerate(keys):
            lines.append(f'  {json.dumps(key)}: {json.dumps(entries[key], sort_keys=True)}' + (',' if j < len(keys) - 1 else ''))
        lines.append(' }' + (',' if i < len(names) - 1 else ''))
    lines.append('}')
    return '\n'.join(lines) + '\n'


def map_order(module_map, existing):
    """Every module of the map, created or planned, in the order of Package.swift.

    `existing` is the package's modules in their order; a planned module goes
    right after the module it will be listed after.
    """
    order = list(existing)
    planned = dict(module_map['planned_modules'])
    while planned:
        placed = [name for name, entry in planned.items() if entry.get('listed_after') in order]
        if not placed:
            break
        for name in sorted(placed):
            order.insert(order.index(planned.pop(name)['listed_after']) + 1, name)
    return order, sorted(planned)


def map_problems(module_map, existing):
    """What is wrong in the map itself, against the modules `existing` of the package, in order."""
    found = []
    if set(module_map) != MAP_SECTIONS:
        return [f'the module map has the sections {sorted(module_map)}, not {sorted(MAP_SECTIONS)}']
    modules, planned = module_map['modules'], module_map['planned_modules']
    for name in existing:
        if name not in modules:
            found.append(f'{name} is not in the module map (tests/module-map.json)' +
                         (': move it from planned_modules to modules' if name in planned else ''))
    for name in sorted(modules):
        if name not in existing:
            found.append(f'{name} is in the modules of the map but not in Package.swift: '
                         'put it in planned_modules or remove it')
    order, unplaced = map_order(module_map, existing)
    for name in unplaced:
        found.append(f'{name}: the planned module is not listed_after a module of the map')
    entries = {**planned, **modules}
    position = {name: index for index, name in enumerate(order)}
    for name, entry in sorted(entries.items()):
        allowed = entry.get('may_depend_on')
        if not isinstance(allowed, list):
            found.append(f'{name}: its entry needs the list may_depend_on')
            continue
        for dependency in allowed:
            if dependency not in entries:
                found.append(f'{name} may depend on {dependency}, which is not in the module map')
            elif name in position and position.get(dependency, len(order)) >= position[name]:
                found.append(f'{name} may depend on {dependency}, which is not listed before it')
        if allowed != sorted(allowed, key=lambda dependency: position.get(dependency, len(order))):
            found.append(f'{name}: may_depend_on does not follow the order of Package.swift')
    for area, entry in sorted(module_map['areas'].items()):
        if not entry.get('modules') or not entry.get('stays_in_app'):
            found.append(f'area {area}: it needs its modules and what stays in the app target')
        for module in entry.get('modules', []):
            if module not in entries:
                found.append(f'area {area}: {module} is not in the module map')
    for port, entry in sorted(module_map['ports'].items()):
        module = entry.get('module')
        if module not in entries:
            found.append(f'port {port}: its module {module} is not in the module map')
        if entry.get('capability') not in CAPABILITIES:
            found.append(f'port {port}: its capability {entry.get("capability")!r} is not one of {sorted(CAPABILITIES)}')
        if not isinstance(entry.get('stage'), int) or isinstance(entry.get('stage'), bool):
            found.append(f'port {port}: its stage is not a stage number')
        if not entry.get('app_consumers') and not entry.get('module_consumers'):
            found.append(f'port {port}: it names no consumer')
        for consumer in entry.get('app_consumers', []):
            if not consumer.startswith('Horos/Sources/') or not (root / consumer).is_file():
                found.append(f'port {port}: its consumer {consumer} does not exist in Horos/Sources')
        for consumer in entry.get('module_consumers', []):
            if consumer not in entries:
                found.append(f'port {port}: its consumer {consumer} is not in the module map')
            elif consumer != module and module not in entries[consumer]['may_depend_on']:
                found.append(f'port {port}: its consumer {consumer} may not depend on {module}')
    return found


def includes(text):
    """(name, when) for each include of `text`; when is 'any', 'cxx', 'c' or 'never'."""
    text = re.sub(r'/\*.*?\*/', lambda comment: '\n' * comment.group(0).count('\n'), text, flags=re.S)
    conditions, found = [], []
    for line in text.splitlines():
        directive = DIRECTIVE.match(line)
        if not directive:
            continue
        name, rest = directive.group(1), directive.group(2).split('//')[0]
        if name in ('if', 'ifdef', 'ifndef'):
            condition = None
            if '__cplusplus' in rest and '&&' not in rest and '||' not in rest:
                negated = name == 'ifndef' or re.search(r'!\s*(?:defined|__cplusplus)', rest)
                condition = 'c' if negated else 'cxx'
            conditions.append(condition)
        elif name == 'elif' and conditions:
            conditions[-1] = None
        elif name == 'else' and conditions and conditions[-1]:
            conditions[-1] = 'c' if conditions[-1] == 'cxx' else 'cxx'
        elif name == 'endif' and conditions:
            conditions.pop()
        elif name in ('include', 'import'):
            included = INCLUDED.match(rest)
            if included:
                active = {condition for condition in conditions if condition}
                found.append((included.group(1), 'never' if len(active) > 1 else (active.pop() if active else 'any')))
    return found


def library_reach(base, extra=None):
    """{relative path: set of libraries} for the source files of Horos/Sources."""
    sources = base / 'Horos/Sources'
    texts = {}
    for folder in (sources, base / 'Nitrogen/Sources'):
        for path in folder.rglob('*'):
            if path.suffix in SOURCE_SUFFIXES + ('.h', '.hpp'):
                texts[path.relative_to(base).as_posix()] = path.read_bytes().decode('latin1')
    texts.update(extra or {})
    parsed = {path: includes(text) for path, text in texts.items()}
    headers = {path.rsplit('/', 1)[-1]: path for path in parsed if path.endswith(('.h', '.hpp'))}

    def reach(path, language, seen):
        if path in seen:
            return set()
        seen.add(path)
        libraries = set()
        for name, when in parsed[path]:
            if when not in ('any', language):
                continue
            libraries |= {library for library, header in LIBRARY_HEADER.items() if header.search(name)}
            local = name.rsplit('/', 1)[-1]
            if local == 'Horos-Swift.h':
                local = 'Horos-Bridging-Header.h'
            if local in headers and not name.startswith('dcmtk/'):
                libraries |= reach(headers[local], language, seen)
        return libraries

    reached = {}
    for path in parsed:
        if path.startswith('Horos/Sources/') and path.endswith(SOURCE_SUFFIXES):
            language = 'c' if path.endswith(('.m', '.c')) else 'cxx'
            libraries = reach(path, language, set())
            if libraries:
                reached[path] = libraries
    return reached


def boundary_problems(base, extra=None):
    """What breaks the library boundary in the checkout at `base`."""
    found = []
    reached = library_reach(base, extra)
    for path, libraries in sorted(reached.items()):
        name = path.rsplit('/', 1)[-1]
        if not path.startswith(ADAPTERS) and name not in LIBRARY_PENDING:
            found.append(f'{path} reaches {", ".join(sorted(libraries))} outside the adapters in {ADAPTERS}')
    still = {path.rsplit('/', 1)[-1] for path in reached}
    for name, stage in sorted(LIBRARY_PENDING.items()):
        if name not in still:
            found.append(f'{name} no longer reaches DCMTK, VTK or ITK: remove it from LIBRARY_PENDING (stage {stage})')
    return found


def registry_key(relative):
    """The registry's name for a source file: bare in Horos/Sources, its path elsewhere."""
    if relative.startswith('Horos/Sources/'):
        return relative.rsplit('/', 1)[-1]
    return relative


def sources_problems(base, extra=()):
    """Objective-C, Objective-C++ and C++ files of the registered folders that are not accounted for.

    `extra` adds relative paths of files that do not exist, to check a mutation.
    """
    found = []
    pending, exceptions = REGISTRY['sources_pending'], REGISTRY['exceptions']
    paths = {path.relative_to(base).as_posix()
             for folder in REGISTERED_FOLDERS for path in (base / folder).rglob('*')}
    present = set()
    for relative in sorted(paths | set(extra)):
        if not relative.endswith(SOURCE_SUFFIXES) or relative.startswith(ADAPTERS):
            continue
        key = registry_key(relative)
        present.add(key)
        if key not in pending and key not in exceptions:
            found.append(f'{relative} is neither converted, an adapter, nor in the registry')
    for name in sorted(set(pending) | set(exceptions)):
        if name not in present:
            found.append(f'{name} is gone: remove it from tests/cxx-boundary-registry.json')
    for name, stage in sorted(pending.items()):
        if not (isinstance(stage, int) and not isinstance(stage, bool)) and stage not in STAGE_NAMES:
            found.append(f'{name}: its stage {stage!r} is neither a stage number nor one of {sorted(STAGE_NAMES)}')
    for name, reason in sorted(exceptions.items()):
        if not isinstance(reason, str) or len(reason.split()) < 4:
            found.append(f'{name}: an exception needs its technical reason')
    for name in sorted(set(pending) & set(exceptions)):
        found.append(f'{name} is both pending and an exception')
    return found


def dump_package(package):
    """The manifest of the package at `package`, or the reason it does not load."""
    if shutil.which('swift') is None:
        sys.stderr.write('needs swift (Xcode command line tools)\n')
        sys.exit(2)
    dumped = subprocess.run(['swift', 'package', '--package-path', str(package), 'dump-package'],
                            capture_output=True, text=True)
    if dumped.returncode != 0:
        return None, 'Package.swift does not load: ' + dumped.stderr.strip()[-500:]
    return json.loads(dumped.stdout), None


def package_modules(manifest):
    """The modules of a manifest, without their tests, in the order of Package.swift."""
    return [target['name'] for target in manifest['targets'] if target['type'] != 'test']


def problems(package, module_map=MODULE_MAP):
    """What breaks the rule in the package at `package`, with the module map `module_map`."""
    manifest, failure = dump_package(package)
    if failure:
        return [failure]
    found = map_problems(module_map, package_modules(manifest))
    entries = {**module_map['planned_modules'], **module_map['modules']}
    app_frameworks = module_map['app_frameworks']
    targets = manifest['targets']
    order = {target['name']: index for index, target in enumerate(targets)}
    for index, target in enumerate(targets):
        name, path = target['name'], target.get('path') or ''
        module = name[:-len('Tests')] if target['type'] == 'test' and name.endswith('Tests') else name
        if not module.startswith('IsiX'):
            found.append(f'{name}: internal modules are named IsiX<Area>')
        if path != f'{module}/{"Tests" if target["type"] == "test" else "Sources"}':
            found.append(f'{name}: its path is {path!r}, not its own folder {module}/Sources or {module}/Tests')
        allowed = set(entries.get(module, {}).get('may_depend_on', []))
        if target['type'] == 'test':
            allowed.add(module)
        declared = set()
        for dependency in target.get('dependencies', []):
            kind, = dependency.keys()
            dependency_name = dependency[kind][0]
            declared.add(dependency_name)
            if dependency_name in order and target['type'] != 'test' and order[dependency_name] >= index:
                found.append(f'{name} depends on {dependency_name}, which is not listed before it')
            if dependency_name in order and module in entries and dependency_name not in allowed:
                found.append(f'{name} depends on {dependency_name}, which the module map does not allow '
                             f'(tests/module-map.json)')
        sources = sorted((package / path).rglob('*')) if path else []
        for source in sources:
            if source.suffix not in ('.swift', '.h', '.m', '.mm', '.c', '.cpp'):
                continue
            text = source.read_text(errors='replace')
            relative = source.relative_to(package)
            for imported in IMPORT.findall(text):
                if imported in APP_MODULES:
                    found.append(f'{relative} imports the app target {imported}')
                elif imported in app_frameworks:
                    found.append(f'{relative} imports {imported}, which stays in the app target: '
                                 f'{app_frameworks[imported]}')
                elif imported in order and imported not in declared and imported != module:
                    found.append(f'{relative} imports {imported} without declaring it as a dependency of {name}')
            if APP_HEADER.search(text):
                found.append(f'{relative} includes a header of the app target')
    return found


failures = problems(root / 'Modules')
if MAP_TEXT != render_map(MODULE_MAP):
    failures.append('tests/module-map.json is not one entry per line with its keys sorted')
for failure in failures:
    print('FAIL:', failure)


def add_import(copy, imported):
    source = next((copy / 'IsiXStorage' / 'Sources').glob('*.swift'))
    source.write_text(source.read_text().replace('import Foundation\n', f'import Foundation\nimport {imported}\n', 1))


def add_later_module(copy, depending_on_it=None):
    (copy / 'IsiXLater' / 'Sources').mkdir(parents=True)
    (copy / 'IsiXLater' / 'Sources' / 'Later.swift').write_text('public enum Later {}\n')
    manifest = (copy / 'Package.swift').read_text()
    if depending_on_it:
        manifest = manifest.replace(f'.target(name: "{depending_on_it}", path:',
                                    f'.target(name: "{depending_on_it}", dependencies: ["IsiXLater"], path:', 1)
    manifest = manifest.replace('    ],\n    swiftLanguageModes',
                                '        .target(name: "IsiXLater", path: "IsiXLater/Sources"),\n    ],\n    swiftLanguageModes', 1)
    (copy / 'Package.swift').write_text(manifest)


def add_dependency(copy, module, dependency):
    manifest = (copy / 'Package.swift').read_text()
    plain = f'.target(name: "{module}", path:'
    listed = f'.target(name: "{module}", dependencies: ['
    if plain in manifest:
        manifest = manifest.replace(plain, f'.target(name: "{module}", dependencies: ["{dependency}"], path:', 1)
    else:
        manifest = manifest.replace(listed, f'{listed}"{dependency}", ', 1)
    (copy / 'Package.swift').write_text(manifest)


# Each mutation of a copy of the package, and the refusal it must meet.
package_mutations = {
    'import Horos': (lambda copy: add_import(copy, 'Horos'), 'imports the app target Horos'),
    'dependency on a later module': (lambda copy: add_later_module(copy, 'IsiXStorage'), 'which is not listed before it'),
    'a dependency the module map does not allow': (lambda copy: add_dependency(copy, 'IsiXDICOMNetwork', 'IsiXDatabase'),
                                                   'IsiXDICOMNetwork depends on IsiXDatabase, which the module map does not allow'),
    'a module the module map does not list': (add_later_module, 'IsiXLater is not in the module map'),
    'a module that imports AppKit': (lambda copy: add_import(copy, 'AppKit'), 'imports AppKit, which stays in the app target'),
}
with tempfile.TemporaryDirectory(prefix='horos-module-rule-') as folder:
    for mutation, (mutate, refusal) in package_mutations.items():
        copy = Path(folder) / mutation.replace(' ', '-')
        shutil.copytree(root / 'Modules', copy, ignore=shutil.ignore_patterns('.build', '.swiftpm'))
        mutate(copy)
        if not any(refusal in failure for failure in problems(copy)):
            failures.append(f'the rule accepts a mutation: {mutation}')
            print(f'FAIL: the rule accepts a mutation: {mutation}')

ROOT_MODULES = package_modules(dump_package(root / 'Modules')[0])


def mutated_map(change):
    module_map = deepcopy(MODULE_MAP)
    change(module_map)
    return module_map


# Each mutation of the map, and the refusal it must meet.
map_mutations = {
    'a module allowed to depend on one listed after it':
        (lambda module_map: module_map['modules']['IsiXLogging']['may_depend_on'].append('IsiXCrashReporting'),
         'IsiXLogging may depend on IsiXCrashReporting, which is not listed before it'),
    'a consumer file that does not exist':
        (lambda module_map: module_map['ports']['LocalStudyReading']['app_consumers'].append('Horos/Sources/MissingConsumer.swift'),
         'Horos/Sources/MissingConsumer.swift does not exist'),
    "a consuming module that may not depend on the port's module":
        (lambda module_map: module_map['ports']['LocalStudyReading']['module_consumers'].append('IsiXROI'),
         'its consumer IsiXROI may not depend on'),
}
for mutation, (change, refusal) in map_mutations.items():
    if not any(refusal in failure for failure in map_problems(mutated_map(change), ROOT_MODULES)):
        failures.append(f'the module map accepts a mutation: {mutation}')
        print(f'FAIL: the module map accepts a mutation: {mutation}')

boundary = boundary_problems(root) + sources_problems(root)
for failure in boundary:
    print('FAIL:', failure)
failures += boundary
mutations = {
    'a new file that includes DCMTK': {'Horos/Sources/BoundaryProbe.mm': '#include <dcmtk/dcmdata/dctk.h>\n'},
    'a new file that reaches VTK through a header':
        {'Horos/Sources/BoundaryProbe.h': '#ifdef __cplusplus\n#include <vtkActor.h>\n#endif\n',
         'Horos/Sources/BoundaryProbe.mm': '#import "BoundaryProbe.h"\n'},
    'a new C++ file that includes VTK': {'Horos/Sources/BoundaryProbe.cxx': '#include <vtkObjectFactory.h>\n'},
}
for mutation, extra in mutations.items():
    probe, = (path for path in extra if not path.endswith('.h'))
    if not any(probe + ' ' in failure for failure in boundary_problems(root, extra)):
        failures.append(f'the boundary accepts a mutation: {mutation}')
        print(f'FAIL: the boundary accepts a mutation: {mutation}')
if any('BoundaryProbe.m ' in failure for failure in boundary_problems(
        root, {'Horos/Sources/BoundaryProbe.h': '#ifdef __cplusplus\n#include <vtkActor.h>\n#endif\n',
               'Horos/Sources/BoundaryProbe.m': '#import "BoundaryProbe.h"\n'})):
    failures.append('the boundary counts an include under #ifdef __cplusplus in an Objective-C file')
    print('FAIL: the boundary counts an include under #ifdef __cplusplus in an Objective-C file')
for probe in ('Horos/Sources/RegistryProbe.m', 'Horos/Sources/RegistryProbe.cxx', 'Nitrogen/Sources/RegistryProbe.m',
              'Decompress/RegistryProbe.mm', 'DICOMPrint/Helper/RegistryProbe.mm'):
    if not any(failure.startswith(probe + ' ') for failure in sources_problems(root, (probe,))):
        failures.append(f'the registry accepts a new file outside it: {probe}')
        print(f'FAIL: the registry accepts a new file outside it: {probe}')

if failures:
    sys.exit(1)
print(f'PASS: {len(LIBRARY_PENDING)} files still reach DCMTK, VTK or ITK outside the adapters, '
      'each listed with its stage, and no other does; a new include is refused')
print(f'PASS: {len(REGISTRY["sources_pending"])} Objective-C, Objective-C++ and C++ files of '
      f'{", ".join(REGISTERED_FOLDERS)} still to convert and {len(REGISTRY["exceptions"])} kept with a reason, '
      'each listed; a new file in any of them is refused')
print('PASS: every internal module is IsiX<Area> in its own folder, depends only on modules listed before it, '
      'and imports nothing of the app; importing Horos or depending on a later module is refused')
print(f'PASS: the module map lists the {len(MODULE_MAP["modules"])} modules and '
      f'{len(MODULE_MAP["planned_modules"])} planned, {len(MODULE_MAP["areas"])} areas and '
      f'{len(MODULE_MAP["ports"])} ports with existing consumers; a dependency it does not allow, '
      'an unlisted module and an AppKit import are refused')
