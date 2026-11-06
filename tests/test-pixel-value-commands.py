#!/usr/bin/env python3
"""2D Viewer > Invert Pixel Values and ROI > Normalize Series by ROI Mean… are wired.

The pixel rules are IsiXImaging's PixelInversion and ROIMeanNormalization,
tested on synthetic buffers by `swift test --package-path Modules --filter
PixelValue`. This checks the rest: where the items are in every menu, the
actions they send to the main menu's ViewerStudyCommands object, which
validates them, that the app hands the pixels to those rules and shows the
result outside the ViewerController hub, that it does not take the names of
the former Invert Data plugin, and that the file is compiled into the app.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
source = (root / 'Horos/Sources/ViewerPixelValues.swift').read_text(encoding='utf-8')
commands = (root / 'Horos/Sources/ViewerStudyCommands.swift').read_text(encoding='utf-8')
COMMANDS_OBJECT = 'Vsc-cm-Obj'


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


def items(menu):
    """The (id, (selector, target)) of each menu item, in the order of the file."""
    found = []
    for match in re.finditer(r'<menuItem\b[^>]*\bid="([^"]+)"[^>]*?(/?)>', menu):
        if match[2] == '/':
            found.append((match[1], None))
            continue
        end = menu.index('</menuItem>', match.end())
        nested = menu.find('<menuItem', match.end())
        body = menu[match.end():end if nested == -1 or nested > end else nested]
        action = re.search(r'<action selector="([^"]+)" target="([^"]+)"', body)
        found.append((match[1], (action[1], action[2]) if action else None))
    return found


def follows(order, before, after):
    ids = [identifier for identifier, _ in order]
    return before in ids and after in ids and ids.index(after) == ids.index(before) + 1


languages = sorted(path.parent.name for path in resources.glob('*.lproj/MainMenu.xib'))
if 'en.lproj' not in languages or len(languages) < 12:
    fail(f'expected the English menu and its translations, found {languages}')
for language in languages:
    order = items((resources / language / 'MainMenu.xib').read_text(encoding='utf-8'))
    actions = dict(order)
    if actions.get('Inv-pv-Itm') != ('invertPixelValues:', COMMANDS_OBJECT):
        fail(f'{language}: Invert Pixel Values does not send invertPixelValues: to the ViewerStudyCommands object')
    if actions.get('Nrm-rm-Itm') != ('normalizeSeriesByROIMean:', COMMANDS_OBJECT):
        fail(f'{language}: Normalize Series by ROI Mean… does not send normalizeSeriesByROIMean: to the ViewerStudyCommands object')
    if not follows(order, '13190', 'Inv-pv-Itm'):
        fail(f'{language}: Invert Pixel Values is not right after Flip Series')
    if not follows(order, '11232', 'Nrm-rm-Itm'):
        fail(f'{language}: Normalize Series by ROI Mean… is not right after Set Pixel Values to...')
print(f'PASS: both items in place in {len(languages)} menus')

english = (resources / 'en.lproj/MainMenu.xib').read_text(encoding='utf-8')
for title in ('title="Invert Pixel Values" id="Inv-pv-Itm"', 'title="Normalize Series by ROI Mean…" id="Nrm-rm-Itm"'):
    if title not in english:
        fail(f'the English menu lost {title}')

if f'id="{COMMANDS_OBJECT}"' not in english or 'customClass="IsiXViewerStudyCommands"' not in english:
    fail('the English menu has no ViewerStudyCommands object')
for needle, why in (
    ('@objc(invertPixelValues:)', 'have the Invert Pixel Values action'),
    ('@objc(normalizeSeriesByROIMean:)', 'have the Normalize Series by ROI Mean… action'),
    ('@objc(normalizeSeriesOfViewer:byROIMeanWithMultiplier:)', 'can normalize without its dialog'),
    ('ViewerPixelValues(viewer: viewer).invert()', 'hand Invert Pixel Values to ViewerPixelValues'),
    ('ViewerPixelValues(viewer: viewer).normalizeAskingForMultiplier()', 'hand the normalization to ViewerPixelValues'),
):
    if needle not in commands:
        fail(f'the menu commands no longer {why}: {needle!r} is missing')
validate = commands[commands.index('func validateMenuItem(_ item: NSMenuItem) -> Bool'):]
validate = validate[:validate.index('\n    }\n')]
if 'case #selector(invertPixelValues(_:)), #selector(normalizeSeriesByROIMean(_:)):\n            return StudyViewers.databaseViewer() != nil' not in validate:
    fail('the two items are not enabled for a 2D viewer of database images')
for name, text in (('ViewerPixelValues.swift', source), ('ViewerStudyCommands.swift', commands)):
    if re.search(r'^\s*(?:public |internal )?extension ViewerController\b', text, re.M):
        fail(f'{name} extends the ViewerController hub; the commands go to types of their own')

for needle, why in (
    ('func normalize(multiplier:', 'can normalize without its dialog'),
    ('PixelInversion.invertGrayscale(', 'inverts grayscale with the rule of IsiXImaging'),
    ('PixelInversion.invertARGB(', 'inverts colour with the rule of IsiXImaging'),
    ('PixelInversion.window(', 'moves the window level of the inverted image'),
    ('ROIMeanNormalization.factor(', 'divides by the ROI mean with the rule of IsiXImaging'),
    ('ROIMeanNormalization.scale(', 'scales the pixels with the rule of IsiXImaging'),
    ('ROIMeanNormalization.window(', 'scales the window level with the pixels'),
    ('viewer.selectedROI()', 'reads the selected ROI'),
    ('horos_movieCount', 'changes every time point'),
    ('checkEverythingLoaded()', 'waits for every image before changing them'),
    ('computePixMinPixMax()', 'computes the range of each image again'),
    ('kill8bitsImage()', 'redraws each image from its new pixels'),
    ('needsDisplayUpdate()', 'refreshes the viewer'),
    ('recomputeROIs(in: viewer)', 'measures the ROIs again'),
    ('.OsirixUpdateVolumeData', 'tells the MPR and 3D views the volume changed'),
    ('Select a ROI first.', 'explains what is missing without a ROI'),
    ('Only grayscale series can be normalized.', 'explains why a colour series is not normalized'),
):
    if needle not in source:
        fail(f'the commands no longer {why}: {needle!r} is missing')

# The former plugin may still be installed and loaded: its title, filter
# class and selectors stay its own.
for former in ('"Invert Data"', 'InvertDataFilter', 'InvertData', 'NormalizeFilter', 'filterImage:'):
    if former in source or former in commands:
        fail(f'the native commands take a name of the former plugin: {former}')

pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if pbx.count('ViewerPixelValues.swift in Sources') != 2 or 'path = ViewerPixelValues.swift;' not in pbx:
    fail('ViewerPixelValues.swift is not compiled into the app')
print('PASS: actions, refresh and build wiring')
