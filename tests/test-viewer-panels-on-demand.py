#!/usr/bin/env python3
"""The viewer's sheets live in ViewerPanels.xib and are loaded only when used.

Viewer.xib used to hold, besides the viewer window, twenty auxiliary windows
(window level, convolution, CLUT and opacity editors, ROI dialogs, thickness,
fusion type, SUV, comments, DICOM/JPEG/QuickTime export, print, workspace
state). Every viewer opened built them all, about 700 of the nib's 1,055
constraints, and took about twice as long to show its first image. They are
now in ViewerPanels.xib, owned by the viewer too, and
-[ViewerController horosLoadViewerPanels] loads it the first time it is needed.

This checks, in every localization, that the split is complete and that each
use of a panel outlet goes through the loader:
- Viewer.xib keeps only the viewer window; ViewerPanels.xib has the twenty,
  with the same structure in every language, and nothing in one nib points
  into the other;
- every horos_ getter of a panel outlet loads the panels before answering;
- every Objective-C method that touches a panel outlet loads them first,
  unless it is an action only the panels' own controls send (they are loaded
  by then);
- -awakeFromNib, which ViewerPanels.nib sends again to its owner, returns at
  once the second time.

    python3 tests/test-viewer-panels-on-demand.py
"""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
LOADER = '[self horosLoadViewerPanels]'
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def windows(doc):
    return [o for o in doc.find('objects') if o.tag == 'window']


def ids(node):
    return {e.get('id') for e in node.iter() if e.get('id')}


def shape(node):
    # Structure without the translated texts: tags, ids and connections. The
    # tool dependencies are not part of it (ja-JP declares one more).
    return (node.tag, node.get('id'), node.get('destination'), node.get('selector'), node.get('property'),
            [shape(child) for child in node if child.tag != 'dependencies'])


languages = sorted(p.parent.name for p in resources.glob('*.lproj/ViewerPanels.xib'))
check(len(languages) == 10, f'ViewerPanels.xib in {len(languages)} languages, expected 10')
english = ET.parse(resources / 'en.lproj/ViewerPanels.xib').getroot()
for language in languages:
    viewer = ET.parse(resources / language / 'Viewer.xib').getroot()
    panels = ET.parse(resources / language / 'ViewerPanels.xib').getroot()
    check([w.get('id') for w in windows(viewer)] == ['5'],
          f'{language}: Viewer.xib must keep only the viewer window, has {[w.get("userLabel") for w in windows(viewer)]}')
    check(len(windows(panels)) == 20, f'{language}: ViewerPanels.xib has {len(windows(panels))} windows, expected 20')
    check(shape(panels) == shape(english), f'{language}: ViewerPanels.xib differs in structure from English')
    panel_ids = set().union(*(ids(w) for w in windows(panels)))
    viewer_ids = ids(viewer)
    for node in viewer.iter():
        for key in ('destination', 'target'):
            check(node.get(key) not in panel_ids, f'{language}: Viewer.xib points into the panels ({node.get(key)})')
    for node in panels.iter():
        target = node.get('destination') or node.get('target')
        if node.tag in ('outlet', 'action', 'binding') and target and target not in panel_ids:
            check(target in ('-2', '-1', '-3') or panels.find(f".//userDefaultsController[@id='{target}']") is not None,
                  f'{language}: ViewerPanels.xib points out of itself ({target})')
    check(not (panel_ids & viewer_ids - {'-1', '-2', '-3'}), f'{language}: ids shared by both nibs')

owner = next(o for o in english.find('objects') if o.get('id') == '-2')
outlets = sorted({c.get('property') for c in owner.iter('outlet')})
panel_actions = {a.get('selector') for w in windows(english) for a in w.iter('action') if a.get('target') == '-2'}
check(len(outlets) == 106, f'{len(outlets)} panel outlets, expected 106')

ivars_m = root / 'Horos/Sources/ViewerController+SwiftIvars.m'
if ivars_m.exists():
    getters = dict(re.findall(r'- \([^)]*\)\s*horos_(\w+)\n\{\n(.*?)\n\}', ivars_m.read_text(), re.S))
    loader = LOADER
else:
    # The class is Swift: the getters are in ViewerController+PanelOutlets.swift.
    getters = dict(re.findall(r'^    var horos_(\w+): [^{\n]+\{\n(.*?)\n    \}', (root / 'Horos/Sources/ViewerController+PanelOutlets.swift').read_text(), re.S | re.M))
    loader = 'horosLoadViewerPanels()'
    check(len(set(outlets) & set(getters)) >= 90, f'only {len(set(outlets) & set(getters))} panel getters found; the scan needs a new look')
for outlet in outlets:
    if outlet in getters:
        body = getters[outlet]
        check(loader in body and body.index(loader) < body.index('return'),
              f'horos_{outlet} answers without loading the panels')

source = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
use = re.compile(r'(?<![\w.>"])(' + '|'.join(map(re.escape, outlets)) + r')\b(?!\s*:)')
methods = re.split(r'\n(?=[-+]\s*\()', source)
checked = 0
for method in methods:
    signature = method.split('\n', 1)[0]
    if not signature.startswith('-') or signature.rstrip().endswith(';') or '{' not in method:
        continue
    body = method[method.index('{'):]
    code = '\n'.join(line.split('//')[0] for line in body.split('\n'))
    first = use.search(code)
    if not first:
        continue
    selector = ''.join(re.findall(r'(\w+:)', re.sub(r'\([^)]*\)', '', signature))) or signature.split(')')[-1].strip()
    if selector in panel_actions:
        continue
    checked += 1
    check(LOADER in code[:first.start()], f'{signature.strip()} uses {first.group(1)} before loading the panels')
# The window level, slice interval and colour table sheets, the preset-naming
# sheet and the comments sheet are Swift now (ViewerController+WindowLevel,
# +SliceInterval, +ColorTables, +PresetMenus, +CommentsStatus,
# +ContextualMenus), and so are the SUV and brush filter sheets
# (+SUV, +BrushROI): Swift reaches the outlets only through the horos_ getters
# checked above.
if '- (void) completeDragOperation:(ViewerController*) vc' in source:
    check(checked >= 2, f'only {checked} entry points found; the outlet scan no longer matches the source')
else:
    # The fusion sheet a drop opens and the movie export positions are Swift
    # too (+DragAndDrop, +Keyboard): they load the panels before they read
    # the outlets, also those of the class's properties.
    for name, signature in (('ViewerController+DragAndDrop', 'func completeDragOperation(_ vc: ViewerController!)'),
                            ('ViewerController+Keyboard', 'func setCurrentPosition(_ sender: Any!)')):
        swift_source = (root / 'Horos/Sources' / (name + '.swift')).read_text()
        body = swift_source[swift_source.index(signature):]
        body = body[:body.index('\n    }\n')]
        outlet_use = re.compile(r'(?<![\w])(?:horos_)?(' + '|'.join(map(re.escape, outlets)) + r')\b')
        first = outlet_use.search(body)
        check(first is not None, f'{name} no longer uses the panel outlets; the scan needs a new look')
        if first:
            check('horosLoadViewerPanels()' in body[:first.start()], f'{signature} uses {first.group(1)} before loading the panels')
            checked += 1

if '-(void)awakeFromNib' in source:
    awake = source[source.index('-(void)awakeFromNib'):]
    awake = awake[:awake.index('\n}')]
    check(awake.split('{', 1)[1].lstrip().startswith('//') and 'if( [self horosViewerPanelsLoaded])\n        return;' in awake,
          '-awakeFromNib must return at once when ViewerPanels.nib sends it again')
else:
    lifecycle = (root / 'Horos/Sources/ViewerController+Lifecycle.swift').read_text()
    awake = lifecycle[lifecycle.index('    private func awakeFromViewerNib() {'):]
    check(awake.split('{', 1)[1].lstrip().startswith('if horosViewerPanelsLoaded {\n            return\n        }'),
          '-awakeFromNib must return at once when ViewerPanels.nib sends it again')

swift = (root / 'Horos/Sources/ViewerController+Panels.swift').read_text()
check('loadNibNamed("ViewerPanels", owner: self' in swift, 'the loader no longer loads ViewerPanels with the viewer as owner')

if failures:
    raise SystemExit('FAIL:\n  ' + '\n  '.join(failures))
print(f'PASS: 20 panels in ViewerPanels.xib in {len(languages)} languages; {len(outlets)} outlets, '
      f'{checked} entry points and the horos_ getters load them on demand')
