#!/usr/bin/env python3
""""Add local path" of Settings > Locations lets a folder be chosen in the sandbox, and keeps the access to it.

The open panel was told that folders can be chosen and then which type of file
it takes, the index of a database. A panel given its types of file stops
taking folders, whatever it was told before (on macOS 27.2,
canChooseDirectories reads false after allowedContentTypes is set): Open
stayed off on every folder, in the sandboxed build and out of it, and a folder
is what the action wants. In the sandbox a folder that had been chosen would
also have been lost at the next launch: the action did not keep the access
the panel gave, as every other chooser of a database folder does.

What the panel is asked in each channel and the folder a choice stands for are
IsiXStorage's LocalDatabasePathChoice, with its tests in Modules/IsiXStorage/Tests.
This reads how the pane uses it. What must stay true:

- the sandboxed build asks as the sandbox, and only that build;
- the panel is given what the choice says, a type only when it names one, and
  the types before it is told that folders can be chosen;
- the folder comes from the choice, over the path the panel gave;
- the access to what the panel gave is kept (SandboxFileAccess.remember, with
  the URL of the panel itself, which carries the grant) before the entry is
  added, and no entry is added when it could not be kept.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ''


pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()
check(re.search(r'^import IsiXStorage$', pane, re.M) is not None, 'the pane does not import IsiXStorage')
add = re.sub(r'//[^\n]*', '', body(pane, '@IBAction public func addPath(_ sender: Any?)'))
check(add, 'addPath not found')

channel = re.search(r'#if MACAPPSTORE\s*let choice = LocalDatabasePathChoice\(sandboxed: (\w+)\)\s*#else\s*'
                    r'let choice = LocalDatabasePathChoice\(sandboxed: (\w+)\)\s*#endif', add)
check(channel is not None and channel.groups() == ('true', 'false'),
      'the sandboxed build does not ask as the sandbox, or the other build does')

check('oPanel.canChooseFiles = choice.canChooseFiles' in add and 'oPanel.canChooseDirectories = choice.canChooseDirectories' in add,
      'the panel is not given what the choice says of files and folders')
check(add.count('allowedContentTypes') == 1, 'the panel is told of a type more than once, or never')
typed = body(add, 'if !choice.fileExtensions.isEmpty')
check('oPanel.allowedContentTypes = choice.fileExtensions.compactMap { UTType(filenameExtension: $0) }' in typed,
      'the panel is told of a type where the choice names none')
check(0 < add.find('oPanel.allowedContentTypes =') < add.find('oPanel.canChooseDirectories ='),
      'the panel is told of its types after it was told that folders can be chosen: it then takes no folder')
check('"sql"' not in add, 'the type of the index file is written in the pane, apart from the choice')

check('if let chosen = oPanel.url' in add, 'the action no longer reads the URL the panel gave')
check('choice.folder(forChosenPath: chosen.path, isDirectory: chosenIsDirectory.boolValue' in add
      and 'isDataDirectoryName: { DatabaseLocation.isDataDirectoryName($0) }' in add,
      'the folder does not come from the choice, over what the panel gave')
condition = re.search(r'if let location, ([^{]*)\{', add)
check(condition is not None and condition.group(1).rstrip().endswith('SandboxFileAccess.remember(chosen)'),
      'an entry is added without the access the panel gave being kept')
kept, added = add.find('SandboxFileAccess.remember(chosen)'), add.find('self.localPaths?.addObject(dict)')
check(0 < kept < added, 'the access is not kept before the entry is added')
check(add.count('self.localPaths?.addObject(') == 1, 'an entry is added in more than one place')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print('ok: "Add local path" asks the sandbox for a folder and names no type of file there, gives the panel its types before '
      'saying that folders can be chosen, takes the folder the choice gives, and keeps the access the panel gave before it adds the entry')
