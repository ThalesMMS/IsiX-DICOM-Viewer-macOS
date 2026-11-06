#!/usr/bin/env python3
"""ROI > Create Points Between Two Points reaches the viewer's command.

Where the points go is IsiXROI's (ROIPointsBetween), tested in the module
(`swift test --package-path Modules --filter ROIPointsBetweenTests`). This
checks what the module cannot see: the item is in the ROI menu of the main
menu with its action, sent to the main menu's ViewerStudyCommands object,
whose validation offers it only with exactly two point ROIs, the command adds
its ROIs from the module's placements as one undo step and announces each,
outside the ViewerController hub, and the file is compiled by the app's
target.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
failures = []
ACTION = 'createPointsBetweenTwoPoints:'
TITLE = 'Create Points Between Two Points'
COMMANDS_OBJECT = 'Vsc-cm-Obj'

menu = ET.parse(root / 'Horos/Resources/en.lproj/MainMenu.xib').getroot()
roi_menu = next((m for m in menu.iter('menu') if m.get('id') == '1400'), None)
if roi_menu is None or roi_menu.get('title') != 'ROI':
    failures.append('the ROI menu (id 1400) is missing from MainMenu.xib')
else:
    items = [item for item in roi_menu.findall('items/menuItem') if item.get('title') == TITLE]
    if len(items) != 1:
        failures.append(f'the ROI menu has {len(items)} items titled {TITLE!r}, not one')
    elif [(a.get('selector'), a.get('target')) for a in items[0].iter('action')] != [(ACTION, COMMANDS_OBJECT)]:
        failures.append(f'{TITLE!r} does not send {ACTION} to the ViewerStudyCommands object')
objects = [o for o in menu.iter('customObject') if o.get('customClass') == 'IsiXViewerStudyCommands']
if [o.get('id') for o in objects] != [COMMANDS_OBJECT]:
    failures.append('MainMenu.xib does not make one ViewerStudyCommands object')

commands = (root / 'Horos/Sources/ViewerStudyCommands.swift').read_text()
if '@objc(createPointsBetweenTwoPoints:)' not in commands or 'ViewerPointsBetween.add(in: viewer)' not in commands:
    failures.append('ViewerStudyCommands does not hand the command to ViewerPointsBetween')
validate = commands[commands.index('func validateMenuItem(_ item: NSMenuItem) -> Bool'):]
validate = validate[:validate.index('\n    }\n')]
case = 'case #selector(createPointsBetweenTwoPoints(_:)):'
if case not in validate:
    failures.append('ViewerStudyCommands does not validate the command')
else:
    start = validate.index(case)
    end = validate.find('\n        case ', start + len(case))
    block = validate[start:end if end != -1 else validate.index('\n        default:', start)]
    if 'StudyViewers.databaseViewer()' not in block or 'ViewerPointsBetween.points(of: viewer).count == 2' not in block:
        failures.append('the command is not offered on exactly two point ROIs')

command = (root / 'Horos/Sources/ViewerPointsBetween.swift').read_text()
if re.search(r'^\s*(?:public |internal )?extension ViewerController\b', command, re.M):
    failures.append('ViewerPointsBetween.swift extends the ViewerController hub')
for needed in ('ROIPointsBetween.placements(', 'add(toUndoQueue: "roi")',
               'ROIEventEmitter.added(', 'ROIEventEmitter.changed(', 'endpoints.count == 2', '.t2DPoint'):
    if needed not in command:
        failures.append(f'the command no longer has {needed}')
if 'PointsToLine' in command or 'PointsToLine' in commands:
    failures.append('the command takes a name of the plugin it replaces, which may still be loaded')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if project.count('ViewerPointsBetween.swift in Sources') != 2 or 'path = ViewerPointsBetween.swift;' not in project:
    failures.append('ViewerPointsBetween.swift is not in the Sources phase of the app')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: ROI > Create Points Between Two Points is wired to ViewerStudyCommands, validated on two point ROIs')
