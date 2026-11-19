#!/usr/bin/env python3
"""The columns the study list shows are saved by identifier, and a preference
saved by the titles of the headers is still read in every language.

COLUMNSDATABASE kept the state of each column of the study list under the title
of its header, which is the language's: written with the German titles, it
named no column of the Spanish list, and the two columns Korean and Simplified
Chinese give one title had one state between them. The state is kept under the
identifier of the column, and a preference kept by title is read through the
titles every language gave the headers (StudyListColumnTitles, in
IsiXDatabase), whose rules IsiXDatabaseTests checks. What is checked here is
what those tests cannot see without the application's files:

- the identifiers of the columns are the same in every copy of the main nib,
  so what one language saves names the same columns in another;
- no two columns of a copy have the same title: the header and the item of
  the header's menu are all that tells the comments from the note;
- StudyListColumnTitles lists, for each column, the title its header had in
  each copy of the main nib when the titles stopped being saved: the last
  revision of the history that saved them (the tree's HEAD while the change is
  not committed). A title a header is given afterwards is never saved, and
  needs no entry;
- no title listed is the identifier of another column, since a key of the
  preference is taken as an identifier first, and only the titles known to
  have been shared by two columns are listed for two;
- the controller of the columns saves by identifier in both places that save,
  and reads through the rule that knows the titles.

    python3 tests/test-study-list-columns-saved-by-identifier.py

Exits 2 (skipped) when the history does not reach the revision that saved the
titles, a shallow clone.
"""
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = 'Horos/Sources/StudyListColumnController.swift'
TITLES = ROOT / 'Modules/IsiXDatabase/Sources/StudyListColumnTitles.swift'
SAVES = 'StudyListColumns.saved(identifiers:'
# The comments and the note, which Korean and Simplified Chinese gave one title.
SHARED = {'메모': {'comment', 'note'}, '备注': {'comment', 'note'}}
failures = []


def columns(xib):
    """{identifier: header title} of the study list in a main nib, in the order of its columns."""
    for outline in ET.fromstring(xib).iter('outlineView'):
        found = outline.find('tableColumns')
        identifiers = [column.get('identifier') for column in found] if found is not None else []
        if 'name' in identifiers and 'patientID' in identifiers:
            result = {}
            for column in found:
                header = column.find('tableHeaderCell')
                title = header.get('title') if header is not None else None
                if title is None and header is not None:
                    text = header.find("string[@key='title']")
                    title = text.text if text is not None else None
                result[column.get('identifier')] = title or ''
            return result
    return None


# The titles the module lists.
source = TITLES.read_text()
table = source[source.index('public static let former'):source.index('\n    ]\n')]
listed = {}
for identifier, titles in re.findall(r'^        "(\w+)": \[(.*?)\],$', table, re.M | re.S):
    listed[identifier] = set(re.findall(r'"([^"]*)"', titles))
if len(listed) < 26:
    sys.exit(f'FAIL: the titles of the columns were not read from {TITLES.name}: {sorted(listed)}')

# The copies of the main nib in the tree: the same columns in every language.
nibs = sorted((ROOT / 'Horos/Resources').glob('*.lproj/MainMenu.xib'))
if len(nibs) < 12:
    sys.exit(f'FAIL: {len(nibs)} copies of the main nib, and the application has 12 languages')
english = columns((ROOT / 'Horos/Resources/en.lproj/MainMenu.xib').read_bytes())
if not english:
    sys.exit('FAIL: the study list was not found in the English main nib')
for nib in nibs:
    found = columns(nib.read_bytes())
    if found is None or list(found) != list(english):
        failures.append(f'{nib.parent.name} does not have the columns of the English study list: {found and list(found)}')
        continue
    # Two columns with one title cannot be told apart in the list nor in the menu of its header.
    titled = {}
    for identifier, title in found.items():
        if title:
            titled.setdefault(title, []).append(identifier)
    for title, identifiers in titled.items():
        if len(identifiers) > 1:
            failures.append(f'{nib.parent.name} gives the title {title!r} to the columns {identifiers}')
if set(listed) != set(english):
    failures.append(f'titles are listed for {sorted(set(listed) ^ set(english))}, which are not the columns of the list')

# The titles the headers had in the last revision that saved them.
tree = (ROOT / CONTROLLER).read_text()
if SAVES not in tree:
    failures.append(f'{CONTROLLER} does not save the columns by identifier')
    reference = None
else:
    head = subprocess.run(['git', '-C', str(ROOT), 'show', 'HEAD:' + CONTROLLER], capture_output=True, text=True)
    if head.returncode == 0 and SAVES not in head.stdout:
        reference = 'HEAD'
    else:
        reference = history_reference.before_text_added(CONTROLLER, SAVES)
        if reference is None:
            print('skipped: needs the history that has the study list saving its columns by title')
            sys.exit(2)
checked = 0
if reference:
    paths = subprocess.run(['git', '-C', str(ROOT), 'ls-tree', '-r', '--name-only', reference, 'Horos/Resources'],
                           capture_output=True, text=True, check=True).stdout.split('\n')
    paths = [path for path in paths if path.endswith('.lproj/MainMenu.xib')]
    if len(paths) < 12:
        failures.append(f'{reference[:12]} has {len(paths)} copies of the main nib')
    for path in paths:
        language = path.split('/')[-2][:-len('.lproj')]
        for identifier, title in (columns(history_reference.show(reference, path)) or {}).items():
            checked += 1
            if title not in listed.get(identifier, ()):
                failures.append(f'{language}: the header {title!r} of {identifier} is not listed in {TITLES.name}')

# A key is an identifier before it is a title.
by_title = {}
for identifier, titles in listed.items():
    for title in titles:
        by_title.setdefault(title, set()).add(identifier)
for title, identifiers in sorted(by_title.items()):
    if title in listed and identifiers != {title}:
        failures.append(f'the title {title!r} of {sorted(identifiers)} is the identifier of another column')
    if len(identifiers) > 1 and SHARED.get(title) != identifiers:
        failures.append(f'the title {title!r} is listed for {sorted(identifiers)}')
for title, identifiers in SHARED.items():
    if by_title.get(title) != identifiers:
        failures.append(f'the title {title!r}, which {sorted(identifiers)} shared, is listed for {sorted(by_title.get(title, ()))}')

# The controller saves by identifier, and reads through the rule that knows the titles.
if tree.count(SAVES) != 2:
    failures.append(f'{CONTROLLER} saves the columns by identifier in {tree.count(SAVES)} places, and two save them')
if 'headerCell.stringValue }, states' in tree or 'map(\\.title), states' in tree:
    failures.append(f'{CONTROLLER} still saves the columns by the titles of their headers')
refresh = tree[tree.index('    func refresh() {'):]
if 'StudyListColumns.read(entries, identifiers: columns.map(\\.identifier.rawValue)' not in refresh:
    failures.append(f'{CONTROLLER} does not read the saved columns through StudyListColumns.read')
if 'if let byIdentifier = reading.byIdentifier {' not in refresh:
    failures.append(f'{CONTROLLER} does not store again by identifier a preference read by title')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'ok: {len(listed)} columns saved by identifier, the same in {len(nibs)} copies of the main nib; '
      f'{sum(len(titles) for titles in listed.values())} titles listed, among them the {checked} of {reference[:12]}')
