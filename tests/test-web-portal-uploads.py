#!/usr/bin/env python3
"""The web portal's uploads.

- An upload that fits in one chunk was never imported: -checkEOF:range: started
  its search at length - 4096 in unsigned arithmetic, which wrapped around for
  a shorter chunk, so the end was never found; then the chunk replaced the
  upload's file handle. The search starts at the file's data, or 4096 bytes
  from the end, whichever is later, and a chunk that began an upload is not
  kept as a form.
- Uploads went to /tmp under fixed names (WebPortal Upload N,
  osirixUnzippedFolder), which another user could put in place first; they go
  to the user's temporary folder, a folder of their own for each zip.
- What was not imported - an upload that is not DICOM, the unzipped folder -
  is removed, and the zip's __MACOSX folder and ._ files are skipped.

Checked in the sources. `<git revision>` as an optional argument reads them from
that revision, the negative control. The app itself is exercised by
a local validation script.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/WebPortalConnection.swift'
if revision:
    source = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
else:
    source = (root / path).read_text()
code = '\n'.join(line.split('//')[0] for line in source.split('\n'))


def block(start):
    at = code.find(start)
    if at < 0:
        return ''
    opening = code.index('{', at)
    depth = 0
    for index in range(opening, len(code)):
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        if depth == 0:
            return code[opening:index + 1]
    return ''


failures = []
eof = block('public func checkEOF(')
if not re.search(r'max\(r\.pointee\.location,\s*Int\(length\)\s*-\s*CHECKLASTPART\)', eof):
    failures.append('checkEOF does not start at the file data or 4096 bytes from the end, in signed arithmetic')
if 'UInt(bitPattern: Int(x)) < length' in eof:
    failures.append('checkEOF still compares an unsigned start that wraps around for a short chunk')

if not re.search(r'chunkLength < 4096 && !startedUpload', code):
    failures.append('a chunk that began an upload still replaces its file handle')

if re.search(r'"/tmp/?(osirixUnzippedFolder)?"', block('public func closeFileHandleAndClean()') + block('private func createUploadFile(')):
    failures.append('uploads still go to fixed names in /tmp')
clean = block('public func closeFileHandleAndClean()')
if 'pathComponents.contains("__MACOSX")' not in clean or 'hasPrefix("._")' not in clean:
    failures.append('the zip\'s __MACOSX folder and ._ files are still imported')
if not re.search(r'if let name = POSTfilename \{\s*try\? FileManager\.default\.removeItem\(atPath: name\)', clean.split('multipartData = nil')[0][-400:]):
    failures.append('an upload that is not imported is left behind')
if 'closeFile()' not in clean:
    failures.append('the upload\'s file handle is not closed')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: short uploads end and are imported; uploads stay in the user\'s temporary folder and leave nothing behind; Finder metadata is skipped')
