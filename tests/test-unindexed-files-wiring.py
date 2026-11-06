#!/usr/bin/env python3
"""File > Files & Maintenance > Find Unindexed Files... is wired to the search.

The rules (which files of the data folder are offered, which are left alone and
why, the paths the index has) are IsiXDatabase's UnindexedFileRules and
UnindexedFileSearch, tested over a disposable database with synthetic files by
`swift test --package-path Modules --filter UnindexedFileSearchTests`. Checked here:

* the menu item: in Files & Maintenance right before Rebuild Entire Database...,
  sent to the nib's DatabaseCommands object, without a shortcut, at the same
  place in every language's menu with the title its catalog gives, a real
  translation;
* the old Zombies plugin may still be installed: its name is not taken;
* the command: validated; the search runs on an Activity thread with its
  progress and Cancel, and asks before importing; the import goes through the
  single entry with the rebuild's options, holds the incoming import's lock,
  and checks every file again first;
* it lives in types of their own, not in a hub class, built into the app.
"""
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
sources = root / 'Horos/Sources'
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
TITLE = 'Find Unindexed Files…'
ACTION = 'findUnindexedFiles:'
failures = []


def selector(item):
    action = item.find('connections/action')
    return None if action is None else action.get('selector')


def placement(language):
    menu = ET.parse(resources / f'{language}.lproj/MainMenu.xib').getroot()
    for parent in menu.iter('menu'):
        children = parent.find('items')
        items = [child for child in (children if children is not None else []) if child.tag == 'menuItem']
        for index, item in enumerate(items):
            if selector(item) == ACTION:
                return item, [selector(each) for each in items], index, parent.get('id'), menu
    return None


english_id = None
for language in ('en',) + LANGUAGES:
    found = placement(language)
    if found is None:
        failures.append(f'{language}: no item sends {ACTION}')
        continue
    item, selectors, index, menu_id, menu = found
    commands = [obj.get('id') for obj in menu.iter('customObject') if obj.get('customClass') == 'IsiXDatabaseCommands']
    if len(commands) != 1 or item.find('connections/action').get('target') != commands[0]:
        failures.append(f'{language}: the item is not sent to the DatabaseCommands object')
    if menu_id != 'Fmt-gp-Mnu':
        failures.append(f'{language}: the item is not in Files & Maintenance')
    if index + 1 >= len(selectors) or selectors[index + 1] != 'ReBuildDatabaseSheet:':
        failures.append(f'{language}: the item is not right before Rebuild Entire Database...')
    if item.get('keyEquivalent'):
        failures.append(f'{language}: the item has the shortcut {item.get("keyEquivalent")!r}')
    if language == 'en':
        english_id = item.get('id')
        if item.get('title') != TITLE:
            failures.append(f'English: {item.get("title")!r}, expected {TITLE!r}')
        continue
    if item.get('id') != english_id:
        failures.append(f'{language}: the item is not the English one')
    strings = json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(resources / f'{language}.lproj/Localizable.strings')]))
    expected = strings.get(TITLE)
    if not expected or expected == TITLE:
        failures.append(f'{language}: no translation of {TITLE!r}')
    elif item.get('title') != expected:
        failures.append(f'{language}: title {item.get("title")!r}, the catalog says {expected!r}')

english_menu = (resources / 'en.lproj/MainMenu.xib').read_text(encoding='utf-8')
for identifier in ('Fui-db-Itm', 'Fui-db-Act', 'Dbc-cm-Obj"'):
    if english_menu.count(f'id="{identifier}') != 1:
        failures.append(f'the id {identifier} is not unique')

commands = (sources / 'DatabaseCommands.swift').read_text(encoding='utf-8')
command = (sources / 'UnindexedFileImport.swift').read_text(encoding='utf-8')
for name, source in (('DatabaseCommands', commands), ('UnindexedFileImport', command)):
    if 'Zombie' in source:
        failures.append(f'{name}.swift takes the name of the old Zombies plugin')
    if re.search(r'^\s*(?:public |internal |private |fileprivate )?extension (BrowserController|DicomDatabase|AppController)\b', source, re.M):
        failures.append(f'{name}.swift extends a hub class')
if 'Zombie' in english_menu:
    failures.append('the menu takes the name of the old Zombies plugin')
for source, needle, what in (
        (commands, '@objc(IsiXDatabaseCommands)', 'the command object is not exposed under its nib class'),
        (commands, f'@objc({ACTION})', 'the command is not implemented under its selector'),
        (commands, 'case #selector(findUnindexedFiles(_:)):', 'the command is not validated'),
        (command, 'ActivityThread.run(name:', 'the search does not run on an Activity thread'),
        (command, 'isCancelled: { thread.isCancelled }', 'cancelling does not stop the search'),
        (command, 'ActivityProgressCount.set(', 'the search shows no progress'),
        (command, 'HorosAlertPanel.runInformational(', 'the import is not asked for'),
        (command, 'importFilesFromIncomingDirLock', 'the import does not wait for the incoming import'),
        (command, 'search.stillUnindexed(', 'the files are not checked again before the import'),
        (command, 'ingest.indexOnOwnContext(still, preset: .rebuild,', 'the import does not go through the single entry'),
        (command, 'ingest.whileAdmitted', 'quitting does not know of the import'),
        (command, 'IndexRebuildsUnderWay.shared.isEmpty', 'the command is offered during a rebuild'),
):
    if needle not in source:
        failures.append(what)
for needle in ('removeItem', 'moveItem', 'trashItem'):
    if needle in command:
        failures.append(f'the command itself moves or deletes files ({needle})')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for name in ('DatabaseCommands.swift', 'UnindexedFileImport.swift'):
    if project.count(f'/* {name} in Sources */') != 2 or f'path = {name};' not in project:
        failures.append(f'{name} is not built into the app')
if not (root / 'Modules/IsiXDatabase/Sources/UnindexedFileSearch.swift').exists():
    failures.append('UnindexedFileSearch.swift is not in IsiXDatabase')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    raise SystemExit(1)
print(f'PASS: Find Unindexed Files is in Files & Maintenance before Rebuild Entire Database in English and {len(LANGUAGES)} languages, '
      'validated, searches on an Activity thread and imports through the single entry once asked')
