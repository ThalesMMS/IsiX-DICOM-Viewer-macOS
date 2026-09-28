#!/usr/bin/env python3
"""The app writes no fixed or predictable name into /tmp (#801, #802).

/tmp is writable by every user of the machine: another user can create the
path first, or a symbolic link in its place. The app's temporary files go to
the user's own temporary folder (NSTemporaryDirectory() or
-[NSFileManager tmpDirPath]). What may still name /tmp:
- a check that a path is in /tmp (databases and files left there by earlier
  versions): `hasPrefix:@"/tmp/"`;
- SourceLocation, which classifies where a file the user opens comes from;
- NSFileManager+N2's workaround for a /tmp that is a symbolic link;
- comments.

Checked in the sources. `<git revision>` as an optional argument reads them
from that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
FOLDERS = ('Horos/Sources', 'Nitrogen/Sources', 'DICOMPrint', 'DCM Framework', 'Preference Panes')
ALLOWED = {
    'Horos/Sources/SourceLocation.swift': [r'resolved\("/tmp"\)'],
    'Nitrogen/Sources/NSFileManager+N2.swift': [r'isEqual\(to: "/tmp"\)', r'NSLog\("/tmp issue workaround"\)'],
}


def files():
    if revision:
        listed = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '-r', '--name-only', revision, *FOLDERS], text=True).split('\n')
    else:
        listed = subprocess.check_output(['git', '-C', str(root), 'ls-files', *FOLDERS], text=True).split('\n')
    return [p for p in listed if p.endswith(('.m', '.mm', '.swift', '.c', '.cpp'))]


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def code(text):
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return [re.sub(r'(?<!:)//.*', '', line) for line in text.split('\n')]


failures = []
for path in files():
    for number, line in enumerate(code(read(path)), 1):
        if '"/tmp' not in line:
            continue
        line = re.sub(r'hasPrefix: ?@"/tmp/"', '', line)
        for allowed in ALLOWED.get(path, []):
            line = re.sub(allowed, '', line)
        if '"/tmp' in line:
            failures.append(f'{path}:{number}: {line.strip()[:120]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    print(f'FAIL: {len(failures)} uses of /tmp')
    sys.exit(1)
print('PASS: no fixed name in /tmp; temporary files go to the user\'s own folder')
