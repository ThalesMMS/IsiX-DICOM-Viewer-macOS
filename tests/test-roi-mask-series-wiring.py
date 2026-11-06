#!/usr/bin/env python3
"""ROI > ROI Volume > Generate Mask Series.

The command opens a new viewer with a binary mask of the series: 1 inside the
ROIs named like the selected one, through the images of the time point shown,
0 elsewhere, with the series' geometry, and shows the volume of the mask (its
voxels times the volume of a voxel) beside Compute Volume's. The volume rules
are tested in IsiXROI (ROIMaskVolumeTests) and against the app's Compute
Volume geometry in tests/test-roi-mask-volume-agreement.py. Checked here:

* the menu item: Generate Mask Series right after Compute Volume... in the ROI
  Volume submenu of the ROI menu, sent to the nib's ROIMaskSeriesCommands
  object, whose class is the Swift one under its Objective-C name, without a
  shortcut; every language's menu has it at the same place with the title its
  catalog gives, a real translation;
* the old VoxelVolume plugin may still be installed: its menu title and its
  class name are not taken;
* the command: implemented under its selector and enabled only with a 2D
  viewer whose selected ROI has an area; it selects the ROIs as Compute Volume
  does (same name, valid for a volume), fills each into a zeroed copy of its
  image with the fill Set Pixels runs, counts the voxels with the module's
  rule, copies the volume as -copyViewerWindow does, opens the viewer with
  +newWindow::: and asks Compute Volume for its volume of the same ROIs;
* the command lives in a type of its own, not in the hub classes, and its
  file is built into the app.
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
OBJC_CLASS = 'IsiXROIMaskSeriesCommands'
TITLE, ACTION, MENU, PREVIOUS = 'Generate Mask Series', 'generateROIMaskSeries:', 'ROI Volume', 'roiVolume:'
OLD_PLUGIN_TITLE, OLD_PLUGIN_NAME = 'VoxelVolume', 'VoxelVolume'
failures = []


def catalog(language):
    return json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(resources / f'{language}.lproj/Localizable.strings')]))


def selector(item):
    action = item.find('connections/action')
    return None if action is None else action.get('selector')


def nib(language):
    return ET.parse(resources / f'{language}.lproj/MainMenu.xib').getroot()


def placement(menu):
    """(menu, the item, the item before it) for each item that sends ACTION."""
    found = []
    for parent in menu.iter('menu'):
        children = parent.find('items')
        items = [child for child in (children if children is not None else []) if child.tag == 'menuItem']
        for index, item in enumerate(items):
            if selector(item) == ACTION:
                found.append((parent, item, items[index - 1] if index else None))
    return found


def target_object(menu):
    objects = [obj for obj in menu.iter('customObject') if obj.get('customClass') == OBJC_CLASS]
    return objects[0].get('id') if len(objects) == 1 else None


english = nib('en')
target = target_object(english)
if target is None:
    failures.append(f'MainMenu.xib does not make one {OBJC_CLASS} object')
english_ids = None
found = placement(english)
if len(found) != 1:
    failures.append(f'English main menu: {len(found)} items send {ACTION}, expected one')
else:
    parent, item, before = found[0]
    english_ids = (parent.get('id'), item.get('id'))
    if item.get('title') != TITLE:
        failures.append(f'English title {item.get("title")!r}, expected {TITLE!r}')
    if item.get('title') == OLD_PLUGIN_TITLE:
        failures.append('the item takes the old plugin\'s menu title')
    if parent.get('title') != MENU:
        failures.append(f'in the {parent.get("title")!r} menu, expected {MENU!r}')
    if before is None or selector(before) != PREVIOUS or before.get('title') != 'Compute Volume...':
        failures.append(f'follows {None if before is None else before.get("title")!r}, expected Compute Volume...')
    if target is not None and item.find('connections/action').get('target') != target:
        failures.append(f'target {item.find("connections/action").get("target")!r}, expected the {OBJC_CLASS} object')
    if item.get('keyEquivalent'):
        failures.append(f'has the shortcut {item.get("keyEquivalent")!r}; the item has none')
    roi_menus = [menu for menu in english.iter('menu') if menu.get('title') == 'ROI'
                 and any(sub is parent for sub in menu.iter('menu'))]
    if not roi_menus:
        failures.append('the ROI Volume submenu that holds the item is not in the ROI menu')

for language in LANGUAGES:
    strings = catalog(language)
    menu = nib(language)
    if target_object(menu) != target:
        failures.append(f'{language}: the menu does not make the {OBJC_CLASS} object of the English menu')
    found = placement(menu)
    if len(found) != 1:
        failures.append(f'{language}: {len(found)} items send {ACTION}')
        continue
    parent, item, before = found[0]
    if (parent.get('id'), item.get('id')) != english_ids:
        failures.append(f'{language}: the item is not where the English menu has it')
    if before is None or selector(before) != PREVIOUS:
        failures.append(f'{language}: the item does not follow Compute Volume...')
    expected = strings.get(TITLE)
    if not expected or expected == TITLE:
        failures.append(f'{language}: no translation of {TITLE!r} in its catalog')
    elif item.get('title') != expected:
        failures.append(f'{language}: title {item.get("title")!r}, catalog says {expected!r}')
    if item.get('keyEquivalent'):
        failures.append(f'{language}: the item has a shortcut')

# --- the command --------------------------------------------------------------
command = source_text('ROIMaskSeries')
for needle, what in (
        (f'@objc({OBJC_CLASS})', f'the menu object is not the Swift class under the name {OBJC_CLASS}'),
        ('NSMenuItemValidation', 'the menu object does not validate its item'),
        (f'@objc({ACTION})', 'the command is not implemented under its selector'),
        ('StudyViewers.active2DViewer()', 'the command does not act on the active 2D viewer'),
        ('viewerIsEqualToString($0.name, name) && $0.isValidForVolume()', 'the ROIs are not chosen as Compute Volume chooses them'),
        ('ViewerVolumeData.copy(movieIndex: movie, of: viewer)', 'the pixels are not copied as -copyViewerWindow copies them'),
        ('memset(pixels, 0,', 'the copies are not zeroed before the ROIs are filled'),
        ('pix.fillROI(roi, newVal: 1,', 'the ROIs are not filled with 1 by the Set Pixels fill'),
        ('outside: false', 'the fill does not set the inside'),
        ('ROIMaskVolume.voxelCount(', 'the voxels are not counted by the module rule'),
        ('ROIMaskVolume(voxelCount:', 'the volume is not the module\'s'),
        ('ROIMaskVolume.sliceInterval(', 'the slice interval is not the module\'s'),
        ('ViewerController.newWindow(copied.pixels,', 'the mask does not open in a new viewer of the copies'),
        ('viewer.computeVolume(selected, points: nil, error: &failure)', 'Compute Volume of the same ROIs is not shown beside it'),
        ('ROIMaskVolumeAgreement.endsMm3(', 'the part of the ends is not shown'),
        ('opened.setPostprocessed(true)', 'the mask viewer is not marked as computed'),
):
    if needle not in command:
        failures.append(what)

validate = command[command.index('func validateMenuItem(_ item: NSMenuItem) -> Bool'):]
validate = validate[:validate.index('\n    }\n')]
for rule in ('StudyViewers.active2DViewer()', 'viewer.selectedROI()', 'roi.isValidForVolume()'):
    if rule not in validate:
        failures.append(f'the item is not enabled only with a 2D viewer whose selected ROI has an area ({rule})')

if re.search(r'^\s*(?:public |internal |private |fileprivate )?extension (ViewerController|AppController|DCMView|BrowserController)\b',
             command, re.M):
    failures.append('ROIMaskSeries.swift extends a hub class; the command goes to a type of its own')

app_sources = ''.join(path.read_text(errors='replace') for path in (root / 'Horos/Sources').glob('*.swift'))
if re.search(rf'@objc\({OLD_PLUGIN_NAME}\w*\)|class {OLD_PLUGIN_NAME}\w*', app_sources):
    failures.append(f'the app takes a class name of the old {OLD_PLUGIN_NAME} plugin')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
if project.count('/* ROIMaskSeries.swift in Sources */') != 2 or 'path = ROIMaskSeries.swift;' not in project:
    failures.append('ROIMaskSeries.swift is not built into the app')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    raise SystemExit(1)
print(f'PASS: Generate Mask Series follows Compute Volume... in the menus of English and {len(LANGUAGES)} languages, '
      'masks the ROIs Compute Volume measures with the Set Pixels fill, outside the hub classes, and clear of the old plugin\'s names')
