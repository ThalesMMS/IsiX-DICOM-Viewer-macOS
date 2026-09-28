#!/usr/bin/env python3
"""The Sources extension tolerates the outlets the nib has not connected yet (#722).

-[BrowserController initWithWindow:] sends -setDatabase:, which selects the
current source through -rowForDatabase: before the nib has connected the
sources array controller and the Sources table. The Objective-C category sent
its messages to nil and got 0; the first Swift translation unwrapped them
implicitly and the application stopped at launch ("Unexpectedly found nil").

This checks that BrowserController+Sources.swift and +Activity.swift reach the
array controller and the two tables only through optional chaining, and that
the private accessor header declares the tables nullable.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
failures = []

for name in ('BrowserController+Sources.swift', 'BrowserController+Activity.swift'):
    text = (sources / name).read_text(encoding='utf-8')
    lines = text.splitlines()
    for number, line in enumerate(lines, 1):
        code = line.split('//', 1)[0]
        use = re.search(r'([\w?.()]*)(?<![\w?])sources\.(arrangedObjects|addObject|removeObject|content)\b', code)
        owner = use.group(1).lstrip('(') if use else None
        if use and owner in ('', 'self.', '_browser?.', 'browser.', 'currentBrowser()?.'):
            # A local `sources` bound by `guard let` / `if let` is non-optional.
            window = '\n'.join(lines[max(0, number - 12):number])
            if not (owner == '' and re.search(r'(guard|if) let sources\b', window)):
                failures.append(f'{name}:{number} unwraps the sources array controller: {line.strip()}')
        if re.search(r'horos_(sources|activity)TableView\.', code):
            failures.append(f'{name}:{number} unwraps a table the nib may not have connected: {line.strip()}')

header = (sources / 'BrowserController+SwiftIvars.h').read_text(encoding='utf-8')
for table in ('horos_sourcesTableView', 'horos_activityTableView'):
    if not re.search(r'@property\s*\([^)]*nullable[^)]*\)\s*NSTableView\s*\*\s*%s' % table, header):
        failures.append(f'BrowserController+SwiftIvars.h does not declare {table} nullable')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('PASS: the Sources and Activity extensions reach the unconnected outlets through optional chaining')
