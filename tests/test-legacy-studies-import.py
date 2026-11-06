#!/usr/bin/env python3
"""File > Import > Import Studies from Horos or OsiriX…

The studies of the data folder an earlier application left come into the
database that is open. What reads that folder (LegacyDatabase, in IsiXStorage)
is tested in its module: found by name, read without changing a byte, the
notes only filling what is empty. This checks what stands around it in the
application:

* the command is in the Import submenu of every language's File menu, with
  its title from the catalog, aimed at the database commands' object, which
  enables it only for a local database that can be written;
* the files go through the import of dropped files, copied or indexed where
  they are as the dialog's button says, never asked a second time, on a thread
  of the Activity list;
* the albums are made before the files arrive, since a study's own
  annotations only put it in albums that exist, and the comments and states
  wait for each study to be added;
* nothing writes into the earlier folder.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
TITLE = 'Import Studies from Horos or OsiriX…'
SELECTOR = 'importStudiesFromEarlierApplication:'
failures = []


def need(text, fragments, where):
    for fragment, what in fragments:
        if fragment not in text:
            failures.append(f'{where}: {what} ({fragment!r} not found)')


def catalog(language):
    path = root / 'Horos/Resources' / f'{language}.lproj' / 'Localizable.strings'
    return plistlib.loads(subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(path)]))


# The menu, in every language.
menus = sorted((root / 'Horos/Resources').glob('*.lproj/MainMenu.xib'))
if len(menus) < 12:
    failures.append(f'{len(menus)} main menus')
for path in menus:
    language = path.parent.stem
    tree = ET.parse(path).getroot()
    parents = {child: parent for parent in tree.iter() for child in parent}
    actions = [node for node in tree.iter('action') if node.get('selector') == SELECTOR]
    if len(actions) != 1:
        failures.append(f'{language}: {len(actions)} menu items send {SELECTOR}')
        continue
    item = parents[parents[actions[0]]]
    target = next((node for node in tree.iter('customObject') if node.get('id') == actions[0].get('target')), None)
    if target is None or target.get('customClass') != 'IsiXDatabaseStudyCommands':
        failures.append(f'{language}: the command is not aimed at the database commands')
    expected = TITLE if language == 'en' else catalog(language).get(TITLE)
    if item.get('title') != expected:
        failures.append(f'{language}: the item is titled {item.get("title")!r}, the catalog says {expected!r}')
    if language != 'en' and expected == TITLE:
        failures.append(f'{language}: the title is not translated')
    siblings = list(parents[item])
    if not any(node.get('selector') == 'selectFilesAndFoldersToAdd:' for sibling in siblings for node in sibling.iter('action')):
        failures.append(f'{language}: the command is not in the Import submenu')
    if siblings[siblings.index(item) - 1].get('isSeparatorItem') != 'YES':
        failures.append(f'{language}: the command is not set apart from the file imports')

commands = (root / 'Horos/Sources/DatabaseStudyCommands.swift').read_text()
need(commands, [
    ('@IBAction @objc(importStudiesFromEarlierApplication:)', 'the action of the menu item'),
    ('LegacyStudiesImport.shared.run(in: browser)', 'the command runs the import'),
    ('case #selector(importStudiesFromEarlierApplication(_:)):\n            return LegacyStudiesImport.canImport(into: browser)', 'the item is validated'),
    ('@objc(importStudiesFromFolderAtPath:copying:)', 'the command without its dialog'),
], 'DatabaseStudyCommands.swift')

source = (root / 'Horos/Sources/LegacyStudiesImport.swift').read_text()
need(source, [
    ('return database.isLocal() && !database.isReadOnly', 'only a local database that can be written takes the studies'),
    ('LegacyDatabase.found(inDocuments: $0)', 'the folders are looked for in the documents folder'),
    ('folders.removeAll { Self.isSame($0, as: openFolder) }', 'the open database is not offered to itself'),
    ('SandboxFileAccess.remember(url)', 'a chosen folder keeps its access'),
    ('"COPYDATABASE": NSNumber(value: choice == .copy)', 'the button decides between copying and indexing in place'),
    ('"COPYDATABASEMODE": NSNumber(value: DatabaseCopyRule.always)', 'the copy is not asked a second time'),
    ('"async": NSNumber(value: true)', 'the import runs on a thread of the Activity list'),
    ('browser.droppedFiles.importFiles(survey.files.paths, options: [', 'the files go through the import of dropped files'),
    ('name: .OsirixAddToDB', 'the notes wait for the studies to be added'),
    ('notes.notesMissing(comments: current', 'the notes only fill what is empty'),
    ('setButtons(copy: fits, link: true)', 'copying is refused without room for it'),
    ('database.files(linked: contents.linkedFiles, isCancelled: { Task.isCancelled })', 'the folder is read off the main thread, and stops when another is chosen'),
], 'LegacyStudiesImport.swift')
prepare = source[source.index('private func prepareNotes('):]
prepare = prepare[:prepare.index('\n    }\n')]
if not prepare.index('createAlbums(') < prepare.index('applyNotes(to: nil)'):
    failures.append('the albums are not made before the notes are applied')
run = source[source.index('func run(in browser: BrowserController) {'):]
run = run[:run.index('\n    }\n')]
if not run.index('prepareNotes(') < run.index('importFiles('):
    failures.append('the albums are not made before the files are imported')

# Nothing here or in the reader writes, moves or removes.
reader = (root / 'Modules/IsiXStorage/Sources/LegacyDatabase.swift').read_text()
for name, text in (('LegacyStudiesImport.swift', source), ('LegacyDatabase.swift', reader)):
    for call in re.findall(r'\b(removeItem|moveItem|copyItem|createDirectory|createFile|write\(to|SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE)\b', text):
        failures.append(f'{name} calls {call}')
need(reader, [('SQLITE_OPEN_READONLY | SQLITE_OPEN_URI', 'the database is opened read-only'), ('"?immutable=1"', 'and as immutable when nothing has it open')],
     'LegacyDatabase.swift')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('ok: the command is in the Import submenu of %d languages, imports through the dropped-files path and only reads the earlier folder' % len(menus))
