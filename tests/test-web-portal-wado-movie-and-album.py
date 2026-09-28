#!/usr/bin/env python3
"""The portal's WADO movies and unknown albums (#761).

- A WADO video/mpeg request has no xid, so every series wrote its movie to the
  same "(null)-WADOMpeg-<frames>" file; and the characters a file name cannot
  hold were removed from the whole path, slashes included, so the movie landed
  in the process's working directory. The name is now the series and the size
  asked for, and only the name is cleaned before it joins the portal's
  temporary folder.
- /studyList and /studyList.json with an album the database does not have
  failed with a 500; they answer 404, before building the list.

Checked in the sources. `<git revision>` as an optional argument reads them from
that revision, the negative control. The app itself is exercised by
local-validation/issue-761/movies.py.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/WebPortalConnection+Data.swift'
if revision:
    source = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
else:
    source = (root / path).read_text()
code = '\n'.join(line.split('//')[0] for line in source.split('\n'))


def block(text, start, end):
    at = text.find(start)
    return text[at:text.find(end, at)] if at >= 0 else ''


failures = []
wado = block(code, 'objcIsEqualToString(contentType, "video/mpeg")', 'self.generateMovie(dict)')
if not wado:
    failures.append('the WADO video/mpeg branch is not where it was')
else:
    if 'parameter("xid")' in wado:
        failures.append('the WADO movie is still named after the xid, which a WADO request does not have')
    if not re.search(r'WADOMpeg-%d-%dx%d', wado):
        failures.append('the WADO movie name does not carry the size asked for')
    clean = re.search(r'objcReplaceNotAdmitted\((\w+)\)', wado)
    joined = re.search(r'appendingPathComponent\((\w+) as String\)', wado)
    if not clean or not joined or clean.group(1) != joined.group(1) or clean.start() > joined.start():
        failures.append('the WADO movie path is cleaned as a whole, not only its name')

for route in ('processStudyListHtml()', 'processStudyListJson()'):
    body = block(code, f'func {route}', 'studyList_requestedStudies(')
    if 'studyList_requestsUnknownAlbum()' not in body or 'setStatusCode(404)' not in body:
        failures.append(f'{route} does not answer 404 for an unknown album before listing')
check = block(code, 'func studyList_requestsUnknownAlbum', '\n    }\n')
if check and 'as AnyObject).value(forKey:' in check:
    failures.append('the album check reads names through AnyObject, whose double optional never casts to String')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: WADO movies are named per series and size inside the portal folder; unknown albums answer 404')
