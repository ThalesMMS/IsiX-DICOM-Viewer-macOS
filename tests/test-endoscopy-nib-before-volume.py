#!/usr/bin/env python3
"""The endoscopy viewer loads its nib before handing the volume to its controllers.

-[EndoscopyViewer initWithPixList:::::] sends the 3D and MPR controllers of
Endoscopy.xib their initializers again. NSWindowController loads the nib when
its window is first asked for; until then the outlets are nil. The Objective-C
initializer asked for the window first ([[self window]
setShowsResizeIndicator:]); its Swift translation dropped that call, so the 3D
controller's initializer went to nil, answered nil, the viewer took it as a
refused volume and returned nil: Endoscopy opened nothing.

Checked in EndoscopyViewer.swift: the initializer asks for its window after
self.init(windowNibName:) and before HorosEndoscopyVRControllerReinit.

`<git revision>` as an optional argument reads that revision, the negative
control.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/EndoscopyViewer.swift'

if revision:
    source = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
else:
    source = (root / path).read_text()

start = source.find('@objc(initWithPixList:::::)')
nib = source.find('self.init(windowNibName: "Endoscopy")', start)
reinit = source.find('HorosEndoscopyVRControllerReinit(', start)
if start < 0 or nib < 0 or reinit < 0:
    print('FAIL: the initializer, its nib or its 3D controller call not found')
    sys.exit(1)
between = '\n'.join(line.split('//', 1)[0] for line in source[nib:reinit].splitlines())
if 'self.window' not in between and 'loadWindow' not in between:
    print('FAIL: the volume goes to the 3D controller before the nib is loaded: its outlet is nil')
    sys.exit(1)
print('PASS: the endoscopy viewer loads its nib before its controllers take the volume')
