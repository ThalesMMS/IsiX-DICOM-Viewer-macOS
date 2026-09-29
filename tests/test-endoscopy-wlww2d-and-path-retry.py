#!/usr/bin/env python3
"""The endoscopy's 2D WL/WW item and the Path Assistant's retry (#885).

1. The toolbar item of the MPR (2D) WL/WW view set usesItemFromMenu on the 3D
   popup, the VR controller's, and never on its own, wlww2DPopup.
2. -pathAssistantSetPointB:, when the distance transform had not finished,
   asked the assistant again for up to ten seconds; a path it found then
   (err == 0) was neither drawn in the MPR views nor looked at by the camera.
   The retry now comes first, and what it finds goes through the same
   handling as a path found at once.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(name):
    if revision is None:
        return sources.source_text(name)
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:Horos/Sources/{name}.swift'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def code(text):
    """Without comments, so that what they recall is not taken for code."""
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


viewer = code(read('EndoscopyViewer'))

# 1. The 2D WL/WW item.
item_2d = block(viewer, 'itemIdent.rawValue == WLWW2DToolbarItemIdentifier {')
item_3d = block(viewer, 'itemIdent.rawValue == WLWW3DToolbarItemIdentifier {')
if not item_2d or not item_3d:
    failures.append('the WLWW2D or WLWW3D toolbar item is missing')
if '(wlww2DPopup?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true' not in item_2d:
    failures.append('the WLWW2D item does not set usesItemFromMenu on the 2D popup')
if 'vrController?.wlwwPopup()' in item_2d:
    failures.append('the WLWW2D item changes the 3D popup')
if '(vrController?.wlwwPopup()?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true' not in item_3d:
    failures.append('the WLWW3D item no longer sets usesItemFromMenu on the 3D popup')

# 2. The retry of -pathAssistantSetPointB:.
point_b = block(viewer, 'public dynamic func pathAssistantSetPointB(_ sender: Any!) {')
if not point_b:
    failures.append('-pathAssistantSetPointB: is missing')
retry = block(point_b, 'if err == ERROR_DISTTRANSNOTFINISH {')
success = block(point_b, 'if err == 0 {')
if not retry or not success:
    failures.append('the retry or the handling of a path found is missing')
else:
    if 'createCenterline' not in retry or 'while i < 5' not in retry:
        failures.append('the retry no longer asks the assistant again')
    if point_b.find('if err == ERROR_DISTTRANSNOTFINISH {') > point_b.find('if err == 0 {'):
        failures.append('a path the retry finds does not reach the handling of a path found')
    if 'if err == 0' in retry:
        failures.append('the retry handles a path found apart from a path found at once')
    for needed, what in [('self.updateCenterlineInMPRViews()', 'draw the path in the MPR views'),
                         ('self.setCameraPosition(cpos, focalPoint: fpos)', 'move the camera to the path'),
                         ('flyAssistantPositionIndex = 0', 'start the fly-through at the path')]:
        if needed not in success:
            failures.append(f'a path found does not {what}')
    for message in ('Path Assistant can not find a path from current location.', 'Path Assistant failed to initialize!'):
        if message not in retry:
            failures.append(f'the retry lost the alert «{message}»')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)

print('PASS: the 2D WL/WW item sets its own popup, and a path found on retry is drawn and looked at')
