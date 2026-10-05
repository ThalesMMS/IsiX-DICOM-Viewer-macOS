#!/usr/bin/env python3
"""VTK's archive defines no function another dependency archive also defines,
and its classes stay visible outside the app's binary.

The app links every dependency as a static archive, and the linker takes a
symbol from the first archive member that defines it, without a word when a
second member it also loads defines the same name. VTK 9 built its wrapping
tools by default, and their header parser defines the same global yy* scanner
functions as DCMTK's VR scanner (dcmdata's vrscanl.c): DCMTK's scanner then ran
VTK's yylex. The configure step keeps the wrapping tools out; this checks the
source and, where a dependency build exists, the archives themselves.

VTK 9 also compiles its classes with hidden visibility unless the build says
otherwise; linked statically they would then be private to the app's binary,
while plugins reach VTK through the host, as they did with VTK 8.2.

A plugin that asks VTK for a class the host's factories replace calls the base
class's New(). The host itself only calls some of them, and the Release link
strips what nothing reaches: the call from the plugin then went to address
zero. The project names the entry points the host does not reach as symbols
the link must keep, and the built executables must export all of them.
"""
from pathlib import Path
import collections
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
failures = []

script = (root / 'Horos/Scripts/VTK/CMake.sh').read_text()
if not re.search(r'^args\+=\(-DVTK_ENABLE_WRAPPING=OFF\)', script, re.M):
    failures.append('Horos/Scripts/VTK/CMake.sh does not turn VTK_ENABLE_WRAPPING off')
if not re.search(r'^args\+=\(-DCMAKE_CXX_VISIBILITY_PRESET=default -DCMAKE_VISIBILITY_INLINES_HIDDEN=OFF\)', script, re.M):
    failures.append('Horos/Scripts/VTK/CMake.sh does not keep VTK\'s symbols visible')
if '-DCMAKE_PROJECT_VTK_INCLUDE="$host_build"' not in script:
    failures.append('VTK does not apply its host visibility hook')


def private(archive, names):
    """The names an archive defines as private externals (hidden visibility)."""
    out = subprocess.run(['nm', '-g', '--defined-only', '-m', str(archive)],
                         capture_output=True, text=True, check=True).stdout
    return {line.split()[-1] for line in out.splitlines()
            if 'private external' in line and line.split()[-1] in names}


def strong(archive):
    """Global, non-weak symbols an archive defines, with the members that define them."""
    out = subprocess.run(['nm', '-g', '--defined-only', '-m', str(archive)],
                         capture_output=True, text=True, check=True).stdout
    symbols, member = collections.defaultdict(set), None
    for line in out.splitlines():
        if line.endswith(':') and ' ' not in line:
            match = re.match(r'^.*\((.+)\):$', line)
            member = match.group(1) if match else line[:-1]
        elif ') external ' in line and 'weak' not in line:
            symbols[line.split()[-1]].add(member)
    return symbols


checked = 0
for configuration in ('Debug', 'Release'):
    base = next((folder / 'Intermediates.noindex/Horos.build' / configuration
                 for folder in (root / 'build', root / 'build/Build')
                 if (folder / 'Intermediates.noindex/Horos.build' / configuration).is_dir()),
                root / 'build/Intermediates.noindex/Horos.build' / configuration)
    vtk_archive = base / 'VTK.build/Install/wlib/libVTK.a'
    if not vtk_archive.exists():
        continue
    checked += 1
    vtk = strong(vtk_archive)
    hidden = private(vtk_archive, {'__ZN9vtkObject3NewEv', '__ZN11vtkRenderer8AddActorEP7vtkProp',
                                    '__ZN20vtkDebugLeaksManagerC1Ev'})
    if hidden:
        failures.append('%s: libVTK.a hides %s' % (configuration, ', '.join(sorted(hidden))))
    if any('vtkParse' in member for members in vtk.values() for member in members):
        failures.append('%s: libVTK.a carries the wrapping tools\' parser' % configuration)
    for archive in sorted(base.glob('*.build/Install/*lib/*.a')):
        if archive.parts[-4] == 'VTK.build':
            continue
        shared = sorted(set(vtk) & set(strong(archive)))
        if shared:
            members = sorted({m for name in shared for m in vtk[name]})
            failures.append('%s: libVTK.a (%s) and %s both define %d symbols, such as %s' % (
                configuration, ', '.join(members[:3]), archive.relative_to(base), len(shared), ', '.join(shared[:3])))

# The base classes the host's factories replace, read from where they are registered.
overridden = set()
for name in ('Horos/Sources/SceneFactory.cxx', 'Horos/Sources/VRPresentation.mm'):
    text = (root / name).read_text(encoding='utf-8', errors='replace')
    overridden |= set(re.findall(r'(?:Add<\w+>|RegisterOverride)\(\s*"(vtk\w+)"', text))
if len(overridden) < 11:
    failures.append('only %d base classes found in the host\'s factory registrations' % len(overridden))
entry_points = {base: '__ZN%d%s3NewEv' % (len(base), base) for base in overridden}
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8', errors='replace')
kept = set(re.findall(r'"-Wl,-u,(__ZN\d+vtk\w+3NewEv)"', project))
for symbol in sorted(kept):
    if project.count('"-Wl,-u,%s"' % symbol) != 2:
        failures.append('%s is not kept in both configurations of the app' % symbol)
    if symbol not in entry_points.values():
        failures.append('%s is kept but no host factory replaces that class' % symbol)
executables = 0
for configuration in ('Debug', 'Release'):
    executable = root / 'build/Build/Products' / configuration / 'IsiX DICOM Viewer.app/Contents/MacOS/IsiX DICOM Viewer'
    if not executable.exists():
        continue
    executables += 1
    out = subprocess.run(['nm', '-gU', str(executable)], capture_output=True, text=True, check=True).stdout
    exported = {line.split()[-1] for line in out.splitlines() if line.strip()}
    missing = sorted(base for base, symbol in entry_points.items() if symbol not in exported)
    if missing:
        failures.append('%s: the app does not export New() of %s, which its factories replace' % (configuration, ', '.join(missing)))

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
if not checked:
    print('SKIP: no VTK build under build[/Build]/Intermediates.noindex; the source check passed')
    raise SystemExit(2)
print('OK: VTK\'s archive shares no symbol with the other dependency archives (%d configurations); '
      '%d built executables export New() of the %d classes the host\'s factories replace' % (checked, executables, len(entry_points)))
