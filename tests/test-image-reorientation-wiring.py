#!/usr/bin/env python3
"""2D Viewer > Reorient All Images to Current Image is wired to a new viewer.

The rules (which images are resampled, the geometry they take, the parameters
of the resampling) are IsiXImaging's ImagePlaneReorientation, tested by
`swift test --package-path Modules --filter ImagePlaneReorientationTests`, and
through the real ITK by tests/test-image-reorientation-itk.py. Checked here:

* the menu item: in the 2D Viewer menu among the series commands that follow
  Flip Series, right before Split Series by b-value, sent to the nib's
  ViewerStudyCommands object, without a shortcut, at the same place in every
  language's menu with the title its catalog gives, a real translation;
* the old SeriesSameOrientation plugin may still be installed: its name is
  not taken, and its Vector Up option is not brought in;
* the command: validated so that it is enabled with a 2D viewer showing an
  image; it resamples with ITKTransform.reorient2Dimage by the module's
  parameters, without the gantry tilt check that refuses other orientations,
  and opens the result in a new viewer instead of changing the series;
* it lives in a type of its own, not in a hub class, built into the app.
"""
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
sources = root / 'Horos/Sources'
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
TITLE = 'Reorient All Images to Current Image'
ACTION = 'reorientAllImagesToCurrentImage:'
failures = []


def selector(item):
    action = item.find('connections/action')
    return None if action is None else action.get('selector')


def placement(language):
    """(the item, the selectors of the items of its menu, its index), or None."""
    menu = ET.parse(resources / f'{language}.lproj/MainMenu.xib').getroot()
    for parent in menu.iter('menu'):
        children = parent.find('items')
        items = [child for child in (children if children is not None else []) if child.tag == 'menuItem']
        for index, item in enumerate(items):
            if selector(item) == ACTION:
                return item, [selector(each) for each in items], index, parent.get('title'), menu
    return None


english = None
for language in ('en',) + LANGUAGES:
    found = placement(language)
    if found is None:
        failures.append(f'{language}: no item sends {ACTION}')
        continue
    item, selectors, index, menu_title, menu = found
    commands = [obj.get('id') for obj in menu.iter('customObject') if obj.get('customClass') == 'IsiXViewerStudyCommands']
    if len(commands) != 1 or item.find('connections/action').get('target') != commands[0]:
        failures.append(f'{language}: the item is not sent to the ViewerStudyCommands object')
    if 'flipDataSeries:' not in selectors[max(0, index - 4):index]:
        failures.append(f'{language}: the item is not among the series commands that follow Flip Series')
    if index + 1 >= len(selectors) or selectors[index + 1] != 'splitSeriesByBValue:':
        failures.append(f'{language}: the item is not right before Split Series by b-value')
    if item.get('keyEquivalent'):
        failures.append(f'{language}: the item has the shortcut {item.get("keyEquivalent")!r}')
    if language == 'en':
        english = (menu_title, item.get('id'))
        if item.get('title') != TITLE or menu_title != '2D Viewer':
            failures.append(f'English: {item.get("title")!r} in {menu_title!r}, expected {TITLE!r} in 2D Viewer')
        continue
    if english and item.get('id') != english[1]:
        failures.append(f'{language}: the item is not the English one')
    strings = json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(resources / f'{language}.lproj/Localizable.strings')]))
    expected = strings.get(TITLE)
    if not expected or expected == TITLE:
        failures.append(f'{language}: no translation of {TITLE!r}')
    elif item.get('title') != expected:
        failures.append(f'{language}: title {item.get("title")!r}, the catalog says {expected!r}')

english_menu = (resources / 'en.lproj/MainMenu.xib').read_text(encoding='utf-8')
if english_menu.count('id="Rao-ci-Itm"') != 1 or english_menu.count('id="Rao-ci-Act"') != 1:
    failures.append('the ids of the item are not unique')
for name in ('SeriesSameOrientation', 'Vector Up', 'Vector Down'):
    if name in english_menu:
        failures.append(f'the menu takes {name!r} from the old plugin')

commands = (sources / 'ViewerStudyCommands.swift').read_text(encoding='utf-8')
command = (sources / 'ViewerSeriesReorientation.swift').read_text(encoding='utf-8')
for source, needle, what in (
        (commands, f'@objc({ACTION})', 'the command is not implemented under its selector'),
        (commands, 'case #selector(reorientAllImagesToCurrentImage(_:)):', 'the command is not validated'),
        (commands, 'ViewerSeriesReorientation(viewer: $0).isPossible } ?? false', 'the command is not enabled only with a 2D viewer'),
        (command, 'horos_imageView?.curDCM', 'the reference is not the image on screen'),
        (command, 'ImagePlaneReorientation.needsResampling(', 'the images resampled are not those the rule chooses'),
        (command, 'ImagePlaneReorientation.parameters(', 'the resampling does not take the parameters of the rule'),
        (command, 'ImagePlaneReorientation.target(', 'the images do not take the geometry of the rule'),
        (command, 'ITKTransform.reorient2Dimage(', 'the resampling is not the gantry tilt correction\'s'),
        (command, 'setOrientationDouble(', 'the resampled images do not take the reference orientation'),
        (command, 'ViewerController.newWindow(', 'the result does not open in a new viewer'),
        (command, 'addMovieSerie(', 'the other time points are left out'),
        (command, 'checkEverythingLoaded()', 'the pixels are not all read before they are copied'),
):
    if needle not in source:
        failures.append(what)
for needle in ('hasModelOrientation', 'changeImageData', 'replaceSeries', 'Vector', 'SeriesSameOrientation'):
    if needle in command:
        failures.append(f'the command uses {needle!r}')
for name, source in (('ViewerStudyCommands', commands), ('ViewerSeriesReorientation', command)):
    if re.search(r'^\s*(?:public |internal |private |fileprivate )?extension (ViewerController|AppController)\b', source, re.M):
        failures.append(f'{name}.swift extends a hub class')

project = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if project.count('/* ViewerSeriesReorientation.swift in Sources */') != 2 or 'path = ViewerSeriesReorientation.swift;' not in project:
    failures.append('ViewerSeriesReorientation.swift is not built into the app')
if not (root / 'Modules/IsiXImaging/Sources/SeriesOperations/ImagePlaneReorientation.swift').exists():
    failures.append('ImagePlaneReorientation.swift is not in IsiXImaging')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    raise SystemExit(1)
print(f'PASS: Reorient All Images to Current Image is in the 2D Viewer menu of English and {len(LANGUAGES)} languages, '
      'validated, and opens a new viewer')
