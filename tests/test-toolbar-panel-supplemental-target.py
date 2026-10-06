#!/usr/bin/env python3
"""The 2D toolbar's items without a target work from its panel.

The 2D viewer's toolbar lives in the ToolbarPanelController's own window.
Several of its items have no target (Note, 3D Panel, 3D Position, Flip,
Navigator…) and look for their action along the responder chain. When the
panel is the key window, as the «Customize Toolbar» sheet leaves it, that
chain held only the panel: the items were disabled and did nothing until the
exam was reopened.

Checked in ToolbarPanel.swift:
- ToolbarPanelController answers -supplementalTargetForAction:sender: with the
  viewer's image view, then the viewer, when they respond to the action, and
  not for a viewer that is closing;
- it observes NSWindowDidEndSheetNotification of its window and hands the key
  window back to the viewer.
And in ViewerController+Toolbar.swift, the items it covers still have no
target, so that they reach the viewer this way.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(relative):
    if revision is None:
        return (root / relative).read_text(encoding='utf-8')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


failures = []
panel = code(read('Horos/Sources/ToolbarPanel.swift'))

supplemental = block(panel, 'override func supplementalTarget(forAction action: Selector, sender: Any?)')
if not supplemental:
    failures.append('ToolbarPanelController does not hand its toolbar\'s actions to the viewer '
                    '(no supplementalTarget(forAction:sender:))')
else:
    image = supplemental.find('imageView()')
    viewer = supplemental.find('viewer.responds(to: action)')
    if image < 0 or 'view.responds(to: action)' not in supplemental:
        failures.append('supplementalTarget does not try the viewer\'s image view')
    if viewer < 0:
        failures.append('supplementalTarget does not try the viewer')
    if image >= 0 and viewer >= 0 and image > viewer:
        failures.append('supplementalTarget tries the viewer before its image view')
    if 'windowWillClose()' not in supplemental:
        failures.append('supplementalTarget answers for a viewer that is closing')
    if 'super.supplementalTarget(forAction: action, sender: sender)' not in supplemental:
        failures.append('supplementalTarget does not fall back on super')

if not re.search(r'addObserver\(self, selector: #selector\(windowDidEndSheet\(_:\)\), '
                 r'name: NSWindow\.didEndSheetNotification, object: self\.window\)', panel):
    failures.append('the panel does not observe the end of its customization sheet')
ended = block(panel, 'func windowDidEndSheet(_ aNotification: Notification?)')
if not ended:
    failures.append('the panel has no windowDidEndSheet(_:)')
elif 'viewer.window?.makeKeyAndOrderFront(self)' not in ended:
    failures.append('the end of the customization sheet does not make the viewer the key window again')

toolbar = code(read('Horos/Sources/ViewerController+Toolbar.swift'))
for identifier in ('VRPanelToolbarItemIdentifier', 'StudyNoteToolbarItemIdentifier',
                   'ThreeDPositionToolbarItemIdentifier', 'FlipVerticalToolbarItemIdentifier'):
    body = block(toolbar, f'itemIdent == {identifier} ')
    if not body:
        failures.append(f'{identifier}: item not found')
    elif 'newItem.target = nil' not in body:
        failures.append(f'{identifier}: the item has a target, the panel no longer routes it')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: the 2D toolbar panel routes the actions of its untargeted items to the viewer')
