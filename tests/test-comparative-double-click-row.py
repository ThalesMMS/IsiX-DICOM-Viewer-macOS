#!/usr/bin/env python3
"""A double click in the comparative studies opens the row clicked, not the one selected (#919).

-doubleClickComparativeStudy:, the double action of the browser's comparative
table, read the table's -selectedRow. With a row still selected, a double click
in the empty area below the rows opened (or retrieved) that row's study. It now
reads -clickedRow, which is -1 outside the rows, and a row outside the studies
opens nothing.

Checked in the source, since the method needs the browser, its database and its
tables around it. `<git revision>` as an optional argument reads the source of
that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/BrowserController+AlbumsTableView.swift'
SELECTOR = 'doubleClickComparativeStudy:'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def code(text):
    """Without line comments and string contents, so that neither is taken for code."""
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    return '\n'.join(line.split('//')[0].rstrip() for line in text.split('\n'))


def body(text, selector):
    at = text.find('@objc(%s)' % selector)
    if at < 0:
        return None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
    return None


failures = []
method = body(code(read(PATH)), SELECTOR)
if method is None:
    failures.append('%s no longer implements -%s; this test needs a new look' % (PATH, SELECTOR))
else:
    if 'selectedRow' in method:
        failures.append('-%s reads the selected row, which opens the selected study '
                        'after a double click outside the rows' % SELECTOR)
    row = re.search(r'let (\w+) = horos_comparativeTable\?\.clickedRow \?\? -1', method)
    if not row:
        failures.append('-%s does not read the clicked row of the comparative table, -1 without one' % SELECTOR)
    else:
        name = row.group(1)
        if not re.search(r'\b%s >= 0 && %s < \(?\w+\??\.count' % (name, name), method):
            failures.append('-%s does not bound the clicked row by the studies' % SELECTOR)
        reads = re.findall(r'object\(at: (\w+)\)', method)
        if reads != [name]:
            failures.append('-%s reads its studies at %r, not once at the clicked row' % (SELECTOR, reads))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a double click in the comparative studies opens the row clicked, and nothing outside the rows')
