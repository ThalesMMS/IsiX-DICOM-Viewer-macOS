#!/usr/bin/env python3
"""The series that keeps an empty study is named in one place.

Its name and number are SelectionImages.noAutodeletionName and noAutodeletionID,
in IsiXDatabase's StudyListRules.swift, and every other source asks those or
SelectionImages.isNoAutodeletionSeries. IsiXLegacyBridge is the exception: it is
Objective-C for plug-ins, and cannot reach the application's internal modules.

`<git revision>` as an optional argument reads the sources of that revision, the
negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
OWNER = 'Modules/IsiXDatabase/Sources/StudyListRules.swift'
SCOPE = ('Horos', 'Modules', 'Nitrogen')
LITERAL = re.compile(r'OsiriX No Autodeletion|\b5005\b')
# The anonymization tables hold DICOM tags, not this number.
UNRELATED = ('Catalog.h',)

command = ['git', '-C', str(root), 'grep', '-n', '-I', '-E', r'OsiriX No Autodeletion|\b5005\b']
if revision:
    command.append(revision)
else:
    command.append('--untracked')
command += ['--', *SCOPE]
output = subprocess.run(command, capture_output=True).stdout.decode('utf-8', 'replace')

hits = []
for line in output.splitlines():
    fields = line.split(':', 3 if revision else 2)
    path, text = fields[1 if revision else 0], fields[-1]
    if path == OWNER or path.endswith(UNRELATED) or '/Tests/' in path or not path.endswith(('.swift', '.m', '.mm')):
        continue
    if LITERAL.search(text):
        hits.append(line)

if hits:
    print('FAIL: the series that keeps an empty study is written out of StudyListRules:')
    print('\n'.join(hits))
    sys.exit(1)
print('PASS: the name and number of the series that keeps an empty study are in StudyListRules only')
