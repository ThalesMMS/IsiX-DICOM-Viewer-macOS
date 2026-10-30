#!/usr/bin/env python3
"""Full screen keeps the zoom of a tiled viewer.

With "No image tiling in full screen" (on by default), the viewer's tiles become
one view when it enters full screen and come back when it leaves. That switch
asked -setImageRows:columns: to rescale, but the view already scales its image
with its own size as it grows from a tile to the screen: the zoom was applied
twice, and every entry and exit zoomed further until the screen showed one flat
region of the image. Both switches in -fullScreenMenu: now leave the scale to
the view.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
viewer = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
failures = []
if '-(IBAction) fullScreenMenu:(id) sender' in viewer:
    start = viewer.index('-(IBAction) fullScreenMenu:(id) sender')
    method = viewer[start:viewer.index('\n}\n', start)]
    switches = re.findall(r'\[self setImageRows: [^\]]*\]', method)
    ending = 'rescale: NO]'
else:
    # The full screen is Swift since ViewerController+FullScreen.swift.
    swift = (root / 'Horos/Sources/ViewerController+FullScreen.swift').read_text()
    start = swift.index('    func fullScreenMenu(_ sender: Any!) {')
    method = swift[start:swift.index('\n    }\n', start)]
    switches = re.findall(r'setImageRows\([^\n]*\)', method)
    ending = 'rescale: false)'

if len(switches) != 2:
    failures.append('expected the two tiling switches of full screen, found %r' % switches)
for call in switches:
    if not call.endswith(ending):
        failures.append('a tiling switch of full screen rescales the zoom again: %s' % call)

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: entering and leaving full screen leave the scale of the tiles to the view')
