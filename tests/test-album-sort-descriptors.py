#!/usr/bin/env python3
"""Reselecting the same album does not load its sort descriptors again.

Source level, with `<git revision>` as an optional argument for the negative
control (run against 56c91e586, before the fix, it must fail).

-saveLoadAlbumsSortDescriptors of BrowserController forwards to
StudyListContent.saveLoadSortDescriptors(), which keeps the album shown as a
layout key: the album's objectID, or the database for the Database row. It
returned early when the selected album was the same as before, but it once
compared the album itself with the stored identifier, which never matched, so
the outline's sort descriptors and columns were loaded again on every call. The
comparison uses the key computed the same way as the one stored, and it happens
after the previous album's layout is saved, as before.

The selected row is read from the albums only when it is inside them:
a table not yet reloaded after the albums changed can select a row past their
end, and -objectAtIndex: raised there. Such a row is taken as no selection.

A behavioural probe would need BrowserController and a live album table; no
existing probe links them, so the structure is checked here.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/StudyListContent.swift'


def read(path):
    if len(sys.argv) > 1:
        result = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else ''
    return (root / path).read_text(encoding='utf-8')


def block(source, start):
    """From `start` to the brace that closes the first brace after it."""
    opening = source.find('{', start)
    if start < 0 or opening < 0:
        return ''
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    return ''


source = read(PATH)
body = block(source, source.find('func saveLoadSortDescriptors()'))
failures = []

if not body:
    failures.append('no saveLoadSortDescriptors() in %s' % PATH)
else:
    if re.search(r'[^(]selectedAlbum\??\s*==\s*shownLayout|\(selectedAlbum as\? \w+\)\??\s*==\s*shownLayout', body):
        failures.append('the selected album itself is still compared with the stored key')
    compared = re.search(r'(\w+)\(of: selectedAlbum\) == shownLayout', body)
    stored = re.search(r'shownLayout = [^\n]*?(\w+)\(of: selectedAlbum\)', body)
    if not compared:
        failures.append('the selected album is not compared by its key')
    elif not stored or stored.group(1) != compared.group(1):
        failures.append('the compared key is not computed as the stored one')
    helper = block(source, source.find('func %s(of' % compared.group(1))) if compared else ''
    if helper and ('.objectID' not in helper or '.database' not in helper):
        failures.append('the key is no longer the objectID, or the database for the Database row')
    access = body.find('albums[selection]')
    guard = re.search(r'if selection >= 0 && selection < albums\.count \{', body)
    if access < 0:
        failures.append('the selected album is no longer read from the albums at the selected row')
    elif not guard or guard.end() > access or body.find('}', guard.end()) < access:
        failures.append('the selected row is read from the albums without checking it is inside them')
    save = body.find('saveLayout(for: shownLayout)')
    early = body.find('return', body.find('== shownLayout'))
    if save < 0 or early < 0 or save > early:
        failures.append('the previous album\'s layout is no longer saved before the early return')

if failures:
    print('FAIL:\n  ' + '\n  '.join(failures))
    sys.exit(1)
print('PASS: the same album selected again keeps its sort descriptors without loading them again,'
      ' and a selected row past the albums is not read from them')
