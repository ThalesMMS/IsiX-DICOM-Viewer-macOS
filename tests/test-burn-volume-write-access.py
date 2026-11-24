#!/usr/bin/env python3
"""A volume the application may not write on is said before anything on it is touched.

Writing a medium to a USB volume empties the volume and then copies the files.
The emptying discarded its errors, so a volume the system kept from the
application (the privacy setting of removable volumes, or the App Sandbox for a
path no panel gave) went through the confirmation, the preparation of the files
and a copy that failed with the system's sentence about privileges, which says
nothing of where the permission is given.

The rule is VolumeWriteProbe of IsiXDatabase, held by its module test. This
test holds its use in the window, the description the system shows when it asks
for removable volumes, and that description in every language of the catalogs.
"""
from pathlib import Path
import json, plistlib, subprocess, sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

source = source_text('BurnerWindowController')
failures = []

# The copy: the probe empties the volume or answers why not, and nothing else removes from it.
copy = source[source.index('private static func copyToVolume('):source.index('public func renameVolume(to name')]
if 'VolumeWriteProbe.empty(' not in copy:
    failures.append('the volume is emptied without asking whether it takes a file')
elif copy.index('VolumeWriteProbe.empty(') > copy.index('copyItem(atPath: folder'):
    failures.append('the volume is asked after the copy started')
if 'removeItem(' in copy:
    failures.append('the copy to a volume removes from it by itself again')
if 'volumeRefusalMessage(refusal' not in copy:
    failures.append('a volume refused at the copy no longer says why')

# The start of a burn: asked before the user confirms that the volume is emptied.
burn = source[source.index('public func burn(_ sender: Any?)'):source.index('private func burnJob(')]
if 'self.volumeTakesFiles(volumePath) == false' not in burn:
    failures.append('a burn to a volume starts without asking whether the volume takes a file')
elif burn.index('self.volumeTakesFiles(volumePath)') > burn.index('The ENTIRE content of the selected media'):
    failures.append('the volume is asked after the user confirmed that it is emptied')

# What the user is told, and the way to the settings.
asked = source[source.index('private func volumeTakesFiles('):source.index('private static func copyToVolume(')]
message = source[source.index('private static func volumeRefusalMessage('):source.index('private func volumeTakesFiles(')]
if 'System Settings > Privacy & Security > Files & Folders' not in message:
    failures.append('a write the system did not permit no longer says where it is permitted')
if message.count('nothing on it was changed') < 5:
    failures.append('a refusal no longer says that the volume was left as it was')
if 'Open Privacy Settings' not in asked or 'NSWorkspace.shared.open(url)' not in asked:
    failures.append('the alert of a write the system did not permit no longer opens the privacy settings')
if 'x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders' not in source:
    failures.append('the privacy settings are no longer opened at Files & Folders')
# The App Sandbox gives a volume only through a panel, opened at the volume chosen.
if 'NSOpenPanel()' not in asked or 'panel.directoryURL = URL(fileURLWithPath: volumePath' not in asked:
    failures.append('a sandboxed application no longer asks for the volume in a panel')
elif asked.index('BurnerWindowController.isSandboxed') > asked.index('NSOpenPanel()'):
    failures.append('the panel for the volume is shown outside the App Sandbox')
if 'APP_SANDBOX_CONTAINER_ID' not in source:
    failures.append('the App Sandbox is no longer recognised when the application runs')

# The description the system shows when it asks for removable volumes.
key = 'NSRemovableVolumesUsageDescription'
with open(root / 'Horos/Info.plist', 'rb') as handle:
    description = plistlib.load(handle).get(key, '')
if 'USB' not in description or 'IsiX DICOM Viewer' not in description:
    failures.append('Info.plist does not say why the application uses removable volumes')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if 'InfoPlist.strings in Resources */,' not in project:
    failures.append('the localized descriptions are not copied into the application')
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    language = catalog.parent.name
    strings = catalog.with_name('InfoPlist.strings')
    if not strings.is_file():
        failures.append('%s has no InfoPlist.strings' % language)
        continue
    converted = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(strings)], capture_output=True, text=True)
    text = json.loads(converted.stdout).get(key, '') if converted.returncode == 0 else ''
    if 'IsiX DICOM Viewer' not in text or 'DICOM' not in text.replace('IsiX DICOM Viewer', ''):
        failures.append('%s does not say why the application uses removable volumes' % language)
    elif language != 'en.lproj' and text == description:
        failures.append('%s says it in English' % language)
    if 'Horos/Resources/%s/InfoPlist.strings' % language not in project:
        failures.append('%s/InfoPlist.strings is not in the project' % language)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('PASS: a volume is asked for a file before the confirmation and before it is emptied, a refusal says what to do, '
      'and the reason for removable volumes is in Info.plist and in every language')
