#!/usr/bin/env python3
"""No open panel is told that folders can be chosen before it is given its types of file.

A panel given its types of file stops taking folders, whatever it was told
before: on macOS 27.2, canChooseDirectories reads false after
allowedContentTypes (or the former allowedFileTypes) is set to types that do
not include the folder. Its Open button then stays off on every folder. Said
in the other order, the choice of folders holds: "Add a local path" of
Settings > Locations and the panel of the JPEG to DICOM plugin, which both
want a folder, could choose none.

This reads every Swift source of the application, its preference panes, its
frameworks and its plugins. For each receiver that is told folders can be
chosen, no later line of the same function gives that receiver its types,
unless the folder is one of them. A later branch of a conditional compilation
is another build, and is not read as later.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
FOLDERS = ('Horos/Sources', 'Preference Panes', 'Nitrogen/Sources', 'Plugins', 'IsiXPluginKit', 'DICOMPrint', 'Examples')
CHOOSES = re.compile(r'^\s*(\w+)\??\.canChooseDirectories\s*=(?!\s*false\b)')
failures = []
panels = 0


def after_types(lines, start, receiver):
    """The line, after `start` and before the function ends, that gives `receiver` its types without the folder."""
    types = re.compile(r'^\s*%s\??\.(allowedContentTypes|allowedFileTypes)\s*=(.*)' % re.escape(receiver))
    depth = 0
    for index in range(start + 1, len(lines)):
        code = re.sub(r'//.*', '', lines[index])
        found = types.match(code)
        if found and '.folder' not in found.group(2) and '.directory' not in found.group(2):
            return index
        depth += code.count('{') - code.count('}')
        # Past the function, or in another branch of a conditional compilation: another build.
        if depth < 0 or code.strip() in ('#else', '#endif') or code.strip().startswith('#elseif'):
            return None
    return None


for folder in FOLDERS:
    for path in sorted((root / folder).rglob('*.swift')):
        if '.build' in path.parts or 'Tests' in path.parts:
            continue
        lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
        for index, line in enumerate(lines):
            found = CHOOSES.match(re.sub(r'//.*', '', line))
            if not found:
                continue
            panels += 1
            late = after_types(lines, index, found.group(1))
            if late is not None:
                failures.append('%s:%d: %s is told that folders can be chosen, and given its types after that, at line %d: it then takes no folder'
                                % (path.relative_to(root), index + 1, found.group(1), late + 1))

# The scan must see the two panels it was written for, and refuse the order they had.
for known in ('Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift',
              'Plugins/Pilots/JPEGToDICOM/Sources/JPEGToDICOMPlugin.swift'):
    text = (root / known).read_text()
    if not re.search(r'\.canChooseDirectories\s*=', text) or not re.search(r'\.allowedContentTypes\s*=', text):
        failures.append('%s no longer sets up the panel this test was written for: revisit it' % known)
former = ['func choose() {', '    let panel = NSOpenPanel()', '    panel.canChooseDirectories = true', '    panel.allowsMultipleSelection = true',
          '    panel.allowedContentTypes = [.image]', '}']
if after_types(former, 2, 'panel') != 4:
    failures.append('the scan accepts the order that takes no folder')
if after_types(former[:2] + [former[4], former[2], former[3], former[5]], 3, 'panel') is not None:
    failures.append('the scan refuses the types given before the folders')
if after_types(former[:4] + ['    panel.allowedContentTypes = [.image, .folder]', '}'], 2, 'panel') is not None:
    failures.append('the scan refuses types that include the folder')
if after_types(former[:4] + ['#else', '    panel.allowedContentTypes = [.image]', '#endif', '}'], 2, 'panel') is not None:
    failures.append('the scan reads the other branch of a conditional compilation as later')
if CHOOSES.match('    panel.canChooseDirectories = false') or not CHOOSES.match('    panel.canChooseDirectories = choice.canChooseDirectories'):
    failures.append('the scan does not tell a panel that takes folders from one that is told it takes none')
if after_types(former[:4] + ['}', 'func other() {', '    panel.allowedContentTypes = [.image]', '}'], 2, 'panel') is not None:
    failures.append('the scan reads past the end of the function')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: %d panels are told that folders can be chosen, none of them before its types of file' % panels)
