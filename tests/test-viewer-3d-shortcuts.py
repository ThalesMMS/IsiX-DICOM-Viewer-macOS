#!/usr/bin/env python3
"""Each entry of the 2D viewer's 2D/3D menu can be a toolbar item of its own.

The 2D/3D toolbar item is a pull-down: two clicks to reach a 3D viewer. Eight
toolbar items, offered in Customize Toolbar and not in the default set, send the
pull-down's own actions with its tags - VRViewer: tells MIP from VR by the tag,
and cprViewer: the curved MPR from Vessel Analysis (tag 11), and the slice
thickness sheet reopens the viewer by it, which it now also does for the curved
MPR, Vessel Analysis, the orthogonal MPR and the endoscopy. They are disabled
where the pull-down is (a single image of one frame). The menu shortcut
catalogue gains the surface rendering, the endoscopy and Vessel Analysis, and
the 3D Viewer menu of every language has the pull-down's eight entries.
"""
from pathlib import Path
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
failures = []
# The items are made by ViewerToolbarItemFactory; their identifiers, lists
# and enablement are IsiXImaging's ViewerToolbarCatalog.
toolbar = (root / 'Horos/Sources/ViewerToolbarItemFactory.swift').read_text()
toolbar_catalog = (root / 'Modules/IsiXImaging/Sources/ViewerMenus/ViewerToolbarCatalog.swift').read_text()
# -sheetDidEnd:returnCode:contextInfo: of the slice interval sheet is Swift.
interval = (root / 'Horos/Sources/ViewerController+SliceInterval.swift').read_text()
catalog = (root / 'Horos/Sources/MenuShortcutCatalog.swift').read_text()
xib = (root / 'Horos/Resources/en.lproj/Viewer.xib').read_text()

popup = xib[xib.index('id="738"'):]
popup = popup[:popup.index('</popUpButton>')]
menu = re.findall(r'<menuItem title="([^"]+)" tag="(\d+)" id="[^"]+">\s*<connections>\s*<action selector="([^"]+)"', popup)
if len(menu) != 8:
    failures.append('the 2D/3D pull-down has %d entries, not 8' % len(menu))
shortcuts = re.findall(r'ThreeDShortcut\(identifier: "([^"]+)", label: "([^"]+)", title: "([^"]+)", action: "([^"]+)", tag: (\d+), image: "([^"]+)"\)', toolbar_catalog)
if len(shortcuts) != 8:
    failures.append('%d shortcuts, not 8' % len(shortcuts))
if sorted((t, int(g), a) for t, g, a in menu) != sorted((t, int(g), a) for _, _, t, a, g, _ in shortcuts):
    failures.append('the shortcuts do not send the pull-down\'s actions and tags:\n%s\n%s' % (menu, shortcuts))
for identifier, label, title, action, tag, image in shortcuts:
    if not ((root / 'Horos/Resources/Icons' / image).exists() or list((root / 'Horos/Resources').rglob(image))):
        failures.append('%s has no icon %s' % (identifier, image))
# The pull-down's entries have no image in the nib: the viewer gives each tag its own as it opens.
life = (root / 'Horos/Sources/ViewerSessionGraph+ViewerLife.swift').read_text()
images = dict(re.findall(r'(\d+): "([^"]+)"', life[life.index('reconstructionMenuImages: [Int: String] = ['):][:400]))
for title, tag, action in menu:
    if tag not in images:
        failures.append('the pull-down\'s %s (tag %s) is given no image' % (title, tag))
    elif not list((root / 'Horos/Resources').rglob(images[tag] + '.*')):
        failures.append('the pull-down\'s %s has no image %s' % (title, images[tag]))

def block(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]
allowed = block(toolbar_catalog, 'public static func allowedIdentifiers', 'if canDisplay12Bit')
default = block(toolbar_catalog, 'public static let defaultIdentifiers', ']')
if 'threeDShortcuts.map(\\.identifier)' not in allowed:
    failures.append('the shortcuts are not offered in Customize Toolbar')
if 'threeDShortcuts' in default or any(s[0] in default for s in shortcuts):
    failures.append('the shortcuts are in the default toolbar')
item = block(toolbar, 'if let shortcut = Catalog.threeDShortcut(itemIdent)', '} else if let bundle')
for needed in ('newItem.tag = shortcut.tag', 'newItem.action = NSSelectorFromString(shortcut.action)', 'newItem.target = nil'):
    if needed not in item:
        failures.append('the shortcut item misses %s' % needed)
validate = block(toolbar_catalog, 'public static func enablement(of', 'public struct ViewerFacts')
if 'threeDShortcut(identifier) != nil ? .severalImages' not in validate or 'case .severalImages: return !facts.singleImageOfOneFrame' not in toolbar_catalog:
    failures.append('the shortcuts are not disabled for a single image')
sheet = block(interval, '@objc(sheetDidEnd:returnCode:contextInfo:)', '@objc(endThicknessInterval:)')
# The Swift names of the selectors: VRViewer: and SRViewer: are vrViewer(_:) and srViewer(_:).
reopened = {tag.strip(): selector for tags, selector in re.findall(r'case ([\d, ]+): (\w+)\(contextInfo\)', sheet)
            for tag in tags.split(',')}
for tag, selector in (('1', 'cprViewer'), ('11', 'cprViewer'), ('8', 'orthogonalMPRViewer'), ('9', 'endoscopyViewer'), ('10', 'mprViewer'), ('3', 'vrViewer'), ('4', 'vrViewer'), ('5', 'srViewer')):
    if reopened.get(tag) != selector:
        failures.append('the thickness sheet does not reopen tag %s with %s' % (tag, selector))
for selector, tag in (('SRViewer:', '5'), ('endoscopyViewer:', '9'), ('cprViewer:', '11')):
    if not re.search(r'selector: "%s", tag: %s' % (re.escape(selector), tag), catalog):
        failures.append('the shortcut catalogue misses %s' % selector)

for main_menu in sorted(root.glob('Horos/Resources/*.lproj/MainMenu.xib')):
    text = main_menu.read_text()
    viewer_menu = text[text.index('id="1281"'):]
    viewer_menu = viewer_menu[:viewer_menu.index('</items>')]
    entries = re.findall(r'<menuItem title="[^"]+" image="[^"]+" tag="(\d+)" id="[^"]+">\s*<connections>\s*<action selector="([^"]+)"', viewer_menu)
    if sorted((int(g), a) for g, a in entries) != sorted((int(g), a) for _, g, a in menu):
        failures.append('%s: the 3D Viewer menu does not have the pull-down\'s entries: %s' % (main_menu.parent.name, entries))

labels = {s[1] for s in shortcuts} | {s[2] for s in shortcuts}
for language in ('en', 'it-IT', 'es', 'ja-JP', 'pt-BR', 'fr', 'de', 'ko', 'hi', 'ar', 'ru', 'zh-Hans'):
    path = root / f'Horos/Resources/{language}.lproj/Localizable.strings'
    present = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
    missing = sorted(l for l in labels if l not in present)
    if missing:
        failures.append('%s lacks %s' % (language, missing))

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: eight toolbar items open the 3D viewers and Vessel Analysis in one click, with the pull-down\'s actions and tags')
