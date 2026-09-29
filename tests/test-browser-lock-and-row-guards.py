#!/usr/bin/env python3
"""The browser unlocks before an exception goes on, reads no row -1, and keeps its export columns in place (#851).

Three defects of BrowserController kept by its translation to Swift (#831):

1. -relatedStudiesForStudy: locked the database's context and
   -isUsingExternalViewer: the database, and an exception raised before the
   unlock went on with them locked, which stalls every thread that locks them
   next. Now what runs locked goes through objcTry, the lock is released, and
   the exception is raised again, as the callers saw it before.
2. -doubleClickComparativeStudy: and the comparative table's tool tip called
   -objectAtIndex: with row -1 (a click or a pointer outside the rows), which
   raised NSRangeException. Now a row outside the studies reads nothing.
3. -exportDBListOnlySelected: counted the column and wrote its tab inside the
   objcTry of the column, so a column that raised shifted the next ones under
   the wrong header, and read their formatter from the wrong column. Now the
   count and the tab come after the objcTry.

Checked in the sources, since the methods need the browser, its database and
its outline around them. `<git revision>` as an optional argument reads the
sources of that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def code(text):
    """Without line comments and string contents, so that neither is taken for code."""
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    return '\n'.join(line.split('//')[0].rstrip() for line in text.split('\n'))


def closing(text, opening):
    """The index of the brace that closes the one at `opening`."""
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return index
    return -1


def method(path, selector):
    text = code(read(path))
    at = text.find('@objc(%s)' % selector)
    if at < 0:
        failures.append('%s no longer implements -%s; this test needs a new look' % (path, selector))
        return ''
    opening = text.index('{', at)
    return text[opening:closing(text, opening) + 1]


def statements(text):
    return [line.strip() for line in text.split('\n') if line.strip()]


# 1. Unlocked before an exception goes on.
LOCKED = (
    ('Horos/Sources/BrowserController+Plugins.swift', 'relatedStudiesForStudy:', 'context?'),
    ('Horos/Sources/BrowserController+DatabaseDragExport.swift', 'isUsingExternalViewer:', 'self.database?'),
)
for path, selector, lock in LOCKED:
    body = method(path, selector)
    if not body:
        continue
    at = body.find(lock + '.lock()')
    if at < 0:
        failures.append('-%s no longer locks %s; this test needs a new look' % (selector, lock))
        continue
    after = body[at + len(lock + '.lock()'):]
    guarded = re.search(r'let (\w+) = objcTry \{', after)
    before = statements(after[:guarded.start()] if guarded else after)
    if not guarded or any(not re.fullmatch(r'var \w+: [\w.]+\? = nil', line) for line in before):
        failures.append('-%s runs %r with %s locked, outside an objcTry' % (selector, (before or ['?'])[0], lock))
        continue
    end = closing(after, after.index('{', guarded.start()))
    rest = statements(after[end + 1:])
    expected = [lock + '.unlock()', 'if let %s { %s.raise() }' % (guarded.group(1), guarded.group(1))]
    if rest[:2] != expected:
        failures.append('-%s does not unlock %s and then raise the exception again: %r' % (selector, lock, rest[:2]))

# 2. No row -1.
path = 'Horos/Sources/BrowserController+AlbumsTableView.swift'
tip = method(path, 'tableView:toolTipForCell:rect:tableColumn:row:mouseLocation:')
if tip and not re.search(r'row >= 0\b.*row < \w+\.count', tip):
    failures.append('the comparative table\'s tool tip reads its studies at a row it does not bound, -1 outside the rows')
double = method(path, 'doubleClickComparativeStudy:')
if double:
    if 'object(at: horos_comparativeTable?.selectedRow' in double:
        failures.append('-doubleClickComparativeStudy: reads its studies at the selected row, -1 when none is')
    elif not re.search(r'row >= 0 && row < \(?\w+\??\.count', double):
        failures.append('-doubleClickComparativeStudy: does not bound the selected row by the studies')

# 3. The export's columns stay in place.
export = method('Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift', 'exportDBListOnlySelected:')
if export:
    tries = [m.start() for m in re.finditer(r'objcTry\(\{', export)]
    if len(tries) != 2:
        failures.append('-exportDBListOnlySelected: has %d objcTry, not the header\'s and the column\'s; '
                        'this test needs a new look' % len(tries))
    for number, start in enumerate(tries, 1):
        closure = export[start:closing(export, export.index('{', start)) + 1]
        if 'i += 1' in closure or 'string.append("")' in closure:
            failures.append('-exportDBListOnlySelected: counts the column or writes its tab inside objcTry #%d, '
                            'so a column that raises shifts the next ones' % number)
    if export.count('i += 1') != 2:
        failures.append('-exportDBListOnlySelected: counts its columns %d times, not once in each loop'
                        % export.count('i += 1'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the browser unlocks before an exception goes on, bounds the comparative rows, '
      'and keeps its export columns in place')
