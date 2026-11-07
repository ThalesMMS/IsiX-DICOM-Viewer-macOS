#!/usr/bin/env python3
"""Network > Modality Worklist… and its settings in Settings > Locations are wired.

The query, the reading of the answers and the matching are tested against a
local worklist SCP by test-modality-worklist-query.py, and in the module
(`swift test --package-path Modules --filter ModalityWorklistTests`). This
checks what those cannot see:

- the item is in the Network menu right after "Query Selected Patient from
  Q&R Window...", sent to the worklist commands object of the nib, whose class
  is the Swift one that opens the window;
- Settings > Locations installs the Worklist column, bound to the nodes'
  "MWL" key, and the refresh popup, which writes the preference the window's
  timer reads;
- the window asks through the C-FIND the plugin API uses, with the node's
  entry and so its TLS settings, in the Modality Worklist model, and only reads
  the database;
- nothing takes a class, menu or preference name of the Worklists plugin it
  replaces, which may still be installed and loaded;
- the new files are compiled by the app's target.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
failures = []
TITLE = 'Modality Worklist…'
ACTION = 'showModalityWorklist:'
TARGET = 'Mwl-cm-Obj'
FILES = {
    'Horos/Sources/NetworkWorklistCommands.swift',
    'Horos/Sources/ModalityWorklistWindowController.swift',
    'Horos/Sources/ModalityWorklistService.swift',
    'Horos/Sources/CFindKeysCoding.swift',
    'Preference Panes/OSILocationsPreferencePane/ModalityWorklistSettings.swift',
}

# --- The menu item ----------------------------------------------------------
menu = ET.parse(root / 'Horos/Resources/en.lproj/MainMenu.xib').getroot()
network = next((m for m in menu.iter('menu') if m.get('id') == '13788'), None)
if network is None or network.get('title') != 'Network':
    failures.append('the Network menu (id 13788) is missing from MainMenu.xib')
else:
    items = network.findall('items/menuItem')
    actions = [[a.get('selector') for a in item.iter('action')] for item in items]
    if ['querySelectedStudy:'] not in actions:
        failures.append('the Network menu has no "Query Selected Patient from Q&R Window..."')
    else:
        following = items[actions.index(['querySelectedStudy:']) + 1]
        action = next(following.iter('action'), None)
        if following.get('title') != TITLE or action is None or action.get('selector') != ACTION:
            failures.append(f'the item after "Query Selected Patient" is {following.get("title")!r}, not {TITLE!r}')
        elif action.get('target') != TARGET:
            failures.append('the item is not sent to the worklist commands object of the nib')
command_object = next((o for o in menu.iter('customObject') if o.get('id') == TARGET), None)
if command_object is None or command_object.get('customClass') != 'IsiXNetworkWorklistCommands':
    failures.append('MainMenu.xib has no IsiXNetworkWorklistCommands object')

commands = (root / 'Horos/Sources/NetworkWorklistCommands.swift').read_text()
for needed in ('@objc(IsiXNetworkWorklistCommands)', '@objc(showModalityWorklist:)', 'ModalityWorklistWindowController.show()'):
    if needed not in commands:
        failures.append(f'NetworkWorklistCommands no longer has {needed}')

# --- Settings > Locations ----------------------------------------------------
pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()
if 'ModalityWorklistSettings.install(below: characterSetPopup, in: mainView, nodes: dicomNodes)' not in pane:
    failures.append('the Locations pane does not install the worklist settings')
settings = (root / 'Preference Panes/OSILocationsPreferencePane/ModalityWorklistSettings.swift').read_text()
for needed in ('"arrangedObjects." + DICOMNode.Key.modalityWorklist', '"arrangedObjects." + DICOMNode.Key.activated',
               'NetworkPreferences.modalityWorklistRefreshMinutes.name', 'ModalityWorklistRefresh.choices'):
    if needed not in settings:
        failures.append(f'the Locations settings no longer use {needed}')
node = (root / 'Modules/IsiXDICOMNetwork/Sources/DICOMNode.swift').read_text()
if 'public static let modalityWorklist = "MWL"' not in node:
    failures.append('a node no longer keeps its Worklist column under "MWL"')

# --- The window's query ------------------------------------------------------
window = (root / 'Horos/Sources/ModalityWorklistWindowController.swift').read_text()
for needed in ('NetworkPreferences.modalityWorklistRefreshMinutes', 'ModalityWorklistRefresh.interval(fromStored:',
               'ModalityWorklistService.refresh(filter:', 'ModalityWorklistService.matches(for:', '.OsirixAddToDBComplete'):
    if needed not in window:
        failures.append(f'the window no longer has {needed}')
service = (root / 'Horos/Sources/ModalityWorklistService.swift').read_text()
for needed in ('PluginCFind.run(entry: node.propertyList, abstractSyntax: ModalityWorklistQuery.abstractSyntax',
               'ModalityWorklistQuery.nodes(DICOMNodeService.store.dicomNodes())', 'CFindKeysCoding.identifier(for: keys)'):
    if needed not in service:
        failures.append(f'the worklist service no longer has {needed}')
if re.search(r'\.(save|setValue|delete|insertNewObject)\(', service):
    failures.append('the worklist service writes to the database; it must only read it')

# --- The plugin it replaces --------------------------------------------------
FORMER = ('WorklistsPlugin', 'WorklistsPreferencesController', 'WorklistImagesQueryNode', 'Temporarily disable Worklists refresh',
          '_Worklists_')
for path in FILES:
    text = (root / path).read_text()
    for name in FORMER:
        if name in text:
            failures.append(f'{path} takes the name {name} of the Worklists plugin')
titles = {item.get('title') for item in menu.iter('menuItem')}
if any(title and title.startswith('Worklists') for title in titles):
    failures.append('a menu item takes the Worklists plugin\'s title')

# --- The project ------------------------------------------------------------
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
phase = re.search(r'AB28B42C05B7921E00A9906C /\* Sources \*/ = \{.*?files = \((.*?)\);', project, re.S)
for path in FILES:
    name = Path(path).name
    if not phase or f'/* {name} in Sources */' not in phase.group(1):
        failures.append(f'{name} is not compiled by the app target')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: Network > Modality Worklist… opens the window, Settings > Locations sets its nodes and refresh, '
      'and the window asks through the plugin C-FIND in the worklist model without writing the database')
