#!/usr/bin/env python3
"""Tile Windows asks the list of hidden viewers about viewers, not windows.

`-[AppController tileWindows:windows:display2DViewerToolbar:displayThumbnailsList:]`
collects the viewers whose window is not visible in `hiddenWindows`, places
them, and at the end rebuilds each viewer's series list, with the selection
shown for the viewers that were hidden. That last test asked whether the list
contained the viewer's window; the list holds window controllers, so the
answer was always no (#840). It now asks about the viewer itself.

The method needs viewers, screens and the defaults of a running app, so the
source is read: what goes into the list and what is looked for in it must be
the same kind of object.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

application = sources.source_text('AppController')
failures = []

start = application.find('@objc(tileWindows:windows:display2DViewerToolbar:displayThumbnailsList:)')
if start < 0:
    sys.exit('FAIL: -tileWindows:windows:display2DViewerToolbar:displayThumbnailsList: is gone')
body = application[start:application.index('\n    }\n', start)]

# What goes in: the elements of viewersList, which are window controllers.
if not re.search(r'for v in viewersList \{\s*if \(\(v as\? NSWindowController\)\?\.window\?\.isVisible \?\? false\) == false \{\s*hiddenWindows\.add\(v\)', body):
    failures.append('the hidden viewers are no longer collected as the test expects')

# What is looked for: never a window.
lookups = re.findall(r'hiddenWindows\.contains\(([^)]*)\)', body)
if not lookups:
    failures.append('nothing asks the list of hidden viewers any more')
for argument in lookups:
    if 'window' in argument or '$0' in argument:
        failures.append('hiddenWindows is asked about a window (%s), and holds viewers' % argument.strip())

call = re.search(r'if let (\w+) = v as\? ViewerController \{\s*if \1 !== keyWindow \{[^}]*?buildMatrixPreview\(hiddenWindows\.contains\(\1\)\)', body, re.S)
if not call:
    failures.append('the series list of a viewer that was hidden is not rebuilt with its selection shown')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: Tile Windows recognises the viewers that were hidden')
