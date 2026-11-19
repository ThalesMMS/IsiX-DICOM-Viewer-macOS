#!/usr/bin/env python3
"""The built application imports weakly, from Foundation and from the Swift
libraries of the system, only symbols known to be safe.

A declaration the SDK marks as back deployed before a system version, or
available from one above the product's minimum, is linked as a weak symbol,
and the compiler guards its call with a check of the running system's version.
The check trusts the version: a system that reports it without having the
symbol, as a beta of a point release can, leaves the symbol's address at 0,
and the guarded call jumps there. The macOS 27.2 SDK back deploys
`Date.<=` and `Date.>=` that way, so every `<=` or `>=` between two dates
became such a call, and the first one runs while the application launches.
`Date.<` and `Date.>` are ordinary symbols of every version: the sources write
`!(a > b)` and `!(a < b)`.

Checked against every Mach-O file of the built application bundle, in each of
its slices:

- no weak import of a symbol tests/weak-system-imports.json lists under
  "refused" (the two operators, with the reason);
- every other weak import from Foundation or from a libswift* library is
  listed under "allowed" for that library.

Weak imports from other libraries (Metal 4 classes, libSystem) are not judged
here. An allowed symbol the bundle does not import is not an error: the Debug
and Release builds do not import the same set.

    python3 tests/test-weak-system-imports.py [--release | --app APP] [--registry FILE]

By default the Debug build in build/Build/Products; --release checks the
Release build there, --app another bundle. Exit status 2 when the bundle or
dyld_info (Xcode command line tools) is missing.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / 'tests/weak-system-imports.json'
DEFAULT_APP = ROOT / 'build/Build/Products/Debug/IsiX DICOM Viewer.app'
RELEASE_APP = ROOT / 'build/Build/Products/Release/IsiX DICOM Viewer.app'
SKIPPED = 2
MACHO = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
SLICE = re.compile(r'^.* \[(\S+)\]:$')
WEAK = re.compile(r'^\s*0x[0-9A-Fa-f]+\s+(\S+) \[weak-import\] \(from ([^)]+)\)\s*$')


def is_macho(path):
    with open(path, 'rb') as handle:
        return handle.read(4) in MACHO


def judged(library):
    return library == 'Foundation' or library.startswith('libswift')


def weak_imports(path):
    """(slice, symbol, library) for each weak import of the image; None when it cannot be read."""
    result = subprocess.run(['dyld_info', '-imports', str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    found, architecture = [], '?'
    for line in result.stdout.splitlines():
        header = SLICE.match(line)
        if header:
            architecture = header.group(1)
            continue
        match = WEAK.match(line)
        if match:
            found.append((architecture, match.group(1), match.group(2)))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    where = parser.add_mutually_exclusive_group()
    where.add_argument('--app', type=Path, help='application bundle to check')
    where.add_argument('--release', action='store_true', help='check the Release build')
    parser.add_argument('--registry', type=Path, default=REGISTRY)
    options = parser.parse_args()
    app = options.app or (RELEASE_APP if options.release else DEFAULT_APP)

    registry = json.loads(options.registry.read_text())
    refused = registry['refused']
    allowed = registry['allowed']
    both = sorted(symbol for symbols in allowed.values() for symbol in symbols if symbol in refused)
    if both:
        print('FAIL: %s lists as allowed a symbol it refuses: %s' % (options.registry.name, ', '.join(both)))
        return 1
    if not {'_$s10Foundation4DateV2leoiySbAC_ACtFZ', '_$s10Foundation4DateV2geoiySbAC_ACtFZ'} <= set(refused):
        print('FAIL: %s no longer refuses Date.<= and Date.>=' % options.registry.name)
        return 1

    if not shutil.which('dyld_info'):
        print('SKIP: dyld_info not found (Xcode command line tools)')
        return SKIPPED
    if not (app / 'Contents/Info.plist').is_file():
        print('SKIP: no built application at %s (expected --app APP, or a Debug build: '
              'script/build_and_run.sh --verify)' % app)
        return SKIPPED

    images = [path for path in sorted(app.rglob('*'))
              if path.is_file() and not path.is_symlink() and is_macho(path)]
    if not images:
        print('FAIL: no Mach-O file found in %s' % app)
        return 1

    failures, weak_count, judged_count, with_weak = [], 0, 0, 0
    for image in images:
        name = str(image.relative_to(app))
        imports = weak_imports(image)
        if imports is None:
            failures.append('%s: dyld_info could not read its imports' % name)
            continue
        weak_count += len(imports)
        with_weak += bool(imports)
        for architecture, symbol, library in imports:
            if symbol in refused:
                failures.append('%s [%s]: %s (from %s): %s' % (name, architecture, symbol, library, refused[symbol]))
            elif judged(library):
                judged_count += 1
                if symbol not in allowed.get(library, {}):
                    failures.append('%s [%s]: %s (from %s) is a weak import %s does not list: check that every '
                                    'system reporting the version its call is guarded by has the symbol, then '
                                    'list it, or write the call another way'
                                    % (name, architecture, symbol, library, options.registry.name))

    print('%d Mach-O files in %s, %d with weak imports; %d weak imports, %d from Foundation or libswift*'
          % (len(images), app.name, with_weak, weak_count, judged_count))
    if failures:
        for failure in failures:
            print('FAIL: ' + failure)
        return 1
    print('PASS: no refused weak import, and every weak import from Foundation or libswift* is listed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
