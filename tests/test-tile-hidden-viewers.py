#!/usr/bin/env python3
"""Tile Windows asks the list of hidden viewers about viewers, not windows.

The tiling collects the viewers whose window is not visible, places them, and
at the end rebuilds each viewer's series list, with the selection shown for the
viewers that were hidden. That last test once asked whether the list contained
the viewer's window; the list held window controllers, so the answer was always
no. It asks about the viewer itself.

ViewerTilingLayout (IsiXImaging) collects the hidden viewers as places in the
list of window controllers it is given; ViewerWindowArranger turns the places
back into those controllers and asks the list about each viewer. The method
needs viewers, screens and the defaults of a running app, so the sources are
read: what goes into the list and what is looked for in it must be the same kind
of object.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
layout = (ROOT / 'Modules/IsiXImaging/Sources/ViewerWorkspace/ViewerTilingLayout.swift').read_text()
arranger = (ROOT / 'Horos/Sources/ViewerWindowArranger.swift').read_text()
failures = []

start = layout.find('public mutating func arrange(')
if start < 0:
    sys.exit('FAIL: ViewerTilingLayout.arrange is gone')
body = layout[start:layout.index('\n    }\n', start)]

# What goes in: the places of the viewers whose window is not visible.
if not re.search(r'for place in viewers\.indices where !viewers\[place\]\.isVisible \{\s*hidden\.append\(place\)', body):
    failures.append('the hidden viewers are no longer collected as the test expects')

start = arranger.find('private func tile(')
if start < 0:
    sys.exit('FAIL: ViewerWindowArranger.tile is gone')
tile = arranger[start:arranger.index('\n    }\n', start)]

# The places become the window controllers given to the layout.
if not re.search(r'let hidden = arrangement\.hidden\.map \{ controllers\[\$0\] \}', tile):
    failures.append('the hidden places are not turned back into the window controllers')
if not re.search(r'isVisible: window\?\.isVisible \?\? false', arranger):
    failures.append('a viewer is no longer hidden when its window is not visible')

# What is looked for: never a window.
lookups = re.findall(r'hidden\.contains[^\n]*', tile)
if not lookups:
    failures.append('nothing asks the list of hidden viewers any more')
for lookup in lookups:
    if 'window' in lookup:
        failures.append('the list of hidden viewers is asked about a window (%s), and holds viewers' % lookup.strip())

call = re.search(r'for case let (\w+) as ViewerController in tiled\.reversed\(\) where \1 !== key \{\s*\1\.buildMatrixPreview\(hidden\.contains \{ \$0 === \1 \}\)', tile)
if not call:
    failures.append('the series list of a viewer that was hidden is not rebuilt with its selection shown')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: Tile Windows recognises the viewers that were hidden')
