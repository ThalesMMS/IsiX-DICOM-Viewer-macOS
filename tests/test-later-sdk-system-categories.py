#!/usr/bin/env python3
"""The helpers later headers of the plugin SDK add to classes of Foundation and
AppKit do what their names say.

A plugin built with those headers sends strings, arrays, dictionaries, data,
dates, the file manager, images and colours the helper selectors the headers
declare for them as categories. Horos/Sources/FoundationCategories+LaterPluginSDK.swift
and AppKitCategories+LaterPluginSDK.swift answer those whose meaning is plain
from the name and the types. The two files use nothing of the application, so
they are compiled here alone, into a library, and an Objective-C program that
declares each selector with the types of the headers (fixtures/later-sdk-system-categories)
sends it by name:
- each selector is answered by the library, with the type encoding the
  compiler gives its declaration and the one of
  tests/fixtures/later-sdk-selector-types.json;
- each does what its name says for a real value, and answers nil, NO or
  nothing for nil and zero arguments;
- those that draw nothing do the same on a second thread;
- the selectors of those classes that the two files do not answer stay
  unanswered by them: the application answers those from its table, or not
  at all.

    python3 tests/test-later-sdk-system-categories.py

The program writes in a temporary folder, which it is also given as the
user's home. Exit status 2 without the Swift compiler.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures/later-sdk-system-categories'
SOURCES = [ROOT / 'Horos/Sources/FoundationCategories+LaterPluginSDK.swift', ROOT / 'Horos/Sources/AppKitCategories+LaterPluginSDK.swift']
OBJC = {'FileManager': 'NSFileManager', 'NotificationCenter': 'NSNotificationCenter', 'Thread': 'NSThread'}
ARCH = 'arm64'


def implemented():
    """"Class -selector" of every selector the two files answer."""
    found = []
    for source in SOURCES:
        owner, lines = None, source.read_text().split('\n')
        for number, line in enumerate(lines):
            extension = re.match(r'(?:private |public )?extension (\w+)', line)
            if extension:
                owner = OBJC.get(extension.group(1), extension.group(1))
            selector = re.search(r'@objc\(([\w:]+)\)', line)
            if selector:
                rest = line[selector.end():] if 'func' in line[selector.end():] else lines[number + 1]
                found.append('%s %s%s' % (owner, '+' if re.search(r'\bclass func\b|\bstatic func\b', rest) else '-', selector.group(1)))
    return found


def main():
    if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode:
        print('skipped: needs the Swift compiler', file=sys.stderr)
        return 2
    answered = implemented()
    if len(set(answered)) != len(answered):
        print('FAIL: a selector is answered twice in the two files')
        return 1
    types = json.loads((ROOT / 'tests/fixtures/later-sdk-selector-types.json').read_text())['types']
    absent = sorted(entry for entry in answered if entry not in types)
    if absent:
        print('FAIL: answered by the two files and not in the fixture of the types: ' + ', '.join(absent))
        return 1
    classes = {entry.split(' ')[0] for entry in answered}
    # The list the program reads: every selector of these classes with its types, answered here or left to the table.
    listing = [{'entry': entry, 'encoding': encoding} for entry, encoding in sorted(types.items()) if entry.split(' ')[0] in classes]
    with tempfile.TemporaryDirectory(prefix='isix-later-sdk-categories-') as name:
        folder = Path(name).resolve()
        (folder / 'list.json').write_text(json.dumps(listing))
        (folder / 'implemented.json').write_text(json.dumps(answered))
        library = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                                  '-target', ARCH + '-apple-macos15.0', '-parse-as-library', '-emit-library', '-O',
                                  '-module-name', 'LaterSDKCategories', '-o', str(folder / 'libLaterSDKCategories.dylib'),
                                  *map(str, SOURCES)], capture_output=True, text=True)
        if library.returncode:
            print('FAIL: the two files do not compile alone, without a warning:\n' + library.stderr[-3000:])
            return 1
        probe = subprocess.run(['xcrun', 'clang', '-arch', ARCH, '-mmacosx-version-min=15.0', '-fobjc-arc', '-Wall',
                                '-Wno-unused-variable', '-I', str(FIXTURES), str(FIXTURES / 'probe.m'), '-framework', 'AppKit',
                                '-lz', '-lcompression', '-L', str(folder), '-lLaterSDKCategories', '-Wl,-rpath,' + str(folder),
                                '-o', str(folder / 'probe')], capture_output=True, text=True)
        if probe.returncode:
            print('FAIL: the program does not build:\n' + probe.stderr[-3000:])
            return 1
        home = folder / 'home'
        home.mkdir()
        run = subprocess.run([str(folder / 'probe'), str(folder / 'list.json'), str(folder / 'implemented.json')],
                             capture_output=True, text=True, timeout=600,
                             env=dict(os.environ, CFFIXED_USER_HOME=str(home), TMPDIR=str(folder) + '/'))
    if run.returncode:
        print(run.stderr[-4000:])
        print('FAIL: ' + (run.stdout.strip().splitlines() or ['the program ended with status %d' % run.returncode])[-1])
        return 1
    print('PASS: %d selectors of the categories on system classes; %s' % (len(answered), run.stdout.strip().splitlines()[-1]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
