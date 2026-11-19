#!/usr/bin/env python3
"""The tables two windows build in code keep the columns the user left, and fit the window they open in.

The ROI manager and the Modality Worklist window build their lists in code. A
table reads the widths and the order saved for its columns when it is given
its autosave name, and only for the columns it has then: the outline of the
ROI manager was named before it had any, so it saved the layout at every
change and showed the widths of the code again at every opening. A table made
in code also has 17 points between its columns where a table of a nib has 3,
and both lists were wider than the window they open in: 801 points in a view
of 569, 1108 in one of 950.

In the source of each window:

- the last column is added before the table is named, and the table is told
  to save its columns after it is named;
- the columns are fitted to their headers (PaneFit.fitColumns) after that, so
  a saved width never leaves a header cut in the running language;
- the table has the spacing of a nib's, 3 by 2 points, and the worklist, whose
  last column gives room while the list enters its bordered scroll view, lets
  that column take the room of the list once it is there;
- the window of the ROI manager, which its nib holds at 800 points at the
  most, is freed of that limit: a saved frame came back cut to 800 points, and
  the window could not be made as wide as its list;
- the window opens, with no saved frame, at the width that shows every column
  of the English list: the test adds the widths of the columns in the source,
  their spacing and the margins AppKit gives the list, and what stands beside
  the list in the window.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SPACING = 3

# Per window: its source; the line that adds the last column; the name, the save and the fit of the table; the
# widths of its columns as the source has them; what the list has around its columns (the margins of its style:
# 29 points with no border, 9 with one) and what stands beside it in the window; the default width of the content.
WINDOWS = {
    'ROI manager': {
        'source': 'Horos/Sources/ROIManagerController.swift',
        'last': 'let c = column(check.rawValue, title, 64, cell: cell)',
        'named': 'outline.autosaveName = "ROIManagerOutline"',
        'saved': 'outline.autosaveTableColumns = true',
        'fitted': 'PaneFit.fitColumns(of: outline)',
        'spaced': 'outline.intercellSpacing = NSSize(width: 3, height: 2)',
        # The swatch, the name, the slice, the count, the measure and the three states.
        'widths': re.compile(r'column\("color", "", (\d+)|let name = column\("name", [^\n]*?, (\d+)\)|column\("slice", [^\n]*?, (\d+)\)'
                             r'|column\("count", "#", (\d+)\)|column\("measure", [^\n]*?, (\d+)\)'),
        'repeated': (re.compile(r'column\(check\.rawValue, title, (\d+),'), 3),
        'columns': 8,
        # The margins of a list with no border, then the divider and the inspector, 250 points wide as it opens.
        'around': 29 + 1 + 250,
        'default': re.compile(r'window\.setContentSize\(NSSize\(width: (\d+), height: 460\)\)'),
        # The nib holds its window at 800 points at the most: the window is freed before it is given a size or
        # a saved frame.
        'freed': 'window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)',
    },
    'Modality Worklist': {
        'source': 'Horos/Sources/ModalityWorklistWindowController.swift',
        'last': 'table.addTableColumn(tableColumn)',
        'named': 'table.autosaveName = "IsiXModalityWorklistTable"',
        'saved': 'table.autosaveTableColumns = true',
        'fitted': 'PaneFit.fitColumns(of: table)',
        'spaced': 'table.intercellSpacing = NSSize(width: 3, height: 2)',
        'widths': None,
        'columns': 9,
        # The list is in its scroll view, and has the margins of a bordered list, before its last column is fitted.
        'refit': ('content.addSubview(view)', 'table.sizeLastColumnToFit()'),
        # The margins of a bordered list, its border, and the 14 points the window leaves on each side.
        'around': 9 + 2 + 28,
        'default': re.compile(r'NSWindow\(contentRect: NSRect\(x: 0, y: 0, width: (\d+), height: 460\)'),
    },
}


def worklist_widths(text):
    """The widths of the nine columns of the worklist, from `var width` of its Column."""
    body = text[text.find('var width: CGFloat {'):]
    body = body[:body.find('\n        }\n')]
    widths = []
    for cases, width in re.findall(r'case ([^:\n]+): return (\d+)', body):
        widths += [int(width)] * len(cases.split(','))
    return widths


failures = []
for name, window in WINDOWS.items():
    text = (ROOT / window['source']).read_text(encoding='utf-8')
    places = {key: text.find(window[key]) for key in ('last', 'named', 'saved', 'fitted', 'spaced')}
    missing = [key for key, place in places.items() if place < 0]
    if missing:
        failures.append(f'{name}: {window["source"]} no longer holds {", ".join(repr(window[key]) for key in missing)}')
        continue
    if text.count(window['named']) != 1:
        failures.append(f'{name}: the table is named more than once')
    if not places['last'] < places['named']:
        failures.append(f'{name}: the table is given its autosave name before its last column is added, and reads no saved layout')
    if not places['named'] < places['saved']:
        failures.append(f'{name}: the table is told to save its columns before it is named')
    if not places['saved'] < places['fitted']:
        failures.append(f'{name}: the columns are fitted to their headers before the saved widths are read')
    if 'freed' in window and not 0 <= text.find(window['freed']) < (window['default'].search(text) or re.search('$', text)).start():
        failures.append(f'{name}: the window keeps the greatest size of its nib, less than the width its list needs')
    if 'refit' in window:
        placed, refit = (text.find(part) for part in window['refit'])
        if refit < 0 or not 0 <= placed < refit:
            failures.append(f'{name}: the last column no longer takes the room of the list once the list is in its scroll view')
    if window['widths'] is None:
        widths = worklist_widths(text)
    else:
        widths = [int(next(group for group in match if group)) for match in window['widths'].findall(text)]
        repeated, times = window['repeated']
        widths += [int(width) for width in repeated.findall(text)] * times
    if len(widths) != window['columns']:
        failures.append(f'{name}: {len(widths)} column widths were read in the source, the list has {window["columns"]}')
        continue
    default = window['default'].search(text)
    if not default:
        failures.append(f'{name}: the default width of the window was not found in the source')
        continue
    needed = sum(widths) + SPACING * len(widths) + window['around']
    if int(default.group(1)) < needed:
        failures.append(f'{name}: the window opens {default.group(1)} points wide, and its list needs {needed} to show its '
                        f'{len(widths)} columns ({sum(widths)} points) without scrolling')
    elif int(default.group(1)) > needed + 12:
        failures.append(f'{name}: the window opens {default.group(1)} points wide, more than the {needed} its list needs')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: the lists of {len(WINDOWS)} windows built in code read their saved columns, fit them to their headers '
      f'and open in a window that shows every column')
