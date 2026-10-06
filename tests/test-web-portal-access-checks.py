#!/usr/bin/env python3
"""Access checks of the web portal's data handlers.

In WebPortalConnection (Data), Objective-C or Swift:
- changing a password needs the current password's hash: a request without
  sha1 used to pass, because [nil compare:] is NSOrderedSame;
- a federated XID opens only a database the federated search includes, never
  the arbitrary path the request encodes, and images reached through it are
  access-checked like studies and series;
- the screen capture renders the image whose XID it is given: it used to read
  the request's xid again, which can name a series, and the exception it
  raised on the main thread ended the application.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path, source_text  # noqa: E402

name = 'WebPortalConnection+Data'
path = source_path(name)
text = source_text(name)
swift = path.suffix == '.swift'
failures = []


def body(pattern):
    match = re.search(pattern, text)
    if not match:
        failures.append(f'{path.name}: nothing matches {pattern!r}')
        return ''
    opening = text.index('{', match.end() - 1 if text[match.end() - 1] == '{' else match.end())
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    return ''


# 1. Password change.
change = text[text.find('changePassword'):]
change = change[:change.find('changeSettings')]
if not re.search(r'\[sha1 length\]\s*>\s*0|\bsha1\.length\s*>\s*0|\bsha1(\?)?\.isEmpty\s*==\s*false|!\s*\(?sha1\b[^\n]*\.isEmpty', change):
    failures.append('changePassword does not require a non-empty sha1 before comparing it')

# 2. Federated XIDs.
xid = body(r'objectWithXID' + (r'\([^)]*\)[^{]*\{' if swift else r':\(NSString\*\)xid\s*\{'))
federated = xid[:xid.find('POD:')] if 'POD:' in xid else xid
if not re.search(r'isPath', federated) or not re.search(r'localDatabasePaths', federated):
    failures.append('objectWithXID opens a federated origin without checking it is an included source')
if federated.find('isPath') > federated.find('databaseAtPath') >= 0:
    failures.append('objectWithXID opens the federated database before checking its origin')
if not re.search(r'DicomImage', federated):
    failures.append('objectWithXID does not check access to images reached through a federated XID')

# 3. Screen capture.
capture = body(r'saveImageAsScreenCapture' + (r'\([^)]*\)[^{]*\{' if swift else r':\s*\(NSString\*\)\s*XID\s*\{'))
if re.search(r'objectWithXID[:(]\s*\[?\s*parameters', capture) or 'parameters' in capture.split('objectWithXID', 1)[-1][:80]:
    failures.append('saveImageAsScreenCapture reads the request xid instead of the XID it is given')
if not re.search(r'isKindOfClass[:(]\s*\[?DicomImage|as\?\s*DicomImage', capture):
    failures.append('saveImageAsScreenCapture does not check it was given an image')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print(f'PASS: {path.name} checks the current password, federated origins and image access, and captures the image it is given')
