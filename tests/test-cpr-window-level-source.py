#!/usr/bin/env python3
"""A Curved MPR view without an image does not give its window to the others.

The curved view and the three transverse views are empty until a path exists.
A drag of the window tool over one of them left its window at zero, and the
controller copied that to the three planes: a width of zero is a request for
an automatic window, so each plane took the full range of its own image and
the next generated image spread the first plane's to every view. The
controller now takes a window only from a view that shows an image, and the
empty views open with the window of the planes.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

controller = source_text('CPRController')
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


start = controller.index('public dynamic func propagateWLWW(_ sender: DCMView!)')
propagate = controller[start:controller.index('\n    }\n', start)]
guard = propagate.find('guard sender?.curDCM != nil else { return }')
require(guard != -1, 'a view without an image still gives its window to the planes')
require(guard != -1 and 'setWLWW' not in propagate[:guard] and '.wl =' not in propagate[:guard],
        'a window is applied before the sender is known to show an image')
for view in ('mprView1', 'mprView2', 'mprView3', 'cprView', 'topTransverseView', 'middleTransverseView', 'bottomTransverseView'):
    require('%s?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)' % view in propagate,
            '%s no longer follows the window of the view the user changed' % view)

# The initializer: the views a path fills take the 2D viewer's window with the planes.
opening = controller[controller.index('hiddenVRView?.setWLWW(viewer?.imageView()?.curWL ?? 0'):]
opening = opening[:opening.index('let nc = NotificationCenter.default')]
for view in ('cprView', 'topTransverseView', 'middleTransverseView', 'bottomTransverseView'):
    require(re.search(r'%s\?\.setWLWW\(viewer\?\.imageView\(\)\?\.curWL \?\? 0, viewer\?\.imageView\(\)\?\.curWW \?\? 0\)' % view, opening) is not None,
            '%s opens without the window of the 2D viewer' % view)

# The views that call the controller pass themselves or the first plane, never a constant.
for name in ('CPRTransverseView', 'CPRStraightenedView', 'CPRStretchedView'):
    text = source_text(name)
    calls = re.findall(r'propagateWLWW\(([^)]*)\)', text)
    require(calls and all(c.strip() == 'self' or c.strip().endswith('mprView1') for c in calls),
            '%s gives the controller something else than a view: %s' % (name, calls))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the Curved MPR takes a window only from a view that shows an image, and its empty views open with the planes\' window')
