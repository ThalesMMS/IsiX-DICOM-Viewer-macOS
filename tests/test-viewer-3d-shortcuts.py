#!/usr/bin/env python3
"""Each entry of the 2D viewer's 2D/3D menu can be a toolbar item of its own.

The 2D/3D toolbar item is a pull-down: two clicks to reach a 3D viewer. Seven
toolbar items, offered in Customize Toolbar and not in the default set, send the
pull-down's own actions with its tags - VRViewer: tells MIP from VR by the tag,
and the slice thickness sheet reopens the viewer by it, which it now also does
for the curved MPR, the orthogonal MPR and the endoscopy. They are disabled
where the pull-down is (a single image of one frame). The menu shortcut
catalogue gains the surface rendering and the endoscopy.
"""
from pathlib import Path
import json
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
failures = []
toolbar = (root / 'Horos/Sources/ViewerController+Toolbar.swift').read_text()
# -sheetDidEnd:returnCode:contextInfo: of the slice interval sheet is Swift.
interval = (root / 'Horos/Sources/ViewerController+SliceInterval.swift').read_text()
catalog = (root / 'Horos/Sources/MenuShortcutCatalog.swift').read_text()
xib = (root / 'Horos/Resources/en.lproj/Viewer.xib').read_text()

popup = xib[xib.index('id="738"'):]
popup = popup[:popup.index('</popUpButton>')]
menu = re.findall(r'<menuItem title="([^"]+)" tag="(\d+)" id="\d+">\s*<connections>\s*<action selector="([^"]+)"', popup)
if len(menu) != 7:
    failures.append('the 2D/3D pull-down has %d entries, not 7' % len(menu))
shortcuts = re.findall(r'ThreeDShortcut\(identifier: "([^"]+)", label: "([^"]+)", title: "([^"]+)", action: NSSelectorFromString\("([^"]+)"\), tag: (\d+), image: "([^"]+)"\)', toolbar)
if len(shortcuts) != 7:
    failures.append('%d shortcuts, not 7' % len(shortcuts))
if sorted((t, int(g), a) for t, g, a in menu) != sorted((t, int(g), a) for _, _, t, a, g, _ in shortcuts):
    failures.append('the shortcuts do not send the pull-down\'s actions and tags:\n%s\n%s' % (menu, shortcuts))
for identifier, label, title, action, tag, image in shortcuts:
    if not ((root / 'Horos/Resources/Icons' / image).exists() or list((root / 'Horos/Resources').rglob(image))):
        failures.append('%s has no icon %s' % (identifier, image))

def block(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]
allowed = block(toolbar, 'func toolbarAllowedItemIdentifiers', 'if AppController.canDisplay12Bit()')
default = block(toolbar, 'func toolbarDefaultItemIdentifiers', '].map')
if 'threeDShortcuts.map(\\.identifier)' not in allowed:
    failures.append('the shortcuts are not offered in Customize Toolbar')
if 'threeDShortcuts' in default or any(s[0] in default for s in shortcuts):
    failures.append('the shortcuts are in the default toolbar')
item = block(toolbar, 'else if let shortcut = threeDShortcuts.first', 'else if itemIdent == NavigatorToolbarItemIdentifier')
for needed in ('newItem.tag = shortcut.tag', 'newItem.action = shortcut.action', 'newItem.target = nil'):
    if needed not in item:
        failures.append('the shortcut item misses %s' % needed)
validate = block(toolbar, 'func validateToolbarItem', 'return enable')
if 'threeDShortcuts.contains' not in validate:
    failures.append('the shortcuts are not disabled for a single image')
sheet = block(interval, '@objc(sheetDidEnd:returnCode:contextInfo:)', '@objc(endThicknessInterval:)')
# The Swift names of the selectors: VRViewer: and SRViewer: are vrViewer(_:) and srViewer(_:).
for tag, selector in (('1', 'cprViewer'), ('8', 'orthogonalMPRViewer'), ('9', 'endoscopyViewer'), ('10', 'mprViewer'), ('3', 'vrViewer'), ('4', 'vrViewer'), ('5', 'srViewer')):
    if not re.search(r'case %s: %s\(contextInfo\)' % (tag, re.escape(selector)), sheet):
        failures.append('the thickness sheet does not reopen tag %s with %s' % (tag, selector))
for selector, tag in (('SRViewer:', '5'), ('endoscopyViewer:', '9')):
    if not re.search(r'selector: "%s", tag: %s' % (re.escape(selector), tag), catalog):
        failures.append('the shortcut catalogue misses %s' % selector)

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
print('PASS: seven toolbar items open the 3D viewers in one click, with the pull-down\'s actions and tags')
