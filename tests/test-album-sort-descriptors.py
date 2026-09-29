#!/usr/bin/env python3
"""Reselecting the same album does not load its sort descriptors again (#850).

Source level, with `<git revision>` as an optional argument for the negative
control (run against 56c91e586, before the fix, it must fail).

-saveLoadAlbumsSortDescriptors of BrowserController (Swift since #831) keeps
the selected album as an identifier: the album's objectID, or an empty
dictionary for the Database row. It returned early when the selected album was
the same as before, but it compared the album itself with that identifier,
which never matched, so the outline's sort descriptors and columns were loaded
again on every call. The comparison now uses the identifier computed the same
way as the one stored, and it happens after the previous album's descriptors
are saved, as before.

The selected row is read from the albums only when it is inside them (#872):
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
PATH = 'Horos/Sources/BrowserController+AlbumsTableView.swift'


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
body = block(source, source.find('@objc(saveLoadAlbumsSortDescriptors)'))
failures = []

if not body:
    failures.append('no -saveLoadAlbumsSortDescriptors in %s' % PATH)
else:
    if re.search(r'\(selectedAlbum as\? \w+\)\??\.isEqual\(previousSelectedAlbumId\)'
                 r'|[^(]selectedAlbum\??\.isEqual\(previousSelectedAlbumId\)', body):
        failures.append('the selected album itself is still compared with the stored identifier')
    compared = re.search(r'(\w+)\(selectedAlbum\)\??\.isEqual\(previousSelectedAlbumId\)', body)
    stored = re.search(r'previousSelectedAlbumId = (\w+)\(selectedAlbum\)', body)
    if not compared:
        failures.append('the selected album is not compared by identifier')
    elif not stored or stored.group(1) != compared.group(1):
        failures.append('the compared identifier is not computed as the stored one')
    helper = block(body, body.find('func %s(' % compared.group(1))) if compared else ''
    if helper and ('.objectID' not in helper or 'NSDictionary()' not in helper):
        failures.append('the identifier is no longer the objectID, or an empty dictionary for the Database row')
    access = body.find('albums?.object(at: selection)')
    guard = re.search(r'if selection >= 0 && selection < \(?albums\??\.count(?: \?\? 0\))? \{', body)
    if access < 0:
        failures.append('the selected album is no longer read from the albums at the selected row')
    elif not guard or guard.end() > access or body.find('}', guard.end()) < access:
        failures.append('the selected row is read from the albums without checking it is inside them (#872)')
    save = body.find('self.saveSortDescriptors(self._album(withID: previousSelectedAlbumId))')
    early = body.find('return', body.find('.isEqual(previousSelectedAlbumId)'))
    if save < 0 or early < 0 or save > early:
        failures.append('the previous album\'s descriptors are no longer saved before the early return')

if failures:
    print('FAIL:\n  ' + '\n  '.join(failures))
    sys.exit(1)
print('PASS: the same album selected again keeps its sort descriptors without loading them again,'
      ' and a selected row past the albums is not read from them')
