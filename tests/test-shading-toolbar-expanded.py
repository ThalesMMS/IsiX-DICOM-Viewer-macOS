#!/usr/bin/env python3
"""The 3D viewers keep their toolbar in a row of its own (#869).

The Shading item of the MPR and of the endoscopy shows three lines, «Ambient»,
«Diffuse» and «Specular». Since the toolbars went back into the title bar, the
third line was cut there. VR keeps the Expanded style it had, and its item shows
the three lines; the MPR and the endoscopy now set the same style before they
attach their toolbar. The maintainer then asked for the same row in the other
3D viewers: Curved MPR, Orthogonal MPR (and its PET-CT form) and Surface
Rendering. The browser stays in the title bar (Automatic).

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


def read(relative):
    if revision is None:
        return (root / relative).read_bytes().decode('latin1')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('latin1')


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


for name, shading in (('MPRController', 'shadingValues?.stringValue'),
                      ('EndoscopyVRController', 'horos_shadingValues?.stringValue')):
    text = code(read(str(sources.source_path(name).relative_to(root))))
    if shading not in text:
        failures.append(f'{name} no longer writes the three lines of the Shading item')

for name in ('MPRController', 'EndoscopyViewer', 'CPRController', 'OrthogonalMPRViewer',
             'OrthogonalMPRPETCTViewer'):
    text = code(read(str(sources.source_path(name).relative_to(root))))
    setup = block(text, 'public dynamic func setupToolbar()')
    if not setup:
        failures.append(f'{name} lost -setupToolbar')
        continue
    style = setup.find('self.window?.toolbarStyle = .expanded')
    attach = setup.find('self.window?.toolbar = toolbar')
    if style < 0:
        failures.append(f'{name} puts its toolbar in the title bar')
    elif attach < 0 or style > attach:
        failures.append(f'{name} sets the Expanded style after it attaches its toolbar')

sr = code(read('Horos/Sources/SRController.mm'))
setup = block(sr, '- (void) setupToolbar')
style = setup.find('self.window.toolbarStyle = NSWindowToolbarStyleExpanded;')
attach = setup.find('[[self window] setToolbar: toolbar];')
if style < 0:
    failures.append('Surface Rendering puts its toolbar in the title bar')
elif attach < 0 or style > attach:
    failures.append('Surface Rendering sets the Expanded style after it attaches its toolbar')

vr = read('Horos/Sources/VRController.mm')
if 'self.window.toolbarStyle = NSWindowToolbarStyleExpanded;' not in vr:
    failures.append('VR no longer keeps its toolbar in a row of its own')
browser = code(read(str(sources.source_path('BrowserController+Toolbar').relative_to(root))))
if 'self.window?.toolbarStyle = .expanded' not in browser:
    failures.append('the browser puts its toolbar back in the title bar (#984)')
policy = code(read(str(sources.source_path('ToolbarPolicy').relative_to(root))))
if 'toolbarStyle' in policy:
    failures.append('ToolbarPolicy changes the style of every toolbar')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)

print('PASS: the 3D viewers and the browser keep their toolbar in a row of its own')
