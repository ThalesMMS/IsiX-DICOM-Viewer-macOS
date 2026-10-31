#!/usr/bin/env python3
"""Importing by link stays available, and asking still asks.

`-[BrowserController copyFilesIntoDatabaseIfNeeded:options:]` decides between
copying a file into the database folder and indexing it where it lies.
`COPYDATABASE` says whether to copy at all; `COPYDATABASEMODE` says when.

Measured against a mounted HFS+ volume, importing one instance through the
AppleScript entry, with the preferences written into the application's own domain
rather than passed as arguments - so that reading them back afterwards says
whether they persisted:

    COPYDATABASE=1 MODE=0 (always)   1 image, inDatabaseFolder set,
                                     1 file in the database folder
    COPYDATABASE=0 (links)           1 image at /Volumes/HOROS78/DICOM/...,
                                     0 files in the database folder
    COPYDATABASE=1 MODE=3 (ask)      the main thread in NSRunInformationalAlertPanel
                                     -> runModalForWindow:, 0 images until answered

and every mode read back unchanged afterwards. Switching from "always" back to
"ask" on a database that already holds a study brings the panel back and leaves
the study where it was.

Mode 1 is migrated to 2 on purpose: the "if on CD" choice was taken out of the
preference pane, whose matrix offers tags 0, 2 and 3.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text

failures = []
# The decision is IsiXDatabase's DatabaseCopyRule; the browser's import asks
# the user and copies or links (DroppedFilesImport.swift).
importing = (root / 'Horos/Sources/DroppedFilesImport.swift').read_text()
rule = (root / 'Modules/IsiXDatabase/Sources/ImportRules.swift').read_text()
# The migration of the mode is a step of the launch in IsiXPreferences'
# LaunchPreferenceMigrations, which ApplicationPreferencesSetup takes.
migrations = source_text('LaunchPreferenceMigrations')
setup = source_text('ApplicationPreferencesSetup')
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return re.sub(r'//[^\n]*', '', source[opening:index + 1])
        index += 1
    return ''


region = body(importing, 'func importFiles(')
decision = body(rule, 'public static func decision(copyEnabled:')
if not region or not decision:
    failures.append('the choice between copying and linking is gone')
else:
    if 'COPYDATABASE' not in region or 'copyEnabled: copyEnabled' not in region:
        failures.append('nothing reads the preference that turns copying off')
    if 'always = 0, cdOnly = 1, notMainDrive = 2, ask = 3' not in rule:
        failures.append('the modes of COPYDATABASEMODE changed their values')
    for mode in ('cdOnly', 'notMainDrive', 'ask'):
        if 'case %s:' % mode not in decision:
            failures.append('the %s mode is gone' % mode)
    if not re.search(r'default:\s*return \.copy', decision):
        failures.append('the always mode is gone')
    ask = region[region.find('case .askUser:'):]
    if 'HorosAlertPanel.runInformational(' not in ask:
        failures.append('asking the user no longer asks')
    for answer in ('Copy Files', 'Copy Links', 'Cancel'):
        if answer not in ask:
            failures.append('the panel no longer offers %r' % answer)
    if 'return false' not in ask:
        failures.append('cancelling no longer stops the import')
    # The selector plugins send still empties the array it was given.
    facade = body((root / 'Horos/Sources/BrowserController+DatabaseImport.swift').read_text(),
                  'func copyFilesIntoDatabaseIfNeeded(')
    if 'droppedFiles.importFiles(' not in facade or 'removeAllObjects' not in facade:
        failures.append('a cancelled import no longer empties the files given to -copyFilesIntoDatabaseIfNeeded:options:')

    # A file whose path has no second component would be read out of bounds.
    drive = decision[decision.find('case notMainDrive:'):decision.find('case cdOnly:')]
    if 'components.count > 1' not in drive:
        failures.append('a path with nothing after its root is read out of bounds')

    # Links must not copy: the copy is the only thing that may write bytes.
    if 'if copyFiles {' not in region:
        failures.append('the copy is no longer conditional')

# The removed mode is migrated on purpose, and the pane offers the three that are
# left.
if 'if store[DatabasePreferences.copyToDatabaseMode] == 1 {\n            store.set(2, for: DatabasePreferences.copyToDatabaseMode)' \
        not in migrations or 'LaunchPreferenceMigrations.migrateCopyToDatabaseMode(in: preferences)' not in setup:
    failures.append('a stored value for the mode that was taken out of the pane is no longer '
                    'migrated, so it would select nothing')
if 'COPYDATABASEMODE' not in defaults:
    failures.append('the mode has no registered default')
for pane in root.glob('Preference Panes/OSIDatabasePreferencePane/*.lproj/'
                      'OSIDatabasePreferencePanePref.xib'):
    text = pane.read_text(encoding='utf-8', errors='replace')
    if 'values.COPYDATABASEMODE' not in text:
        failures.append('%s no longer offers the choice' % pane.parent.name)
    if 'values.COPYDATABASE' not in text:
        failures.append('%s no longer offers copying by link' % pane.parent.name)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: copying, linking and asking are all still offered, and a path with no second component '
      'is not read out of bounds')
