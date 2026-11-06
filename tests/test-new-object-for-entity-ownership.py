#!/usr/bin/env python3
"""-[N2ManagedDatabase newObjectForEntity:] answers an autoreleased object.

Its name puts it in the new family, so a Swift or ARC caller takes a +1 over
unless the declaration says otherwise; the object was then released once too
often, and creating an album from Swift could crash. The declaration carries
NS_RETURNS_NOT_RETAINED for as long as the implementation autoreleases.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
header = (root / 'Nitrogen/Sources/N2ManagedDatabase.h').read_text()
# Implemented in Objective-C: a Swift implementation would return it retained.
source = (root / 'Nitrogen/Sources/N2ManagedDatabase+CAPI.m').read_text()
failures = []

declaration = re.search(r'-\s*\(id\)\s*newObjectForEntity:\(id\)\w+([^;]*);', header)
if not declaration:
    failures.append('-newObjectForEntity: is no longer declared')
body = re.search(r'-\(id\)newObjectForEntity:\(id\)\w+\s*\{(.*?)\n\}', source, re.S)
if not body:
    failures.append('-newObjectForEntity: is no longer implemented')
if declaration and body and 'autorelease]' in body.group(1) \
        and 'NS_RETURNS_NOT_RETAINED' not in declaration.group(1):
    failures.append('-newObjectForEntity: autoreleases its object but is declared in the new '
                    'family: Swift and ARC callers release it once too often')
# N2ManagedDatabase is otherwise Swift; a Swift -newObjectForEntity: returns its
# object retained (+1) whatever the declaration says, which callers would leak.
for swift in sorted((root / 'Nitrogen/Sources').glob('N2Managed*.swift')):
    if re.search(r'func\s+newObject\s*\(\s*forEntity', swift.read_text()):
        failures.append('%s implements -newObjectForEntity: in Swift, which returns it retained' % swift.name)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: -newObjectForEntity: is declared as returning an object it does not retain')
