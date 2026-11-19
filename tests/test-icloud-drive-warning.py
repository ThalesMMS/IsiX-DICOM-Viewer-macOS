#!/usr/bin/env python3
"""The iCloud Drive warning asks in the user's language, and no key starts the move.

The confirmation is read from the source of the detector: its two texts and its
two buttons come from the catalogs, and Continue answers no key. Every catalog
is read for the two texts, with both folders in each translation. The nibs of
the warning are read for the two words that were misspelled in them.
"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
QUESTION = 'Stop synchronizing the IsiX DICOM Viewer database with iCloud Drive?'
MOVE = ('The database and its image files will be moved from “%@” to “%@”. '
        'IsiX DICOM Viewer restarts when the move is finished.')

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


detector = source_text('ICloudDriveDetector')
start = detector.index('private func moveConfirmation(from databasePath: String, to nosyncPath: String) -> NSAlert {')
confirmation = detector[start:detector.index('\n    }\n', start)]
check(f'alert.messageText = NSLocalizedString("{QUESTION}"' in confirmation, 'the question of the confirmation is not localized')
check(f'NSLocalizedString("{MOVE}"' in confirmation and 'databasePath, nosyncPath)' in confirmation,
      'the text that names both folders is not localized, or no longer names them in that order')
check('let proceed = alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))' in confirmation
      and 'alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))' in confirmation
      and confirmation.index('"Continue"') < confirmation.index('"Cancel"'),
      'the buttons of the confirmation are not Continue then Cancel, from the catalogs')
# The first button of an alert answers Return unless its key is taken away, and
# the button titled Cancel answers Escape unless it is made the default one.
check('proceed.keyEquivalent = ""' in confirmation, 'Return starts the move again')
check('defaultButtonCell' not in confirmation and 'cancel.keyEquivalent' not in confirmation, 'Escape may no longer answer Cancel')
check(not re.search(r'alert\.(messageText|informativeText) = "', detector) and not re.search(r'addButton\(withTitle: "', detector),
      'the detector shows a text that is not in the catalogs')
check('let alert = moveConfirmation(from: databasePath, to: nosyncPath)' in detector, 'the move is no longer confirmed by that question')

catalogs = sorted(RESOURCES.glob('*.lproj/Localizable.strings'))
check(len(catalogs) == 12, f'{len(catalogs)} catalogs instead of 12')
for catalog in catalogs:
    language = catalog.parent.name[:-len('.lproj')]
    # The binary form: a catalog holds characters an XML property list cannot.
    table = plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'binary1', '-o', '-', str(catalog)]))
    question, move = table.get(QUESTION), table.get(MOVE)
    check(bool(question), f'{language}: the question is missing')
    check(bool(move) and '%1$@' in move and '%2$@' in move and move.count('%') == 2,
          f'{language}: the text of the move does not name both folders once each')
    if language != 'en':
        check(question != QUESTION and move != MOVE.replace('%@', '%1$@', 1).replace('%@', '%2$@', 1), f'{language}: left in English')
    check(not [key for key in table if 'dabase' in key or 'Alternativelly' in key], f'{language}: a misspelled key')
    check(not [value for value in table.values() if 'dabase' in value], f'{language}: a translation with the misspelled word')

nibs = sorted(RESOURCES.glob('*.lproj/ICloudDriveDetector.xib'))
check(bool(nibs), 'no nib of the warning')
for nib in nibs:
    text = nib.read_text(encoding='utf-8')
    check('dabase' not in text and 'Alternativelly' not in text, f'{nib.parent.name}: a misspelled word in the warning')
english = (RESOURCES / 'en.lproj/ICloudDriveDetector.xib').read_text(encoding='utf-8')
check('Do you want IsiX DICOM Viewer to flag the database folder?' in english and 'Alternatively, IsiX DICOM Viewer can flag' in english,
      'the English warning lost its question or its second paragraph')
# Enter closes the warning without a decision; no button of it answers Return.
check(english.count('<string key="keyEquivalent"') == 1 and 'keyEquivalent="&#xD;"' not in english
      and english.index('<string key="keyEquivalent"') < english.index('selector="askLater:"') < english.index('selector="keepSync:"'),
      'a key of the warning answers something other than "Ask me later"')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the confirmation is localized in 12 catalogs, no key answers Continue, and the warning is spelled right')
