#!/usr/bin/env python3
"""2D Viewer > Duplicate Series and Window > Close Viewers of This Study.

Duplicate Series opens a new viewer with a copy of the series, of its ROIs and
of its window level; Close Viewers of This Study closes the 2D, 3D and 4D
viewers of the active viewer's study and leaves the other studies' viewers
open. The rules (one copy per ROI shown on every image; which windows close,
3D first) are tested in the modules (ROISliceListCopyTests in IsiXROI,
StudyViewerClosingTests in IsiXImaging). Checked here:

* the menu items: Duplicate Series right after Revert series in the 2D Viewer
  menu, Close Viewers of This Study right after Close All Viewers in the
  Window menu, both sent to the nib's ViewerStudyCommands object, whose class
  is the Swift one under its Objective-C name; neither has a shortcut, and
  every language's menu has them at the same place with the title its catalog
  gives, a real translation;
* the old Duplicate and CloseThisStudy plugins may still be installed: neither
  their menu titles ("Duplicate", "Close Study") nor their principal classes
  (DuplicateFilter, CloseThisStudyFilter) are taken;
* the commands: each is implemented under its selector and validated so that
  it is enabled only with a viewer to act on; the duplicate copies the ROIs,
  the volume lengths and the window over -copyViewerWindow's copy of the
  pixels, and the closing asks the module rule which windows go and takes the
  3D and 4D windows in;
* the commands live in types of their own, not in the hub classes
  (ViewerController, AppController), and both files are built into the app.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
OBJC_CLASS = 'IsiXViewerStudyCommands'
COMMANDS = (
    # title, selector, menu, the item it follows
    ('Duplicate Series', 'duplicateSeriesInNewViewer:', '2D Viewer', 'revertSeries:'),
    ('Close Viewers of This Study', 'closeViewersOfThisStudy:', 'Window', 'closeAllViewers:'),
)
OLD_PLUGIN_TITLES = {'Duplicate', 'Close Study'}
OLD_PLUGIN_CLASSES = ('DuplicateFilter', 'CloseThisStudyFilter')
failures = []


def catalog(language):
    return json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(resources / f'{language}.lproj/Localizable.strings')]))


def selector(item):
    action = item.find('connections/action')
    return None if action is None else action.get('selector')


def nib(language):
    return ET.parse(resources / f'{language}.lproj/MainMenu.xib').getroot()


def placement(menu, wanted):
    """(menu, the item, the item before it) for each item that sends `wanted`."""
    found = []
    for parent in menu.iter('menu'):
        children = parent.find('items')
        items = [child for child in (children if children is not None else []) if child.tag == 'menuItem']
        for index, item in enumerate(items):
            if selector(item) == wanted:
                found.append((parent, item, items[index - 1] if index else None))
    return found


def target_object(menu):
    """The id of the nib object of class OBJC_CLASS, or None."""
    objects = [obj for obj in menu.iter('customObject') if obj.get('customClass') == OBJC_CLASS]
    return objects[0].get('id') if len(objects) == 1 else None


english = nib('en')
target = target_object(english)
if target is None:
    failures.append(f'MainMenu.xib does not make one {OBJC_CLASS} object')
english_ids = {}
for title, action, menu_title, previous in COMMANDS:
    found = placement(english, action)
    if len(found) != 1:
        failures.append(f'English main menu: {len(found)} items send {action}, expected one')
        continue
    parent, item, before = found[0]
    english_ids[action] = (parent.get('id'), item.get('id'))
    if item.get('title') != title:
        failures.append(f'{action}: English title {item.get("title")!r}, expected {title!r}')
    if title in OLD_PLUGIN_TITLES:
        failures.append(f'{action}: takes an old plugin\'s menu title')
    if parent.get('title') != menu_title:
        failures.append(f'{action}: in the {parent.get("title")!r} menu, expected {menu_title!r}')
    if before is None or selector(before) != previous:
        failures.append(f'{action}: follows {None if before is None else before.get("title")!r}, expected the item of {previous}')
    if target is not None and item.find('connections/action').get('target') != target:
        failures.append(f'{action}: target {item.find("connections/action").get("target")!r}, expected the {OBJC_CLASS} object')
    if item.get('keyEquivalent'):
        failures.append(f'{action}: has the shortcut {item.get("keyEquivalent")!r}; the item has none')

for language in LANGUAGES:
    strings = catalog(language)
    menu = nib(language)
    if target_object(menu) != target:
        failures.append(f'{language}: the menu does not make the {OBJC_CLASS} object of the English menu')
    for title, action, _, previous in COMMANDS:
        found = placement(menu, action)
        if len(found) != 1:
            failures.append(f'{language}: {len(found)} items send {action}')
            continue
        parent, item, before = found[0]
        if (parent.get('id'), item.get('id')) != english_ids.get(action):
            failures.append(f'{language}: {action} is not where the English menu has it')
        if before is None or selector(before) != previous:
            failures.append(f'{language}: {action} does not follow the item of {previous}')
        expected = strings.get(title)
        if not expected or expected == title:
            failures.append(f'{language}: no translation of {title!r} in its catalog')
        elif item.get('title') != expected:
            failures.append(f'{language}: title {item.get("title")!r}, catalog says {expected!r}')
        if item.get('keyEquivalent'):
            failures.append(f'{language}: {action} has a shortcut')

# --- the commands --------------------------------------------------------------
commands = source_text('ViewerStudyCommands')
duplicate = source_text('ViewerSeriesDuplicate')
for source, needle, what in (
        (commands, f'@objc({OBJC_CLASS})', f'the menu object is not the Swift class under the name {OBJC_CLASS}'),
        (commands, 'NSMenuItemValidation', 'the menu object does not validate its items'),
        (commands, '@objc(duplicateSeriesInNewViewer:)', 'Duplicate Series is not implemented under its selector'),
        (commands, '@objc(closeViewersOfThisStudy:)', 'Close Viewers of This Study is not implemented under its selector'),
        (commands, 'StudyViewerClosing.windowsToClose(', 'the closing does not ask the module rule'),
        (commands, 'controller is Window3DController', 'the closing leaves the 3D and 4D windows out'),
        (duplicate, 'horosDuplicatedViewerWindow()', 'the duplicate does not copy the pixels as -copyViewerWindow does'),
        (duplicate, 'ROISliceListCopy.copy(', 'the duplicate does not copy the ROIs one per ROI'),
        (duplicate, 'restoreVolumeLengthSnapshot(', 'the duplicate does not take the volume lengths'),
        (duplicate, 'setWLWW(level, width)', 'the duplicate does not take the window level'),
):
    if needle not in source:
        failures.append(what)

validate = commands[commands.index('func validateMenuItem(_ item: NSMenuItem) -> Bool'):]
validate = validate[:validate.index('\n    }\n')]
for case, rule, what in (
        ('case #selector(duplicateSeriesInNewViewer(_:)):', 'ViewerSeriesDuplicate(source: $0).isPossible } ?? false',
         'Duplicate Series is not enabled only with a 2D viewer that has a series'),
        ('case #selector(closeViewersOfThisStudy(_:)):', 'StudyViewers.activeViewer() != nil',
         'Close Viewers of This Study is not enabled only with a viewer'),
):
    if case not in validate:
        failures.append(what)
        continue
    body = validate[validate.index(case) + len(case):]
    body = body[:min(end for end in (body.find('\n        case '), body.find('\n        default:'), len(body)) if end >= 0)]
    if rule not in body:
        failures.append(what)

for name, source in (('ViewerStudyCommands', commands), ('ViewerSeriesDuplicate', duplicate)):
    if re.search(r'^\s*(?:public |internal |private |fileprivate )?extension (ViewerController|AppController)\b', source, re.M):
        failures.append(f'{name}.swift extends a hub class; the commands go to types of their own')

app_sources = ''.join(path.read_text(errors='replace') for path in (root / 'Horos/Sources').glob('*.swift'))
for name in OLD_PLUGIN_CLASSES:
    if f'@objc({name})' in app_sources or f'class {name}' in app_sources:
        failures.append(f'the app takes the class name {name} of an old plugin')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
for name in ('ViewerStudyCommands.swift', 'ViewerSeriesDuplicate.swift'):
    if project.count(f'/* {name} in Sources */') != 2 or f'path = {name};' not in project:
        failures.append(f'{name} is not built into the app')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    raise SystemExit(1)
print(f'PASS: Duplicate Series and Close Viewers of This Study are in the menus of English and {len(LANGUAGES)} languages, '
      'validated, outside the hub classes, and clear of the old plugins\' names')
