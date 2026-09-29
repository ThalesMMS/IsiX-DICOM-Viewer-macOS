#!/usr/bin/env python3
"""Each window's toolbar has an identifier of its own (#941).

NSToolbar saves a customized toolbar under «NSToolbar Configuration
<identifier>». The Curved MPR used the 3D MPR's identifier, «3DMPR Toolbar
Identifier»: each saved its own items over the other's customization, and at
opening each dropped the items it did not know. The Curved MPR now has its own
identifier; the 3D MPR keeps «3DMPR Toolbar Identifier», so its saved
customization stays.

Checked in the sources: the identifiers of the viewers' toolbars (the literal
or the static string it names) are all different, and the 3D MPR's is still
«3DMPR Toolbar Identifier».

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

FILES = [
    'Horos/Sources/BrowserController+Toolbar.swift',
    'Horos/Sources/CPRController.swift',
    'Horos/Sources/EndoscopyViewer.swift',
    'Horos/Sources/MPRController.swift',
    'Horos/Sources/OrthogonalMPRPETCTViewer.swift',
    'Horos/Sources/OrthogonalMPRViewer.swift',
    'Horos/Sources/XMLController.swift',
    'Horos/Sources/VRController.mm',
    'Horos/Sources/SRController.mm',
    'Horos/Sources/ViewerController+Toolbar.swift',
]


def read(relative):
    if revision is None:
        return (root / relative).read_bytes().decode('latin1')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('latin1')


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


failures = []
owners = {}
for relative in FILES:
    text = code(read(relative))
    names = re.findall(r'Toolbar\(identifier:\s*([^)]+)\)', text) + \
        re.findall(r'initWithIdentifier:\s*([^\]]+)\]', text)
    if not names:
        failures.append(f'{relative}: no toolbar identifier found')
    for name in names:
        name = name.strip()
        if name.startswith('"') or name.startswith('@"'):
            value = name.lstrip('@').strip('"')
        else:
            constant = re.search(rf'\b{re.escape(name)}\b[^=\n]*=\s*@?"([^"]+)"', text)
            if not constant:
                failures.append(f'{relative}: the value of {name} is not in the file')
                continue
            value = constant.group(1)
        owners.setdefault(value, set()).add(relative)

for value, files in sorted(owners.items()):
    if len(files) > 1:
        failures.append(f'«{value}» names the toolbar of {", ".join(sorted(files))}: '
                        'each saves its customization over the others\'')

if 'Horos/Sources/MPRController.swift' not in owners.get('3DMPR Toolbar Identifier', set()):
    failures.append('the 3D MPR no longer uses «3DMPR Toolbar Identifier»: its saved customization would be lost')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print(f'PASS: {len(owners)} toolbar identifiers, one per window')
