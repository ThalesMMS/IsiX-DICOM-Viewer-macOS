#!/usr/bin/env python3
"""The pilot's «Compare in Metal» windows stay gone (#800).

The 2D viewer's contextual menu had «Compare in Metal» and the 3D viewer's
«Compare in Metal (3D)». Each opened a window of the pilot (#373, #375) that
drew the viewer's state with Metal beside the viewer's own picture, then drawn
by OpenGL or VTK, and told the user to go back to the «original viewer» for
tools and overlays. Since #728 and #731 the viewers draw with Metal
themselves, and since #734/#735 there is no other renderer: the window
compared Metal with Metal and pointed to a viewer that no longer exists.

Checked, in the tracked sources, project and resources:

- PlanarComparison.swift and VolumeComparison.swift are gone, from the tree
  and from the Xcode project;
- no source names the windows, their Objective-C classes and protocols, or the
  menu actions that opened them;
- no string literal in the sources, and no key in any Localizable.strings
  (ja-JP read as UTF-16), speaks of the «original viewer», of «Compare in
  Metal» or of a «Metal comparison»; no nib offers «Compare in Metal».

`<git revision>` as an optional argument reads that revision instead of the
working tree, the negative control: the revision before #800 fails.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

GONE_FILES = ('Horos/Sources/PlanarComparison.swift', 'Horos/Sources/VolumeComparison.swift')
# Names only the comparison windows used: the classes and protocols Swift
# exported to Objective-C, and the actions the contextual menus sent.
GONE_NAMES = ('HorosPlanarComparison', 'HorosVolumeComparison', 'HorosPlanarSource', 'HorosVolumeSource',
              'PlanarComparisonWindow', 'VolumeComparisonWindow', 'PlanarRenderWorker',
              'openPlanarMetalComparison', 'openVolumeMetalComparison')
WORDING = re.compile(r'original viewer|compare in metal|compared in metal|metal comparison', re.IGNORECASE)
LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def tracked_files():
    command = ['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision] if revision else \
              ['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard']
    names = subprocess.check_output(command + ['--', 'Horos', 'Horos.xcodeproj']).decode('utf-8').splitlines()
    if not revision:
        names = [name for name in names if (root / name).exists()]
    return names


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path])
    return (root / path).read_bytes()


def text(data):
    if data[:2] in (b'\xff\xfe', b'\xfe\xff'):
        return data.decode('utf-16')
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError:
        return data.decode('latin-1')


failures = []
files = tracked_files()
present = set(files)
for gone in GONE_FILES:
    if gone in present:
        failures.append(gone + ' is back')

sources = [name for name in files if name.startswith('Horos/Sources/') and
           name.endswith(('.m', '.mm', '.h', '.swift', '.c', '.cpp', '.cxx'))]
if len(sources) < 100:
    failures.append('only %d sources found; the test is not reading the tree it should' % len(sources))
for name in sources:
    body = text(read(name))
    for gone in GONE_NAMES:
        if gone in body:
            failures.append('%s names %s' % (name, gone))
    for number, line in enumerate(body.splitlines(), 1):
        for literal in LITERAL.findall(line):
            if WORDING.search(literal):
                failures.append('%s:%d says %s' % (name, number, literal))

project = text(read('Horos.xcodeproj/project.pbxproj'))
for gone in GONE_FILES:
    if Path(gone).name in project:
        failures.append('the Xcode project still lists ' + Path(gone).name)

catalogs = [name for name in files if name.endswith('/Localizable.strings')]
if len(catalogs) < 4:
    failures.append('expected the en, es, it-IT and ja-JP catalogs, found %d' % len(catalogs))
for name in catalogs:
    for number, line in enumerate(text(read(name)).splitlines(), 1):
        key = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=', line)
        if key and WORDING.search(key.group(1)):
            failures.append('%s:%d has the key "%s"' % (name, number, key.group(1)))

for name in files:
    if name.endswith('.xib') and re.search(r'compare in metal', text(read(name)), re.IGNORECASE):
        failures.append(name + ' offers Compare in Metal')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: no comparison window, menu item, action or «original viewer» text in %d sources, %d catalogs and the project'
      % (len(sources), len(catalogs)))
