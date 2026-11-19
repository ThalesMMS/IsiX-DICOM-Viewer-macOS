#!/usr/bin/env python3
"""The Stenosis tool of the curved MPR is told of every change of the path.

The tool measures the path it was given and measures again when
-curvedPathDidChange finds other nodes. The views' own edits and the Path
Assistant told it; an undo or a redo of the path, a path loaded from a file,
an imported centerline and the nodes the simplification slider removes or
brings back did not, and the tool kept the measures, the strip and the
outlines of a path that was no longer shown.

Every place of CPRController that gives the window another path, or changes
the nodes of the one it has, shows it through showChangedCurvedPath(), which
tells the tool, or tells it itself. Two places are not changes for the tool:
the update a view sends during a drag, whose end tells it, and the tool's own
move of the transverse section.

    python3 tests/test-stenosis-follows-path-changes.py [<git revision>]

A revision reads the source from it instead of the tree: the negative control.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = 'Horos/Sources/CPRController.swift'
revision = sys.argv[1] if len(sys.argv) > 1 else None
if revision:
    source = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{PATH}'], capture_output=True, check=True).stdout.decode('utf-8')
else:
    source = (ROOT / PATH).read_text(encoding='utf-8')

TELLS = ('showChangedCurvedPath()', 'stenosisTool?.curvedPathDidChange()')
# A drag in progress, and the tool's own move.
NOT_A_CHANGE = {'cprViewDidUpdateCurvedPath', 'stenosisMoveTransverseSection'}
# The private steps of the simplification: their callers show the result once.
STEPS = {'removeCheapestNode': ('removeNode', 'onSliderMove'), 'restoreLastRemovedNode': ('undoLastNodeRemoval', 'onSliderMove')}

functions = {}
for match in re.finditer(r'^    (?:[@\w(): ]+ )?func (\w+)\(', source, re.M):
    opening = source.index('{', match.end())
    depth = 0
    for index in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            functions.setdefault(match.group(1), '')
            functions[match.group(1)] += source[opening:index + 1]
            break

failures = []
shown = functions.get('showChangedCurvedPath', '')
if 'showCurvedPathInViews()' not in shown or TELLS[1] not in shown:
    failures.append('showChangedCurvedPath() does not show the path in the views and tell the Stenosis tool')

CHANGES = re.compile(r'self\.curvedPath = |_curvedPath\?\.(?:insertPatientNode|removeNode|addPatientNode|clearPath)\(|'
                     r'self\.curvedPath\?\.(?:insertPatientNode|removeNode|addPatientNode|clearPath)\(')
changing = sorted(name for name, body in functions.items() if CHANGES.search(body))
if len(changing) < 8:
    failures.append(f'only {changing} change the path: the source is not read as it is written')
for name in changing:
    if name in NOT_A_CHANGE or name == 'setCurvedPathValue':
        continue
    told = [name] if name not in STEPS else list(STEPS[name])
    for teller in told:
        if not any(tell in functions.get(teller, '') for tell in TELLS):
            failures.append(f'{teller} changes the path ({name}) and the Stenosis tool is not told')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: the Stenosis tool is told of the path changed by {", ".join(n for n in changing if n not in NOT_A_CHANGE)}')
